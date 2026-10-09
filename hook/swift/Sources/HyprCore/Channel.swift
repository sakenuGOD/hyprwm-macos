// Канал демон -> движок — порт chan.py поверх hook/src/chanlib.c (тот же код, что грузит Python через
// ctypes). Структуры — из hook/src/chan.h через модуль CChan, вручную не дублируются.
// ВНИМАНИЕ: chanlib.c держит один канал на процесс (static ch) — как и в Python.
import CChan
import Foundation

public final class LiveChannel: ChannelAPI {
    public let path: String
    public let base: UnsafeMutableRawPointer
    let hdr: UnsafeMutablePointer<ch_hdr>
    let winArr: UnsafeMutablePointer<ch_win>
    private var fullLogged = false

    /// create=true — НОВЫЙ файл (O_EXCL внутри ch_open); иначе подключиться к существующему.
    public init(path: String, create: Bool) throws {
        guard let p = ch_open(path, create ? 1 : 0) else {
            throw CmdError("не открыть \(path)")
        }
        // chan.py: assert, что Python-структуры совпали с chan.h; здесь структуры и есть chan.h — сверяем
        // только, что Swift видит те же размеры, что компилятор C.
        guard MemoryLayout<ch_win>.stride == Int(ch_off(0)), MemoryLayout<ch_var>.stride == Int(ch_off(3)),
              MemoryLayout<ch_hdr>.stride == Int(ch_off(7)) else {
            throw CmdError("chan.h: размеры структур в Swift и C разошлись")
        }
        self.path = path
        base = p
        hdr = p.assumingMemoryBound(to: ch_hdr.self)
        winArr = (p + Int(ch_off(1))).assumingMemoryBound(to: ch_win.self)
    }

    public var magicOK: Bool { hdr.pointee.magic == CH_MAGIC }
    public var sizeOK: Bool { hdr.pointee.size == ch_abi() }
    public var ticks: UInt32 { hdr.pointee.ticks }
    public func setStop() { hdr.pointee.stop = 1 }
    public var raw: UnsafeMutablePointer<ch_hdr> { hdr }

    private func full() {
        if !fullLogged { log("кольцо команд полно (движок не забирает)") }
        fullLogged = true
    }

    // ── команды ──────────────────────────────────────────────────────────
    public func geom(_ wid: Int, _ to: Rect, _ cpos: Int, _ csize: Int, dpos: Double, dsize: Double, frm: Rect?,
                     move: Bool, warp: Bool, stretch: Bool) {
        let fl = (frm != nil ? UInt32(F_FROM) : 0) | (move ? UInt32(F_MOVE) : 0) | (stretch ? UInt32(F_STRETCH) : 0)
        let f = frm ?? Rect(0, 0, 0, 0)
        // ОТЛИЧИЕ: Python бросал RuntimeError при полном кольце (в главном цикле — падение демона);
        // здесь — запись в лог, команда теряется (движок всё равно мёртв, сторож alive() его переставит).
        if ch_geom(Int32(warp ? OP_WARP : OP_GEOM), UInt32(wid), fl, to.x, to.y, to.w, to.h, f.x, f.y, f.w, f.h,
                   UInt32(cpos), UInt32(csize), dpos, dsize) != 0 { full() } else { fullLogged = false }
    }

    public func alpha(_ wid: Int, _ a: Double, _ curve: Int, _ dur: Double, frm: Double?) {
        if ch_alpha(UInt32(wid), frm != nil ? UInt32(F_FROM) : 0, a, frm ?? 0, UInt32(curve), dur) != 0 { full() }
    }

    public func under(_ wid: Int, _ under: Int) { _ = ch_under(UInt32(wid), UInt32(under)) }
    public func forget(_ wid: Int) { _ = ch_forget(UInt32(wid)) }
    public func commit() { ch_commit() }

    // ── кривые ───────────────────────────────────────────────────────────
    public func bezier(_ i: Int, _ p1: (Double, Double), _ p2: (Double, Double)) {
        ch_curve_bezier(Int32(i), Float(p1.0), Float(p1.1), Float(p2.0), Float(p2.1))
    }
    public func spring(_ i: Int, _ mass: Double, _ k: Double, _ d: Double) { ch_curve_spring(Int32(i), mass, k, d) }

    // ── состояние ────────────────────────────────────────────────────────
    public func events() -> [EngEvent] {
        var out: [EngEvent] = []
        var e = ch_evt()
        while ch_event(&e) != 0 {
            out.append(EngEvent(type: Int(e.type), wid: Int(e.wid), t: e.t, rect: Rect(e.x, e.y, e.w, e.h)))
        }
        return out
    }

    public func wins() -> [EngWin] {
        var out: [EngWin] = []
        for i in 0..<Int(CH_NW) {
            let w = winArr[i]
            if w.used == 0 { continue }
            out.append(EngWin(wid: Int(w.wid), pos: (w.pos.v.0, w.pos.v.1), size: (w.size.v.0, w.size.v.1),
                              posActive: w.pos.active != 0, sizeActive: w.size.active != 0,
                              alphaActive: w.alpha.active != 0, settling: w.settling != 0, curAlpha: w.cur_alpha,
                              held: w.held != 0, radius: w.radius, a: Rect(w.ax, w.ay, w.aw, w.ah)))
        }
        return out
    }

    public var stats: EngStats {
        let h = hdr.pointee
        var s = EngStats()
        s.ticks = Int(h.ticks); s.nactive = Int(h.nactive); s.errors = Int(h.errors)
        s.ticksLate = Int(h.ticks_late); s.teSkips = Int(h.te_skips)
        s.tickUsMax = h.tick_us_max; s.tickUsLast = h.tick_us_last
        return s
    }

    static let offTail = MemoryLayout<ch_hdr>.offset(of: \ch_hdr.cmd_tail)!
    static let offHead = MemoryLayout<ch_hdr>.offset(of: \ch_hdr.cmd_head)!
    public var pending: Bool {
        // cmd_tail пишет движок, cmd_head — мы; чтение из общей памяти при каждом вызове
        base.load(fromByteOffset: LiveChannel.offTail, as: UInt32.self) !=
            base.load(fromByteOffset: LiveChannel.offHead, as: UInt32.self)
    }

    public var widMax: Int {
        get { Int(hdr.pointee.wid_max) }
        set { hdr.pointee.wid_max = UInt32(truncatingIfNeeded: newValue) }
    }
}

