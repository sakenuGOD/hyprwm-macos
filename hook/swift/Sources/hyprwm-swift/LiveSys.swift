// Живая система: SkyLight/CG/AX через C-цели (hook/src/axlib.c, winsnap.m и обёртки sys.c).
// Всё, что здесь, обращается к WindowServer — в тестах не используется.
import CAX
import CSnap
import Foundation
import HyprCore

final class LiveSys: SysAPI {
    private var buf = [CChar](repeating: 0, count: 1 << 21)

    func now() -> Double { Date().timeIntervalSince1970 }
    func sleep(_ s: Double) { usleep(useconds_t(max(0, s) * 1e6)) }

    func snapshot() throws -> Snapshot {
        var n = ws_snapshot(&buf, Int32(buf.count))
        if n < 0 {                                   // ОТЛИЧИЕ: Python падал «не влез в буфер»; здесь буфер растёт
            buf = [CChar](repeating: 0, count: Int(-n) + 4096)
            n = ws_snapshot(&buf, Int32(buf.count))
            if n < 0 { throw CmdError("снимок окон не влез в буфер") }
        }
        let j = try buf.withUnsafeBufferPointer { p in
            try JSON.parse(Array(UnsafeRawBufferPointer(start: p.baseAddress, count: Int(n))))
        }
        return Snapshot.parse(j)
    }

    func winPidLevel(_ wid: Int) -> (pid: Int?, level: Int?) {
        var p: Int32 = 0, lv: Int32 = 0
        if hs_win_pid_level(UInt32(wid), &p, &lv) != 0 { return (nil, nil) }
        return (Int(p), Int(lv))
    }

    func frontPid() -> Int? {
        var p: Int32 = 0
        return hs_front_pid(&p) == 0 ? Int(p) : nil
    }

    func winBounds(_ wid: Int) -> Rect? {
        var r = [Double](repeating: 0, count: 4)
        return hs_win_bounds(UInt32(wid), &r) == 0 ? Rect(r[0], r[1], r[2], r[3]) : nil
    }

    func winAlpha(_ wid: Int) -> Double? {
        var a: Float = -1
        return hs_win_alpha(UInt32(wid), &a) == 0 ? Double(a) : nil
    }

    func moveToSpace(_ wids: [Int], _ space: Int) {
        let w = wids.map { Int32(truncatingIfNeeded: $0) }
        w.withUnsafeBufferPointer { hs_move_to_space($0.baseAddress, Int32(w.count), UInt64(space)) }
    }

    func activeSpace() -> UInt64 { hs_active_space() }

    func mouse() -> (Double, Double) {
        var x = 0.0, y = 0.0
        hs_mouse(&x, &y)
        return (x, y)
    }

    func mouseDown() -> Bool { hs_mouse_down() != 0 }

    func axTileable(_ pid: Int, _ wid: Int) -> Int { Int(ax_tileable(Int32(pid), UInt32(wid))) }
    func axFrame(_ pid: Int, _ wid: Int, _ r: Rect) -> Int { Int(ax_frame(Int32(pid), UInt32(wid), r.x, r.y, r.w, r.h)) }
    func axGetFrame(_ pid: Int, _ wid: Int) -> Rect? {
        var o = [Double](repeating: 0, count: 4)
        return ax_get_frame(Int32(pid), UInt32(wid), &o) == 0 ? Rect(o[0], o[1], o[2], o[3]) : nil
    }
    func axForget(_ wid: Int) { ax_forget(UInt32(wid)) }
    func axFocus(_ pid: Int, _ wid: Int, raise: Bool) -> Int { Int(ax_focus(Int32(pid), UInt32(wid), raise ? 1 : 0)) }
    func axMenuPress(_ pid: Int, _ title: String) -> Int { Int(ax_menu_press(Int32(pid), title)) }

    func wsClose(_ pid: Int, _ wid: Int) -> Int { Int(ws_close(Int32(pid), UInt32(wid))) }
    func wsQuit(_ pid: Int) -> Int { Int(ws_quit(Int32(pid))) }

    func spotlight() { hs_spotlight() }

    func pgrep(_ name: String) -> Int? {
        let out = run(["/usr/bin/pgrep", "-x", name])
        return out.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }.first
    }

    func spawn(_ argv: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        do { try p.run() } catch { log("запуск \(argv): \(error)") }
    }

    func background(_ f: @escaping () -> Void) { DispatchQueue.global(qos: .userInitiated).async(execute: f) }

    func run(_ argv: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
}
