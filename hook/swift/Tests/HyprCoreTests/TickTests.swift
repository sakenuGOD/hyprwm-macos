// Main-loop tick (WM.run while True body) with fakes: snapshot gate (Q2), command before the first
// snapshot, configure response -> retarget, EV_GONE, startup rescue. No Python run() oracle exists (it is
// an infinite select loop); behavior is checked manually against REFERENCE_hyprwm.py, with invariants here.
@testable import HyprCore
import XCTest

final class SnapWorld: SysAPI {
    let inner = FakeWorld()
    var snap: Snapshot
    var snapCalls = 0
    init(_ s: Snapshot) { snap = s }
    func now() -> Double { inner.now() }
    func sleep(_ s: Double) {}
    func snapshot() throws -> Snapshot { snapCalls += 1; return snap }
    func winPidLevel(_ wid: Int) -> (pid: Int?, level: Int?) { inner.winPidLevel(wid) }
    func frontPid() -> Int? { inner.front }
    func winBounds(_ wid: Int) -> Rect? { snap.windows.first { $0.wid == wid }?.rect }
    func winAlpha(_ wid: Int) -> Double? { 1 }
    func moveToSpace(_ wids: [Int], _ space: Int) {}
    func activeSpace() -> UInt64 { UInt64(snap.space) }
    func mouse() -> (Double, Double) { inner.m }
    func mouseDown() -> Bool { inner.md }
    func axTileable(_ pid: Int, _ wid: Int) -> Int { 1 }
    func axFrame(_ pid: Int, _ wid: Int, _ r: Rect) -> Int { 0 }
    func axGetFrame(_ pid: Int, _ wid: Int) -> Rect? { nil }
    func axForget(_ wid: Int) { inner.axForget(wid) }
    func axFocus(_ pid: Int, _ wid: Int, raise: Bool) -> Int { inner.axFocus(pid, wid, raise: raise) }
    func axMenuPress(_ pid: Int, _ title: String) -> Int { 0 }
    func wsClose(_ pid: Int, _ wid: Int) -> Int { 0 }
    func wsQuit(_ pid: Int) -> Int { 0 }
    func spotlight() {}
    func pgrep(_ name: String) -> Int? { nil }
    func spawn(_ argv: [String]) {}
    func background(_ f: @escaping () -> Void) { f() }
}

final class TickTests: XCTestCase {
    func testTickGatingCommandsAndRetarget() throws {
        hyprLogSink = { _ in }
        let cfg = try Fx.config()
        let area = Rect(0, 33, 1470, 923)
        let w1 = WinInfo(wid: 11, pid: 1, owner: "Ghostty", x: 12, y: 41, w: 700, h: 870, on: true, space: 3)
        let w2 = WinInfo(wid: 22, pid: 2, owner: "Telegram", x: 740, y: 41, w: 700, h: 870, on: true, space: 3)
        let deco = WinInfo(wid: 99, pid: 3, owner: "hyprdeco", x: 0, y: 0, w: 900, h: 900, on: true, space: 3)
        let sys = SnapWorld(Snapshot(space: 3, stable: true, area: area, windows: [w1, w2, deco]))
        sys.inner.t = 1000
        sys.inner.m = (1000, 500)
        let eng = FakeEngine(cfg: cfg)
        let rec = JobRecorder()
        let tmp = NSTemporaryDirectory() + "hyprwm-tick-\(getpid())"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let wm = WM(sys: sys, eng: eng, deco: NullDeco(), cfg: cfg, statePath: tmp + "/s.json", minsizePath: tmp + "/m.json",
                    cfgSink: rec)
        let path = tmp + "/ctl"
        wm.server = try CommandServer(path: path)

        // command arrived before the first snapshot: process after snapshot in the same tick
        let cl = SocketTests().client(path, "status\n")
        wm.tick(socketReady: true)
        let reply = SocketTests().reply(cl)
        let st = try JSON.parse(reply.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(st["space"]?.int, 3)
        XCTAssertEqual(sys.snapCalls, 1)
        XCTAssertEqual(wm.snaps, 1)
        // windows tiled, hyprdeco backdrop filtered, batch sent to engine, configure both windows
        XCTAssertEqual(Set(wm.target.keys), [11, 22])
        XCTAssertEqual(Set(rec.jobs.map { $0.array![0].int! }), [11, 22])
        XCTAssertTrue(eng.ch.ops.contains { $0["op"]?.string == "commit" })
        XCTAssertEqual(eng.ch.widMax, 22)        // as in Python: windows excluding backdrops
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp + "/s.json"))

        // nothing changed and 250 ms has not elapsed: no snapshot (Q2)
        sys.inner.t += 0.016
        wm.tick(socketReady: false)
        XCTAssertEqual(sys.snapCalls, 1)
        sys.inner.t += 0.3
        wm.tick(socketReady: false)
        XCTAssertEqual(sys.snapCalls, 2, "reconcile every 250 ms")

        // configure response: Telegram did not shrink; learn minimum and retarget in this tick
        let to = wm.target[22]!
        rec.jobs = []; eng.ch.ops = []
        wm.cfgQ.append(CfgResult(wid: 22, owner: "Telegram", to: to, got: Rect(to.x, to.y, to.w + 100, to.h), e: 0, pre: nil))
        sys.inner.t += 0.016
        wm.tick(socketReady: false)
        XCTAssertEqual(sys.snapCalls, 3, "configure response triggers snapshot")
        XCTAssertEqual(wm.mins["Telegram"]?[0].double, to.w + 100)
        XCTAssertNotEqual(wm.target[22], to, "layout recomputed with minimum")

        // EV_GONE: window closed; clear target and AX cache, remove from layout
        sys.snap.windows.removeAll { $0.wid == 11 }
        eng.ch.evs = [EngEvent(type: Ev.gone, wid: 11, t: 0, rect: Rect(0, 0, 0, 0))]
        sys.inner.t += 0.016
        wm.tick(socketReady: false)
        XCTAssertNil(wm.target[11])
        XCTAssertTrue(sys.inner.calls.contains(.array([.string("ax_forget"), .int(11)])))
        XCTAssertEqual(Dwindle.leaves(wm.sp(3).tree).map(\.wid), [22])

        // unstable snapshot (desktop switching): tick does nothing
        sys.snap.stable = false
        let before = eng.ch.ops.count
        sys.inner.t += 0.3
        wm.tick(socketReady: false)
        XCTAssertEqual(eng.ch.ops.count, before)
    }
}
