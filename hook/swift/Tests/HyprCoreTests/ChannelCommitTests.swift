import CChan
import Foundation
import HyprCore
import XCTest

final class ChannelCommitTests: XCTestCase {
    func testEmptyCommitPreservesSequentialWritersHeadAndNextBatchContinues() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let channel = try LiveChannel(path: path, create: true)
        defer { unlink(path) }
        channel.forget(123)
        channel.commit()
        XCTAssertEqual(channel.raw.pointee.cmd_head, 1)

        // A sequential writer published and the engine consumed its batch.
        channel.raw.pointee.cmd_head = 17
        channel.raw.pointee.cmd_tail = 17
        channel.commit()
        channel.commit()
        XCTAssertEqual(channel.raw.pointee.cmd_head, 17)
        XCTAssertFalse(channel.pending)

        channel.forget(456)
        channel.commit()
        XCTAssertEqual(channel.raw.pointee.cmd_head, 18)
        let offset = MemoryLayout<CChan.ch>.offset(of: \CChan.ch.cmd)!
        let commands = (channel.base + offset).assumingMemoryBound(to: ch_cmd.self)
        XCTAssertEqual(commands[17].op, UInt32(OP_FORGET))
        XCTAssertEqual(commands[17].wid, 456)
        channel.commit()
        XCTAssertEqual(channel.raw.pointee.cmd_head, 18)
    }
}
