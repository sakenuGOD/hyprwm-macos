@testable import HyprCore
import XCTest

final class CommandErrorResponseTests: XCTestCase {
    func testThrowingCommandGetsExplanatoryReplyAndDoesNotBreakNextClient() throws {
        let sockets=SocketTests()
        let path=NSTemporaryDirectory()+"hyprwm-errors-"+UUID().uuidString.prefix(8)+".ctl"
        let server=try CommandServer(path:path)
        let refused=sockets.client(path,"float -1\n")
        server.drain { _ in throw CmdError("command: window ID must be 1..4294967295") }
        XCTAssertEqual(sockets.reply(refused),"error: command: window ID must be 1..4294967295\n")
        let ready=sockets.client(path,"status\n")
        server.drain { _ in "{\"enabled\":true}" }
        XCTAssertEqual(sockets.reply(ready),"{\"enabled\":true}\n")
    }
    func testErrorReplyIsBoundedAndCannotInjectExtraResponseLines() throws {
        let sockets=SocketTests()
        let path=NSTemporaryDirectory()+"hyprwm-errors-"+UUID().uuidString.prefix(8)+".ctl"
        let server=try CommandServer(path:path)
        let client=sockets.client(path,"invalid\n")
        server.drain { _ in throw CmdError("invalid\n\r\0"+String(repeating:"x",count:10000)) }
        let reply=sockets.reply(client)
        XCTAssertTrue(reply.hasPrefix("error: invalid   "))
        XCTAssertEqual(reply.filter { $0=="\n" }.count,1)
        XCTAssertLessThanOrEqual(reply.utf8.count,4104)
    }
}
