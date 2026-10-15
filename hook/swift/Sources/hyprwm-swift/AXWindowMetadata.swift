import ApplicationServices
import CAX
import Darwin
import Foundation
import HyprCore

/// AX role strings for rules. AX queries run off the census thread and are bounded
/// by an application timeout, a window count and a per-pass time budget.
final class AXWindowMetadata {
    private struct Entry {
        let birth: String
        var updated: Double
        var values: [Int:(role:String,subrole:String)]
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label:"hyprwm.ax.rule-metadata",qos:.utility)
    private var entries: [Int:Entry] = [:]
    private var pending = Set<Int>()
    private typealias WindowID = @convention(c) (AXUIElement,UnsafeMutablePointer<CGWindowID>) -> AXError
    // Existing AX bridge uses this SPI too. Capability-probed here; SIP-on behavior
    // is unverified by this adapter and absence leaves metadata unknown.
    private let windowID: WindowID? = dlsym(UnsafeMutableRawPointer(bitPattern:-2),"_AXUIElementGetWindow").map { unsafeBitCast($0,to:WindowID.self) }
    private func birth(_ pid:Int) -> String? {
        var seconds:UInt64=0,micros:UInt64=0
        return hs_process_birth(Int32(pid),&seconds,&micros) == 0 ? "\(pid):\(seconds):\(micros)" : nil
    }
    func enrich(_ input: Snapshot) -> Snapshot {
        guard windowID != nil else { return input }
        var snapshot = input
        let now = ProcessInfo.processInfo.systemUptime
        // No AX work for non-window server surfaces. Front-to-back order favors
        // current windows and prevents a census burst from queuing unbounded work.
        var identities: [Int:String] = [:]
        for window in input.windows where window.layer == 0 && window.pid > 0 {
            if identities[window.pid] == nil, identities.count < 32 { identities[window.pid] = birth(window.pid) }
        }
        lock.lock()
        entries = entries.filter { now-$0.value.updated < 10 && identities[$0.key] == $0.value.birth }
        var refresh: [(Int,String)] = []
        for (pid,identity) in identities {
            if entries[pid]?.birth != identity || now-(entries[pid]?.updated ?? 0) > 1 {
                if pending.count < 32, pending.insert(pid).inserted { refresh.append((pid,identity)) }
            }
        }
        for index in snapshot.windows.indices {
            let window=snapshot.windows[index]
            guard let entry=entries[window.pid],entry.birth==identities[window.pid],let value=entry.values[window.wid] else { continue }
            snapshot.windows[index].role=value.role;snapshot.windows[index].subrole=value.subrole
        }
        lock.unlock()
        for (pid,identity) in refresh {
            queue.async { [weak self] in self?.read(pid:pid,birth:identity) }
        }
        return snapshot
    }
    private func read(pid:Int,birth expected:String) {
        var values: [Int:(role:String,subrole:String)] = [:]
        defer {
            let fresh=birth(pid)==expected
            lock.lock();pending.remove(pid)
            if fresh { entries[pid]=Entry(birth:expected,updated:ProcessInfo.processInfo.systemUptime,values:values) }
            lock.unlock()
        }
        guard birth(pid)==expected,let windowID else { return }
        let application=AXUIElementCreateApplication(pid_t(pid))
        AXUIElementSetMessagingTimeout(application,0.08)
        var raw:CFTypeRef?
        guard AXUIElementCopyAttributeValue(application,kAXWindowsAttribute as CFString,&raw) == .success,
              let windows=raw as? [AXUIElement] else { return }
        let started=ProcessInfo.processInfo.systemUptime
        for window in windows.prefix(128) {
            if ProcessInfo.processInfo.systemUptime-started > 0.2 { break }
            AXUIElementSetMessagingTimeout(window,0.04)
            var wid:CGWindowID=0
            guard windowID(window,&wid) == .success,wid>0 else { continue }
            var owner:Int32=0,level:Int32=0
            guard hs_win_pid_level(wid,&owner,&level)==0,owner==pid else { continue }
            func string(_ name:String) -> String {
                var value:CFTypeRef?
                guard AXUIElementCopyAttributeValue(window,name as CFString,&value) == .success,
                      let text=value as? String,text.utf8.count<=512 else { return "" }
                return text
            }
            values[Int(wid)]=(string(kAXRoleAttribute),string(kAXSubroleAttribute))
        }
    }
}
