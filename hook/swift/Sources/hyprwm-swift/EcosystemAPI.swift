import Darwin
import Foundation
import HyprCore

/// Observes the WM's existing census. It never polls AX or mutates windows.
final class EcosystemAPI {
    private struct Identity: Equatable {
        let wid: Int
        let pid: Int
        let space: Int
        var json: JSON { .object([("wid", .int(wid)), ("pid", .int(pid)), ("space", .int(space))]) }
    }
    private final class Subscriber {
        let fd: Int32
        var pending = Data()
        init(fd: Int32) { self.fd = fd }
    }
    private let path: String
    private let fd: Int32
    private var inode: UInt64 = 0
    private let queue = DispatchQueue(label: "hyprwm.events", qos: .utility)
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var subscribers: [Subscriber] = []
    private var previousWindows: [Int: Identity]?
    private var previousSpace: Int?
    private var previousFocus: Int?
    private var sequence = 0

    init(path: String) throws {
        self.path = path
        var old = stat()
        if lstat(path, &old) == 0 {
            guard old.st_mode & S_IFMT == S_IFSOCK, old.st_uid == getuid(), !CommandServer.isAlive(path), unlink(path) == 0 else {
                throw CmdError("event socket path is occupied or has another owner")
            }
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw CmdError("event socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw CmdError("cannot create event socket") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(listener); throw CmdError("cannot bind event socket") }
        guard chmod(path, 0o600) == 0, listen(listener, 16) == 0 else {
            close(listener); unlink(path); throw CmdError("cannot protect or listen on event socket")
        }
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        fd = listener
        var created = stat()
        if lstat(path, &created) == 0 { inode = UInt64(created.st_ino) }
        let readSource = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        readSource.setEventHandler { [weak self] in self?.acceptSubscribers() }
        source = readSource
        readSource.resume()
        let flushTimer = DispatchSource.makeTimerSource(queue: queue)
        flushTimer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
        flushTimer.setEventHandler { [weak self] in self?.flush() }
        timer = flushTimer
        flushTimer.resume()
    }

    deinit {
        source?.cancel()
        timer?.cancel()
        for subscriber in subscribers { close(subscriber.fd) }
        close(fd)
        var current = stat()
        if lstat(path, &current) == 0, UInt64(current.st_ino) == inode { unlink(path) }
    }

    /// Call on the WM main queue after a normal tick, using its cached snapshot.
    func observe(windows: [WinInfo], space: Int, focusedWindow: Int?) {
        var current: [Int: Identity] = [:]
        for window in windows where window.layer == 0 && window.wid > 0 && window.pid > 0 {
            current[window.wid] = Identity(wid: window.wid, pid: window.pid, space: window.space)
        }
        defer { previousWindows = current; previousSpace = space; previousFocus = focusedWindow }
        guard let previous = previousWindows else { return }
        for wid in previous.keys.sorted() where current[wid]?.pid != previous[wid]?.pid {
            emit("window_closed", window: previous[wid], space: space)
        }
        for wid in current.keys.sorted() where previous[wid]?.pid != current[wid]?.pid {
            emit("window_opened", window: current[wid], space: space)
        }
        if previousSpace != space { emit("space_changed", window: nil, space: space) }
        if previousFocus != focusedWindow || previousSpace != space ||
            focusedWindow.map({ previous[$0]?.pid != current[$0]?.pid }) == true {
            emit("window_focused", window: focusedWindow.flatMap { current[$0] }, space: space)
        }
    }

    private func emit(_ name: String, window: Identity?, space: Int) {
        sequence += 1
        let event = JSON.object([("event", .string(name)), ("sequence", .int(sequence)),
                                 ("timestamp", .double(Date().timeIntervalSince1970)),
                                 ("space", .int(space)), ("window", window?.json ?? .null)])
        let data = Data((event.dumps(ensureASCII: false) + "\n").utf8)
        queue.async { [weak self] in
            guard let self else { return }
            self.subscribers = self.subscribers.filter { subscriber in
                guard subscriber.pending.count + data.count <= 32768 else { close(subscriber.fd); return false }
                subscriber.pending.append(data)
                return true
            }
            self.flush()
        }
    }

    private func acceptSubscribers() {
        for _ in 0..<16 {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { break }
            var uid: uid_t = 0, gid: gid_t = 0
            guard subscribers.count < 16, getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let subscriber = Subscriber(fd: client)
            subscriber.pending = Data("{\"event\":\"connected\",\"version\":1}\n".utf8)
            subscribers.append(subscriber)
        }
        flush()
    }

    private func flush() {
        subscribers = subscribers.filter { subscriber in
            if subscriber.pending.isEmpty {
                var byte: UInt8 = 0
                let count = recv(subscriber.fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                if count == 0 || count > 0 || count < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                    close(subscriber.fd); return false
                }
                return true
            }
            let sent = subscriber.pending.withUnsafeBytes { buffer in write(subscriber.fd, buffer.baseAddress, buffer.count) }
            if sent > 0 { subscriber.pending.removeFirst(sent); return true }
            if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return true }
            close(subscriber.fd); return false
        }
    }
}
