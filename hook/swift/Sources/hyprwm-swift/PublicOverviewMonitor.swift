import AppKit
import ApplicationServices
import CAX
import HyprCore

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
        // AX containers can outlive Mission Control. Require an actual
        // onscreen full-display Dock surface as independent visible evidence.
        var displayIDs=[CGDirectDisplayID](repeating:0,count:16),displayCount:UInt32=0
        guard CGGetActiveDisplayList(16,&displayIDs,&displayCount) == .success,displayCount>0,displayCount<=16,
              let native=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]],native.count<=8192 else{return}
        let displays=displayIDs.prefix(Int(displayCount)).map {id->Rect in
            let r=CGDisplayBounds(id);return Rect(r.origin.x,r.origin.y,r.size.width,r.size.height)
        }
        var surfaces:[WinInfo]=[]
        for row in native where (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid {
            guard let bounds=row[kCGWindowBounds as String] as? [String:Any],
                  let x=bounds["X"] as? Double,let y=bounds["Y"] as? Double,
                  let width=bounds["Width"] as? Double,let height=bounds["Height"] as? Double,
                  let wid=row[kCGWindowNumber as String] as? Int,
                  let level=row[kCGWindowLayer as String] as? Int,
                  let alpha=row[kCGWindowAlpha as String] as? Double else{continue}
            var surface=WinInfo(wid:wid,pid:Int(pid),owner:"",x:x,y:y,w:width,h:height,
                on:(row[kCGWindowIsOnscreen as String] as? Bool)==true,space:0)
            surface.layer=level;surface.alpha=alpha;surfaces.append(surface)
        }
        var currentSeconds:UInt64=0,currentMicros:UInt64=0
        guard PublicOverviewEvidence.active(containerPresent:found,surfaces:surfaces,displays:displays),hs_process_birth(pid,&currentSeconds,&currentMicros)==0,
              seconds==currentSeconds,micros==currentMicros else{return}
        lock.lock();positiveAt=ProcessInfo.processInfo.systemUptime;lock.unlock()
    }
}
