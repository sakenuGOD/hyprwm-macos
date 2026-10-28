// Config: compare hyprcfg.animation/curves/gaps/dwindle and engine.anim/ids to reference Python output
// using the same hypr_cfg.json copy.
@testable import HyprCore
import XCTest

final class ConfigGoldenTests: XCTestCase {
    func testLoadUsesDefaultsWithoutHyprHome() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let environment = ProcessInfo.processInfo.environment
        defer {
            for key in ["PATH", "HYPR_HOME"] {
                if let value = environment[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
            try? FileManager.default.removeItem(at: directory)
        }
        // Record the home passed to Lua without requiring an installed interpreter.
        let lua = directory.appendingPathComponent("lua")
        try Data("#!/bin/sh\nprintf '{\"load_ok\":true,\"home\":\"%s\"}' \"$2\" > \"$3\"\n".utf8).write(to: lua)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lua.path)
        setenv("PATH", directory.path, 1)
        unsetenv("HYPR_HOME")
        let config = try HyprConfig.load(configDir: directory.path)
        XCTAssertEqual(config.raw["home"]?.string, directory.path + "/defaults")
    }

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
        for (name, id) in g["ids"]!.object! { XCTAssertEqual(cfg.curveIDs[name], id.int, "curve ID \(name)") }
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
