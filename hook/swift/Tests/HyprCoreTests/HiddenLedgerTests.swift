@testable import HyprCore
import CryptoKit
import XCTest

final class HiddenLedgerTests:XCTestCase {
    func testIntentMatchesSortedCompactFullLedgerAndUnicodeEscaping() throws {
        let row=Hidden(wid:1,pid:101,owner:"Window 🚀",space:1,rect:[0,2,400,500],extra:.object([
            ("tiled",.bool(true)),("swift_birth",.string("101:40:50")),("hidden_at",.double(1000.5)),
            ("generation",.array([.int(101),.int(501),.int(40),.int(50)]))]))
        let canonical=#"{"generation":[101,501,40,50],"hidden_at":1000.5,"owner":"\u041e\u043a\u043d\u043e \ud83d\ude80","pid":101,"rect":[0.0,2.0,400.0,500.0],"space":1,"swift_birth":"101:40:50","tiled":true,"wid":1}"#
        let expected=SHA256.hash(data:Data(canonical.utf8)).map{String(format:"%02x",$0)}.joined()
        XCTAssertEqual(try row.intentFingerprint(),expected)
        let source=try OverviewHidden(record:row,parked:Rect(1500,0,400,500),space:1,birth:[101,501,40,50])
        XCTAssertEqual(source.intent,expected)
        let reloaded=Hidden.from(try JSON.parse(row.json.dumps(indent:1)))
        XCTAssertEqual(try reloaded.intentFingerprint(),expected)
    }
    func testNativeHideEmitsVerifiedLegacyLedgerAndRejectsMalformedBirthBeforeMutation() throws {
        let fixture=ProductionPolicyTests(),(wm,sys,eng,wins)=try fixture.world(fixture.pair())
        let tree=wm.sp(1).tree!.json
        XCTAssertTrue(wm.hide(fixture.area,1,wins,1).hasPrefix("hide refused"))
        XCTAssertEqual(wm.sp(1).tree!.json,tree);XCTAssertTrue(wm.hidden.isEmpty);XCTAssertTrue(eng.ch.ops.isEmpty)
        sys.births[101]="101:40:50"
        XCTAssertEqual(wm.hide(fixture.area,1,wins,1),"hidden 1")
        let row=wm.hidden[0]
        XCTAssertEqual(row.extra["generation"],.array([.int(101),.int(Int(getuid())),.int(40),.int(50)]))
        XCTAssertTrue(row.extra["hidden_at"]!.double!>0);XCTAssertEqual(row.extra["tiled"],.bool(true))
        XCTAssertNil(row.extra["hidden_intent"]);XCTAssertTrue(wm.hiddenRecordLive(row))
    }
}
