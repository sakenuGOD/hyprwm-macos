// Обёртка движка в WindowServer — порт hook/engine.py. Сам движок (anim4.c) и его установщик
// (scripts/install4.py через run_lldb.sh) не меняются и вызываются так же, как из Python.
// Каталог канала /tmp/hyprwm зашит в install4.py — поэтому здесь он тоже постоянный.
import CChan
import CryptoKit
import Foundation
import HyprCore

/// Канал-заглушка до установки движка (все команды теряются; Python в этом состоянии падал на None).
final class DeadChannel: ChannelAPI {
    func geom(_ wid: Int, _ to: Rect, _ cpos: Int, _ csize: Int, dpos: Double, dsize: Double, frm: Rect?, move: Bool,
              warp: Bool, stretch: Bool) {}
    func alpha(_ wid: Int, _ a: Double, _ curve: Int, _ dur: Double, frm: Double?) {}
    func under(_ wid: Int, _ under: Int) {}
    func forget(_ wid: Int) {}
    func commit() {}
    func events() -> [EngEvent] { [] }
    func wins() -> [EngWin] { [] }
    var stats: EngStats { EngStats() }
    var pending: Bool { false }
    var widMax: Int { get { 1 } set {} }
}

final class LiveEngine: EngineAPI {
    static let dir = "/tmp/hyprwm"
    static let ptr = dir + "/chan_path"   // путь к текущему каналу; каждая установка — НОВЫЙ файл
    let hook: String
    let cfg: HyprConfig
    var ch: LiveChannel?
    private let dead = DeadChannel()
    private var pt: UInt32?
    var c: ChannelAPI { ch ?? dead }
    var statePath: String { hook + "/anim4.state" }

    init(hook: String, cfg: HyprConfig) {
        self.hook = hook
        self.cfg = cfg
    }

    func anim(_ leaf: String) -> (curve: Int, dur: Double, on: Bool) { cfg.anim(leaf) }

    static func wsPid() -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "WindowServer"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }.first
    }

    func alive() -> Bool {
        guard let ch, ch.magicOK, ch.sizeOK else { return false }   // канал другой версии структуры — переставить
        guard let st = try? String(contentsOfFile: statePath, encoding: .utf8),
              let p = st.split(whereSeparator: { $0.isWhitespace }).first.flatMap({ Int($0) }), p == LiveEngine.wsPid()
        else { return false }
        let t = ch.ticks
        if t != pt { pt = t; return true }                           // тикал с прошлой проверки — без сна
        usleep(50_000)
        pt = ch.ticks
        return pt != t
    }

    /// startup=true (только при запуске демона): если движок в WS другой сборки, чем anim4.bin, —
    /// переставить безопасно. Работающий демон движок сам не трогает.
    func ensure(startup: Bool) throws {
        if startup && staleBuild() {
            if ch == nil && FileManager.default.fileExists(atPath: LiveEngine.ptr) { ch = try? openExisting() }
            try install()
            return
        }
        if ch == nil && FileManager.default.fileExists(atPath: LiveEngine.ptr) { ch = try? openExisting() }
        if alive() {
            setup()
            return
        }
        try install()
    }

    func openExisting() throws -> LiveChannel {
        let p = try String(contentsOfFile: LiveEngine.ptr, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try LiveChannel(path: p, create: false)
    }

    func staleBuild() -> Bool {
        guard let st = try? String(contentsOfFile: statePath, encoding: .utf8) else { return true }
        let f = st.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let have = f.count > 4 ? f[4] : ""
        guard let bin = FileManager.default.contents(atPath: hook + "/anim4.bin") else { return true }
        let hex = Insecure.SHA1.hash(data: bin).map { String(format: "%02x", $0) }.joined()
        return have != String(hex.prefix(12))
    }

    /// Поставить движок заново. Старый сначала останавливается (stop) и мы ждём, пока его тик перестанет
    /// идти; новый получает НОВЫЙ файл канала — старый файл никогда не обрезается (SIGBUS в WS).
    func install() throws {
        if let ch, ch.magicOK {
            ch.setStop()
            for _ in 0..<20 {
                let t = ch.ticks
                usleep(50_000)
                if ch.ticks == t { break }
            }
        }
        let old = ch?.path
        log("ставлю движок в WindowServer (экран замрёт на ~2 с)")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: LiveEngine.dir, withIntermediateDirectories: true)
        chmod(LiveEngine.dir, 0o777)
        let path = "\(LiveEngine.dir)/chan.\(getpid()).\(Int(Date().timeIntervalSince1970 * 1000))"
        guard !fm.fileExists(atPath: path) else { throw CmdError("канал \(path) уже есть") }
        let nc = try LiveChannel(path: path, create: true)
        let tmp = LiveEngine.ptr + ".tmp"
        try path.write(toFile: tmp, atomically: false, encoding: .utf8)
        guard rename(tmp, LiveEngine.ptr) == 0 else { throw CmdError("rename chan_path") }
        ch = nc
        setup()
        try "1".write(toFile: LiveEngine.dir + "/display", atomically: false, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: hook + "/run_lldb.sh")
        p.arguments = [hook + "/scripts/install4.py"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let inst = out.split(separator: "\n").filter { $0.hasPrefix("INST") }
        log(inst.isEmpty ? String(out.suffix(400)) : inst.joined(separator: " "))
        if !alive() { throw CmdError("движок не запустился: " + String(out.suffix(400))) }
        if let old, old != path { unlink(old) }                    // отображение у старого движка остаётся валидным
    }

    /// Кривые Hyprland -> номера в канале; параметры такта и ожидания размера (engine.setup).
    func setup() {
        guard let ch else { return }
        let h = ch.raw
        h.pointee.idle_poll = 0.004; h.pointee.phase = 0.1; h.pointee.margin = 0.002   // опрос команд каждые 4 мс (A2)
        // Ожидание кадра приложения перед стартом стоило 2 кадра задержки; HYPRWM_HOLD=0.017 — вернуть.
        h.pointee.hold_max = Double(ProcessInfo.processInfo.environment["HYPRWM_HOLD"] ?? "-1") ?? -1
        h.pointee.settle = 1.0; h.pointee.settle_px = 8.0    // ждать конечный размер от приложения; сетка терминалов
        let ts = cfg.timeScale
        for (i, (_, cv)) in cfg.sortedCurves().enumerated() where i < 16 {
            switch cv {
            case let .spring(mass, k, d): ch.spring(i, mass, k / (ts * ts), d / ts)   // время ×TIME_SCALE без изменения формы
            case let .bezier(p1, p2): ch.bezier(i, p1, p2)
            }
        }
    }
}
