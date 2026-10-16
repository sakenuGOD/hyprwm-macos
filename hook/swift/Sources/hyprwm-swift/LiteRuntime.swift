import AppKit
import ApplicationServices
import Darwin
import HyprCore

final class LiteRuntime {
    let hook: String, controlPath: String, stateDir: String
    let environment: [String: String]
    let engineRecoveryIssue: String?
    let sys: LiteSys, engine: LiteEngine, wm: WM
    private var formattingStatus = false, stopping = false, recovering = true
    private var recoveryEpoch = 0
    private var restoringAll = false, restoreAllDeadline = 0.0
    private var ignoredReleases: [Int: (record: LiteRecovery.Record, hidden: Hidden?)] = [:]
    private lazy var restorePump = LiteRestorePump(sys: sys) { [weak self] wid in
        guard let self else { return }
        self.engine.channel.recovered(wid)
        if let release = self.ignoredReleases.removeValue(forKey: wid) {
            self.sys.membership[wid] = nil
            if let hidden = release.hidden {
                self.wm.hidden.removeAll { $0 == hidden }
                if !self.wm.hidden.contains(where: { $0.wid == wid }) { self.wm.restoring.remove(wid) }
                self.wm.save()
            }
        }
    }
    private var timer: DispatchSourceTimer?, socketSource: DispatchSourceRead?
    private var signals: [DispatchSourceSignal] = []
    private var menu: MenuBarController?, watcher: ConfigFileWatcher?, hotkeys: LiteHotkeys?
    private var ecosystem: EcosystemAPI?, configure: LiteConfigureSink?
    private var workspaceReceiver: LiteWorkspaceReceiver?
    private var pendingReload: DispatchWorkItem?
    private var censusAt = 0.0
    private var createdRuntimeStages: [String: Int] = [:]
    private var pendingCreated: [Int: LiteAX.Created] = [:]
    private var createdEpoch = 0
    private var observer: NSObjectProtocol?
    init(hook: String, config: HyprConfig, controlPath: String, stateDir: String, environment: [String: String]) throws {
        self.hook = hook; self.controlPath = controlPath; self.stateDir = stateDir; self.environment = environment
        engineRecoveryIssue = Self.engineRecoveryProblem(stateDir: stateDir)
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
        sys.ax.onCreated = { [weak self] created in self?.created(created) }
    }
    private func created(_ created: LiteAX.Created, mayDefer: Bool = true) {
        func note(_ stage: String) { createdRuntimeStages[stage, default: 0] += 1 }
        note("received")
        guard !stopping, !recovering, wm.enabled else { note("paused"); return }
        guard !sys.sessionLocked(), !sys.mouseDown(), !sys.interactionOverlay() else { note("interaction"); return }
        guard sys.frontPid() == created.window.pid else {
            note("foreground")
            if mayDefer, pendingCreated.count < 16 || pendingCreated[created.window.wid] != nil {
                pendingCreated[created.window.wid] = created
                note("deferred")
            }
            return
        }
        guard !sys.applicationHidden(created.window.pid) else { note("hidden"); return }
        guard sys.now()-censusAt < 0.1 else { note("old_census"); return }
        guard let last = wm.last, last.space == sys.workspace else { note("workspace"); return }
        guard let windows = sys.admitCreated(created) else { note("sys_"+sys.createdRefusal); return }
        note("admitted")
        // Reuse Core admission, classification, ignore/float/no-animation policy.
        // Metadata alone never authorizes a write or persisted ownership.
        let (changed, opened) = wm.sync(last.area, last.space, windows)
        wm.last = (last.area, last.space, windows)
        if changed { wm.apply(last.area, last.space, windows, opening: opened) }
    }
    private func invalidateCreated() { createdEpoch += 1; pendingCreated.removeAll() }
    private func retryCreated() {
        guard !stopping, !recovering, wm.enabled else { pendingCreated.removeAll(); return }
        let foreground = sys.frontPid(), now = sys.now()
        for (wid, candidate) in pendingCreated {
            if now-candidate.received >= 0.25 || sys.processBirth(candidate.window.pid) != candidate.birth {
                pendingCreated[wid] = nil; continue
            }
            guard foreground == candidate.window.pid else { continue }
            pendingCreated[wid] = nil
            createdRuntimeStages["retry", default: 0] += 1
            let epoch = createdEpoch, workspace = sys.workspace
            sys.ax.revalidateCreated(candidate) { [weak self] fresh in
                guard let self else { return }
                guard self.createdEpoch == epoch, self.sys.workspace == workspace else {
                    self.createdRuntimeStages["retry_cancelled", default: 0] += 1; return
                }
                guard let fresh else { self.createdRuntimeStages["retry_rejected", default: 0] += 1; return }
                self.created(fresh, mayDefer: false)
            }
        }
    }
    private var workspaceStatus: JSON {
        .object([("state", .string("virtual")), ("active", .int(sys.workspace)), ("previous", .int(sys.previousWorkspace)),
                 ("native_spaces_used", .bool(false)), ("empty_receiver", workspaceReceiver?.status ?? .null), ("members", .object(sys.membership.map { (String($0.key), .int($0.value)) }))])
    }
    private func control(_ command: String) throws -> String? {
        if command == "pause" || command == "restore-all" { invalidateCreated() }
        if command == "status", !formattingStatus, let last = wm.last {
            formattingStatus = true; defer { formattingStatus = false }
            let original = try wm.command("status", last.area, last.space, last.wins)
            let pid = sys.frontPid(), context = pid.map(sys.focusContext)
            let focus = JSON.array([pid.map(JSON.int) ?? .null, context?.wid.map(JSON.int) ?? .null, context.map { .int($0.flags) } ?? .null])
            let pointer = sys.pointerHit()
            return try RuntimeMode.decorate(original, mode: .lite)
                .setting("hotkey_bindings", hotkeys?.metadata ?? .array([]))
                .setting("lite", engine.channel.capabilityStatus.setting("focus_context", focus).setting("pointer_hit", pointer.map { .int($0.wid) } ?? .null).setting("ignored_release_count", .int(ignoredReleases.count)).setting("created_runtime", .object(createdRuntimeStages.sorted { $0.key < $1.key }.map { ($0.key, .int($0.value)) })).setting("recovery_count", .int(sys.recovery.records.count)).setting("recovery_error", (engineRecoveryIssue ?? sys.recovery.loadError).map(JSON.string) ?? .null).setting("hotkey_conflicts", .int(hotkeys?.conflicts ?? 0)))
                .setting("workspace_public", workspaceStatus).dumps(ensureASCII: false)
        }
        if command == "reload" { try reload(); return "configuration reloaded" }
        if command == "resume", recovering { throw CmdError("resume refused: complete restore-all before resuming Lite tiling") }
        if command == "restore-all" {
            if let error = engineRecoveryIssue { throw CmdError("restore-all: \(error)") }
            if let error = sys.recovery.loadError { throw CmdError("restore-all: \(error)") }
            recoveryEpoch += 1 // An explicit restore cancels the startup-enable callback.
            recovering = true; restoringAll = true; restoreAllDeadline = sys.now()+4
            wm.setEnabled(false); configure?.cancelAll(); engine.channel.prepareRecovery()
            wm.hidden.removeAll(); wm.save()
            let remaining = restoreRecords()
            guard remaining == 0 else { throw CmdError("Lite restoration pending: \(remaining) records awaiting AX acknowledgement; recovery ledger preserved") }
            finishRestoreAll()
            return "restored every Lite window; tiling paused"
        }
        let words = try CommandArguments.parse(command)
        guard let first = words.first else { return nil }
        if ["workspace", "ws", "wsstep"].contains(first) {
            guard wm.enabled, !recovering else { throw CmdError("workspace: tiling paused; resume first") }
            guard words.count == 2, !sys.mouseDown(), !sys.sessionLocked() else { throw CmdError("workspace: expected 1..10, previous, or wsstep -1/1") }
            let target: Int
            if first == "wsstep" {
                guard ["-1", "1"].contains(words[1]) else { throw CmdError("wsstep: expected -1 or 1") }
                target = 1+(sys.workspace-1+(words[1] == "1" ? 1 : -1)+10)%10
            } else if words[1] == "previous" { target = sys.previousWorkspace }
            else { guard let value = Int(words[1]), (1...10).contains(value) else { throw CmdError("workspace: expected 1..10 or previous") }; target = value }
            if target != sys.workspace { try reserveEmptyReceiver(destination: target, excluding: []) }
            switchWorkspace(target); return "workspace \(sys.workspace) (Lite virtual)"
        }
        if ["sendws", "moveworkspace"].contains(first) {
            guard wm.enabled, !recovering, !sys.mouseDown(), !sys.sessionLocked() else { throw CmdError("moveworkspace: tiling paused or interaction active") }
            guard (2...3).contains(words.count), let target = Int(words[1]), (1...10).contains(target) else { throw CmdError("moveworkspace: expected workspace 1..10 and follow/silent; sendws: workspace 1..10 [wid]") }
            let requested: Int?, silent: Bool
            if first == "sendws" {
                if words.count == 3 {
                    guard let number = UInt32(words[2]), number > 0 else { throw CmdError("sendws: window ID must be 1..4294967295") }
                    requested = Int(number)
                } else { requested = nil }
                silent = true
            } else {
                guard words.count == 2 || ["follow", "silent"].contains(words[2]) else { throw CmdError("moveworkspace: expected follow or silent") }
                requested = nil; silent = words.last == "silent"
            }
            let source = sys.workspace
            guard target != source else { return "window already on virtual workspace \(source)" }
            let focused = sys.frontPid().flatMap { sys.focusContext($0).wid }
            guard let wid = requested ?? focused, sys.membership[wid] == source,
                  wm.sp(source).tree?.contains(wid) == true, let window = sys.window(wid), window.on, window.space == source,
                  wm.tileable(window), sys.focusContext(window.pid).flags & (NativeFocusFlags.positive|NativeFocusFlags.unknown) == 0 else { throw CmdError("moveworkspace: exact visible managed window required") }
            if silent { try reserveEmptyReceiver(destination: source, excluding: [wid]) }
            sys.cancelFocus(); configure?.cancel(wid); wm.target[wid] = nil
            wm.newbies[wid] = nil; wm.optimistic[wid] = nil; wm.restoring.remove(wid)
            let state = wm.sp(source); state.tree = wm.tile.removeReorientingPromoted(state.tree, wid, in: sys.area)
            if state.focus == wid { state.focus = nil }; if state.full == wid { state.full = nil }
            sys.membership[wid] = target
            engine.channel.alpha(wid, 0, 16, 0); engine.channel.commit(); wm.save()
            if silent { applyWorkspace(source, focus: focused == wid) }
            else { switchWorkspace(target) }
            return "window moved to virtual workspace \(target)"
        }
        return nil
    }
    private func reserveEmptyReceiver(destination: Int, excluding: Set<Int>) throws {
        let hidden = Set(wm.hidden.map(\.wid))
        let candidates = Dwindle.leaves(wm.sp(destination).tree).compactMap(\.wid).filter { wid in
            guard !excluding.contains(wid), !hidden.contains(wid), sys.membership[wid] == destination,
                  let window = sys.window(wid), !sys.applicationHidden(window.pid) else { return false }
            return wm.tileable(window)
        }
        guard candidates.isEmpty else { return }
        if let receiver = workspaceReceiver, receiver.visible, receiver.key { receiver.rename(workspace: destination); return }
        guard let pid = sys.frontPid() else { throw CmdError("workspace: native foreground unavailable") }
        let context = sys.focusContext(pid)
        if context.flags & NativeFocusFlags.unknown != 0,
           sys.rawWindows.contains(where: { $0.pid == pid && sys.membership[$0.wid] == sys.workspace }) {
            throw CmdError("workspace: native keyboard receiver unverified; current windows preserved")
        }
        guard let key = context.wid, sys.membership[key] == sys.workspace else { return }
        guard let record = sys.recovery.records[key], record.pid == pid, sys.processBirth(pid) == record.birth else {
            throw CmdError("workspace: keyboard receiver lifetime unverified; current windows preserved")
        }
        let safe = sys.ax.perform(pid, key) { application, window in
            guard !LiteAX.modalBarrier(application, window),
                  let focused = LiteAX.attribute(application, kAXFocusedWindowAttribute),
                  CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, window) else { return -1 }
            return 0
        }
        guard safe == 0, sys.frontPid() == pid, !sys.mouseDown(), !sys.sessionLocked() else {
            throw CmdError("workspace: keyboard receiver changed or a modal interaction is active")
        }
        let receiver = workspaceReceiver ?? LiteWorkspaceReceiver(); workspaceReceiver = receiver
        guard receiver.show(workspace: destination, area: sys.area, sourcePID: pid, sourceWindow: key) else {
            throw CmdError("workspace: empty-workspace keyboard receiver unavailable; current windows preserved")
        }
    }
    private func releaseEmptyReceiver() {
        guard let receiver = workspaceReceiver, receiver.visible, let pid = sys.frontPid() else { return }
        let context = sys.focusContext(pid)
        if let key = context.wid, let record = sys.recovery.records[key], record.pid == pid,
           sys.processBirth(pid) == record.birth, sys.winPidLevel(key).pid == pid,
           sys.membership[key] == sys.workspace, let window = sys.window(key), window.on,
           !sys.concealed.contains(key), let actual = sys.winBounds(key), !sys.parked(actual),
           context.flags & (NativeFocusFlags.positive|NativeFocusFlags.unknown) == 0 { receiver.hide(); return }
        // A user's visible nonmember choice is respected; an unacknowledged
        // managed app activation must not expose its still-parked key window.
        if let key = context.wid, sys.membership[key] == nil, sys.recovery.records[key] == nil,
           sys.winPidLevel(key).pid == pid, let window = sys.window(key), window.on,
           let actual = sys.winBounds(key), !sys.parked(actual) { receiver.hide(); return }
        let ownedApp = sys.recovery.records.values.contains { $0.pid == pid }
        if pid != receiver.sourcePID, pid != Int(getpid()), !ownedApp { receiver.hide() }
    }
    private func switchWorkspace(_ target: Int) {
        guard target != sys.workspace, wm.enabled else { return }
        invalidateCreated()
        sys.cancelFocus()
        let source = sys.workspace
        configure?.cancelAll(); wm.target.removeAll()
        for (wid, sid) in sys.membership where sid == source { engine.channel.alpha(wid, 0, 16, 0) }
        sys.previousWorkspace = source; sys.workspace = target
        let hidden = Set(wm.hidden.map(\.wid))
        for (wid, sid) in sys.membership where sid == target && !hidden.contains(wid) {
            engine.channel.alpha(wid, 1, 16, 0)
            if let frame = engine.channel.destination(wid) {
                engine.channel.geom(wid, frame, 16, 16, move: true, warp: true)
            }
        }
        engine.channel.commit()
        applyWorkspace(target, focus: true)
    }
    private func applyWorkspace(_ workspace: Int, focus: Bool) {
        guard let snapshot = try? sys.snapshot(), snapshot.space == workspace else { return }
        wm.last = (snapshot.area, snapshot.space, snapshot.windows)
        let (_, opening) = wm.sync(snapshot.area, workspace, snapshot.windows)
        wm.apply(snapshot.area, workspace, snapshot.windows, opening: opening)
        guard focus, let wid = wm.sp(workspace).focus, let window = sys.window(wid), window.on,
              let birth = sys.processBirth(window.pid) else { return }
        let request = FocusRequest(pid: window.pid, wid: wid, space: workspace, birth: birth, sourcePID: sys.frontPid(), reason: .space, deadline: sys.now()+1, pointer: nil)
        sys.requestFocus(request) { [weak self] accepted in
            guard let self, accepted, self.wm.enabled, self.sys.workspace == workspace else { return }
            self.wm.sp(workspace).focus = wid
            self.engine.channel.decorationFocus(wid, fullscreen: self.wm.sp(workspace).fullmode == "fullscreen" ? self.wm.sp(workspace).full ?? 0 : 0)
        }
    }
    private func reload() throws {
        invalidateCreated()
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
        releaseIgnoredMembers(sys.rawWindows)
        let tile = next.makeDwindle()
        wm.tile.gapsIn = tile.gapsIn; wm.tile.gapsOut = tile.gapsOut; wm.tile.defaultRatio = tile.defaultRatio
        wm.tile.splitWidthMult = tile.splitWidthMult; wm.tile.minimumPolicy = tile.minimumPolicy
        if configuredEnabledChanged, !recovering { wm.setEnabled(options.tilingEnabled) }
        if geometryChanged, wm.enabled, let last = wm.last { wm.apply(last.area, last.space, last.wins) }
    }
    private func releaseIgnoredMembers(_ windows: [WinInfo]) {
        for window in windows where sys.membership[window.wid] != nil && wm.ignored(window) && ignoredReleases[window.wid] == nil {
            guard let record = sys.recovery.records[window.wid], record.pid == window.pid,
                  sys.processBirth(window.pid) == record.birth else { continue }
            let hidden = wm.hidden.first { $0.wid == window.wid && $0.pid == record.pid && $0.extra["swift_birth"]?.string == record.birth }
            ignoredReleases[window.wid] = (record, hidden); configure?.cancel(window.wid)
            wm.target[window.wid] = nil; wm.newbies[window.wid] = nil; wm.optimistic[window.wid] = nil
            wm.restoring.remove(window.wid); engine.channel.prepareRelease(window.wid)
        }
        if !ignoredReleases.isEmpty, !restoringAll, !recovering { restorePump.step(only: Set(ignoredReleases.keys)) }
    }
    private func finishRestoreAll() {
        workspaceReceiver?.hide()
        restoringAll = false; recovering = false; engine.channel.cancelMotions()
        sys.membership.removeAll(); sys.concealed.removeAll(); wm.spaces.removeAll(); wm.target.removeAll(); wm.save()
    }
    /// AX work is asynchronous; a bounded batch keeps paused IPC responsive.
    @discardableResult private func restoreRecords() -> Int { restorePump.step() }
    private func recoverBeforeStart(_ ready: @escaping () -> Void) {
        recoveryEpoch += 1; let epoch = recoveryEpoch; recovering = true
        if let error = engineRecoveryIssue ?? sys.recovery.loadError { log("Lite recovery:", error, "; tiling stays paused"); return }
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
            if command == "panic-toggle" { if !self.recovering { self.invalidateCreated(); self.wm.setEnabled(!self.wm.enabled) }; return }
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
            self.retryCreated()
            if self.sys.now()-self.censusAt >= 0.05 {
                self.censusAt = self.sys.now()
                if self.restoringAll {
                    if self.sys.now() >= self.restoreAllDeadline { self.restoringAll = false }
                    else if self.restoreRecords() == 0 { self.finishRestoreAll() }
                }
                if let snapshot = try? self.sys.snapshot() {
                    self.releaseIgnoredMembers(snapshot.windows)
                    self.engine.channel.observe(snapshot)
                    if !self.wm.enabled { self.wm.last = (snapshot.area, snapshot.space, snapshot.windows) }
                }
            }
            self.engine.channel.advance(); self.configure?.drain(); self.wm.tick(socketReady: false)
            self.releaseEmptyReceiver()
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
            self.retryCreated()
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
        guard !stopping else { completion(false); return }; stopping = true; recovering = true; restoringAll = false; recoveryEpoch += 1
        invalidateCreated()
        pendingReload?.cancel(); wm.setEnabled(false); configure?.cancelAll(); engine.channel.prepareRecovery()
        wm.hidden.removeAll(); wm.save()
        let deadline = sys.now()+3
        func attempt() {
            let remaining = self.restoreRecords()
            if remaining == 0 { self.workspaceReceiver?.hide(); self.hotkeys?.close(); self.engine.channel.shutdown(); completion(true); return }
            guard self.sys.now() < deadline else {
                self.stopping = false
                log("Quit deferred: \(remaining) Lite windows need AX restoration; recovery ledger preserved.")
                completion(false); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now()+0.08) { attempt() }
        }
        attempt()
    }
    /// A mode switch cannot adopt native alpha/Space ownership through AX.
    /// Inspect only bounded, owner-controlled state; never rewrite its ledger.
    static func engineRecoveryProblem(stateDir: String) -> String? {
        let enginePath = stateDir+"/hyprwm.state.json"
        var engineInfo = stat()
        if lstat(enginePath, &engineInfo) == 0 {
            let descriptor = Darwin.open(enginePath, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { return "cannot safely inspect existing Engine state; start Engine mode and run restore-all" }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            guard fstat(descriptor, &engineInfo) == 0, engineInfo.st_uid == getuid(),
                  engineInfo.st_mode & S_IFMT == S_IFREG, engineInfo.st_mode & 0o022 == 0,
                  engineInfo.st_size >= 0, engineInfo.st_size <= 2_097_152,
                  let data = try? file.read(upToCount: 2_097_153), data.count <= 2_097_152,
                  let state = try? JSON.parse(data), let hidden = state["hidden"]?.array else {
                return "unreadable or invalid Engine state; start Engine mode and run restore-all"
            }
            guard hidden.isEmpty else { return "Engine has hidden-window records; start HYPRWM_MODE=engine and run restore-all before selecting Lite" }
        } else if errno != ENOENT { return "cannot inspect Engine recovery state; start Engine mode and run restore-all" }
        return nil
    }
    /// A dead daemon's recovery path requires no engine, hotkeys, or full WM.
    static func restoreOnly(stateDir: String) -> Never {
        if let error = engineRecoveryProblem(stateDir: stateDir) { die("restore-all: \(error)") }
        let sys = LiteSys(stateDir: stateDir)
        if let error = sys.recovery.loadError { die("restore-all: \(error)") }
        if sys.recovery.records.isEmpty { print("no outstanding Lite recovery records"); exit(0) }
        guard AXIsProcessTrusted() else { die("restore-all needs Accessibility: System Settings → Privacy & Security → Accessibility") }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let deadline = sys.now()+4
        let restorePump = LiteRestorePump(sys: sys)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(80))
        timer.setEventHandler {
            _ = restorePump.step()
            if sys.recovery.records.isEmpty { print("restored every Lite recovery record"); exit(0) }
            if sys.now() >= deadline { die("restore-all: \(sys.recovery.records.count) unresolved Lite records; ledger and application preserved") }
        }
        timer.resume(); withExtendedLifetime((sys, timer)) { application.run() }; exit(0)
    }
}
