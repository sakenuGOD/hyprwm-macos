// Конфиг: hyprcfg.animation/curves/gaps/dwindle и engine.anim/ids — против ответа эталонного Python
// на той же копии hypr_cfg.json.
@testable import HyprCore
import XCTest

final class ConfigGoldenTests: XCTestCase {
    func testGolden() throws {
        let cfg = try Fx.config()
        let g = try Fx.load("config_golden.json")
        let (gi, go) = cfg.gaps()
        XCTAssertEqual(gi, g["gaps"]!.array![0].double)
        let gj = g["gaps"]!.array![1]
        XCTAssertEqual(go, Gaps(top: gj["top"]!.double!, right: gj["right"]!.double!, bottom: gj["bottom"]!.double!,
                                left: gj["left"]!.double!))
        let t = cfg.makeDwindle()
        XCTAssertEqual(t.splitWidthMult, g["dwindle"]!["swm"]!.double)
        XCTAssertEqual(t.defaultRatio, g["dwindle"]!["ratio"]!.double)
        for (name, id) in g["ids"]!.object! { XCTAssertEqual(cfg.curveIDs[name], id.int, "номер кривой \(name)") }
        XCTAssertEqual(cfg.curveIDs.count, g["ids"]!.object!.count)
        for (leaf, a) in g["animations"]!.object! {
            let s = cfg.animation(leaf)
            XCTAssertEqual(s.enabled, a["enabled"]!.truthy, leaf)
            XCTAssertEqual(s.speed, a["speed"]!.double, leaf)
            XCTAssertEqual(s.kind, a["kind"]!.string, leaf)
            XCTAssertEqual(s.curve, a["curve"]!.string, leaf)
            XCTAssertEqual(s.style, a["style"]!.string, leaf)
            XCTAssertEqual(s.node, a["node"]!.string, leaf)
        }
        for (leaf, e) in g["anim"]!.object! {
            let x = cfg.anim(leaf), arr = e.array!
            XCTAssertEqual(x.curve, arr[0].int, leaf)
            XCTAssertEqual(x.dur, arr[1].double!, accuracy: 1e-12, leaf)
            XCTAssertEqual(x.on, arr[2].truthy, leaf)
        }
        let cv = cfg.curves()
        XCTAssertEqual(cv.count, g["curves"]!.object!.count)
        for (name, c) in g["curves"]!.object! {
            if c["type"]!.string == "spring" {
                XCTAssertEqual(cv[name], .spring(mass: c["mass"]!.double!, stiffness: c["stiffness"]!.double!,
                                                 damping: c["damping"]!.double!), name)
            } else {
                let p = c["points"]!.array!
                XCTAssertEqual(cv[name], .bezier(p1: (p[0].array![0].double!, p[0].array![1].double!),
                                                 p2: (p[1].array![0].double!, p[1].array![1].double!)), name)
            }
        }
        XCTAssertEqual(cfg.floatRules.count, g["float_rules"]!.int)
        XCTAssertEqual(cfg.popin("windowsIn"), 0.86)
        XCTAssertEqual(cfg.popin("windowsOut"), 0.92)
        XCTAssertNil(cfg.popin("windowsMove"))
    }
}
