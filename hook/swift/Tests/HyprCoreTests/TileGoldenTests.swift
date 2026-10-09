// Золотой тест раскладки: 400 случайных деревьев/параметров, прогнанных через REFERENCE_tile.py
// (insert/remove/переворот сплита/ratio, минимумы, зазоры), — Swift должен дать те же деревья после
// каждого шага, те же boxes/with_gaps/округление, need, neighbour и find_parent.
@testable import HyprCore
import XCTest

final class TileGoldenTests: XCTestCase {
    func at(_ n: Node, _ p: String) -> Node {
        var n = n
        for c in p { n = c == "a" ? n.a : n.b }
        return n
    }

    func testGolden() throws {
        let cases = try Fx.load("tile_golden.json").array!
        XCTAssertEqual(cases.count, 400)
        var checked = 0
        for (ci, c) in cases.enumerated() {
            let go = c["gaps_out"]!
            let t = Dwindle(gapsIn: c["gaps_in"]!.double!,
                            gapsOut: Gaps(top: go["top"]!.double!, right: go["right"]!.double!,
                                          bottom: go["bottom"]!.double!, left: go["left"]!.double!),
                            splitWidthMult: c["swm"]!.double!, defaultRatio: c["ratio"]!.double!)
            for (k, v) in c["mins"]!.object! { t.mins[Int(k)!] = (v.array![0].double!, v.array![1].double!) }
            let area = Rect.j(c["area"])!
            var tree: Node?
            for (oi, op) in c["ops"]!.array!.enumerated() {
                switch op["op"]!.string! {
                case "insert": tree = t.insert(tree, op["wid"]!.int!, op["target"]!.int, area)
                case "remove": tree = Dwindle.remove(tree, op["wid"]!.int!)
                case "toggle":
                    let n = at(tree!, op["path"]!.string!)
                    n.split = n.split == "v" ? "h" : "v"
                case "ratio": at(tree!, op["path"]!.string!).ratio = op["value"]!.double!
                default: XCTFail("операция?")
                }
                if let d = jsonDiff(tree?.json ?? .null, op["tree"]!) {
                    XCTFail("случай \(ci) шаг \(oi) (\(op["op"]!.string!)): дерево \(d)")
                    return
                }
            }
            let res = c["result"]!
            let bx = t.boxes(tree, area)
            let got = JSON.array(bx.map { .array([.int($0.0), $0.1.json]) })
            if let d = jsonDiff(got, res["boxes"]!) { XCTFail("случай \(ci): boxes \(d)"); return }
            let g = JSON.array(bx.map { .array([.int($0.0), t.withGaps($0.1, area).json]) })
            if let d = jsonDiff(g, res["gaps"]!) { XCTFail("случай \(ci): with_gaps \(d)"); return }
            var rects = OrderedMap<Int, Rect>()
            for (w, b) in bx {
                let r = t.withGaps(b, area)
                rects[w] = Rect(pyRound(r.x), pyRound(r.y), pyRound(r.w), pyRound(r.h))
            }
            let rr = JSON.array(rects.map { .array([.int($0.0), $0.1.json]) })
            if let d = jsonDiff(rr, res["rounded"]!, tol: 0) { XCTFail("случай \(ci): округление \(d)"); return }
            if let tree {
                let (nw, nh) = t.need(tree)
                if let d = jsonDiff(.array([.double(nw), .double(nh)]), res["need"]!) { XCTFail("случай \(ci): need \(d)"); return }
            }
            for nb in res["neighbour"]!.array! {
                let a = nb.array!
                let n = Dwindle.neighbour(rects, a[0].int!, a[1].string!)
                XCTAssertEqual(n, a[2].int, "случай \(ci): neighbour \(a[0].int!) \(a[1].string!)")
            }
            for p in res["parents"]!.array! {
                let a = p.array!
                let par = Dwindle.findParent(tree, a[0].int!)
                if a[1].isNull { XCTAssertNil(par, "случай \(ci): find_parent \(a[0].int!)") } else {
                    XCTAssertEqual(par?.split, a[1]["split"]!.string)
                    XCTAssertEqual(par.flatMap { Dwindle.leaves($0.a)[0].wid }, a[1]["a"]!.int)
                }
            }
            checked += 1
        }
        XCTAssertEqual(checked, 400)
    }

    /// Ничья в neighbour и порядок: берётся первое по порядку rects (как dict в Python).
    func testNeighbourTieTakesFirst() {
        var r = OrderedMap<Int, Rect>()
        r[1] = Rect(0, 0, 100, 100)
        r[3] = Rect(100, -50, 100, 100)
        r[2] = Rect(100, 50, 100, 100)
        XCTAssertEqual(Dwindle.neighbour(r, 1, "right"), 3)
    }

    /// round() Python — половина к чётному.
    func testPyRound() {
        XCTAssertEqual(pyRound(2.5), 2)
        XCTAssertEqual(pyRound(3.5), 4)
        XCTAssertEqual(pyRound(-0.5), -0)
    }
}
