import AppKit
import ApplicationServices
import CAX
import Darwin
import HyprCore

/// AX work is isolated per application; a slow client cannot hold another client's queue.
/// The optional ID bridge is documented SIP-on by AeroSpace's README project
/// values (github.com/nikitabobko/AeroSpace#project-values), unverified locally.
/// The public fallback
/// matches a unique AX frame/title against the public CGWindowList census.
final class LiteAX {
    struct Window {
        let element: AXUIElement
        let role: String, subrole: String
        let resizable: Bool, modal: Bool, fullscreen: Bool
    }
    private final class Client {
        let queue: DispatchQueue
        let application: AXUIElement
        let birth: String
        var observer: AXObserver?
        var windows: [Int: Window] = [:]
        var closed = Set<Int>()
        var focused: Int?, flags = NativeFocusFlags.unknown
        var refreshed = 0.0, censusBegan = 0.0, refreshing = false, enumerated = false
        var cursor = 0, complete = false
        init(pid: Int, birth: String) {
            queue = DispatchQueue(label: "hyprwm.lite.ax.\(pid)", qos: .userInteractive)
            application = AXUIElementCreateApplication(pid_t(pid)); self.birth = birth
            AXUIElementSetMessagingTimeout(application, 0.08)
        }
    }
    static let cancelledAdmission = -100_001
    typealias WindowIDBridge = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private let bridge: WindowIDBridge? = {
        guard ProcessInfo.processInfo.environment["HYPRWM_LITE_PUBLIC_AX"] != "1",
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowIDBridge.self)
    }()
    private let lock = NSLock()
    private var clients: [Int: Client] = [:]
    private var createdStages: [String: Int] = [:]
    private func createdStage(_ stage: String) {
        lock.lock(); createdStages[stage, default: 0] += 1; lock.unlock()
    }
    var createdStatus: JSON {
        lock.lock(); defer { lock.unlock() }
        return .object(createdStages.sorted { $0.key < $1.key }.map { ($0.key, .int($0.value)) })
    }
    var privateIDBridgeAvailable: Bool { bridge != nil }
    struct Created {
        let window: WinInfo, birth: String, element: AXUIElement, received: Double
    }
    var onCreated: ((Created) -> Void)?
    private static let createdCallback: AXObserverCallback = { observer, element, _, context in
        guard let context else { return }
        Unmanaged<LiteAX>.fromOpaque(context).takeUnretainedValue().created(observer, element)
    }
    private func observe(_ pid: Int, _ client: Client) {
        client.queue.async { [weak self] in
            guard let self else { return }
            var value: AXObserver?
            guard AXObserverCreate(pid_t(pid), Self.createdCallback, &value) == .success, let observer = value,
                  AXObserverAddNotification(observer, client.application, kAXWindowCreatedNotification as CFString,
                    Unmanaged.passUnretained(self).toOpaque()) == .success else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); let current = self.clients[pid] === client
                if current { client.observer = observer }; self.lock.unlock()
                if current { CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes); self.createdStage("observer_registered") }
            }
        }
    }
    private func created(_ observer: AXObserver, _ element: AXUIElement) {
        let received = ProcessInfo.processInfo.systemUptime
        createdStage("notification")
        var rawPID: pid_t = 0
        guard AXUIElementGetPid(element, &rawPID) == .success else { return }
        let pid = Int(rawPID)
        lock.lock(); let client = clients[pid]; lock.unlock()
        guard let client, client.observer.map({ CFEqual($0, observer) }) == true else { return }
        client.queue.async { [weak self] in
            guard let self, Self.birth(pid) == client.birth else { return }
            AXUIElementSetMessagingTimeout(element, 0.08)
            guard let values = Self.attributes(element), let frame = Self.frame(values), Self.validCreatedFrame(frame),
                  values[kAXRoleAttribute] as? String == kAXWindowRole,
                  values[kAXSubroleAttribute] as? String == kAXStandardWindowSubrole,
                  let modal = values[kAXModalAttribute] as? Bool, !modal,
                  let full = values["AXFullScreen"] as? Bool, !full else { return }
            self.createdStage("ordinary")
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success,
                  settable.boolValue, !Self.modalBarrier(client.application, element),
                  let focused = Self.attribute(client.application, kAXFocusedWindowAttribute), CFEqual(focused, element) else { return }
            self.createdStage("focused")
            let title = values[kAXTitleAttribute] as? String ?? ""
            var number: CGWindowID = 0
            var row: [String: Any]?
            if let bridge = self.bridge, bridge(element, &number) == .success, number > 0 {
                row = (CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]])?.first {
                    $0[kCGWindowNumber as String] as? Int == Int(number) && $0[kCGWindowOwnerPID as String] as? Int == pid
                }
            } else {
                let matches = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).filter { row in
                    guard row[kCGWindowOwnerPID as String] as? Int == pid,
                          let bounds = row[kCGWindowBounds as String] as? [String: Any],
                          let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                    let name = row[kCGWindowName as String] as? String ?? ""
                    return Rect(rect.minX, rect.minY, rect.width, rect.height).maxDiff(frame) <= 2 && (title.isEmpty || name.isEmpty || title == name)
                }
                if matches.count == 1 { row = matches[0] }
            }
            guard let row, let wid = row[kCGWindowNumber as String] as? Int, wid > 0,
                  row[kCGWindowOwnerPID as String] as? Int == pid, row[kCGWindowLayer as String] as? Int == 0,
                  Self.birth(pid) == client.birth, ProcessInfo.processInfo.systemUptime-received < 0.25 else { return }
            self.createdStage("mapped")
            var window = WinInfo(wid: wid, pid: pid, owner: row[kCGWindowOwnerName as String] as? String ?? "",
                name: title, x: frame.x, y: frame.y, w: frame.w, h: frame.h, on: true, space: 0)
            window.role = kAXWindowRole; window.subrole = kAXStandardWindowSubrole
            self.lock.lock()
            let current = self.clients[pid] === client && client.observer.map { CFEqual($0, observer) } == true
            let fresh = client.windows[wid] == nil
            if current && fresh {
                client.windows[wid] = Window(element: element, role: window.role, subrole: window.subrole, resizable: true, modal: false, fullscreen: false)
                client.closed.remove(wid); client.focused = wid; client.flags = 0
            }
            self.lock.unlock()
            guard current, fresh else { return }
            self.createdStage("delivered")
            let created = Created(window: window, birth: client.birth, element: element, received: received)
            DispatchQueue.main.async { [weak self] in self?.onCreated?(created) }
        }
    }

    static func birth(_ pid: Int) -> String? {
        var seconds: UInt64 = 0, micros: UInt64 = 0
        return hs_process_birth(Int32(pid), &seconds, &micros) == 0 ? "\(pid):\(seconds):\(micros)" : nil
    }
    static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    static func string(_ element: AXUIElement, _ key: String) -> String { attribute(element, key) as? String ?? "" }
    static func bool(_ element: AXUIElement, _ key: String) -> Bool { attribute(element, key) as? Bool ?? false }
    static func attributes(_ element: AXUIElement) -> [String: Any]? {
        let keys = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXModalAttribute,
                    "AXFullScreen", kAXPositionAttribute, kAXSizeAttribute]
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &result) == .success,
              let values = result as? [Any], values.count == keys.count else { return nil }
        return Dictionary(uniqueKeysWithValues: zip(keys, values))
    }
    /// Query fresh modal/sheet state on the app's AX worker before mutating
    /// focus or repairing a raise. Cached census flags cannot cover new sheets.
    static func modalBarrier(_ application: AXUIElement, _ target: AXUIElement) -> Bool {
        func blocked(_ element: AXUIElement) -> Bool {
            guard let values = attributes(element), let role = values[kAXRoleAttribute] as? String else { return true }
            let subrole = values[kAXSubroleAttribute] as? String ?? ""
            if values[kAXModalAttribute] as? Bool == true || values["AXFullScreen"] as? Bool == true ||
                role == kAXSheetRole || subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole { return true }
            return (attribute(element, kAXChildrenAttribute) as? [AXUIElement])?.prefix(32).contains {
                string($0, kAXRoleAttribute) == kAXSheetRole
            } == true
        }
        if blocked(target) { return true }
        if let ui = attribute(application, kAXFocusedUIElementAttribute), CFGetTypeID(ui) == AXUIElementGetTypeID() {
            let role = string(unsafeBitCast(ui, to: AXUIElement.self), kAXRoleAttribute)
            if [kAXMenuRole, kAXMenuItemRole, kAXMenuBarRole, kAXMenuBarItemRole].contains(role) { return true }
        }
        if let focused = attribute(application, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            return blocked(unsafeBitCast(focused, to: AXUIElement.self))
        }
        return false
    }
    static func validCreatedFrame(_ frame: Rect) -> Bool {
        frame.arr.allSatisfy(\.isFinite) && frame.w > 0 && frame.h > 0 && frame.w <= 32768 && frame.h <= 32768 &&
            abs(frame.x) <= 1_048_576 && abs(frame.y) <= 1_048_576
    }
    static func frame(_ attributes: [String: Any]) -> Rect? {
        guard let rawPosition = attributes[kAXPositionAttribute], let rawSize = attributes[kAXSizeAttribute] else { return nil }
        let position = rawPosition as CFTypeRef, size = rawSize as CFTypeRef
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return Rect(point.x, point.y, dimensions.width, dimensions.height)
    }
    static func frame(_ element: AXUIElement) -> Rect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return Rect(point.x, point.y, dimensions.width, dimensions.height)
    }
    private func client(_ pid: Int) -> Client? {
        guard let birth = Self.birth(pid) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let old = clients[pid], old.birth == birth { return old }
        let client = Client(pid: pid, birth: birth); clients[pid] = client
        observe(pid, client)
        return client
    }
    func watch(_ pid: Int) { _ = client(pid) }
    func window(_ pid: Int, _ wid: Int) -> Window? {
        guard let client = client(pid) else { return nil }
        lock.lock(); defer { lock.unlock() }; return client.windows[wid]
    }
    func confirmedClosed(_ pid: Int, _ wid: Int) -> Bool {
        guard let client = client(pid) else { return false }
        lock.lock(); defer { lock.unlock() }; return client.closed.contains(wid) || client.complete && client.windows[wid] == nil
    }
    /// Public AXWindows existence after a native-unmap observation. A CG row
    /// can outlive a closed document; old/incomplete AX reads stay unknown.
    func presence(_ pid: Int, _ wid: Int, after began: Double) -> Int {
        guard let client = client(pid) else { return -1 }
        lock.lock(); defer { lock.unlock() }
        guard client.censusBegan >= began, !client.refreshing else { return -1 }
        if client.closed.contains(wid) { return 0 }
        if client.windows[wid] != nil { return 1 }
        return client.complete ? 0 : -1
    }
    func context(_ pid: Int) -> (wid: Int?, flags: Int) {
        guard let client = client(pid) else { return (nil, NativeFocusFlags.unknown) }
        lock.lock(); defer { lock.unlock() }; return (client.focused, client.flags)
    }
    func enumerated(_ pid: Int) -> Bool {
        guard let client = client(pid) else { return false }
        lock.lock(); defer { lock.unlock() }; return client.enumerated
    }
    func noteFocused(_ pid: Int, _ wid: Int) {
        guard let client = client(pid) else { return }
        lock.lock(); defer { lock.unlock() }
        client.focused = wid; client.flags = 0; client.refreshed = 0
    }
    func refresh(_ pid: Int, rows: [WinInfo], force: Bool = false) {
        guard let client = client(pid) else { return }
        lock.lock()
        guard !client.refreshing, force || ProcessInfo.processInfo.systemUptime - client.refreshed >= 0.12 else { lock.unlock(); return }
        client.refreshing = true; lock.unlock()
        client.queue.async { [weak self] in
            guard let self else { return }
            let began = ProcessInfo.processInfo.systemUptime
            guard let elements = Self.attribute(client.application, kAXWindowsAttribute) as? [AXUIElement] else {
                self.lock.lock(); client.refreshing = false; client.refreshed = began
                client.flags |= NativeFocusFlags.unknown; self.lock.unlock(); return
            }
            self.lock.lock(); let known = client.windows, cursor = client.cursor; self.lock.unlock()
            let closed = Set(known.filter { _, value in !elements.contains { CFEqual($0, value.element) } }.keys)
            var windows = known.filter { wid, _ in !closed.contains(wid) && rows.contains { $0.wid == wid && $0.pid == pid } }
            var processed = 0, failed = false
            for offset in 0..<min(256, elements.count) {
                if processed > 0, ProcessInfo.processInfo.systemUptime-began > 0.05 { break }
                let element = elements[(cursor+offset)%elements.count]; processed += 1
                AXUIElementSetMessagingTimeout(element, 0.08)
                guard let attributes = Self.attributes(element) else { failed = true; break }
                let wid: Int?
                var number: CGWindowID = 0
                if let bridge = self.bridge, bridge(element, &number) == .success,
                   rows.contains(where: { $0.wid == Int(number) && $0.pid == pid }) { wid = Int(number) }
                else if let previous = known.first(where: { CFEqual($0.value.element, element) }),
                        rows.contains(where: { $0.wid == previous.key && $0.pid == pid }) { wid = previous.key }
                else if let frame = Self.frame(attributes) {
                    let title = attributes[kAXTitleAttribute] as? String ?? ""
                    let matches = rows.filter { $0.pid == pid && $0.rect.maxDiff(frame) <= 2 && (title.isEmpty || $0.name.isEmpty || $0.name == title) }
                    wid = matches.count == 1 ? matches[0].wid : nil
                } else { wid = nil }
                guard let wid else { failed = true; continue }
                var settable = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success else { failed = true; continue }
                windows[wid] = Window(element: element, role: attributes[kAXRoleAttribute] as? String ?? "",
                    subrole: attributes[kAXSubroleAttribute] as? String ?? "", resizable: settable.boolValue,
                    modal: attributes[kAXModalAttribute] as? Bool ?? false, fullscreen: attributes["AXFullScreen"] as? Bool ?? false)
            }
            var focused: Int?, flags = NativeFocusFlags.noKey
            if let value = Self.attribute(client.application, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                let element = unsafeBitCast(value, to: AXUIElement.self)
                focused = windows.first(where: { CFEqual($0.value.element, element) })?.key
                flags = focused == nil ? NativeFocusFlags.unknown : 0
                let metadata = focused.flatMap { windows[$0] }
                if metadata?.modal == true { flags |= NativeFocusFlags.modal }
                if let children = Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement],
                   children.prefix(16).contains(where: { Self.string($0, kAXRoleAttribute) == kAXSheetRole }) { flags |= NativeFocusFlags.child }
                let role = metadata?.role ?? "", subrole = metadata?.subrole ?? ""
                if role == kAXSheetRole || subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole { flags |= NativeFocusFlags.child }
                if metadata?.fullscreen == true { flags |= NativeFocusFlags.fullscreen }
            }
            guard Self.birth(pid) == client.birth else { self.lock.lock(); client.refreshing = false; self.lock.unlock(); return }
            self.lock.lock()
            client.closed.formUnion(closed); client.closed.subtract(windows.keys)
            client.complete = !failed && processed >= elements.count
            client.windows = windows; client.focused = focused; client.flags = flags
            client.cursor = elements.isEmpty ? 0 : (cursor+processed)%elements.count
            client.censusBegan = began
            client.refreshed = ProcessInfo.processInfo.systemUptime; client.refreshing = false; client.enumerated = true
            self.lock.unlock()
        }
    }
    func perform(_ pid: Int, _ wid: Int, _ body: (AXUIElement, AXUIElement) -> Int) -> Int {
        guard let client = client(pid), let window = window(pid, wid) else { return -1 }
        return client.queue.sync {
            guard Self.birth(pid) == client.birth else { return -1 }
            return body(client.application, window.element)
        }
    }
    func performAsync(_ pid: Int, _ wid: Int, _ body: @escaping (AXUIElement, AXUIElement) -> Int,
                      completion: @escaping (Int) -> Void) {
        guard let client = client(pid), let window = window(pid, wid) else { completion(-1); return }
        client.queue.async {
            let result = Self.birth(pid) == client.birth ? body(client.application, window.element) : -1
            DispatchQueue.main.async { completion(result) }
        }
    }
    /// Size -> position -> size avoids AppKit clamping growth at the old edge.
    /// AXEnhancedUserInterface is an optional undocumented attribute, unverified
    /// under SIP; ordinary public setters remain the fallback. Restore its old
    /// value even after a failed configure.
    static func setFrame(_ application: AXUIElement, _ window: AXUIElement, _ frame: Rect) -> Int {
        let enhanced = attribute(application, "AXEnhancedUserInterface")
        if enhanced as? Bool == true { _ = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if let enhanced, enhanced as? Bool == true { _ = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, enhanced) } }
        var point = CGPoint(x: frame.x, y: frame.y), size = CGSize(width: frame.w, height: frame.h)
        guard let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size) else { return -1 }
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        let resized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
        return moved == .success && resized == .success ? 0 : Int((moved == .success ? resized : moved).rawValue)
    }
    func setFrame(_ pid: Int, _ wid: Int, _ frame: Rect) -> Int { perform(pid, wid) { Self.setFrame($0, $1, frame) } }
    func setFrameAsync(_ pid: Int, _ wid: Int, _ frame: Rect, deadline: Double = .infinity, validation: ((AXUIElement, AXUIElement) -> Bool)? = nil, completion: @escaping (Int, Rect?) -> Void) {
        guard let client = client(pid), let window = window(pid, wid) else { completion(-1, nil); return }
        client.queue.async {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  Self.birth(pid) == client.birth else { DispatchQueue.main.async { completion(validation == nil ? -1 : Self.cancelledAdmission, nil) }; return }
            guard validation?(client.application, window.element) != false else {
                DispatchQueue.main.async { completion(Self.cancelledAdmission, nil) }; return
            }
            let result = Self.setFrame(client.application, window.element, frame)
            let accepted = Self.frame(window.element)
            DispatchQueue.main.async { completion(result, accepted) }
        }
    }
    func getFrame(_ pid: Int, _ wid: Int) -> Rect? {
        var result: Rect?
        _ = perform(pid, wid) { _, window in result = Self.frame(window); return result == nil ? -1 : 0 }
        return result
    }
    /// Activation can follow AX-created delivery. A deferred admission gets a
    /// new ordinary/key/owner read on its original worker, never a cached replay.
    func revalidateCreated(_ created: Created, completion: @escaping (Created?) -> Void) {
        let pid = created.window.pid, wid = created.window.wid
        guard let client = client(pid), client.birth == created.birth else { completion(nil); return }
        client.queue.async { [weak self] in
            func finish(_ value: Created?) { DispatchQueue.main.async { completion(value) } }
            guard let self, Self.birth(pid) == created.birth,
                  ProcessInfo.processInfo.systemUptime-created.received < 0.25 else { finish(nil); return }
            self.lock.lock()
            let exact = self.clients[pid] === client && client.windows[wid].map { CFEqual($0.element, created.element) } == true
            self.lock.unlock()
            guard exact, let values = Self.attributes(created.element), let frame = Self.frame(values), Self.validCreatedFrame(frame),
                  values[kAXRoleAttribute] as? String == kAXWindowRole,
                  values[kAXSubroleAttribute] as? String == kAXStandardWindowSubrole,
                  values[kAXModalAttribute] as? Bool == false, values["AXFullScreen"] as? Bool == false,
                  let focused = Self.attribute(client.application, kAXFocusedWindowAttribute), CFEqual(focused, created.element),
                  let ui = Self.attribute(client.application, kAXFocusedUIElementAttribute), CFGetTypeID(ui) == AXUIElementGetTypeID(),
                  !Self.string(unsafeBitCast(ui, to: AXUIElement.self), kAXRoleAttribute).isEmpty,
                  !Self.modalBarrier(client.application, created.element) else { finish(nil); return }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(created.element, kAXSizeAttribute as CFString, &settable) == .success, settable.boolValue,
                  let row = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(wid)) as? [[String: Any]])?.first(where: {
                      $0[kCGWindowNumber as String] as? Int == wid && $0[kCGWindowOwnerPID as String] as? Int == pid
                  }), row[kCGWindowLayer as String] as? Int == 0,
                  Self.birth(pid) == created.birth, ProcessInfo.processInfo.systemUptime-created.received < 0.25 else { finish(nil); return }
            var window = created.window
            window.name = values[kAXTitleAttribute] as? String ?? ""
            window.x = frame.x; window.y = frame.y; window.w = frame.w; window.h = frame.h
            finish(Created(window: window, birth: created.birth, element: created.element, received: created.received))
        }
    }
    func expireCreated(_ created: Created) {
        lock.lock(); defer { lock.unlock() }
        guard let client = clients[created.window.pid], client.birth == created.birth,
              let window = client.windows[created.window.wid], CFEqual(window.element, created.element) else { return }
        client.windows[created.window.wid] = nil
        client.refreshed = 0
    }
    func forget(_ wid: Int) {
        lock.lock(); defer { lock.unlock() }
        for client in clients.values { client.windows[wid] = nil }
    }
}
