import AppKit
import ApplicationServices
import HyprCore

final class LiteRuntime {
    let hook: String, controlPath: String, stateDir: String
    let environment: [String: String]
    let sys: LiteSys, engine: LiteEngine, wm: WM
    private var formattingStatus = false, stopping = false, recovering = true
    private var recoveryEpoch = 0
    private var timer: DispatchSourceTimer?, socketSource: DispatchSourceRead?
    private var signals: [DispatchSourceSignal] = []
    private var menu: MenuBarController?, watcher: ConfigFileWatcher?, hotkeys: LiteHotkeys?
    private var ecosystem: EcosystemAPI?, configure: LiteConfigureSink?
    private var pendingReload: DispatchWorkItem?
    private var censusAt = 0.0
    private var observer: NSObjectProtocol?
    init(hook: String, config: HyprConfig, controlPath: String, stateDir: String, environment: [String: String]) throws {
        self.hook = hook; self.controlPath = controlPath; self.stateDir = stateDir; self.environment = environment
        sys = LiteSys(stateDir: stateDir); engine = try LiteEngine(sys: sys, config: config)
        wm = WM(sys: sys, eng: engine, deco: NullDeco(), cfg: config, statePath: stateDir+"/lite.state.json", minsizePath: stateDir+"/lite-minsize.json")
        wm.options = try RuntimeOptions.load(configDir: hook+"/config", environment: environment)
        wm.options.nativeFrames = false; wm.options.snapshotFrames = false
        wm.options.transferOnActivation = false; wm.options.overviewHiddenWindows = false
        // Runtime recovery restores its own lifetime ledger before this separate
        // logical workspace state is allowed to manage any client again.
        wm.enabled = false
        configure = LiteConfigureSink(channel: engine.channel) { [weak wm] result in wm?.cfgQ.append(result) }
        wm.cfgSink = configure
        wm.workspaceStatus = { [weak self] in self?.workspaceStatus ?? .null }
        wm.controlHandler = { [weak self] command in try self?.control(command) }
    }
    private var workspaceStatus: JSON {
        .object([("state", .string("virtual")), ("active", .int(sys.workspace)), ("previous", .int(sys.previousWorkspace)),
                 ("native_spaces_used", .bool(false)), ("members", .object(sys.membership.map { (String($0.key), .int($0.value)) }))])
    }
    private func control(_ command: String) throws -> String? {
        if command == "status", !formattingStatus, let last = wm.last {
            formattingStatus = true; defer { formattingStatus = false }
            let original = try wm.command("status", last.area, last.space, last.wins)
            let pid = sys.frontPid(), context = pid.map(sys.focusContext)
            let focus = JSON.array([pid.map(JSON.int) ?? .null, context?.wid.map(JSON.int) ?? .null, context.map { .int($0.flags) } ?? .null])
            let pointer = sys.pointerHit()
            return try RuntimeMode.decorate(original, mode: .lite)
                .setting("hotkey_bindings", hotkeys?.metadata ?? .array([]))
                .setting("lite", engine.channel.capabilityStatus.setting("focus_context", focus).setting("pointer_hit", pointer.map { .int($0.wid) } ?? .null).setting("recovery_count", .int(sys.recovery.records.count)).setting("recovery_error", sys.recovery.loadError.map(JSON.string) ?? .null).setting("hotkey_conflicts", .int(hotkeys?.conflicts ?? 0)))
                .setting("workspace_public", workspaceStatus).dumps(ensureASCII: false)
        }
        if command == "reload" { try reload(); return "configuration reloaded" }
        if command == "resume", recovering { throw CmdError("resume refused: complete restore-all before resuming Lite tiling") }
        if command == "restore-all" {
            if let error = sys.recovery.loadError { throw CmdError("restore-all: \(error)") }
            recoveryEpoch += 1 // An explicit restore cancels the startup-enable callback.
            recovering = true; wm.setEnabled(false); configure?.cancelAll(); engine.channel.prepareRecovery()
            wm.hidden.removeAll(); wm.save()
            let remaining = restoreRecords()
            guard remaining == 0 else { throw CmdError("restore-all: \(remaining) exact lifetime records still need AX permission or a responsive app; recovery ledger preserved") }
            recovering = false; engine.channel.cancelMotions()
            sys.membership.removeAll(); sys.concealed.removeAll(); wm.spaces.removeAll(); wm.target.removeAll(); wm.save()
            return "restored every Lite window; tiling paused"
        }
        let words = try CommandArguments.parse(command)
        guard let first = words.first else { return nil }
        if ["workspace", "ws", "wsstep"].contains(first) {
            guard words.count == 2, !sys.mouseDown(), !sys.sessionLocked() else { throw CmdError("workspace: expected 1..10, previous, or wsstep -1/1") }
            let target: Int
            if first == "wsstep" {
                guard ["-1", "1"].contains(words[1]) else { throw CmdError("wsstep: expected -1 or 1") }
                target = 1+(sys.workspace-1+(words[1] == "1" ? 1 : -1)+10)%10
            } else if words[1] == "previous" { target = sys.previousWorkspace }
            else { guard let value = Int(words[1]), (1...10).contains(value) else { throw CmdError("workspace: expected 1..10 or previous") }; target = value }
            switchWorkspace(target); return "workspace \(sys.workspace) (Lite virtual)"
        }
        if ["sendws", "moveworkspace"].contains(first) {
            guard words.count >= 2, let target = Int(words[1]), (1...10).contains(target),
                  let wid = wm.sp(sys.workspace).focus, sys.membership[wid] == sys.workspace else { throw CmdError("moveworkspace: focused tile and workspace 1..10 required") }
            let source = sys.workspace
            wm.sp(source).tree = Dwindle.remove(wm.sp(source).tree, wid)
            sys.membership[wid] = target
            engine.channel.alpha(wid, 0, 16, 0); engine.channel.commit(); wm.save()
            if words.last != "silent" { switchWorkspace(target) }
            return "window moved to virtual workspace \(target)"
        }
        return nil
    }
    private func switchWorkspace(_ target: Int) {
        guard target != sys.workspace, wm.enabled else { return }
        sys.cancelFocus()
        let source = sys.workspace
        configure?.cancelAll(); wm.target.removeAll()
        for (wid, sid) in sys.membership where sid == source { engine.channel.alpha(wid, 0, 16, 0) }
        sys.previousWorkspace = source; sys.workspace = target
        for (wid, sid) in sys.membership where sid == target {
            engine.channel.alpha(wid, 1, 16, 0)
            if let frame = engine.channel.destination(wid) {
                engine.channel.geom(wid, frame, 16, 16, move: true, warp: true)
            }
        }
        engine.channel.commit()
        wm.tick(socketReady: false)
        if let wid = wm.sp(target).focus, let window = sys.window(wid), window.space == target {
            _ = sys.axFocus(window.pid, wid, raise: false)
        }
    }
    private func reload() throws {
        let base = try HyprConfig.load(configDir: hook+"/config", rebuild: false, timeScale: wm.cfg.timeScale)
        let next = try NativeRuntimeConfig.load(base: base, configDir: hook+"/config", environment: environment)
        var options = try RuntimeOptions.load(configDir: hook+"/config", environment: environment)
        options.nativeFrames = false; options.snapshotFrames = false; options.transferOnActivation = false; options.overviewHiddenWindows = false
        let old = wm.cfg.raw, fresh = next.raw
        let geometryChanged = old["config"]?["general"]?["gaps_in"] != fresh["config"]?["general"]?["gaps_in"] ||
            old["config"]?["general"]?["gaps_out"] != fresh["config"]?["general"]?["gaps_out"] ||
            old["config"]?["dwindle"] != fresh["config"]?["dwindle"] || RuntimeMode.layoutRules(old) != RuntimeMode.layoutRules(fresh)
        let configuredEnabledChanged = options.tilingEnabled != wm.options.tilingEnabled
        try engine.replaceConfig(next)
        try hotkeys?.reload(configDir: hook+"/config")
        wm.cfg = next; wm.options = options; wm.floatRules = next.floatRules
        let tile = next.makeDwindle()
        wm.tile.gapsIn = tile.gapsIn; wm.tile.gapsOut = tile.gapsOut; wm.tile.defaultRatio = tile.defaultRatio
        wm.tile.splitWidthMult = tile.splitWidthMult; wm.tile.minimumPolicy = tile.minimumPolicy
        if configuredEnabledChanged, !recovering { wm.setEnabled(options.tilingEnabled) }
        if geometryChanged, wm.enabled, let last = wm.last { wm.apply(last.area, last.space, last.wins) }
    }
    /// Returns unresolved exact lifetimes; records are deleted only after AX ACK.
    @discardableResult private func restoreRecords() -> Int {
        if sys.recovery.loadError != nil { return max(1, sys.recovery.records.count) }
        guard (try? sys.snapshot()) != nil else { return sys.recovery.records.count }
        for record in Array(sys.recovery.records.values) {
            if sys.processExited(record.pid) || sys.processBirth(record.pid).map({ $0 != record.birth }) == true ||
                sys.winPidLevel(record.wid).pid.map({ $0 != record.pid }) == true { sys.recovery.remove(record.wid); engine.channel.recovered(record.wid); continue }
            if sys.ax.confirmedClosed(record.pid, record.wid) { sys.recovery.remove(record.wid); engine.channel.recovered(record.wid); continue }
            guard sys.processBirth(record.pid) == record.birth, sys.winPidLevel(record.wid).pid == record.pid,
                  let frame = Rect(record.frame), sys.ax.window(record.pid, record.wid) != nil else { continue }
            if sys.axFrame(record.pid, record.wid, frame) == 0,
               sys.axGetFrame(record.pid, record.wid).map({ $0.maxDiff(frame) <= 8 }) == true {
                sys.recovery.remove(record.wid); sys.concealed.remove(record.wid); sys.presentation[record.wid] = nil
                engine.channel.recovered(record.wid)
            }
        }
        return sys.recovery.records.count
    }
    private func recoverBeforeStart(_ ready: @escaping () -> Void) {
        recoveryEpoch += 1; let epoch = recoveryEpoch; recovering = true
        if let error = sys.recovery.loadError { log("Lite recovery:", error, "; tiling stays paused"); return }
        let deadline = sys.now()+3
        func attempt() {
            guard self.recoveryEpoch == epoch, !self.stopping else { return }
            let remaining = self.restoreRecords()
            if remaining == 0 { ready(); return }
            guard self.sys.now() < deadline else {
                log("Lite recovery: \(remaining) windows still need restoration; tiling stays paused. Run hyprwm restore-all after granting Accessibility.")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now()+0.08) { attempt() }
        }
        attempt()
    }
    func run() -> Never {
        guard AXIsProcessTrusted() else { die("Lite mode needs Accessibility: System Settings → Privacy & Security → Accessibility → enable HyprWM (or the terminal launching it).") }
        let application = NSApplication.shared; application.setActivationPolicy(.accessory)
        do { wm.server = try CommandServer(path: controlPath) } catch { die("socket: \(error)") }
        ecosystem = try? EcosystemAPI(path: environment["HYPRWM_EVENTS"] ?? controlPath+".events")
        do { hotkeys = try LiteHotkeys(configDir: hook+"/config") { [weak self] command in
            guard let self else { return }
            if command == "panic-toggle" { if !self.recovering { self.wm.setEnabled(!self.wm.enabled) }; return }
            guard let last = self.wm.last else { return }
            do { _ = try self.wm.command(command, last.area, last.space, last.wins) } catch { log("Lite hotkey:", error.localizedDescription) }
        }} catch { log("Lite hotkeys:", error.localizedDescription) }
        watcher = try? ConfigFileWatcher(url: TextConfig.url(configDir: hook+"/config")) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }; self.pendingReload?.cancel()
                let work = DispatchWorkItem { do { try self.reload() } catch { log("configuration reload:", error.localizedDescription) } }
                self.pendingReload = work; DispatchQueue.main.asyncAfter(deadline: .now()+0.065, execute: work)
            }
        }
        if wm.options.menuBar {
            menu = MenuBarController(hook: hook, companion: false, startupAnimation: wm.options.startupAnimation) { [weak self] command, completion in
                guard let self, let last = self.wm.last else { completion(.failure(CmdError("window snapshot not ready"))); return }
                completion(Result { try self.wm.command(command, last.area, last.space, last.wins) })
            }
            menu?.onQuit = { [weak self] completion in self?.shutdown(completion) }
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopping else { return }
            if self.sys.now()-self.censusAt >= 0.05 {
                self.censusAt = self.sys.now()
                if let snapshot = try? self.sys.snapshot() {
                    self.engine.channel.observe(snapshot)
                    if !self.wm.enabled { self.wm.last = (snapshot.area, snapshot.space, snapshot.windows) }
                }
            }
            self.engine.channel.advance(); self.configure?.drain(); self.wm.tick(socketReady: false)
            // Persisted tree leaves predate this process's empty channel. Once
            // their public AX metadata arrives, establish the missing ownership
            // even when no layout change is needed to trigger core apply.
            if self.wm.enabled, let last = self.wm.last {
                let owned = Set(self.engine.channel.wins().map(\.wid))
                let leaves = Set(Dwindle.leaves(self.wm.sp(last.space).tree).compactMap(\.wid))
                let missing = last.wins.filter { leaves.contains($0.wid) && !owned.contains($0.wid) && $0.on && $0.space == last.space && self.wm.tileable($0) }
                if !missing.isEmpty {
                    for window in missing { self.wm.target[window.wid] = nil }
                    self.wm.apply(last.area, last.space, last.wins)
                }
            }
            if let last = self.wm.last { self.ecosystem?.observe(windows: last.wins, space: last.space, focusedWindow: self.wm.sp(last.space).focus) }
        }
        self.timer = timer; timer.resume()
        let socket = DispatchSource.makeReadSource(fileDescriptor: wm.server!.fd, queue: .main)
        socket.setEventHandler { [weak self] in self?.wm.tick(socketReady: true) }; socket.resume(); socketSource = socket
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.stopping else { return }
            if let pid = self.sys.frontPid(), let wid = self.sys.focusContext(pid).wid,
               let workspace = self.sys.membership[wid], workspace != self.sys.workspace { self.switchWorkspace(workspace) }
            self.wm.tick(socketReady: false)
        }
        signals = [SIGTERM, SIGINT].map { value in
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler { [weak self] in self?.shutdown { ready in if ready { application.terminate(nil) } } }
            source.resume(); return source
        }
        recoverBeforeStart { [weak self] in
            guard let self else { return }
            self.recovering = false
            self.wm.hidden.removeAll(); self.wm.save()
            self.wm.setEnabled(self.wm.options.tilingEnabled)
            log("HyprWM started (Lite); public AX, virtual workspaces, \(self.engine.channel.captures.permitted ? "captured proxy animations" : "Screen Recording missing; direct AX fallback")")
        }
        application.run(); exit(0)
    }
    private func shutdown(_ completion: @escaping (Bool) -> Void) {
        guard !stopping else { completion(false); return }; stopping = true; recovering = true; recoveryEpoch += 1
        pendingReload?.cancel(); wm.setEnabled(false); configure?.cancelAll(); engine.channel.prepareRecovery()
        wm.hidden.removeAll(); wm.save()
        let deadline = sys.now()+3
        func attempt() {
            let remaining = self.restoreRecords()
            if remaining == 0 { self.hotkeys?.close(); self.engine.channel.shutdown(); completion(true); return }
            guard self.sys.now() < deadline else {
                self.stopping = false
                log("Quit deferred: \(remaining) Lite windows need AX restoration; recovery ledger preserved.")
                completion(false); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now()+0.08) { attempt() }
        }
        attempt()
    }
    /// A dead daemon's recovery path requires no engine, hotkeys, or full WM.
    static func restoreOnly(stateDir: String) -> Never {
        let sys = LiteSys(stateDir: stateDir)
        if let error = sys.recovery.loadError { die("restore-all: \(error)") }
        if sys.recovery.records.isEmpty { print("no outstanding Lite recovery records"); exit(0) }
        guard AXIsProcessTrusted() else { die("restore-all needs Accessibility: System Settings → Privacy & Security → Accessibility") }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let deadline = sys.now()+4
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(80))
        timer.setEventHandler {
            _ = try? sys.snapshot()
            for record in Array(sys.recovery.records.values) {
                if sys.processExited(record.pid) || sys.processBirth(record.pid).map({ $0 != record.birth }) == true { sys.recovery.remove(record.wid); continue }
                if sys.winPidLevel(record.wid).pid.map({ $0 != record.pid }) == true || sys.ax.confirmedClosed(record.pid, record.wid) { sys.recovery.remove(record.wid); continue }
                guard sys.processBirth(record.pid) == record.birth, sys.winPidLevel(record.wid).pid == record.pid,
                      let frame = Rect(record.frame), sys.ax.window(record.pid, record.wid) != nil else { continue }
                if sys.axFrame(record.pid, record.wid, frame) == 0, sys.axGetFrame(record.pid, record.wid).map({ $0.maxDiff(frame) <= 8 }) == true { sys.recovery.remove(record.wid) }
            }
            if sys.recovery.records.isEmpty { print("restored every Lite recovery record"); exit(0) }
            if sys.now() >= deadline { die("restore-all: \(sys.recovery.records.count) unresolved Lite records; ledger and application preserved") }
        }
        timer.resume(); withExtendedLifetime((sys, timer)) { application.run() }; exit(0)
    }
}
