@testable import HyprCore
import XCTest

final class RuntimeResizeModeTests: XCTestCase {
    func withConfig(_ document: String?, _ body: (String) throws -> Void) throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let original=ProcessInfo.processInfo.environment["HYPRWM_CONFIG"]
        setenv("HYPRWM_CONFIG",directory.appendingPathComponent("hyprwm.conf").path,1)
        defer {
            if let original { setenv("HYPRWM_CONFIG",original,1) } else { unsetenv("HYPRWM_CONFIG") }
            try? FileManager.default.removeItem(at:directory)
        }
        guard TextConfig.url(configDir:directory.path).path == directory.appendingPathComponent("hyprwm.conf").path else {
            throw CmdError("Runtime fixture config path is not isolated")
        }
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config/runtime.schema.json")
        try FileManager.default.copyItem(at:source,to:directory.appendingPathComponent("runtime.schema.json"))
        try Data(Fx.config().raw.dumps().utf8).write(to:directory.appendingPathComponent("hypr_cfg.json"))
        if let document {
            // Keep deliberately invalid object values as assignments rather than
            // canonicalizing an empty object into an absent preference.
            let runtime=try JSON.parse(document)["runtime"]?.object ?? []
            let text=runtime.map { "runtime."+$0.0+" = "+$0.1.dumps(indent:nil) }.joined(separator:"\n")+"\n"
            try text.write(to:directory.appendingPathComponent("hyprwm.conf"),atomically:true,encoding:.utf8)
        }
        try body(directory.path)
    }
    func testMissingFieldUsesNativeWithoutEnablingSnapshots() throws {
        for document in [nil, "{}", "{\"runtime\":{\"prehide\":false}}"] {
            try withConfig(document) { path in
                let options=try RuntimeOptions.load(configDir:path,environment:[:])
                XCTAssertTrue(options.production);XCTAssertFalse(options.nativeFrames);XCTAssertFalse(options.snapshotFrames)
            }
        }
        XCTAssertFalse(RuntimeOptions.standard.nativeFrames)
        // Frozen differential fixtures retain their explicitly non-production policy.
        XCTAssertFalse(RuntimeOptions().production);XCTAssertFalse(RuntimeOptions().nativeFrames)
    }
    func testBothModesAndReloadResolveFromLatestFile() throws {
        try withConfig("{\"runtime\":{\"window_resize_mode\":\"buffer\"}}") { path in
            XCTAssertFalse(try RuntimeOptions.load(configDir:path,environment:[:]).nativeFrames)
            XCTAssertEqual(try NativeRuntimeConfig.load(base:Fx.config(),configDir:path,environment:[:]).raw["runtime"]?["window_resize_mode"]?.string,"buffer")
            try TextConfig.write(JSON.parse("{\"runtime\":{\"window_resize_mode\":\"native\"}}"),configDir:path)
            XCTAssertFalse(try RuntimeOptions.load(configDir:path,environment:[:]).nativeFrames)
            let config=try NativeRuntimeConfig.load(base:Fx.config(),configDir:path,environment:[:])
            XCTAssertEqual(config.raw["runtime"]?["window_resize_mode"]?.string,"native")
        }
    }
    func testPerFrameDebugOverrideNeverChangesProjectionMode() throws {
        let base=try Fx.config()
        for (mode,override,expected) in [("native","0",false),("buffer","0",false),("native","1",true),("buffer","1",true)] {
            let text="{\"runtime\":{\"window_resize_mode\":\"\(mode)\"}}"
            let environment=["HYPRWM_NATIVE_FRAMES":override]
            try withConfig(text) { path in
                let options=try RuntimeOptions.load(configDir:path,environment:environment)
                let config=try NativeRuntimeConfig.build(base:base,document:JSON.parse(text),environment:environment)
                XCTAssertEqual(options.nativeFrames,expected)
                XCTAssertFalse(options.snapshotFrames)
                XCTAssertEqual(config.raw["runtime"]?["window_resize_mode"]?.string,mode)
            }
        }
    }
    func testInvalidValuesAreReportedByTextLoaderAndRejectedByStrictBuilder() throws {
        for value in ["\"zoom\"","false","3","null","{}"] {
            let text="{\"runtime\":{\"window_resize_mode\":\(value)}}"
            try withConfig(text) { path in
                XCTAssertEqual(try TextConfig.read(configDir:path).issues.count,1)
                XCTAssertFalse(try RuntimeOptions.load(configDir:path,environment:[:]).nativeFrames)
                XCTAssertThrowsError(try NativeRuntimeConfig.build(base:Fx.config(),document:JSON.parse(text)))
            }
        }
        try withConfig(nil) { path in
            XCTAssertThrowsError(try RuntimeOptions.load(configDir:path,environment:["HYPRWM_NATIVE_FRAMES":"true"]))
        }
    }
    func testHiddenOverviewIsStrictOptInAndReloadsWithoutChangingNativeFreezePolicy() throws {
        XCTAssertFalse(RuntimeOptions.standard.overviewHiddenWindows)
        for (value,expected) in [("false",false),("true",true)] {
            let text="{\"runtime\":{\"overview_hidden_windows\":\(value)}}"
            try withConfig(text) { path in
                XCTAssertEqual(try RuntimeOptions.load(configDir:path,environment:[:]).overviewHiddenWindows,expected)
                _=try NativeRuntimeConfig.build(base:Fx.config(),document:JSON.parse(text))
            }
        }
        for value in ["1","\"true\"","null"] {
            let text="{\"runtime\":{\"overview_hidden_windows\":\(value)}}"
            try withConfig(text) { path in
                XCTAssertEqual(try TextConfig.read(configDir:path).issues.count,1)
                XCTAssertFalse(try RuntimeOptions.load(configDir:path,environment:[:]).overviewHiddenWindows)
                XCTAssertThrowsError(try NativeRuntimeConfig.build(base:Fx.config(),document:JSON.parse(text)))
            }
        }
    }

}
