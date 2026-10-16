// Dwindle layout: 1:1 port of hook/scripts/tile.py (insert/remove/need/split_box/boxes/with_gaps/
// find_parent/neighbour). Tree nodes are references, like Python dicts: the daemon edits nodes in place
// (find_parent -> split/ratio, replacing a tab wid), so value-type structs are unsuitable.
import Foundation

public final class Node {
    public var wid: Int?                 // leaf: window ID
    public var split: String = "v"       // "v": left/right; "h": top/bottom
    public var manualRatio = false
    public var manualSplit = false
    public var ratio: Double?            // nil means the key is absent (Python node.get("ratio", 0.5))
    public var a: Node!
    public var b: Node!

    public init(leaf wid: Int) { self.wid = wid }
    public init(split: String, ratio: Double?, a: Node, b: Node) {
        self.split = split; self.ratio = ratio; self.a = a; self.b = b
    }
    public var isLeaf: Bool { wid != nil }

    public func contains(_ w: Int) -> Bool {
        if let x = wid { return x == w }
        return a.contains(w) || b.contains(w)
    }

    // JSON (hyprwm.state.json format)
    public static func from(_ j: JSON?) -> Node? {
        guard let j, case .object = j else { return nil }
        if let w = j["wid"] { return Node(leaf: w.int ?? 0) }
        guard let a = from(j["a"]), let b = from(j["b"]) else { return nil }
        let node = Node(split: j["split"]?.string ?? "v", ratio: j["ratio"]?.double, a: a, b: b)
        node.manualRatio = j["manual_ratio"]?.truthy ?? false
        node.manualSplit = j["manual_split"]?.truthy ?? false
        return node
    }
    public var json: JSON {
        if let w = wid { return .object([("wid", .int(w))]) }
        var kv: [(String, JSON)] = [("split", .string(split))]
        if let r = ratio { kv.append(("ratio", .double(r))) }
        if manualRatio { kv.append(("manual_ratio", .bool(true))) }
        if manualSplit { kv.append(("manual_split", .bool(true))) }
        kv.append(("a", a.json))
        kv.append(("b", b.json))
        return .object(kv)
    }
}

public struct Gaps: Equatable {
    public var top, right, bottom, left: Double
    public init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top; self.right = right; self.bottom = bottom; self.left = left
    }
    public var values: [Double] { [top, right, bottom, left] }   // GAPS_OUT order in hyprcfg.gaps()
}

/// tile.py parameters and global tables (GAPS_IN, GAPS_OUT, SPLIT_WIDTH_MULT, DEFAULT_RATIO, MINS).
/// MINS is module state: Python WM.layout() sets it, and subsequent calls use it
/// (insert/move_dir/resize_active) until the next layout(). Same behavior here.
public final class Dwindle {
    public static let minW = 200.0, minH = 150.0
    public var gapsIn: Double
    public var gapsOut: Gaps
    public var splitWidthMult: Double
    public var minimumPolicy = "native"
    public var constrainFrames = false
    public var defaultRatio: Double
    public var mins: [Int: (Double, Double)] = [:]

    public init(gapsIn: Double, gapsOut: Gaps, splitWidthMult: Double = 1.0, defaultRatio: Double = 0.5) {
        self.gapsIn = gapsIn; self.gapsOut = gapsOut; self.splitWidthMult = splitWidthMult; self.defaultRatio = defaultRatio
    }

    public static func leaves(_ n: Node?) -> [Node] {
        guard let n else { return [] }
        if n.isLeaf { return [n] }
        return leaves(n.a) + leaves(n.b)
    }

    /// Remove a leaf; its sibling replaces the parent (as in dwindle).
    public static func remove(_ n: Node?, _ wid: Int) -> Node? {
        guard let n else { return nil }
        if let w = n.wid { return w == wid ? nil : n }
        let a = remove(n.a, wid), b = remove(n.b, wid)
        guard let a else { return b }
        guard let b else { return a }
        n.a = a; n.b = b
        return n
    }

    /// Closing a sibling gives a promoted subtree a different aspect box.
    /// Re-evaluate its automatic splits there, keeping leaf order and ratios.
    /// Explicit directions and manually dragged dividers retain their axis.
    public func removeReorientingPromoted(_ tree:Node?,_ wid:Int,in area:Rect) -> Node? {
        var promoted=Set<ObjectIdentifier>()
        func remove(_ node:Node?) -> Node? {
            guard let node else{return nil}
            if let leaf=node.wid {return leaf==wid ? nil:node}
            let a=remove(node.a),b=remove(node.b)
            guard let a else {if let b {promoted.insert(ObjectIdentifier(b))};return b}
            guard let b else {promoted.insert(ObjectIdentifier(a));return a}
            node.a=a;node.b=b;return node
        }
        let result=remove(tree)
        func orient(_ node:Node?,_ box:Rect,_ expanded:Bool) {
            guard let node,!node.isLeaf else{return}
            let expanded=expanded || promoted.contains(ObjectIdentifier(node))
            if expanded && !node.manualSplit && !node.manualRatio {
                node.split=box.w>box.h*splitWidthMult ? "v":"h"
            }
            let (a,b)=splitBox(box,node)
            orient(node.a,a,expanded);orient(node.b,b,expanded)
        }
        orient(result,area,false)
        return result
    }

    /// Split target (or the first leaf if target == nil) in half; the new window is second.
    /// Python detects insertion into a by comparing json.dumps before/after; this is equivalent to
    /// target == nil or target being in a (inserting into a found leaf always changes the tree).
    public func insert(_ n: Node?, _ wid: Int, _ target: Int?, _ box: Rect) -> Node {
        guard let n else { return Node(leaf: wid) }
        if let w = n.wid {
            if w == 0 { return Node(leaf: wid) }
            if let t = target, w != t { return n }
            let split = box.w > box.h * splitWidthMult ? "v" : "h"
            return Node(split: split, ratio: defaultRatio, a: n, b: Node(leaf: wid))
        }
        let (ba, bb) = splitBox(box, n)
        if target == nil || n.a.contains(target!) {
            n.a = insert(n.a, wid, target, ba)
        } else {
            n.b = insert(n.b, wid, target, bb)
        }
        return n
    }

    /// Minimum tile size for a subtree (including gaps around windows).
    public func need(_ n: Node, learned:Bool=true) -> (Double, Double) {
        if let w = n.wid {
            var (mw, mh) = learned ? mins[w] ?? (Dwindle.minW, Dwindle.minH) : (Dwindle.minW,Dwindle.minH)
            mw = max(mw, Dwindle.minW); mh = max(mh, Dwindle.minH)   // a learned zero on an axis cannot lower the default
            let pad = 2 * max(gapsIn, gapsOut.values.max()!)          // worst case: tile at the screen edge
            return (mw + pad, mh + pad)
        }
        let (aw, ah) = need(n.a,learned:learned), (bw, bh) = need(n.b,learned:learned)
        if n.split == "v" { return (aw + bw, max(ah, bh)) }
        return (max(aw, bw), ah + bh)
    }

    /// Split by ratio while fitting both subtrees within their minimum sizes.
    public func splitBox(_ box: Rect, _ n: Node) -> (Rect, Rect) {
        let (x, y, w, h) = (box.x, box.y, box.w, box.h)
        let r = n.ratio ?? 0.5
        let ratioOnly = minimumPolicy == "ratio" || n.manualRatio
        let (aw, ah) = need(n.a,learned:!constrainFrames || !ratioOnly), (bw, bh) = need(n.b,learned:!constrainFrames || !ratioOnly)
        if ratioOnly && !constrainFrames {
            if n.split == "v" { return (Rect(x, y, w*r, h), Rect(x+w*r, y, w*(1-r), h)) }
            return (Rect(x, y, w, h*r), Rect(x, y+h*r, w, h*(1-r)))
        }
        if n.split == "v" {
            let wa = aw + bw <= w ? min(max(w * r, aw), max(w - bw, 0)) : w * aw / (aw + bw)
            return (Rect(x, y, wa, h), Rect(x + wa, y, w - wa, h))
        }
        let ha = ah + bh <= h ? min(max(h * r, ah), max(h - bh, 0)) : h * ah / (ah + bh)
        return (Rect(x, y, w, ha), Rect(x, y + ha, w, h - ha))
    }

    public func boxes(_ n: Node?, _ box: Rect) -> OrderedMap<Int, Rect> {
        var out = OrderedMap<Int, Rect>()
        boxes(n, box, &out)
        return out
    }
    private func boxes(_ n: Node?, _ box: Rect, _ out: inout OrderedMap<Int, Rect>) {
        guard let n else { return }
        if let w = n.wid { out[w] = box; return }
        let (ba, bb) = splitBox(box, n)
        boxes(n.a, ba, &out)
        boxes(n.b, bb, &out)
    }

    /// Gaps: gaps_out at screen edges, gaps_in on each interior side (as in Hyprland).
    public func withGaps(_ box: Rect, _ area: Rect) -> Rect {
        let eps = 1.0
        let l = abs(box.x - area.x) < eps ? gapsOut.left : gapsIn
        let t = abs(box.y - area.y) < eps ? gapsOut.top : gapsIn
        let r = abs((box.x + box.w) - (area.x + area.w)) < eps ? gapsOut.right : gapsIn
        let b = abs((box.y + box.h) - (area.y + area.h)) < eps ? gapsOut.bottom : gapsIn
        if constrainFrames {
            // A client minimum cannot enlarge its viewport across a partition.
            // When overcrowded, reduce gaps and clip the client inside its box.
            let sx=l+r>0 ? min(1,max(0,box.w-1)/(l+r)):1
            let sy=t+b>0 ? min(1,max(0,box.h-1)/(t+b)):1
            return Rect(box.x+l*sx,box.y+t*sy,max(1,box.w-(l+r)*sx),max(1,box.h-(t+b)*sy))
        }
        return Rect(box.x + l, box.y + t, max(Dwindle.minW, box.w - l - r), max(Dwindle.minH, box.h - t - b))
    }

    public static func findParent(_ n: Node?, _ wid: Int?, _ par: Node? = nil) -> Node? {
        guard let n, let wid else { return nil }
        if let w = n.wid { return w == wid ? par : nil }
        return findParent(n.a, wid, n) ?? findParent(n.b, wid, n)
    }

    /// Nearest window in direction from wid (tile centers). Ties use the first entry in rects order.
    public static func neighbour(_ rects: OrderedMap<Int, Rect>, _ wid: Int, _ dir: String) -> Int? {
        guard let me = rects[wid] else { return nil }
        let cx = me.x + me.w / 2, cy = me.y + me.h / 2
        var best: Int?, bestd: Double?
        for (other, o) in rects {
            if other == wid { continue }
            let dx = o.x + o.w / 2 - cx, dy = o.y + o.h / 2 - cy
            let ok: Bool
            switch dir {
            case "left": ok = dx < -1 && abs(dy) < max(me.h, o.h) / 2 + 1
            case "right": ok = dx > 1 && abs(dy) < max(me.h, o.h) / 2 + 1
            case "up": ok = dy < -1 && abs(dx) < max(me.w, o.w) / 2 + 1
            case "down": ok = dy > 1 && abs(dx) < max(me.w, o.w) / 2 + 1
            default: ok = false            // Python raises KeyError; only l/r/u/d reach here
            }
            if !ok { continue }
            let d = abs(dx) + abs(dy)
            if bestd == nil || d < bestd! { best = other; bestd = d }
        }
        return best
    }
}
