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
    if Bundle.main.bundleIdentifier == "dev.hyprwm.HyprWM",
       let root=Bundle.main.object(forInfoDictionaryKey:"HyprWMSourceRoot") as? String,
       FileManager.default.fileExists(atPath:root+"/hook/config/hypr_shim.lua") {
        return root+"/hook"
    }
    var u = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    for _ in 0..<8 {
        if FileManager.default.fileExists(atPath: u.path + "/config/hypr_shim.lua") { return u.path }
        u = u.deletingLastPathComponent()
    }
    return NSHomeDirectory() + "/Developer/re-tools/hook"
}

let hook = findHook()
let timeScale = Double(env["HYPRWM_TIME_SCALE"] ?? "1") ?? 1
let args: [String] = {
    let supplied=Array(CommandLine.arguments.dropFirst())
    if supplied.isEmpty, Bundle.main.bundleIdentifier == "dev.hyprwm.HyprWM",
       Bundle.main.object(forInfoDictionaryKey:"HyprWMLaunchRole") as? String == "menu-only" {
        return ["--menu-only"]
    }
    return supplied
}()

func die(_ m: String) -> Never {
    FileHandle.standardError.write((m + "\n").data(using: .utf8)!)
    exit(1)
}

if args.first == "--menu-only" {
    guard args.count == 1 || args == ["--menu-only", "--show-settings"] else { die("--menu-only [--show-settings]") }
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let client = ControlClient(path: env["HYPRWM_CTL"] ?? "/tmp/hyprwm.ctl")
    let queue = DispatchQueue(label: "hyprwm.menu.control", qos: .userInitiated)
    let options = (try? RuntimeOptions.load(configDir: hook + "/config")) ?? .standard
    let menu = MenuBarController(hook: hook, companion: true, startupAnimation: options.startupAnimation) { command, completion in
        queue.async {
            let result = Result { try client.request(command) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    if args.contains("--show-settings") { menu.showSettings() }
    withExtendedLifetime(menu) { application.run() }
    exit(0)
}

if args.first == "--ui-preview" {
    var section:String?, step:Int?, index=1
    while index < args.count {
        guard index+1 < args.count else { die("--ui-preview [--section SECTION] [--onboarding-step 0..3]") }
        if args[index] == "--section", ["general","layout","animations","appearance","focus","hotkeys","rules","advanced","about","menu"].contains(args[index+1]) { section=args[index+1] }
        else if args[index] == "--onboarding-step", let value=Int(args[index+1]), (0...3).contains(value) { step=value }
        else { die("invalid UI preview option") };index+=2
    }
    setenv("HYPRWM_UI_PREVIEW","1",1)
    let application=NSApplication.shared;application.setActivationPolicy(.accessory)
    let menu=MenuBarController(hook:hook,companion:true,startupAnimation:false) { command,completion in
        completion(.success(command == "status" ? "{\"runtime\":\"preview\",\"enabled\":true,\"space\":1,\"hidden\":[],\"engine\":{\"active\":0,\"errors\":0,\"tick_us_last\":40}}" : "preview: no runtime mutation"))
    }
    menu.showPreview(section:section,onboardingStep:step)
    withExtendedLifetime(menu) { application.run() };exit(0)
}

if args == ["--diagnose"] {
    print(diagnose(hook: hook, controlPath: env["HYPRWM_CTL"] ?? "/tmp/hyprwm.ctl").dumps(ensureASCII: false))
    exit(0)
}
if args == ["--workspace-observe"] {
    do {
        let before=try VerifiedPublicWorkspace.diagnostic(),sys=LiveSys(),snapshot=try sys.snapshot()
        var after=try VerifiedPublicWorkspace.diagnostic()
        for (key,value) in OrdinaryWorkspace.describe(snapshot:snapshot,hook:hook).object ?? [] {after=after.setting(key,value)}
        after=after.setting("native_current_window_count",.int(snapshot.windows.filter{$0.space==snapshot.space}.count))
        if before["generation"] != after["generation"] || before["displays"] != after["displays"] ||
            OverviewBinding.integer(before["active_before"]) != snapshot.space || OverviewBinding.integer(after["active_after"]) != snapshot.space ||
            before["consistent"] != .bool(true) || after["consistent"] != .bool(true) {after=after.setting("consistent",.bool(false))}
        print(after.dumps(ensureASCII:false))
    }
    catch { die("workspace observer: \(error)") };exit(0)
}
if args.first == "--settings-check" {
    guard args.count == 2 else { die("--settings-check PATH") }
    do { try SettingsValidation.validate(Data(contentsOf:URL(fileURLWithPath:args[1])),hook:hook);print("valid") }
    catch { die("settings: \(error)") };exit(0)
}
if args.first == "--settings-merge-check" {
    guard args.count == 4 else { die("--settings-merge-check BASE DISK PATCH") }
    do {
        func readObject(_ path:String) throws -> [String:Any] {
            let bytes=try Data(contentsOf:URL(fileURLWithPath:path));guard bytes.count <= 262144, let object=try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw CmdError("bounded JSON object required") };return object
        }
        let result=try SettingsPersistence.merge(base:readObject(args[1]),disk:readObject(args[2]),changes:readObject(args[3]))
        let bytes=try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.withoutEscapingSlashes]);print(String(decoding:bytes,as:UTF8.self))
    } catch { die("settings merge: \(error)") };exit(0)
}

switch args.first {
case "--help", "-h":
    print("hyprwm-swift [--menu-only [--show-settings] | --diagnose | --print-config | --layout STATE SPACE X Y W H]   (см. hook/swift/README.md)")
    exit(0)

case "--print-config":
    do {
        let base = try HyprConfig.load(configDir: hook + "/config", rebuild: false, timeScale: timeScale)
        let cfg = try NativeRuntimeConfig.load(base: base, configDir: hook + "/config", environment: env)
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
        let base = try HyprConfig.load(configDir: hook + "/config", rebuild: false, timeScale: timeScale)
        let cfg = try NativeRuntimeConfig.load(base: base, configDir: hook + "/config", environment: env)
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

if CommandServer.isAlive(ctl) || (ctl != "/tmp/hyprwm.ctl" && CommandServer.isAlive("/tmp/hyprwm.ctl")) {
    die("на \(ctl) уже отвечает демон — не запускаюсь поверх (сначала hook/stop.sh)")
}

let cfg: HyprConfig
do {
    let base = try HyprConfig.load(configDir: hook + "/config", rebuild: env["HYPRWM_ADOPT_ENGINE"] != "1", timeScale: timeScale)
    cfg = try NativeRuntimeConfig.load(base: base, configDir: hook + "/config", environment: env)
} catch { die("конфиг: \(error)") }
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
do { wm.options = try RuntimeOptions.load(configDir: hook + "/config") } catch { die("конфиг Swift: \(error)") }
wm.controlHandler = { command in
    guard command == "reload" else { return nil }
    let base = try HyprConfig.load(configDir: hook + "/config", rebuild: true, timeScale: timeScale)
    let next = try NativeRuntimeConfig.load(base: base, configDir: hook + "/config", environment: env)
    let nextOptions = try RuntimeOptions.load(configDir: hook + "/config")
    try NativeHotkeys.apply(configDir:hook+"/config")
    wm.cancelFocusRecovery()
    try eng.replaceConfig(next)
    wm.cfg = next; wm.options = nextOptions; wm.floatRules = next.floatRules
    let (inside, outside) = next.gaps()
    wm.tile.gapsIn = inside; wm.tile.gapsOut = outside
    wm.tile.defaultRatio = next.makeDwindle().defaultRatio
    wm.tile.splitWidthMult = next.makeDwindle().splitWidthMult
    wm.tile.minimumPolicy = next.makeDwindle().minimumPolicy
    if let last = wm.last { wm.apply(last.area, last.space, last.wins, force: true) }
    return "configuration reloaded"
}
wm.clientPolicy = ClientPolicy(path:hook + "/compositor-clients.json")
let firstMapService:NativeAdmissionService?
do {firstMapService=try NativeAdmissionService(sys:sys);wm.admission=firstMapService?.gateway}
catch {log("first-map admission unavailable:",error);firstMapService=nil}
let publicWorkspace=VerifiedPublicWorkspace(hook:hook)
wm.workspaceFocus={ sid,preflight in publicWorkspace.request(sid,preflight:preflight) }
wm.workspaceObserver={ snapshot,fresh in publicWorkspace.observe(snapshot,fresh:fresh) }
wm.workspaceDescribe={ snapshot in OrdinaryWorkspace.describe(snapshot:snapshot,hook:hook) }
wm.workspaceStatus={ publicWorkspace.status }
wm.workspaceCancel={ publicWorkspace.cancel() }
wm.workspaceBusy={ publicWorkspace.busy }
let overview = OverviewBridge(sys:sys)
let overviewEntryBarrier=OverviewEntryBarrier(sys:sys,overview:overview,wm:wm)
sys.overviewGuard = {[weak overview,weak overviewEntryBarrier] in (overview?.active ?? false) || (overviewEntryBarrier?.busy ?? false)}
wm.overviewFrozen = { overview.active || overviewEntryBarrier.busy }
wm.overviewGrantedWindows = {overview.grantedWindowIDs}
wm.overviewEntryAck = {overviewEntryBarrier.acknowledge(ready:$0)}
wm.overviewStatus = { overview.status }
wm.overviewRefresh = {
    overview.updateHiddenWindowsEnabled(wm.options.overviewHiddenWindows)
    overview.updateHiddenIntents(wm.overviewHiddenIntents())
    if !overviewEntryBarrier.busy {
        for selection in overview.takeSelections() { wm.restoreOverviewSelection(selection) }
    }
    if !overview.active && !overviewEntryBarrier.busy {
        if !wm.options.overviewHiddenWindows {overview.update([])}
        else if let records=wm.overviewDesiredPool() {overview.update(records)}
    }
}
wm.cfgSink = Configurer(sys: sys) { r in
    DispatchQueue.main.async {                 // ответ configure — событие: сразу такт (в Python — опрос cfg_q)
        wm.cfgQ.append(r)
        wm.tick(socketReady: false)
    }
}
do { try eng.ensure(startup: true) } catch { die("движок: \(error)") }
do {try NativeHotkeys.apply(configDir:hook+"/config")} catch {die("горячие клавиши: \(error)")}
sys.startLauncher()
do { wm.server = try CommandServer(path: ctl) } catch { die("сокет: \(error)") }
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

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
var menu: MenuBarController?
let shutdown=ShutdownCoordinator(wm:wm,overview:overview,sys:sys)
if wm.options.menuBar {
    menu = MenuBarController(hook: hook, companion: false, startupAnimation: wm.options.startupAnimation) { command, completion in
        guard let last = wm.last else { completion(.failure(CmdError("window snapshot not ready"))); return }
        completion(Result { try wm.command(command, last.area, last.space, last.wins) })
    }
    menu?.onQuit = { completion in shutdown.request(completion) }
}
let signalSources = [SIGTERM, SIGINT].map { value -> DispatchSourceSignal in
    signal(value, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
    source.setEventHandler { shutdown.request { ready in if ready { application.terminate(nil) } } }
    source.resume(); return source
}
withExtendedLifetime((menu, signalSources,firstMapService)) { application.run() }
firstMapService?.close()
