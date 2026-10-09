// Сокет команд /tmp/hyprwm.ctl — протокол тот же, что у Python-демона (keys/hyprkeys, ctl.sh, stop.sh):
// клиент подключается, пишет одну строку, читает одну строку ответа, соединение закрывается.
// Ошибка в команде — в лог «команда упала», ответа нет (клиент видит закрытое соединение) — как в Python.
import Foundation

public final class CommandServer {
    public let path: String
    public let fd: Int32

    /// Отвечает ли уже кто-то на этом сокете (второй демон не запускается поверх живого).
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

    public init(path: String) throws {
        self.path = path
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw CmdError("socket: \(String(cString: strerror(errno)))") }
        var a = sockaddr_un()
        guard CommandServer.fillAddr(&a, path) else { close(s); throw CmdError("слишком длинный путь сокета \(path)") }
        let r = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0 else { close(s); throw CmdError("bind \(path): \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        // SO_NOSIGPIPE — на слушающем сокете: принятые его наследуют. На принятом сокете, чей клиент уже
        // закрылся, setsockopt не проходит (EINVAL), и ответ в закрытый сокет убил бы демон SIGPIPE.
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard listen(s, 8) == 0 else { close(s); throw CmdError("listen: \(String(cString: strerror(errno)))") }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)   // drain() забирает всё ждущее и не блокируется
        fd = s
    }

    deinit { close(fd) }

    /// Все ждущие подключения за раз (автоповтор бинда не морит голодом остальное — P42).
    public func drain(_ handle: (String) throws -> String) {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { return }                                  // EAGAIN: больше никого
            serve(c, handle)
        }
    }

    private func serve(_ c: Int32, _ handle: (String) throws -> String) {
        defer { close(c) }
        _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)   // на BSD принятый сокет наследует O_NONBLOCK
        var tv = timeval(tv_sec: 1, tv_usec: 0)                  // c.settimeout(1)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var buf = [UInt8]()
        var ch: UInt8 = 0
        while buf.count < 65536 {                                 // readline()
            let n = read(c, &ch, 1)
            if n <= 0 {
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    log("команда упала: TimeoutError('timed out')")
                    return
                }
                break
            }
            buf.append(ch)
            if ch == 0x0a { break }
        }
        let line = String(decoding: buf, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let t = Date()
        do {
            let out = try handle(line)
            log(String(format: "команда '%@' -> %@ (%.2f с)", line, String(out.prefix(200)), Date().timeIntervalSince(t)))
            let data = Array((out + "\n").utf8)
            var off = 0
            while off < data.count {
                let n = data[off...].withUnsafeBufferPointer { write(c, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                off += n
            }
        } catch {
            log("команда упала: \(error)")
        }
    }
}

/// configure приложениям: последняя цель окна побеждает (серийный номер); одна последовательная очередь
/// на приложение (AX приложения всё равно сериализуется его главным потоком) — поздний ответ со старой
/// целью не перетирает новую (P6/S3). Ответ (что окно реально приняло) уходит в deliver — живой демон
/// кладёт его на главную очередь и сразу делает такт (событие вместо опроса cfg_q).
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
    var queues: [Int: DispatchQueue] = [:]

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
            let wid = j.wid
            q.async { [weak self] in self?.work(wid) }
        }
    }

    func work(_ wid: Int) {
        lock.lock()
        guard let w = want[wid], !w.taken else { lock.unlock(); return }   // уже сделано более новым заданием
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

    /// _cfg_one: поставить рамку и дождаться, что окно реально приняло.
    func cfgOne(_ j: CfgJob) {
        let (wid, seq, pid, to) = (j.wid, j.seq, j.pid, j.to)
        let pre = sys.axGetFrame(pid, wid)
        let e = sys.axFrame(pid, wid, to)
        var got: Rect?
        var same = 0
        let t0 = sys.now()
        while e == 0 && sys.now() - t0 < 0.6 {
            sys.sleep(0.03)
            if !latest(wid, seq) { return }                       // пришла новая цель — этот ответ не нужен
            guard let cur = sys.axGetFrame(pid, wid) else { continue }
            if abs(cur.w - to.w) <= TOL && abs(cur.h - to.h) <= TOL {
                got = cur
                break
            }
            same = cur == got ? same + 1 : 0
            got = cur
            // окно встало, где смогло: 90 мс без изменений; если так и не сдвинулось с прежнего размера —
            // ждать дольше (Ghostty/Telegram применяют размер асинхронно)
            if same >= 3 && (pre == nil || max(abs(cur.w - pre!.w), abs(cur.h - pre!.h)) > 1 || sys.now() - t0 > 0.35) {
                break
            }
        }
        if latest(wid, seq) { deliver(CfgResult(wid: wid, owner: j.owner, to: to, got: got, e: e, pre: pre)) }
    }
}
