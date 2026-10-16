// Command socket /tmp/hyprwm.ctl: same protocol as the Python daemon (keys/hyprkeys, ctl.sh, stop.sh):
// the client connects, writes one line, reads one response line, and the connection closes.
// Command failures return a bounded single-line error before closing the connection.
import Foundation

public final class CommandServer {
    public let path: String
    public let fd: Int32

    /// Does anyone already answer on this socket? Do not start a second daemon over a live one.
    public static func isAlive(_ path: String) -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        defer { close(s) }
        var a = sockaddr_un()
        guard fillAddr(&a, path) else { return false }
        return withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    static func fillAddr(_ a: inout sockaddr_un, _ path: String) -> Bool {
        a.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: a.sun_path) else { return false }
        withUnsafeMutableBytes(of: &a.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return true
    }

    private final class Client {
        let fd: Int32
        let started = ProcessInfo.processInfo.systemUptime
        var input: [UInt8] = []
        var output: [UInt8]?
        var sent = 0
        init(_ fd: Int32) { self.fd = fd }
    }
    private var clients: [Client] = []
    private var socketInode: UInt64 = 0

    public init(path: String) throws {
        self.path = path
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == getuid(), !Self.isAlive(path) else {
                throw CmdError("control path is occupied or belongs to another owner: \(path)")
            }
            guard unlink(path) == 0 else { throw CmdError("cannot remove stale control socket") }
        }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw CmdError("socket: \(String(cString: strerror(errno)))") }
        var a = sockaddr_un()
        guard Self.fillAddr(&a, path) else { close(s); throw CmdError("control socket path is too long") }
        let result = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(s); throw CmdError("bind: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard listen(s, 32) == 0 else { close(s); unlink(path); throw CmdError("listen failed") }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        _ = fcntl(s, F_SETFD, FD_CLOEXEC)
        fd = s
        var info = stat()
        if lstat(path, &info) == 0 { socketInode = UInt64(info.st_ino) }
    }

    deinit {
        for client in clients { close(client.fd) }
        close(fd)
        var info = stat()
        if lstat(path, &info) == 0 && UInt64(info.st_ino) == socketInode { unlink(path) }
    }

    /// Bounded, nonblocking service: an incomplete command cannot stall animation or keyboard input.
    public func drain(_ handle: (String) throws -> String) {
        for _ in 0..<16 {
            let c = accept(fd, nil, nil)
            if c < 0 { break }
            guard clients.count < 32 else { close(c); continue }
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK)
            _ = fcntl(c, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            clients.append(Client(c))
        }
        clients = clients.filter { serve($0, handle) }
    }

    private func serve(_ client: Client, _ handle: (String) throws -> String) -> Bool {
        func finish() -> Bool { close(client.fd); return false }
        guard ProcessInfo.processInfo.systemUptime-client.started < 1 else { return finish() }
        if client.output == nil {
            var bytes = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<16 {
                let count = read(client.fd, &bytes, bytes.count)
                if count == 0 && client.input.isEmpty { return finish() }
                if count < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK { return true }
                    return finish()
                }
                if count > 0 { client.input.append(contentsOf: bytes.prefix(count)) }
                guard client.input.count <= 65536 else { return finish() }
                if let newline = client.input.firstIndex(of: 10) {
                    client.input = Array(client.input.prefix(newline)); break
                }
                if count == 0 { break }
                if count < bytes.count { return true }
            }
            guard !client.input.isEmpty else { return finish() }
            let line = String(decoding: client.input, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            do { client.output = Array((try handle(line) + "\n").utf8) }
            catch {
                let message=String(String(describing:error).unicodeScalars.prefix(1024).map {
                    CharacterSet.controlCharacters.contains($0) ? " " : String($0)
                }.joined()).trimmingCharacters(in:.whitespaces)
                log("command failed:",message)
                client.output=Array(("error: "+(message.isEmpty ? "command failed" : message)+"\n").utf8)
            }
            guard client.output!.count <= 1_048_576 else { return finish() }
        }
        let output = client.output!
        let count = output.withUnsafeBufferPointer { buffer in
            write(client.fd, buffer.baseAddress!.advanced(by: client.sent), output.count-client.sent)
        }
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return true }
        guard count > 0 else { return finish() }
        client.sent += count
        return client.sent == output.count ? finish() : true
    }

}

/// App configure: the latest window target wins (sequence number); one serial queue
/// per app (its main thread serializes AX anyway). A late response for an old
/// target cannot overwrite a new one (P6/S3). The actual accepted frame goes to deliver; the live daemon
/// posts it on the main queue and ticks immediately (event delivery instead of polling cfg_q).
public final class Configurer: ConfigureSink {
    final class Want {
        let job: CfgJob
        var taken = false
        init(_ j: CfgJob) { job = j }
    }
    let sys: SysAPI
    let deliver: (CfgResult) -> Void
    let lock = NSLock()
    var want: [Int: Want] = [:]
    var seq = 0
    /// Read-only queue counters, including work not yet sent to the AX adapter.
    public var status: JSON {
        lock.lock(); defer { lock.unlock() }
        return .object([("submitted", .int(seq)), ("running", .int(running)),
                        ("pending", .int(want.values.filter { !$0.taken }.count))])
    }
    var queues: [Int: DispatchQueue] = [:]
    var scheduled=Set<Int>()
    var running=0
    var runningWIDs=Set<Int>()
    public func busy(_ wid:Int) -> Bool { lock.lock();defer { lock.unlock() };return runningWIDs.contains(wid) || want[wid].map { !$0.taken } == true }
    public var idle:Bool { lock.lock();defer { lock.unlock() };return running == 0 && !want.values.contains { !$0.taken } }

    public init(sys: SysAPI, deliver: @escaping (CfgResult) -> Void) {
        self.sys = sys
        self.deliver = deliver
    }

    public func submit(_ jobs: [CfgJob]) {
        lock.lock()
        defer { lock.unlock() }
        for var j in jobs {
            seq += 1
            j.seq = seq
            want[j.wid] = Want(j)
            let q: DispatchQueue
            if let x = queues[j.pid] { q = x } else {
                q = DispatchQueue(label: "hyprwm.configure.\(j.pid)", qos: .userInteractive)
                queues[j.pid] = q
            }
            let pid=j.pid
            if scheduled.insert(pid).inserted { q.async { [weak self] in self?.drain(pid) } }
        }
    }

    public func cancelAll() { lock.lock(); want.removeAll(); lock.unlock() }
    public func cancel(_ wid: Int) { lock.lock(); want[wid] = nil; lock.unlock() }

    func drain(_ pid:Int) {
        while true {
            lock.lock()
            guard let next=want.values.filter({ $0.job.pid == pid && !$0.taken }).min(by: { $0.job.seq < $1.job.seq }) else {
                scheduled.remove(pid);queues[pid]=nil;lock.unlock();return
            }
            next.taken=true;running+=1;let job=next.job;runningWIDs.insert(job.wid);lock.unlock()
            cfgOne(job)
            lock.lock();running-=1;runningWIDs.remove(job.wid);lock.unlock()
        }
    }

    func work(_ wid: Int) {
        lock.lock()
        guard let w = want[wid], !w.taken else { lock.unlock(); return }   // already handled by a newer job
        w.taken = true
        let j = w.job
        lock.unlock()
        cfgOne(j)
    }

    func latest(_ wid: Int, _ seq: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return want[wid]?.job.seq == seq
    }

    /// _cfg_one: set the frame and wait for the frame the window actually accepts.
    func cfgOne(_ j: CfgJob) {
        let (wid, seq, pid, to) = (j.wid, j.seq, j.pid, j.to)
        func owned() -> Bool { !j.requireOwnership || (!sys.sessionLocked() && !sys.protectedProcess(pid) && sys.winPidLevel(wid).pid == pid && sys.processBirth(pid) == j.birth && j.birth != nil) }
        guard latest(wid,seq), owned() else { return }
        let pre = sys.axGetFrame(pid, wid)
        guard latest(wid, seq), owned() else { return }
        let unchanged=pre.map { current in
            j.sizeOnly ? abs(current.w-to.w)<=1 && abs(current.h-to.h)<=1 : current.maxDiff(to)<=1
        } ?? false
        let e = j.verifyOnly || unchanged ? 0 : j.sizeOnly ? sys.axSize(pid,wid,to.w,to.h) : sys.axFrame(pid, wid, to)
        var got: Rect? = unchanged ? pre:nil
        var same = 0
        let t0 = sys.now()
        while e == 0 && !unchanged && sys.now() - t0 < 0.6 {
            if !latest(wid, seq) || !owned() { return }                       // a newer target arrived; this response is obsolete
            guard let cur = sys.axGetFrame(pid, wid) else {sys.sleep(0.03);continue}
            if abs(cur.w - to.w) <= TOL && abs(cur.h - to.h) <= TOL {
                got = cur
                break
            }
            same = cur == got ? same + 1 : 0
            got = cur
            // The window settled where it could: 90 ms without changes. If its size never changed,
            // wait longer (Ghostty/Telegram apply sizes asynchronously).
            if same >= 3 && (pre == nil || max(abs(cur.w - pre!.w), abs(cur.h - pre!.h)) > 1 || sys.now() - t0 > 0.35) {
                break
            }
            sys.sleep(0.03)
        }
        if latest(wid, seq) && owned() {
            var result=CfgResult(wid:wid,owner:j.owner,to:to,got:got,e:e,pre:pre)
            result.pid=pid;result.birth=j.birth;result.isCurrent={ [weak self] in self?.latest(wid,seq) == true }
            deliver(result)
        }
    }
}
