import AppKit
import ApplicationServices
import Darwin
import HyprCore

extension Rect {
    func contains(_ px: Double, _ py: Double) -> Bool { px >= x && px < x+w && py >= y && py < y+h }
}

/// Recovery contains identities and geometry, never window titles or captured pixels.
final class LiteRecovery {
    struct Record: Codable {
        let wid: Int, pid: Int, birth: String
        let frame: [Double]
    }
    let url: URL
    private var safeStorage: Bool
    private(set) var loadError: String?
    private var warned = false
    private(set) var records: [Int: Record] = [:]
    init(directory: String) {
        url = URL(fileURLWithPath: directory).appendingPathComponent("lite-recovery.json")
        var parent = stat()
        let parentResult = lstat(directory, &parent)
        safeStorage = parentResult == 0 && parent.st_mode & S_IFMT == S_IFDIR && parent.st_uid == getuid() && parent.st_mode & 0o022 == 0
        func refuse(_ reason: String) { safeStorage = false; loadError = reason }
        if !safeStorage {
            // A genuinely missing parent also means no recovery file exists.
            // Daemon startup creates its directory before constructing this type.
            if parentResult == 0 || errno != ENOENT { refuse("unsafe or unreadable Lite recovery directory") }
            return
        }
        var existing = stat()
        if lstat(url.path, &existing) != 0 {
            if errno != ENOENT { refuse("unreadable existing Lite recovery ledger") }
            return
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { refuse("cannot safely open existing Lite recovery ledger"); return }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o022 == 0, info.st_size >= 0, info.st_size <= 262_144 else { refuse("unsafe or oversized existing Lite recovery ledger"); return }
        if let data = try? file.read(upToCount: 262_145), data.count <= 262_144,
           let rows = try? JSONDecoder().decode([Record].self, from: data) {
            let valid = rows.filter { record in
                record.wid > 0 && record.wid <= Int(UInt32.max) && record.pid > 0 && record.birth.hasPrefix("\(record.pid):") &&
                record.frame.count == 4 && record.frame.allSatisfy(\.isFinite) && abs(record.frame[0]) <= 1_048_576 && abs(record.frame[1]) <= 1_048_576 &&
                record.frame[2] > 0 && record.frame[2] <= 32768 && record.frame[3] > 0 && record.frame[3] <= 32768
            }
            guard rows.count <= 1024, valid.count == rows.count, Set(rows.map(\.wid)).count == rows.count else { refuse("invalid or ambiguous Lite recovery records"); return }
            records = Dictionary(rows.map { ($0.wid, $0) }, uniquingKeysWith: { first, _ in first })
        } else { refuse("cannot decode existing Lite recovery ledger; file preserved") }
    }
    @discardableResult func remember(_ window: WinInfo) -> Bool {
        guard let birth = LiteAX.birth(window.pid) else { return false }
        if let existing = records[window.wid], existing.pid == window.pid, existing.birth == birth { return safeStorage }
        guard safeStorage, records.count < 1024 else {
            if !warned { log("Lite refused to move a window: a safe writable recovery directory is required"); warned = true }
            return false
        }
        records[window.wid] = Record(wid: window.wid, pid: window.pid, birth: birth, frame: window.rect.arr)
        if save() { return true }
        records[window.wid] = nil; return false
    }
    func remove(_ wid: Int) { if records.removeValue(forKey: wid) != nil { save() } }
    @discardableResult func save() -> Bool {
        guard safeStorage, let data = try? JSONEncoder().encode(records.values.sorted { $0.wid < $1.wid }), data.count <= 262_144 else { return false }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { if !warned { log("Lite recovery ledger:", error.localizedDescription); warned = true }; return false }
    }
}

/// Lite uses public CG census, public AX control, and logical workspace IDs.
/// It never calls SkyLight, the native engine channel, or the launcher injector.
final class LiteSys: SysAPI {
    let ax = LiteAX()
    let recovery: LiteRecovery
    var workspace = 1
    var previousWorkspace = 1
    var membership: [Int: Int] = [:]
    var presentation: [Int: Rect] = [:]
    var concealed = Set<Int>()
    private(set) var rawWindows: [WinInfo] = []
    private var physicalWindows: [WinInfo] = []
    private var locked = false
    private let sessionLock = NSLock(), focusLock = NSLock()
    private var focusEpoch = 0, focusing = 0, closing = 0
    private var observers: [NSObjectProtocol] = []
    var beforeClose: ((Int, @escaping (Bool) -> Void) -> Void)?
    var onFrame: ((Int, Rect) -> Void)?
    init(stateDir: String) {
        recovery = LiteRecovery(directory: stateDir)
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setLocked(true) })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setLocked(false) })
    }
    deinit { for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    func now() -> Double { ProcessInfo.processInfo.systemUptime }
    func sleep(_ seconds: Double) { Thread.sleep(forTimeInterval: max(0, seconds)) }
    static var desktopTop: Double { Double(NSScreen.screens.first?.frame.maxY ?? 0) }
    static func rect(_ frame: NSRect) -> Rect { Rect(frame.minX, desktopTop - frame.maxY, frame.width, frame.height) }
    static func cocoa(_ frame: Rect) -> NSRect { NSRect(x: frame.x, y: desktopTop - frame.y - frame.h, width: frame.w, height: frame.h) }
    var area: Rect {
        let point = mouse()
        let screen = NSScreen.screens.first { Self.rect($0.frame).contains(point.0, point.1) } ?? NSScreen.main ?? NSScreen.screens.first
        return screen.map { Self.rect($0.visibleFrame) } ?? Rect(0, 0, 1440, 900)
    }
    var parkingPoint: (Double, Double) {
        let frames = NSScreen.screens.map { Self.rect($0.frame) }
        return (frames.map { $0.x + $0.w }.max().map { $0 - 1 } ?? 1439,
                frames.map { $0.y + $0.h }.max().map { $0 - 1 } ?? 899)
    }
    func park(_ frame: Rect) -> Rect { let point = parkingPoint; return Rect(point.0, point.1, frame.w, frame.h) }
    func snapshot() throws -> Snapshot {
        guard let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { throw CmdError("Lite public window census unavailable") }
        let ownPID = Int(getpid())
        var windows: [WinInfo] = []
        var physical: [WinInfo] = []
        for row in rows.prefix(4096) {
            guard let wid = row[kCGWindowNumber as String] as? Int,
                  let pid = row[kCGWindowOwnerPID as String] as? Int, pid != ownPID,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.width > 0, frame.height > 0 else { continue }
            let nativeOn = row[kCGWindowIsOnscreen as String] as? Bool ?? false
            var window = WinInfo(wid: wid, pid: pid, owner: row[kCGWindowOwnerName as String] as? String ?? "",
                name: row[kCGWindowName as String] as? String ?? "", x: frame.minX, y: frame.minY, w: frame.width, h: frame.height,
                on: nativeOn, space: nativeOn ? workspace : 0)
            window.layer = row[kCGWindowLayer as String] as? Int ?? 0
            window.alpha = row[kCGWindowAlpha as String] as? Double ?? 1
            physical.append(window)
            if let sid = membership[wid] { window.space = sid; window.on = sid == workspace && !concealed.contains(wid) }
            if let virtual = presentation[wid] { window.x = virtual.x; window.y = virtual.y; window.w = virtual.w; window.h = virtual.h }
            if let metadata = ax.window(pid, wid) {
                window.nativeFullscreen = metadata.fullscreen
                window.role = metadata.role; window.subrole = metadata.subrole
            }
            windows.append(window)
        }
        rawWindows = windows
        physicalWindows = physical
        for pid in Set(windows.filter { $0.layer == 0 && !protectedProcess($0.pid) }.map(\.pid)) {
            ax.refresh(pid, rows: physical.filter { $0.pid == pid })
        }
        var result = Snapshot(space: workspace, stable: true, area: area, windows: windows)
        result.locked = sessionLocked()
        result.nativeMetadata = .object([("workspace_kind", .string("virtual")), ("space", .int(workspace)), ("space_type", .int(0)), ("stable", .bool(true))])
        return result
    }
    func window(_ wid: Int) -> WinInfo? { rawWindows.first { $0.wid == wid } }
    func track(_ wid: Int) -> Bool {
        guard let window = window(wid), !protectedProcess(window.pid), recovery.remember(window) else { return false }
        if membership[wid] == nil { membership[wid] = workspace }
        return true
    }
    func winPidLevel(_ wid: Int) -> (pid: Int?, level: Int?) {
        if let row = window(wid) { return (row.pid, row.layer) }
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(wid)) as? [[String: Any]], let row = rows.first else { return (nil, nil) }
        return (row[kCGWindowOwnerPID as String] as? Int, row[kCGWindowLayer as String] as? Int)
    }
    func frontPid() -> Int? { NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) } }
    func winBounds(_ wid: Int) -> Rect? {
        // SysAPI bounds are physical acknowledgement, including the core's
        // mid-motion pause barrier. Proxy rectangles live only in Snapshot and
        // EngWin.visible; returning them here could release a still-parked body.
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(wid)) as? [[String: Any]],
              let row = rows.first, let bounds = row[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        return Rect(frame.minX, frame.minY, frame.width, frame.height)
    }
    func winAlpha(_ wid: Int) -> Double? { winPidLevel(wid).pid == nil ? nil : concealed.contains(wid) ? 0 : 1 }
    func moveToSpace(_ wids: [Int], _ space: Int) { for wid in wids where membership[wid] != nil { membership[wid] = space } }
    func activeSpace() -> UInt64 { UInt64(workspace) }
    func mouse() -> (Double, Double) { let point = CGEvent(source: nil)?.location ?? .zero; return (point.x, point.y) }
    func mouseDown() -> Bool { (0..<3).contains { CGEventSource.buttonState(.combinedSessionState, button: CGMouseButton(rawValue: UInt32($0))!) } }
    func pointerHit() -> (wid: Int, pid: Int?)? {
        let point = mouse()
        guard let window = rawWindows.first(where: { $0.on && $0.alpha > 0.01 && $0.rect.contains(point.0, point.1) }) else { return nil }
        return (window.wid, window.pid)
    }
    func axTileable(_ pid: Int, _ wid: Int) -> Int {
        guard let value = ax.window(pid, wid) else { return -1 }
        return value.role == kAXWindowRole && value.subrole == kAXStandardWindowSubrole && value.resizable && !value.modal && !value.fullscreen ? 1 : 0
    }
    func axFrame(_ pid: Int, _ wid: Int, _ frame: Rect) -> Int { ax.setFrame(pid, wid, frame) }
    func axSize(_ pid: Int, _ wid: Int, _ width: Double, _ height: Double) -> Int {
        ax.perform(pid, wid) { _, window in
            var size = CGSize(width: width, height: height)
            guard let value = AXValueCreate(.cgSize, &size) else { return -1 }
            return Int(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value).rawValue)
        }
    }
    func axGetFrame(_ pid: Int, _ wid: Int) -> Rect? { ax.getFrame(pid, wid) }
    func axForget(_ wid: Int) { ax.forget(wid) }
    func axFocus(_ pid: Int, _ wid: Int, raise: Bool) -> Int {
        guard !mouseDown(), !sessionLocked(), ax.window(pid, wid) != nil,
              let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return -1 }
        if let source = frontPid(), focusContext(source).flags & (NativeFocusFlags.positive|NativeFocusFlags.unknown) != 0 { return -1 }
        let result = ax.perform(pid, wid) { application, window in
            guard !self.mouseDown(), !self.sessionLocked() else { return -1 }
            return Self.setFocus(application, window, app)
        }
        if result == 0 { ax.noteFocused(pid, wid) }
        return result
    }
    func focusContext(_ pid: Int) -> (wid: Int?, flags: Int) { ax.context(pid) }
    var focusBusy: Bool { focusing > 0 }
    private static func setFocus(_ application: AXUIElement, _ window: AXUIElement, _ app: NSRunningApplication) -> Int {
        _ = app.activate(options: [])
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, window)
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        guard raised == .success, let focused = LiteAX.attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, window) else { return -1 }
        return 0
    }
    func cancelFocus() { focusLock.lock(); focusEpoch += 1; focusLock.unlock() }
    private func focusCurrent(_ epoch: Int) -> Bool { focusLock.lock(); defer { focusLock.unlock() }; return focusEpoch == epoch }
    func requestFocus(_ request: FocusRequest, completion: @escaping (Bool) -> Void) {
        focusLock.lock(); focusEpoch += 1; let epoch = focusEpoch; focusLock.unlock()
        guard now() < request.deadline, !mouseDown(), !sessionLocked(), processBirth(request.pid) == request.birth,
              membership[request.wid].map({ $0 == workspace }) ?? true, !concealed.contains(request.wid),
              let target = ax.window(request.pid, request.wid), !target.modal,
              let app = NSRunningApplication(processIdentifier: pid_t(request.pid)) else { completion(false); return }
        if let source = frontPid(), focusContext(source).flags & (NativeFocusFlags.positive|NativeFocusFlags.unknown) != 0 { completion(false); return }
        if request.reason == .pointer {
            guard pointerHit()?.wid == request.wid else { completion(false); return }
        }
        focusing += 1
        ax.performAsync(request.pid, request.wid, { [weak self] application, window in
            guard let self, self.focusCurrent(epoch), self.now() < request.deadline, !self.mouseDown(), !self.sessionLocked(),
                  self.processBirth(request.pid) == request.birth else { return -1 }
            if let source = request.sourcePID, NSRunningApplication(processIdentifier: pid_t(source))?.isActive != true { return -1 }
            return Self.setFocus(application, window, app)
        }) { [weak self] code in
            guard let self else { completion(false); return }; self.focusing -= 1
            let accepted = code == 0 && self.focusCurrent(epoch) && self.frontPid() == request.pid
            if accepted { self.ax.noteFocused(request.pid, request.wid) }
            self.ax.refresh(request.pid, rows: self.physicalWindows.filter { $0.pid == request.pid }, force: true)
            completion(accepted)
        }
    }
    func preserveAppFloats(_ tile: WinInfo, space: Int, windows: [WinInfo]) {
        for window in windows.reversed() where window.pid == tile.pid && window.wid != tile.wid && window.on && axTileable(window.pid, window.wid) == 0 {
            _ = ax.perform(window.pid, window.wid) { _, element in Int(AXUIElementPerformAction(element, kAXRaiseAction as CFString).rawValue) }
        }
    }
    func axMenuPress(_ pid: Int, _ title: String) -> Int { -1 }
    func wsClose(_ pid: Int, _ wid: Int) -> Int {
        ax.perform(pid, wid) { _, window in
            guard let button = LiteAX.attribute(window, kAXCloseButtonAttribute), CFGetTypeID(button) == AXUIElementGetTypeID() else { return -1 }
            return Int(AXUIElementPerformAction(unsafeBitCast(button, to: AXUIElement.self), kAXPressAction as CFString).rawValue)
        }
    }
    var closeBusy: Bool { closing > 0 }
    func requestClose(_ pid: Int, _ wid: Int, birth: String, completion: @escaping (CloseResult) -> Void) {
        guard processBirth(pid) == birth, winPidLevel(wid).pid == pid else { completion(CloseResult(code: -1)); return }
        closing += 1
        let action = { [weak self] (ready: Bool) in
            guard let self else { completion(CloseResult(code: -1)); return }
            guard ready else { self.closing -= 1; completion(CloseResult(code: -1)); return }
            self.ax.performAsync(pid, wid, { _, window in
                guard let button = LiteAX.attribute(window, kAXCloseButtonAttribute), CFGetTypeID(button) == AXUIElementGetTypeID() else { return -1 }
                return Int(AXUIElementPerformAction(unsafeBitCast(button, to: AXUIElement.self), kAXPressAction as CFString).rawValue)
            }) { code in self.closing -= 1; completion(CloseResult(code: code)) }
        }
        if let beforeClose { beforeClose(wid, action) } else { action(true) }
    }
    func wsQuit(_ pid: Int) -> Int { NSRunningApplication(processIdentifier: pid_t(pid))?.terminate() == true ? 0 : -1 }
    func spotlight() { spawn(["/usr/bin/open", "-a", "Spotlight"]) }
    func pgrep(_ name: String) -> Int? { NSWorkspace.shared.runningApplications.first { $0.executableURL?.lastPathComponent == name }.map { Int($0.processIdentifier) } }
    func spawn(_ argv: [String]) {
        guard let first = argv.first else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: first); process.arguments = Array(argv.dropFirst())
        do { try process.run() } catch { log("Lite launch:", error.localizedDescription) }
    }
    func background(_ work: @escaping () -> Void) { DispatchQueue.global(qos: .userInitiated).async(execute: work) }
    func protectedProcess(_ pid: Int) -> Bool {
        guard pid != getpid() else { return true }
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)), let executable = app.executableURL?.path else { return true }
        return SystemUI.protected(executable: executable, bundle: app.bundleIdentifier)
    }
    func appPath(_ pid: Int) -> String? { NSRunningApplication(processIdentifier: pid_t(pid))?.bundleURL?.path }
    func processBirth(_ pid: Int) -> String? { LiteAX.birth(pid) }
    // Lite intercepts logical sendws before native Space authorization. Unknown
    // process credentials are not fabricated from this daemon's own UID.
    func processUID(_ pid: Int) -> Int? { nil }
    func processExited(_ pid: Int) -> Bool { kill(pid_t(pid), 0) != 0 && errno == ESRCH }
    func windowPresence(_ pid: Int, _ wid: Int) -> Int {
        guard !processExited(pid) else { return 0 }
        return rawWindows.contains { $0.pid == pid && $0.wid == wid } ? 1 : 0
    }
    private func setLocked(_ value: Bool) { sessionLock.lock(); locked = value; sessionLock.unlock() }
    func sessionLocked() -> Bool { sessionLock.lock(); defer { sessionLock.unlock() }; return locked }
}
