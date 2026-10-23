@testable import HyprCore
import XCTest

final class ScriptedWindowCommandTests:XCTestCase {
    func testInstalledStylePublicNewWindowEventIsDecoded() {
        let definition="<dictionary><suite><command name=\"new window\" code=\"GhstNWin\"/></suite></dictionary>"
        let command=ScriptedWindowCommand(definition)
        XCTAssertEqual(command?.eventClass,0x47687374);XCTAssertEqual(command?.eventID,0x4e57696e)
    }
    func testMissingAmbiguousOrMalformedCommandNeverGuessesAction() {
        let command="<command name=\"new window\" code=\"GhstNWin\"/>"
        XCTAssertNil(ScriptedWindowCommand("<dictionary/>"))
        XCTAssertNil(ScriptedWindowCommand("<dictionary><suite>"+command+command+"</suite></dictionary>"))
        XCTAssertNil(ScriptedWindowCommand("<dictionary><suite><command name=\"new window\" code=\"short\"/></suite></dictionary>"))
        XCTAssertNil(ScriptedWindowCommand(String(repeating:"x",count:524289)))
    }
}
