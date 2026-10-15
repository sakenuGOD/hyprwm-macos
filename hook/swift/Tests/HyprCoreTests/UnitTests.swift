// Точечные тесты: разбор команд, протокол сокета (на временном пути), ABI канала (на временном файле,
// не /tmp/hyprwm), вывод JSON как у Python, очередь configure «последняя цель побеждает».
import CChan
@testable import HyprCore
import XCTest

final class CommandTests: XCTestCase {
    var sys: FakeWorld!
    var eng: FakeEngine!
    var wm: WM!
    let area = Rect(0, 33, 1470, 923)
    var wins: [WinInfo] = []

    override func setUpWithError() throws {
        hyprLogSink = { _ in }
        let cfg = try Fx.config()
        sys = FakeWorld()
        eng = FakeEngine(cfg: cfg)
        let tmp = NSTemporaryDirectory() + "hyprwm-cmd-\(getpid())"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        wm = WM(sys: sys, eng: eng, deco: NullDeco(), cfg: cfg, statePath: tmp + "/s.json", minsizePath: tmp + "/m.json",
                cfgSink: JobRecorder())
        wm.saveEnabled = false
        wins = [WinInfo(wid: 11, pid: 1, owner: "Ghostty", x: 12, y: 41, w: 700, h: 870, on: true, space: 3),
                WinInfo(wid: 22, pid: 2, owner: "Telegram", x: 740, y: 41, w: 700, h: 870, on: true, space: 3)]
        sys.tileableM = [11: 1, 22: 1]
        sys.m = (1000, 500)
        _ = try wm.command("retile", area, 3, wins)        // оба окна — в раскладку
    }

    func cmd(_ s: String) throws -> String { try wm.command(s, area, 3, wins) }

    func testParsing() throws {
        XCTAssertEqual(try cmd(""), "пусто")
        XCTAssertEqual(try cmd("   "), "пусто")
        XCTAssertEqual(try cmd("bogus x"), "не знаю команду: bogus x")
        XCTAssertEqual(try cmd("focus"), "не знаю команду: focus")       // без стороны — как в Python
        XCTAssertEqual(try cmd("resize 5"), "не знаю команду: resize 5")
        XCTAssertThrowsError(try cmd("resize abc 1"))                    // float() -> ValueError: ответа нет
        XCTAssertEqual(try cmd("preselect l"), "preselect left")
        XCTAssertEqual(try cmd("preselect"), "preselect None")
        XCTAssertEqual(try cmd("preselect zz"), "preselect None")
        XCTAssertEqual(try cmd("focus x"), "нет окна: x")
        XCTAssertEqual(try cmd("unhide"), "скрытых нет")
        XCTAssertEqual(try cmd("exec"), "нечего запускать")
        XCTAssertEqual(try cmd("\t togglesplit  \n"), "ok")
    }

    func testFocusAndLayout() throws {
        XCTAssertEqual(wm.target.keys.sorted(), [11, 22])
        XCTAssertEqual(try cmd("focus r"), "фокус -> 22 (0)")
        XCTAssertEqual(wm.ownFocus.pid, 2)
        XCTAssertEqual(try cmd("focus left"), "нет окна: left")
        XCTAssertEqual(try cmd("move r"), "ok")                          // 11 уходит направо
        let r = wm.layout(area, wm.sp(3))
        XCTAssertGreaterThan(r[11]!.x, r[22]!.x)
    }

    func testStatusJSON() throws {
        let j = try JSON.parse(try cmd("status"))
        XCTAssertEqual(j["space"]?.int, 3)
        XCTAssertEqual(j["focus"]?.int, 11)
        XCTAssertEqual(j["rects"]?.object?.count, 2)
        XCTAssertEqual(j["engine"]?["tick_us_max"]?.double, 147.2)
        XCTAssertEqual(j["engine"]?["tick_us_last"]?.double, 3.0)
    }

    func testHideUnhideRoundTrip() throws {
        XCTAssertEqual(try cmd("hide 22"), "скрыто 22")
        XCTAssertEqual(try cmd("hide 22"), "уже скрыто 22")
        XCTAssertNil(wm.target[22])
        XCTAssertEqual(try cmd("unhide all"), "возвращено [22]")
        XCTAssertTrue(wm.hidden.isEmpty)
    }

    func testExec() throws {
        XCTAssertEqual(try cmd("exec Ghostty --new"), "запуск Ghostty --new")   // pgrep ничего не нашёл -> open -a
        XCTAssertEqual(sys.calls.last, .string("spawn?"))
        XCTAssertEqual(try cmd("exec spotlight"), "лаунчер")
    }
}

final class SocketTests: XCTestCase {
    func client(_ path: String, _ line: String) -> Int32 {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        var a = sockaddr_un()
        XCTAssertTrue(CommandServer.fillAddr(&a, path))
        let r = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(r, 0)
        _ = line.withCString { write(s, $0, strlen($0)) }
        return s
    }

    func reply(_ s: Int32) -> String {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(s, &buf, buf.count)
        close(s)
        return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
    }

    func testProtocol() throws {
        hyprLogSink = { _ in }
        let path = NSTemporaryDirectory() + "hyprwm-test-\(getpid()).ctl"
        XCTAssertFalse(CommandServer.isAlive(path))
        let srv = try CommandServer(path: path)
        defer { unlink(path) }
        XCTAssertTrue(CommandServer.isAlive(path))
        var st = stat()
        stat(path, &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        // две команды ждут — drain забирает обе за раз (P42)
        let a = client(path, "status\n"), b = client(path, "  focus l  \n")
        var seen: [String] = []
        srv.drain { seen.append($0); return "ok:" + $0 }
        XCTAssertEqual(seen.filter { $0 != "" }.suffix(2), ["status", "focus l"])
        XCTAssertEqual(reply(a), "ok:status\n")
        XCTAssertEqual(reply(b), "ok:focus l\n")
        // команда «упала» — соединение закрывается без ответа (как в Python)
        let c = client(path, "resize abc 1\n")
        srv.drain { _ in throw CmdError("ValueError") }
        XCTAssertEqual(reply(c), "")
    }
}

final class ChannelABITests: XCTestCase {
    func testLiveChannelOnTempFile() throws {
        hyprLogSink = { _ in }
        XCTAssertEqual([Ev.gone, Ev.settled, Ev.done, Ev.new, Ev.moved],
                       [Int(EV_GONE), Int(EV_SETTLED), Int(EV_DONE), Int(EV_NEW), Int(EV_MOVED)])
        let path = NSTemporaryDirectory() + "hyprwm-chan-test.\(getpid()).\(Int(Date().timeIntervalSince1970 * 1000))"
        defer { unlink(path) }
        let c = try LiveChannel(path: path, create: true)
        XCTAssertTrue(c.magicOK)
        XCTAssertTrue(c.sizeOK)
        XCTAssertThrowsError(try LiveChannel(path: path, create: true))     // O_EXCL: существующий не пересоздаётся
        XCTAssertEqual(MemoryLayout<ch_win>.stride, Int(ch_off(0)))
        XCTAssertEqual(MemoryLayout<ch_cmd>.stride, Int(ch_off(2)))
        XCTAssertEqual(MemoryLayout<ch_hdr>.stride, Int(ch_off(7)))
        XCTAssertEqual(MemoryLayout<ch_win>.offset(of: \ch_win.pos), Int(ch_off(4)))
        XCTAssertEqual(MemoryLayout<ch_win>.offset(of: \ch_win.ax), Int(ch_off(5)))

        XCTAssertFalse(c.pending)
        c.geom(42, Rect(10, 20, 300, 400), 3, 3, frm: Rect(1, 2, 3, 4), move: true, warp: false, stretch: true)
        c.alpha(42, 0.0, 5, 0.3, frm: 1.0)
        XCTAssertFalse(c.pending)                                           // не опубликовано до commit
        c.commit()
        XCTAssertTrue(c.pending)
        let cmdBase = c.base + MemoryLayout<ch_hdr>.stride + Int(CH_NCURVE) * MemoryLayout<ch_curve>.stride
        let k0 = cmdBase.assumingMemoryBound(to: ch_cmd.self).pointee
        XCTAssertEqual(k0.op, UInt32(OP_GEOM))
        XCTAssertEqual(k0.wid, 42)
        XCTAssertEqual(k0.flags, UInt32(F_FROM | F_MOVE | F_STRETCH))
        XCTAssertEqual([k0.x, k0.y, k0.w, k0.h, k0.fx, k0.fy, k0.fw, k0.fh], [10, 20, 300, 400, 1, 2, 3, 4])
        XCTAssertEqual(k0.cpos, 3)
        let k1 = (cmdBase + MemoryLayout<ch_cmd>.stride).assumingMemoryBound(to: ch_cmd.self).pointee
        XCTAssertEqual(k1.op, UInt32(OP_ALPHA))
        XCTAssertEqual(k1.flags, UInt32(F_FROM))
        XCTAssertEqual([k1.a, k1.fa, k1.dalpha], [0, 1, 0.3])
        XCTAssertEqual(k1.calpha, 5)
        // движок «забрал» пачку
        c.raw.pointee.cmd_tail = c.raw.pointee.cmd_head
        XCTAssertFalse(c.pending)
        // событие от движка
        let evBase = cmdBase + Int(CH_NCMD) * MemoryLayout<ch_cmd>.stride
        evBase.assumingMemoryBound(to: ch_evt.self).pointee = ch_evt(type: UInt32(EV_MOVED), wid: 42, t: 1.5, x: 1, y: 2, w: 3, h: 4)
        c.raw.pointee.evt_head = 1
        let evs = c.events()
        XCTAssertEqual(evs.count, 1)
        XCTAssertEqual(evs[0].type, Ev.moved)
        XCTAssertEqual(evs[0].rect, Rect(1, 2, 3, 4))
        XCTAssertEqual(c.raw.pointee.evt_tail, 1)
        XCTAssertTrue(c.events().isEmpty)
        // слот окна
        XCTAssertTrue(c.wins().isEmpty)
        let wp = (c.base + Int(ch_off(1))).assumingMemoryBound(to: ch_win.self)
        wp[3].used = 1; wp[3].wid = 77; wp[3].ax = 5; wp[3].aw = 600; wp[3].cur_alpha = 0.5; wp[3].pos.active = 1
        let ws = c.wins()
        XCTAssertEqual(ws.count, 1)
        XCTAssertEqual(ws[0].wid, 77)
        XCTAssertEqual(ws[0].real, Rect(5, 0, 600, 0))
        XCTAssertTrue(ws[0].moving)
        XCTAssertEqual(ws[0].curAlpha, 0.5)
        c.widMax = 900
        XCTAssertEqual(c.raw.pointee.wid_max, 900)
    }
}

final class JSONTests: XCTestCase {
    func testPythonFormatting() throws {
        let o = JSON.object([
            ("spaces", .object([("3", .object([
                ("tree", .object([("split", .string("v")), ("ratio", .double(0.5)), ("a", .object([("wid", .int(1))])),
                                  ("b", .object([("wid", .int(2))]))])),
                ("focus", .int(1)), ("full", .null), ("presel", .null)]))])),
            ("floating", .array([])),
            ("hidden", .array([.object([("wid", .int(5)), ("pid", .null), ("owner", .string("Телеграм \"x\"\n")),
                                        ("space", .int(3)),
                                        ("rect", .array([.double(1), .double(2.5), .double(1e-05), .double(1e16), .double(123456.789)]))])])),
        ])
        XCTAssertEqual(o.dumps(indent: 1), "{\n \"spaces\": {\n  \"3\": {\n   \"tree\": {\n    \"split\": \"v\",\n    \"ratio\": 0.5,\n    \"a\": {\n     \"wid\": 1\n    },\n    \"b\": {\n     \"wid\": 2\n    }\n   },\n   \"focus\": 1,\n   \"full\": null,\n   \"presel\": null\n  }\n },\n \"floating\": [],\n \"hidden\": [\n  {\n   \"wid\": 5,\n   \"pid\": null,\n   \"owner\": \"\\u0422\\u0435\\u043b\\u0435\\u0433\\u0440\\u0430\\u043c \\\"x\\\"\\n\",\n   \"space\": 3,\n   \"rect\": [\n    1.0,\n    2.5,\n    1e-05,\n    1e+16,\n    123456.789\n   ]\n  }\n ]\n}")
        XCTAssertEqual(o.dumps(ensureASCII: false), "{\"spaces\": {\"3\": {\"tree\": {\"split\": \"v\", \"ratio\": 0.5, \"a\": {\"wid\": 1}, \"b\": {\"wid\": 2}}, \"focus\": 1, \"full\": null, \"presel\": null}}, \"floating\": [], \"hidden\": [{\"wid\": 5, \"pid\": null, \"owner\": \"Телеграм \\\"x\\\"\\n\", \"space\": 3, \"rect\": [1.0, 2.5, 1e-05, 1e+16, 123456.789]}]}")
        let m = JSON.object([("Telegram", .array([.double(470), .int(0)])), ("X", .array([.double(0.1), .double(1e22)]))])
        XCTAssertEqual(m.dumps(), "{\"Telegram\": [470.0, 0], \"X\": [0.1, 1e+22]}")
        // разбор и обратно — то же самое
        XCTAssertEqual(try JSON.parse(o.dumps(indent: 1)).dumps(indent: 1), o.dumps(indent: 1))
    }

    func testLiveStateFileShape() throws {
        // реальный файл состояния Python-демона (только чтение) читается и пишется обратно без потерь
        let p = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../hyprwm.state.json").standardized
        guard let d = FileManager.default.contents(atPath: p.path) else { throw XCTSkip("нет \(p.path)") }
        let j = try JSON.parse(d)
        for (_, s) in j["spaces"]?.object ?? [] {
            XCTAssertEqual(SpaceState.from(s).json.dumps(), s.dumps())
        }
    }
}

final class ConfigurerTests: XCTestCase {
    /// Подделка AX: окно «упирается» в минимум 470×584; первая рамка задерживается, пока не пришли новые цели.
    final class AXSys: SysAPI {
        let lock = NSLock()
        var frames: [Rect] = []
        var sizes:[(Double,Double)]=[]
        var cur = Rect(0, 0, 800, 600)
        let gate = DispatchSemaphore(value: 0)
        var gateFirst = true
        var t = 0.0
        func now() -> Double { lock.lock(); defer { lock.unlock() }; return t }
        func sleep(_ s: Double) { lock.lock(); t += s; lock.unlock() }
        func axFrame(_ pid: Int, _ wid: Int, _ r: Rect) -> Int {
            lock.lock(); frames.append(r); let g = gateFirst; gateFirst = false; lock.unlock()
            if g { gate.wait() }
            lock.lock(); cur = Rect(r.x, r.y, max(r.w, 470), max(r.h, 584)); lock.unlock()
            return 0
        }
        func axGetFrame(_ pid: Int, _ wid: Int) -> Rect? { lock.lock(); defer { lock.unlock() }; return cur }
        func axSize(_ pid:Int,_ wid:Int,_ width:Double,_ height:Double) -> Int {
            lock.lock();defer{lock.unlock()}
            sizes.append((width,height));cur=Rect(cur.x,cur.y,max(width,470),max(height,584));return 0
        }
        func snapshot() throws -> Snapshot { throw CmdError("-") }
        func winPidLevel(_ wid: Int) -> (pid: Int?, level: Int?) { (nil, nil) }
        func frontPid() -> Int? { nil }
        func winBounds(_ wid: Int) -> Rect? { nil }
        func winAlpha(_ wid: Int) -> Double? { nil }
        func moveToSpace(_ wids: [Int], _ space: Int) {}
        func activeSpace() -> UInt64 { 0 }
        func mouse() -> (Double, Double) { (0, 0) }
        func mouseDown() -> Bool { false }
        func axTileable(_ pid: Int, _ wid: Int) -> Int { 1 }
        func axForget(_ wid: Int) {}
        func axFocus(_ pid: Int, _ wid: Int, raise: Bool) -> Int { 0 }
        func axMenuPress(_ pid: Int, _ title: String) -> Int { 0 }
        func wsClose(_ pid: Int, _ wid: Int) -> Int { 0 }
        func wsQuit(_ pid: Int) -> Int { 0 }
        func spotlight() {}
        func pgrep(_ name: String) -> Int? { nil }
        func spawn(_ argv: [String]) {}
        func background(_ f: @escaping () -> Void) { f() }
    }

    func testLatestTargetWinsAndMinimumReported() throws {
        let sys = AXSys()
        let got = DispatchSemaphore(value: 0)
        var results: [CfgResult] = []
        let lock = NSLock()
        let c = Configurer(sys: sys) { r in lock.lock(); results.append(r); lock.unlock(); got.signal() }
        c.submit([CfgJob(wid: 1, pid: 9, owner: "Telegram", to: Rect(0, 0, 300, 300))])
        Thread.sleep(forTimeInterval: 0.05)                    // первое задание висит в ax_frame
        c.submit([CfgJob(wid: 1, pid: 9, owner: "Telegram", to: Rect(0, 0, 350, 300))])
        c.submit([CfgJob(wid: 1, pid: 9, owner: "Telegram", to: Rect(0, 0, 400, 300))])
        sys.gate.signal()
        XCTAssertEqual(got.wait(timeout: .now() + 5), .success)
        Thread.sleep(forTimeInterval: 0.1)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(results.count, 1, "ответ только на последнюю цель")
        XCTAssertEqual(results[0].to, Rect(0, 0, 400, 300))
        XCTAssertEqual(results[0].got, Rect(0, 0, 470, 584))   // окно встало на свой минимум
        XCTAssertEqual(sys.frames.map(\.w), [300, 400], "промежуточная цель 350 пропущена")
    }
    func testEarlySizeOnlyKeepsLogicalDestinationAndNeverCallsPositionSetter() throws {
        let sys=AXSys(),done=expectation(description:"one size accepted")
        sys.cur=Rect(12,41,1176,850)
        let logical=Rect(605,41,583,850)
        let worker=Configurer(sys:sys) {result in
            XCTAssertEqual(result.to,logical)
            XCTAssertEqual(result.got,Rect(12,41,583,850))
            done.fulfill()
        }
        var job=CfgJob(wid:1,pid:9,owner:"Fixture",to:logical);job.sizeOnly=true
        worker.submit([job]);wait(for:[done],timeout:2)
        sys.lock.lock();defer{sys.lock.unlock()}
        XCTAssertEqual(sys.sizes.count,1);XCTAssertTrue(sys.frames.isEmpty)
    }
}
