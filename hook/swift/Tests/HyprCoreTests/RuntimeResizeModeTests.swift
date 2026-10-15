@testable import HyprCore
import XCTest

final class RuntimeResizeModeTests: XCTestCase {
    func withConfig(_ document: String?, _ body: (String) throws -> Void) throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        if let document { try document.write(to:directory.appendingPathComponent("runtime.json"),atomically:true,encoding:.utf8) }
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
            try "{\"runtime\":{\"window_resize_mode\":\"native\"}}".write(toFile:path+"/runtime.json",atomically:true,encoding:.utf8)
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
    func testInvalidValuesFailBothRuntimeConsumers() throws {
        for value in ["\"zoom\"","false","3","null","{}"] {
            let text="{\"runtime\":{\"window_resize_mode\":\(value)}}"
            try withConfig(text) { path in
                XCTAssertThrowsError(try RuntimeOptions.load(configDir:path,environment:[:]))
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
                XCTAssertThrowsError(try RuntimeOptions.load(configDir:path,environment:[:]))
                XCTAssertThrowsError(try NativeRuntimeConfig.build(base:Fx.config(),document:JSON.parse(text)))
            }
        }
    }

}
