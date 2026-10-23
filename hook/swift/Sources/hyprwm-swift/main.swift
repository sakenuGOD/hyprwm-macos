// Swift tiling daemon and native menu companion.
// Dry modes: --print-config, --layout, --diagnose, import FILE.
// HYPRWM_HOOK selects the source integration directory.
// HYPRWM_STATE_DIR selects persistent state; HYPRWM_CTL selects the Unix socket.
// HYPRWM_TIME_SCALE, HYPRWM_HOLD and HYPRWM_DEBUG override runtime behavior.
// HYPRWM_NO_DECO=1 disables the optional decoration helper.
import AppKit
import CAX
import Foundation
import HyprCore

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)                       // A disconnected client must not terminate the daemon.

let env = ProcessInfo.processInfo.environment

func findHook() -> String {
    if let h = env["HYPRWM_HOOK"] { return h }
    if let resources = Bundle.main.resourceURL?.appendingPathComponent("hook"),
       FileManager.default.fileExists(atPath: resources.appendingPathComponent("config/hypr_cfg.json").path) {
        return resources.path
    }
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
// An installed, signed bundle carries its generated portable baseline. Loading
// it must never require Lua or write back into the application bundle.
let bundledHook = Bundle.main.resourceURL.map { hook.hasPrefix($0.path + "/") } ?? false
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

if args == ["--startup-canary-helper"] {StartupCanary.helper()}

if args == ["--platform-fingerprint"] {
    print(StartupQualification.fingerprint().dumps());exit(0)
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
    let previewStatus=env["HYPRWM_UI_PREVIEW_UNVERIFIED"] == "1" ?
        "{\"runtime\":\"preview\",\"mode\":\"unverified\",\"enabled\":false,\"compatibility\":{\"verified\":false}}" :
        "{\"runtime\":\"preview\",\"enabled\":true,\"space\":1,\"hidden\":[],\"engine\":{\"active\":0,\"errors\":0,\"tick_us_last\":40}}"
    let menu=MenuBarController(hook:hook,companion:true,startupAnimation:false) { command,completion in
        completion(.success(command == "status" ? previewStatus : "preview: no runtime mutation"))
    }
    menu.showPreview(section:section,onboardingStep:step)
    withExtendedLifetime(menu) { application.run() };exit(0)
}

if args == ["--diagnose"] {
    print(diagnose(hook: hook, controlPath: env["HYPRWM_CTL"] ?? "/tmp/hyprwm.ctl").dumps(ensureASCII: false))
    exit(0)
}
if args == ["doctor"] {
    print(doctor(hook: hook, controlPath: env["HYPRWM_CTL"] ?? "/tmp/hyprwm.ctl"))
    exit(0)
}
if args == ["--init-config"] {
    do { try initDefaultConfig(hook: hook) } catch { die("configuration: \(error)") }
    exit(0)
}
if args.first == "import" {
    guard args.count == 2 else { die("usage: hyprwm import FILE") }
    do {
        let result=try ForeignConfigImport.importFile(URL(fileURLWithPath:args[1]),configDir:hook+"/config",apply:true)
        print("Imported \(result.mappedCount) settings from \(result.format).")
        for issue in result.issues {FileHandle.standardError.write(Data((issue.description+"\n").utf8))}
    } catch {die("import: \(error)")}
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
    print("hyprwm-swift [--menu-only [--show-settings] | --diagnose | --print-config | --layout STATE SPACE X Y W H]   (see hook/swift/README.md)")
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
        for (i, (name, cv)) in cfg.sortedCurves().enumerated() { print("curve", i, name, cv) }
        for leaf in ["windowsIn", "windowsOut", "windowsMove", "fadeIn", "fadeOut", "border", "workspaces"] {
            let a = cfg.animation(leaf), e = cfg.anim(leaf)
            print(leaf, a.kind, a.curve, "speed", pyFloat(a.speed), "style '\(a.style)'", "-> curve", e.curve,
                  "duration", pyFloat(e.dur), e.on ? "on" : "off")
        }
        print("float rules:", cfg.floatRules.count)
    } catch { die("configuration: \(error)") }
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
    } catch { die("layout: \(error)") }
    exit(0)

case nil:
    break

case "--startup-check":
    guard args.count==1 else{die("--startup-check")}

default:
    die("unknown argument \(args[0]) (--help)")
}

// Daemon lifecycle.
let ctl = env["HYPRWM_CTL"] ?? "/tmp/hyprwm.ctl"
let stateDir = env["HYPRWM_STATE_DIR"] ?? "/tmp/hyprwm-swift"
try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)

let startupCheckOnly=args == ["--startup-check"]
if startupCheckOnly {
    for existing in Set([ctl,"/tmp/hyprwm.ctl"]) where CommandServer.isAlive(existing) {
    guard let text=try? ControlClient(path:existing).request("status"),let status=try? JSON.parse(text),
          status["enabled"] == .bool(false),status["engine"]?["active"]?.int==0,
          status["engine"]?["holding"]?.int==0,status["engine"]?["pending_commands"] == .bool(false)
    else{die("pause the running daemon and wait for engine idle before checking the service canary")}
    }
}
if !startupCheckOnly && (CommandServer.isAlive(ctl) || (ctl != "/tmp/hyprwm.ctl" && CommandServer.isAlive("/tmp/hyprwm.ctl"))) {
    die("a daemon already responds on \(ctl); stop it before starting another")
}

var startupQualification=StartupQualification.fingerprint()
if startupQualification["verified"] != .bool(true) {
    if startupCheckOnly{die(startupQualification.dumps())}
    StartupQualification.unverified(startupQualification,hook:hook,controlPath:ctl,statePath:stateDir + "/hyprwm.state.json",nativeWorkUnknown:false)
}
let cfg: HyprConfig
do {
    let base = try HyprConfig.load(configDir: hook + "/config", rebuild: !bundledHook && env["HYPRWM_ADOPT_ENGINE"] != "1", timeScale: timeScale)
    cfg = try NativeRuntimeConfig.load(base: base, configDir: hook + "/config", environment: env)
} catch { die("configuration: \(error)") }
let sys = LiveSys()
let eng = LiveEngine(hook: hook, cfg: cfg)
do {
    startupQualification=startupQualification.setting("stage",.string("census"))
    let snapshot=try StartupQualification.census(sys)
    try eng.attachForCanary()
    startupQualification=startupQualification.setting("stage",.string("canary"))
    try StartupCanary.check(sys:sys,engine:eng,cfg:cfg,snapshot:snapshot)
    eng.commitStartupCurves()
    startupQualification=startupQualification.setting("stage",.string("ready")).setting("reason",.string("native census and owned resize/apply canary passed"))
    if startupCheckOnly{print(startupQualification.dumps());exit(0)}
} catch {
    var reason=String(describing:error)
    do {try eng.rollbackStartupCurves()} catch {reason += "; \(error)"}
    startupQualification=startupQualification.setting("verified",.bool(false)).setting("reason",.string(reason))
    if startupCheckOnly{die(startupQualification.dumps())}
    StartupQualification.unverified(startupQualification,hook:hook,controlPath:ctl,statePath:stateDir + "/hyprwm.state.json",nativeWorkUnknown:true)
}
let deco: DecoAPI
if env["HYPRWM_NO_DECO"] == "1" {
    deco = NullDeco()
} else {
    do { deco = try Deco(hook: hook) } catch { log("decoration helper unavailable:", error); deco = NullDeco() }
}
do { try EngineStatePreflight.check(stateDir + "/hyprwm.state.json") } catch { die("Engine state: \(error)") }
let wm = WM(sys: sys, eng: eng, deco: deco, cfg: cfg, statePath: stateDir + "/hyprwm.state.json",
            minsizePath: stateDir + "/minsize_app.json")
wm.startupCompatibility=startupQualification
wm.buildCommit = String(cString: hs_build_revision())
wm.buildSourceDirty = hs_build_source_dirty() != 0
do { wm.options = try RuntimeOptions.load(configDir: hook + "/config") } catch { die("Swift configuration: \(error)") }
do { try wm.prepareStartupRecovery() } catch { die("startup recovery: \(error)") }
let firstMapService:NativeAdmissionService?
do {firstMapService=try NativeAdmissionService(sys:sys);wm.admission=firstMapService?.gateway}
catch {log("first-map admission unavailable:",error);firstMapService=nil}
let firstMapContainers=firstMapService.map{NativeAdmissionContainers(sys:sys,gateway:$0.gateway)}
firstMapContainers?.restore()
wm.controlHandler = { command in
    if command.hasPrefix("firstmap-listen ") {
        guard let firstMapContainers else{throw CmdError("first-map service unavailable")}
        return try firstMapContainers.register(JSON.parse(String(command.dropFirst("firstmap-listen ".count))))
    }
    guard command == "reload" else { return nil }
    let base = try HyprConfig.load(configDir: hook + "/config", rebuild: false, timeScale: timeScale)
    let next = try NativeRuntimeConfig.load(base: base, configDir: hook + "/config", environment: env)
    let nextOptions = try RuntimeOptions.load(configDir: hook + "/config")
    do { try NativeHotkeys.apply(configDir:hook+"/config") }
    catch { log("hotkey configuration:",error) }
    let old=wm.cfg.raw, fresh=next.raw
    let geometryChanged = old["config"]?["general"]?["gaps_in"] != fresh["config"]?["general"]?["gaps_in"] ||
        old["config"]?["general"]?["gaps_out"] != fresh["config"]?["general"]?["gaps_out"] ||
        old["config"]?["dwindle"] != fresh["config"]?["dwindle"] || old["window_rules"] != fresh["window_rules"]
    try eng.replaceConfig(next)
    wm.cfg = next; wm.options = nextOptions; wm.floatRules = next.floatRules
    let (inside, outside) = next.gaps()
    wm.tile.gapsIn = inside; wm.tile.gapsOut = outside
    wm.tile.defaultRatio = next.makeDwindle().defaultRatio
    wm.tile.splitWidthMult = next.makeDwindle().splitWidthMult
    wm.tile.minimumPolicy = next.makeDwindle().minimumPolicy
    wm.setEnabled(nextOptions.tilingEnabled)
    if geometryChanged, wm.enabled, let last = wm.last { wm.apply(last.area, last.space, last.wins) }
    return "configuration reloaded"
}
wm.clientPolicy = ClientPolicy(path:hook + "/compositor-clients.json")
let publicWorkspace=VerifiedPublicWorkspace(hook:hook,sys:sys)
let nativeWorkspace=NativeDockWorkspace(sys:sys)
wm.workspaceCommandSubmit={selector,source in
    guard !publicWorkspace.busy else{return false}
    if nativeWorkspace.ownsRequest || (selector != "new" && nativeWorkspace.available()) {
        return nativeWorkspace.enqueueExplicit(selector,source:source)
    }
    return publicWorkspace.enqueueExplicit(selector,source:source)
}
wm.workspaceFocus={sid,preflight in
    guard !publicWorkspace.busy else{return false}
    return nativeWorkspace.ownsRequest || nativeWorkspace.available() ? nativeWorkspace.request(sid,preflight:preflight):publicWorkspace.request(sid,preflight:preflight)
}
wm.workspaceObserver={snapshot,fresh in publicWorkspace.observe(snapshot,fresh:fresh);nativeWorkspace.observe(snapshot,fresh:fresh)}
wm.workspaceDescribe={ snapshot in OrdinaryWorkspace.describe(snapshot:snapshot,hook:hook) }
wm.workspaceStatus={
    if nativeWorkspace.ownsRequest{return nativeWorkspace.status}
    if publicWorkspace.busy{return publicWorkspace.status}
    return nativeWorkspace.configured ? nativeWorkspace.status:publicWorkspace.status
}
wm.workspaceCancel={publicWorkspace.cancel();nativeWorkspace.cancel()}
wm.workspaceBusy={publicWorkspace.busy || nativeWorkspace.busy}
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
    DispatchQueue.main.async {                 // Configure completion schedules an immediate tick.
        wm.cfgQ.append(r)
        wm.tick(socketReady: false)
    }
}
do { try eng.ensure(startup: true) } catch { die("engine: \(error)") }
do {try NativeHotkeys.apply(configDir:hook+"/config")} catch {die("hotkeys: \(error)")}
sys.startLauncher()
do { wm.server = try CommandServer(path: ctl) } catch { die("socket: \(error)") }
wm.setEnabled(wm.options.tilingEnabled)
let ecosystemAPI = try? EcosystemAPI(path:env["HYPRWM_EVENTS"] ?? ctl+".events")
var pendingConfigReload:DispatchWorkItem?
func reloadSharedConfiguration(_ attempt:Int=0) {
    pendingConfigReload?.cancel()
    do { _ = try wm.controlHandler?("reload") }
    catch {
        guard attempt < 30 else { log("configuration reload:",error); return }
        let task=DispatchWorkItem { reloadSharedConfiguration(attempt+1) }
        pendingConfigReload=task
        DispatchQueue.main.asyncAfter(deadline:.now()+0.065,execute:task)
    }
}
let configWatcher = try? ConfigFileWatcher(url:TextConfig.url(configDir:hook+"/config")) {
    DispatchQueue.main.async { reloadSharedConfiguration() }
}
log("HyprWM started (Swift); state: \(stateDir), socket \(ctl)")

// Census and pointer focus run every 16 ms; other work is event driven.
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(1))
timer.setEventHandler {
    // Paused startup still needs a census so the command server can drain.
    if !wm.enabled, wm.last == nil, let snapshot = try? sys.snapshot() {
        wm.last = (snapshot.area, snapshot.space, snapshot.windows)
    }
    wm.tick(socketReady:false)
    if let last=wm.last {ecosystemAPI?.observe(windows:last.wins,space:last.space,focusedWindow:wm.sp(last.space).focus,
        tilingOrder:Dictionary(uniqueKeysWithValues:wm.spaces.map { ($0.0,Dwindle.leaves($0.1.tree).compactMap(\.wid)) }))}
}
timer.resume()

// Process socket commands immediately.
let sockSrc = DispatchSource.makeReadSource(fileDescriptor: wm.server!.fd, queue: .main)
sockSrc.setEventHandler { wm.tick(socketReady: true) }
sockSrc.resume()

// Application activation schedules an immediate tick with native foreground checks.
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                  object: nil, queue: .main) { _ in wm.tick(socketReady: false) }

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let panicHotkey: PanicHotkey?
do { panicHotkey = try PanicHotkey { wm.setEnabled(!wm.enabled) } }
catch { panicHotkey = nil; log("panic hotkey:", error) }
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
withExtendedLifetime((menu,panicHotkey,signalSources,firstMapService,firstMapContainers,configWatcher,ecosystemAPI)) { application.run() }
firstMapContainers?.close()
firstMapService?.close()
