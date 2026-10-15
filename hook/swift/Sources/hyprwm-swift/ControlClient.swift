import Foundation
import HyprCore

/// Used only by the menu companion. It communicates with the existing daemon; it never opens an engine channel.
final class ControlClient {
    let path: String
    init(path: String) { self.path = path }
    func request(_ command: String) throws -> String {
        guard !command.contains("\n"), command.utf8.count < 65536 else { throw CmdError("invalid command") }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw CmdError("control socket unavailable") }
        defer { close(socketFD) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw CmdError("control path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes); buffer[bytes.count] = 0
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw CmdError("HyprWM is not running") }
        let data = Array((command + "\n").utf8)
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBufferPointer { write(socketFD, $0.baseAddress!.advanced(by: offset), data.count-offset) }
            guard sent > 0 else { throw CmdError("control write timed out") }; offset += sent
        }
        var output: [UInt8] = [], buffer = [UInt8](repeating: 0, count: 4096)
        while output.count < 1_048_576 {
            let count = read(socketFD, &buffer, buffer.count)
            guard count >= 0 else { throw CmdError("control reply timed out") }
            if count == 0 { break }
            output.append(contentsOf: buffer.prefix(count))
            if output.contains(10) { break }
        }
        guard let newline = output.firstIndex(of: 10) else { throw CmdError("incomplete control reply") }
        return String(decoding: output.prefix(newline), as: UTF8.self)
    }
}
