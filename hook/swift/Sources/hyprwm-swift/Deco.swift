// Окна-подложки (build/hyprdeco) — порт deco.py: отдельный процесс, управление строками по stdin,
// ответ «wid <окно> <подложка>» по stdout. Ступенька до CA-слоя в дереве окна (MASTER §9.3).
import Foundation
import HyprCore

final class Deco: DecoAPI {
    // фон приложений, которые рисуют свой цвет (Ghostty: Catppuccin Mocha base, background-opacity 0.85)
    static let colors: [String: (Double, Double, Double, Double)] = ["Ghostty": (0x1e / 255.0, 0x1e / 255.0, 0x2e / 255.0, 0.85)]
    let p = Process()
    let inp = Pipe(), outp = Pipe()
    let lock = NSLock()
    var wids: [Int: Int] = [:]          // wid окна -> wid подложки (пишет поток чтения)
    var asked = Set<Int>()
    var radius: [Int: Double] = [:]

    init(hook: String) throws {
        p.executableURL = URL(fileURLWithPath: hook + "/build/hyprdeco")
        p.standardInput = inp
        p.standardOutput = outp
        try p.run()
        let h = outp.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            var acc = Data()
            while true {
                let d = h.availableData
                if d.isEmpty { return }
                acc.append(d)
                while let nl = acc.firstIndex(of: 0x0a) {
                    let line = String(decoding: acc[acc.startIndex..<nl], as: UTF8.self)
                    acc.removeSubrange(acc.startIndex...nl)
                    let a = line.split(separator: " ")
                    if a.count == 3, a[0] == "wid", let w = Int(a[1]), let u = Int(a[2]) {
                        self?.lock.lock(); self?.wids[w] = u; self?.lock.unlock()
                    }
                }
            }
        }
    }

    private func send(_ s: String) {
        do { try inp.fileHandleForWriting.write(contentsOf: (s + "\n").data(using: .utf8)!) } catch { log("подложки:", error) }
    }

    private func under(_ wid: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return wids[wid]
    }

    /// Создать подложку; когда движок узнает радиус скругления окна у сервера — обновить его.
    func ensure(_ wid: Int, _ owner: String, _ r: Double) {
        if asked.contains(wid) && (r == 0 || radius[wid] == r) { return }
        asked.insert(wid)
        radius[wid] = r
        let (cr, cg, cb, ca) = Deco.colors[owner] ?? (-1, -1, -1, 1.0)
        send(String(format: "new %d %.4f %.4f %.4f %.1f %.3f", wid, cr, cg, cb, r != 0 ? r : 16, ca))
    }

    /// Перед анимацией: реальная рамка = цель, прямо под окном.
    func place(_ wid: Int, _ rect: Rect) -> Int? {
        if under(wid) != nil {
            send(String(format: "frame %d %.1f %.1f %.1f %.1f", wid, rect.x, rect.y, rect.w, rect.h))
            send("below \(wid) \(wid)")
        }
        return under(wid)
    }

    func sample(_ wid: Int) {
        if under(wid) != nil { send("sample \(wid) \(wid)") }
    }

    func drop(_ wid: Int) {
        if asked.contains(wid) {
            asked.remove(wid)
            lock.lock(); wids[wid] = nil; lock.unlock()
            send("del \(wid)")
        }
    }
}
