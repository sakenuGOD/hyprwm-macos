import AppKit
import ApplicationServices
import CAX

/// Read-only fallback when the private overview controller is unavailable.
/// Reads only Dock container roles/identifiers, never window titles or actions.
final class PublicOverviewMonitor {
    private let lock=NSLock(),queue=DispatchQueue(label:"hyprwm.overview.public",qos:.userInitiated)
    private var timer:DispatchSourceTimer?
    private var positiveAt = -Double.infinity
    var active:Bool {
        lock.lock();defer{lock.unlock()}
        return ProcessInfo.processInfo.systemUptime-positiveAt<0.25
    }
    init() {
        let timer=DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now(),repeating:.milliseconds(50),leeway:.milliseconds(5))
        timer.setEventHandler{[weak self] in self?.poll()};self.timer=timer;timer.resume()
    }
    deinit {timer?.cancel()}
    private func poll() {
        guard let dock=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").first,
              dock.executableURL?.path=="/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock" else{return}
        let pid=dock.processIdentifier
        var seconds:UInt64=0,micros:UInt64=0
        guard hs_process_birth(pid,&seconds,&micros)==0 else{return}
        let app=AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app,0.02)
        let deadline=ProcessInfo.processInfo.systemUptime+0.08
        var visited=0
        func string(_ node:AXUIElement,_ attribute:String)->String {
            var value:CFTypeRef?
            guard AXUIElementCopyAttributeValue(node,attribute as CFString,&value) == .success,
                  let value,CFGetTypeID(value)==CFStringGetTypeID() else{return ""}
            return value as! String
        }
        func scan(_ node:AXUIElement,_ depth:Int)->Bool {
            guard depth<=3,visited<64,ProcessInfo.processInfo.systemUptime<deadline else{return false}
            visited+=1
            let role=string(node,kAXRoleAttribute)
            guard ["AXApplication","AXGroup","AXWindow","AXList","AXUnknown"].contains(role) else{return false}
            let identifier=string(node,kAXIdentifierAttribute).lowercased()
                .replacingOccurrences(of:"-",with:"").replacingOccurrences(of:" ",with:"")
            if ["mc","missioncontrol","missioncontrolwindow","appexpose"].contains(identifier) {return true}
            for attribute in depth==0 ? [kAXChildrenAttribute,kAXWindowsAttribute]:[kAXChildrenAttribute] {
                var values:CFArray?
                guard AXUIElementCopyAttributeValues(node,attribute as CFString,0,32,&values) == .success,let values else{continue}
                for value in values as [AnyObject] where CFGetTypeID(value)==AXUIElementGetTypeID() {
                    if scan(value as! AXUIElement,depth+1){return true}
                }
            }
            return false
        }
        let found=scan(app,0)
        var currentSeconds:UInt64=0,currentMicros:UInt64=0
        guard found,hs_process_birth(pid,&currentSeconds,&currentMicros)==0,
              seconds==currentSeconds,micros==currentMicros else{return}
        lock.lock();positiveAt=ProcessInfo.processInfo.systemUptime;lock.unlock()
    }
}
