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
        var windows: [Int: Window] = [:]
        var focused: Int?, flags = NativeFocusFlags.unknown
        var refreshed = 0.0, refreshing = false
        init(pid: Int, birth: String) {
            queue = DispatchQueue(label: "hyprwm.lite.ax.\(pid)", qos: .userInteractive)
            application = AXUIElementCreateApplication(pid_t(pid)); self.birth = birth
            AXUIElementSetMessagingTimeout(application, 0.08)
        }
    }
    typealias WindowIDBridge = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private let bridge: WindowIDBridge? = {
        guard ProcessInfo.processInfo.environment["HYPRWM_LITE_PUBLIC_AX"] != "1",
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowIDBridge.self)
    }()
    private let lock = NSLock()
    private var clients: [Int: Client] = [:]
    var privateIDBridgeAvailable: Bool { bridge != nil }

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
        return client
    }
    func window(_ pid: Int, _ wid: Int) -> Window? {
        guard let client = client(pid) else { return nil }
        lock.lock(); defer { lock.unlock() }; return client.windows[wid]
    }
    func context(_ pid: Int) -> (wid: Int?, flags: Int) {
        guard let client = client(pid) else { return (nil, NativeFocusFlags.unknown) }
        lock.lock(); defer { lock.unlock() }; return (client.focused, client.flags)
    }
    func enumerated(_ pid: Int) -> Bool {
        guard let client = client(pid) else { return false }
        lock.lock(); defer { lock.unlock() }; return client.refreshed > 0
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
            let elements = Self.attribute(client.application, kAXWindowsAttribute) as? [AXUIElement] ?? []
            var windows: [Int: Window] = [:]
            for element in elements.prefix(256) {
                AXUIElementSetMessagingTimeout(element, 0.08)
                let wid: Int?
                var number: CGWindowID = 0
                if let bridge = self.bridge, bridge(element, &number) == .success,
                   rows.contains(where: { $0.wid == Int(number) && $0.pid == pid }) { wid = Int(number) }
                else if let frame = Self.frame(element) {
                    let title = Self.string(element, kAXTitleAttribute)
                    let matches = rows.filter { $0.pid == pid && $0.rect.maxDiff(frame) <= 2 && (title.isEmpty || $0.name.isEmpty || $0.name == title) }
                    wid = matches.count == 1 ? matches[0].wid : nil
                } else { wid = nil }
                guard let wid, windows[wid] == nil else { continue }
                var settable = DarwinBoolean(false)
                _ = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable)
                windows[wid] = Window(element: element, role: Self.string(element, kAXRoleAttribute),
                    subrole: Self.string(element, kAXSubroleAttribute), resizable: settable.boolValue,
                    modal: Self.bool(element, kAXModalAttribute), fullscreen: Self.bool(element, "AXFullScreen"))
            }
            var focused: Int?, flags = NativeFocusFlags.noKey
            if let value = Self.attribute(client.application, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                let element = unsafeBitCast(value, to: AXUIElement.self)
                focused = windows.first(where: { CFEqual($0.value.element, element) })?.key
                flags = focused == nil ? NativeFocusFlags.unknown : 0
                if Self.bool(element, kAXModalAttribute) { flags |= NativeFocusFlags.modal }
                if let children = Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement],
                   children.prefix(16).contains(where: { Self.string($0, kAXRoleAttribute) == kAXSheetRole }) { flags |= NativeFocusFlags.child }
                let role = Self.string(element, kAXRoleAttribute), subrole = Self.string(element, kAXSubroleAttribute)
                if role == kAXSheetRole || subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole { flags |= NativeFocusFlags.child }
                if Self.bool(element, "AXFullScreen") { flags |= NativeFocusFlags.fullscreen }
            }
            guard Self.birth(pid) == client.birth else { self.lock.lock(); client.refreshing = false; self.lock.unlock(); return }
            self.lock.lock()
            client.windows = windows; client.focused = focused; client.flags = flags
            client.refreshed = ProcessInfo.processInfo.systemUptime; client.refreshing = false
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
    func setFrameAsync(_ pid: Int, _ wid: Int, _ frame: Rect, completion: @escaping (Int) -> Void) {
        performAsync(pid, wid, { Self.setFrame($0, $1, frame) }, completion: completion)
    }
    func getFrame(_ pid: Int, _ wid: Int) -> Rect? {
        var result: Rect?
        _ = perform(pid, wid) { _, window in result = Self.frame(window); return result == nil ? -1 : 0 }
        return result
    }
    func forget(_ wid: Int) {
        lock.lock(); defer { lock.unlock() }
        for client in clients.values { client.windows[wid] = nil }
    }
}
