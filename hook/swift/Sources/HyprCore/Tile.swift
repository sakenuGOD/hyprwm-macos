// Раскладка dwindle — порт 1:1 hook/scripts/tile.py (insert/remove/need/split_box/boxes/with_gaps/
// find_parent/neighbour). Дерево — ссылочные узлы, как dict в Python: демон правит узлы на месте
// (find_parent -> split/ratio, подмена wid у вкладки), поэтому значения-структуры не годятся.
import Foundation

public final class Node {
    public var wid: Int?                 // лист: номер окна
    public var split: String = "v"       // "v" — слева/справа, "h" — сверху/снизу
    public var ratio: Double?            // nil — ключа нет (в Python node.get("ratio", 0.5))
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

    // ── JSON (формат hyprwm.state.json) ─────────────────────────────────
    public static func from(_ j: JSON?) -> Node? {
        guard let j, case .object = j else { return nil }
        if let w = j["wid"] { return Node(leaf: w.int ?? 0) }
        guard let a = from(j["a"]), let b = from(j["b"]) else { return nil }
        return Node(split: j["split"]?.string ?? "v", ratio: j["ratio"]?.double, a: a, b: b)
    }
    public var json: JSON {
        if let w = wid { return .object([("wid", .int(w))]) }
        var kv: [(String, JSON)] = [("split", .string(split))]
        if let r = ratio { kv.append(("ratio", .double(r))) }
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
    public var values: [Double] { [top, right, bottom, left] }   // порядок GAPS_OUT в hyprcfg.gaps()
}

/// Параметры и «глобальные» таблицы tile.py (GAPS_IN, GAPS_OUT, SPLIT_WIDTH_MULT, DEFAULT_RATIO, MINS).
/// MINS — состояние модуля: в Python его выставляет WM.layout(), и им пользуются все следующие вызовы
/// (insert/move_dir/resize_active) до следующего layout(). Здесь поведение то же.
public final class Dwindle {
    public static let minW = 200.0, minH = 150.0
    public var gapsIn: Double
    public var gapsOut: Gaps
    public var splitWidthMult: Double
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

    /// Убрать лист; второй ребёнок занимает место родителя (как dwindle).
    public static func remove(_ n: Node?, _ wid: Int) -> Node? {
        guard let n else { return nil }
        if let w = n.wid { return w == wid ? nil : n }
        let a = remove(n.a, wid), b = remove(n.b, wid)
        guard let a else { return b }
        guard let b else { return a }
        n.a = a; n.b = b
        return n
    }

    /// Разделить лист target (или первый лист, если target == nil) пополам, новое окно — вторым.
    /// В Python «вставилось ли в a» определяется сравнением json.dumps до/после; это ровно
    /// «target == nil или target есть в a» (вставка в найденный лист всегда меняет дерево).
    public func insert(_ n: Node?, _ wid: Int, _ target: Int?, _ box: Rect) -> Node {
        guard let n else { return Node(leaf: wid) }
        if let w = n.wid {
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

    /// Минимальный размер плитки под поддерево (с зазорами вокруг окна).
    public func need(_ n: Node) -> (Double, Double) {
        if let w = n.wid {
            var (mw, mh) = mins[w] ?? (Dwindle.minW, Dwindle.minH)
            mw = max(mw, Dwindle.minW); mh = max(mh, Dwindle.minH)   // выученный 0 по оси — не меньше дефолта
            let pad = 2 * max(gapsIn, gapsOut.values.max()!)          // худший случай: плитка у края экрана
            return (mw + pad, mh + pad)
        }
        let (aw, ah) = need(n.a), (bw, bh) = need(n.b)
        if n.split == "v" { return (aw + bw, max(ah, bh)) }
        return (max(aw, bw), ah + bh)
    }

    /// Деление по ratio, но так, чтобы обе части вмещали минимумы своих поддеревьев.
    public func splitBox(_ box: Rect, _ n: Node) -> (Rect, Rect) {
        let (x, y, w, h) = (box.x, box.y, box.w, box.h)
        let r = n.ratio ?? 0.5
        let (aw, ah) = need(n.a), (bw, bh) = need(n.b)
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

    /// Зазоры: у края экрана gaps_out, внутри gaps_in с каждой стороны (как в Hyprland).
    public func withGaps(_ box: Rect, _ area: Rect) -> Rect {
        let eps = 1.0
        let l = abs(box.x - area.x) < eps ? gapsOut.left : gapsIn
        let t = abs(box.y - area.y) < eps ? gapsOut.top : gapsIn
        let r = abs((box.x + box.w) - (area.x + area.w)) < eps ? gapsOut.right : gapsIn
        let b = abs((box.y + box.h) - (area.y + area.h)) < eps ? gapsOut.bottom : gapsIn
        return Rect(box.x + l, box.y + t, max(Dwindle.minW, box.w - l - r), max(Dwindle.minH, box.h - t - b))
    }

    public static func findParent(_ n: Node?, _ wid: Int?, _ par: Node? = nil) -> Node? {
        guard let n, let wid else { return nil }
        if let w = n.wid { return w == wid ? par : nil }
        return findParent(n.a, wid, n) ?? findParent(n.b, wid, n)
    }

    /// Ближайшее окно в стороне direction от окна wid (по центрам плиток). Ничья — первое по порядку rects.
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
            default: ok = false            // в Python — KeyError; сюда попадают только l/r/u/d
            }
            if !ok { continue }
            let d = abs(dx) + abs(dy)
            if bestd == nil || d < bestd! { best = other; bestd = d }
        }
        return best
    }
}
