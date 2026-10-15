@testable import HyprCore
import XCTest

final class ForeignImportRobustnessTests: XCTestCase {
    private func directory() throws -> URL {
        let config = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:config.appendingPathComponent("runtime.schema.json"),to:directory.appendingPathComponent("runtime.schema.json"))
        try Data(Fx.config().raw.dumps().utf8).write(to:directory.appendingPathComponent("hypr_cfg.json"))
        return directory
    }
    func testStandardSkhdModifierSyntaxAndLineWarnings() throws {
        let directory=try directory();defer{try? FileManager.default.removeItem(at:directory)}
        let result=try ForeignConfigImport.preview("alt + shift - h : yabai -m window --swap west\ncmd - return : open -a Terminal\n",filename:"skhdrc",configDir:directory.path)
        XCTAssertEqual(result.mappedCount,1)
        XCTAssertEqual(result.document["hotkeys"]?.array?.first?["keycode"],.int(4))
        XCTAssertEqual(result.document["hotkeys"]?.array?.first?["modifiers"],.int(0xa00))
        XCTAssertEqual(result.document["hotkeys"]?.array?.first?["command"],.array([.string("move"),.string("left")]))
        XCTAssertEqual(result.issues.map(\.line),[2])
    }
    func testImportMergeKeepsExistingCommandIdentityAndAllocatesNonconflictingIDs() throws {
        let existing=try JSON.parse(#"{"hotkeys":[{"id":0,"keycode":4,"modifiers":2048,"command":["focus","left"]}]}"#)
        let incoming=try JSON.parse(#"{"hotkeys":[{"id":0,"keycode":37,"modifiers":2048,"command":["move","right"]}]}"#)
        let merged=ForeignConfigImport.merge(existing,incoming)
        XCTAssertEqual(merged["hotkeys"]?.array?.compactMap { $0["id"]?.int },[0,1])
        _=try NativeRuntimeConfig.build(base:Fx.config(),document:merged,environment:[:])
        let replacement=try JSON.parse(#"{"hotkeys":[{"id":9,"keycode":123,"modifiers":2048,"command":["focus","left"]}]}"#)
        let replaced=ForeignConfigImport.merge(merged,replacement)
        XCTAssertEqual(replaced["hotkeys"]?.array?.count,2)
        XCTAssertEqual(replaced["hotkeys"]?.array?.first?["id"],.int(0))
        XCTAssertEqual(replaced["hotkeys"]?.array?.first?["keycode"],.int(123))
    }
    func testSupportedFormatSamplesKeepValidSettingsAlongsideWarnings() throws {
        let directory=try directory();defer{try? FileManager.default.removeItem(at:directory)}
        let cases:[(String,String,String)]=[
            ("aerospace.toml","[gaps]\ninner.horizontal = 7\nunsupported = 1\n","AeroSpace"),
            ("hyprland.conf","general {\ngaps_in = 7\nunsupported = 1\n}\n","Hyprland"),
            ("yabairc","yabai -m config window_gap 7\nyabai -m config window_shadow off\n","yabai"),
            ("i3.conf","gaps inner 7\nexec dangerous-command\n","i3/sway"),
            ("amethyst.yml","window-margin-size: 7\nlayouts: [tall]\n","Amethyst")
        ]
        for (filename,text,format) in cases {
            let result=try ForeignConfigImport.preview(text,filename:filename,configDir:directory.path)
            XCTAssertEqual(result.format,format);XCTAssertEqual(result.mappedCount,1,filename)
            XCTAssertEqual(result.document["layout"]?["gaps_in"],.int(7),filename)
            XCTAssertEqual(result.issues.count,1,filename)
        }
        let rectangle=try ForeignConfigImport.preview("gapSize = 7",filename:"Rectangle.json",configDir:directory.path)
        XCTAssertEqual(rectangle.mappedCount,0);XCTAssertEqual(rectangle.issues.map(\.line),[1])
    }
}
