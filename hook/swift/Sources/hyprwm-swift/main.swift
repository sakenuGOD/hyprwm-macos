// hyprwm-swift — демон тайлинга (порт hook/hyprwm.py, MASTER.md §11 П1а).
//
// Запуск демона:   hyprwm-swift                 (лог — stdout, как у Python: start.sh пишет в /tmp/hyprwm.log)
// Сухие режимы (WindowServer, канал и сокет НЕ трогают):
//   hyprwm-swift --print-config                 зазоры, dwindle, анимации и номера кривых из hypr_cfg.json
//   hyprwm-swift --layout STATE SPACE X Y W H   раскладка стола из файла состояния (без минимумов)
//
// Переменные окружения:
//   HYPRWM_HOOK        каталог hook/ (по умолчанию ищется вверх от бинарника по config/hypr_shim.lua)
//   HYPRWM_STATE_DIR   где hyprwm.state.json и minsize_app.json (по умолчанию /tmp/hyprwm-swift —
//                      чтобы случайный запуск не перетёр файлы Python-демона; для боевой замены — $H)
//   HYPRWM_CTL         сокет команд (по умолчанию /tmp/hyprwm.ctl)
//   HYPRWM_TIME_SCALE, HYPRWM_HOLD, HYPRWM_DEBUG — как у Python-демона
//   HYPRWM_NO_DECO=1   не запускать build/hyprdeco (подложки)
import AppKit
import Foundation
import HyprCore

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)                       // запись в умерший hyprdeco/клиента не должна убивать демон

let env = ProcessInfo.processInfo.environment

func findHook() -> String {
    if let h = env["HYPRWM_HOOK"] { return h }
    var u = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    for _ in 0..<8 {
        if FileManager.default.fileExists(atPath: u.path + "/config/hypr_shim.lua") { return u.path }
        u = u.deletingLastPathComponent()
    }
    return NSHomeDirectory() + "/Developer/re-tools/hook"
}

let hook = findHook()
let timeScale = Double(env["HYPRWM_TIME_SCALE"] ?? "1.2") ?? 1.2
let args = Array(CommandLine.arguments.dropFirst())

func die(_ m: String) -> Never {
    FileHandle.standardError.write((m + "\n").data(using: .utf8)!)
    exit(1)
}

switch args.first {
case "--help", "-h":
    print("hyprwm-swift [--print-config | --layout STATE SPACE X Y W H]   (см. hook/swift/README.md)")
    exit(0)

case "--print-config":
    do {
        let cfg = try HyprConfig.load(configDir: hook + "/config", rebuild: false, timeScale: timeScale)
        let (gi, go) = cfg.gaps()
        let t = cfg.makeDwindle()
        print("hook:", hook)
        print("gaps_in", pyFloat(gi), "gaps_out", go.values.map(pyFloat), "split_width_mult", pyFloat(t.splitWidthMult),
              "default_ratio", pyFloat(t.defaultRatio))
        for (i, (name, cv)) in cfg.sortedCurves().enumerated() { print("кривая", i, name, cv) }
        for leaf in ["windowsIn", "windowsOut", "windowsMove", "fadeIn", "fadeOut", "border", "workspaces"] {
            let a = cfg.animation(leaf), e = cfg.anim(leaf)
            print(leaf, a.kind, a.curve, "speed", pyFloat(a.speed), "style '\(a.style)'", "-> кривая", e.curve,
                  "длит", pyFloat(e.dur), e.on ? "вкл" : "выкл")
        }
        print("правил float:", cfg.floatRules.count)
    } catch { die("конфиг: \(error)") }
    exit(0)

case "--layout":
    guard args.count == 7, let x = Double(args[3]), let y = Double(args[4]), let w = Double(args[5]),
          let h = Double(args[6]) else { die("--layout STATE SPACE X Y W H") }
    do {
        let cfg = try HyprConfig.load(configDir: hook + "/config", rebuild: false, timeScale: timeScale)
        let st = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: args[1])))
        let t = cfg.makeDwindle()
        let tree = Node.from(st["spaces"]?[args[2]]?["tree"])
        let area = Rect(x, y, w, h)
        for (wid, b) in t.boxes(tree, area) {
            let r = t.withGaps(b, area)
            print(wid, [r.x, r.y, r.w, r.h].map { Int(pyRound($0)) })
        }
    } catch { die("раскладка: \(error)") }
    exit(0)

case nil:
    break

default:
    die("неизвестный аргумент \(args[0]) (--help)")
}

// ── демон ───────────────────────────────────────────────────────────────
let ctl = env["HYPRWM_CTL"] ?? "/tmp/hyprwm.ctl"
let stateDir = env["HYPRWM_STATE_DIR"] ?? "/tmp/hyprwm-swift"
try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)

if CommandServer.isAlive(ctl) {
    die("на \(ctl) уже отвечает демон — не запускаюсь поверх (сначала hook/stop.sh)")
}

let cfg: HyprConfig
do { cfg = try HyprConfig.load(configDir: hook + "/config", rebuild: true, timeScale: timeScale) } catch { die("конфиг: \(error)") }
let sys = LiveSys()
let eng = LiveEngine(hook: hook, cfg: cfg)
let deco: DecoAPI
if env["HYPRWM_NO_DECO"] == "1" {
    deco = NullDeco()
} else {
    do { deco = try Deco(hook: hook) } catch { log("подложки не запущены:", error); deco = NullDeco() }
}
let wm = WM(sys: sys, eng: eng, deco: deco, cfg: cfg, statePath: stateDir + "/hyprwm.state.json",
            minsizePath: stateDir + "/minsize_app.json")
wm.cfgSink = Configurer(sys: sys) { r in
    DispatchQueue.main.async {                 // ответ configure — событие: сразу такт (в Python — опрос cfg_q)
        wm.cfgQ.append(r)
        wm.tick(socketReady: false)
    }
}
do { wm.server = try CommandServer(path: ctl) } catch { die("сокет: \(error)") }
do { try eng.ensure(startup: true) } catch { die("движок: \(error)") }
log("hyprwm запущен (swift); состояние в \(stateDir), сокет \(ctl)")

// такт 16 мс (POLL в Python) — сверка и follow_mouse; всё остальное — по событиям
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(1))
timer.setEventHandler { wm.tick(socketReady: false) }
timer.resume()

// команда в сокете — обработать сразу (не ждать такта)
let sockSrc = DispatchSource.makeReadSource(fileDescriptor: wm.server!.fd, queue: .main)
sockSrc.setEventHandler { wm.tick(socketReady: true) }
sockSrc.resume()

// активация приложения — такт сразу (front_pid сверяется в такте через _SLPSGetFrontProcess, как в Python)
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                  object: nil, queue: .main) { _ in wm.tick(socketReady: false) }

CFRunLoopRun()
