@testable import HyprCore
import XCTest

final class WindowRuleMetadataTests: XCTestCase {
    func testRoleAndSubroleRequireVerifiedMetadataAndAllConditions() throws {
        let rule = try JSON.parse(#"{"match":{"class":"Editor","role":"AXWindow","subrole":"AXDialog"},"float":true}"#)
        _ = try WindowProperties.validateRules(.array([rule]))
        var window = WinInfo(wid:1,pid:101,owner:"Editor",x:0,y:0,w:400,h:300,on:true,space:1)
        XCTAssertFalse(WindowProperties.matches(rule,window))
        window.role = "AXWindow"; window.subrole = "AXDialog"
        XCTAssertTrue(WindowProperties.matches(rule,window))
        window.subrole = "AXStandardWindow"
        XCTAssertFalse(WindowProperties.matches(rule,window))
    }
    func testUnknownRoleCannotSatisfyNegativeRule() throws {
        let rule = try JSON.parse(#"{"match":{"role":"negative:AXSheet"},"float":true}"#)
        var window = WinInfo(wid:1,pid:101,owner:"Editor",x:0,y:0,w:400,h:300,on:true,space:1)
        XCTAssertFalse(WindowProperties.matches(rule,window))
        window.role = "AXWindow"
        XCTAssertTrue(WindowProperties.matches(rule,window))
        window.role = "AXSheet"
        XCTAssertFalse(WindowProperties.matches(rule,window))
    }
    func testSnapshotDecodesAXMetadataWithoutChangingLegacyDefaults() throws {
        let window = WinInfo.from(try JSON.parse(#"{"wid":1,"role":"AXSheet","subrole":"AXDialog"}"#))
        XCTAssertEqual(window.role,"AXSheet"); XCTAssertEqual(window.subrole,"AXDialog")
        XCTAssertEqual(WinInfo.from(.object([])).role,"")
    }
    func testTextRuleAcceptsMetadataAndRejectsBadRegexAtItsLine() throws {
        let directory = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config").path
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temporary) }
        try FileManager.default.copyItem(at:URL(fileURLWithPath:directory).appendingPathComponent("runtime.schema.json"),to:temporary.appendingPathComponent("runtime.schema.json"))
        try Data(Fx.config().raw.dumps().utf8).write(to:temporary.appendingPathComponent("hypr_cfg.json"))
        let parsed = try TextConfig.parse("windowrule = float, role:^AXWindow$, subrole:^AXDialog$\nwindowrule = float, role:[\nlayout.gaps_in = 7\n",configDir:temporary.path)
        XCTAssertEqual(parsed.issues.map(\.line),[2])
        XCTAssertEqual(parsed.document["window_rules"]?.array?.count,1)
        XCTAssertEqual(parsed.document["layout"]?["gaps_in"],.int(7))
    }
}
