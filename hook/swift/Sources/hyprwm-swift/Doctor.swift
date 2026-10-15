import AppKit
import ApplicationServices
import Carbon
import Foundation
import HyprCore

/// Read-only diagnostics: never requests TCC access or creates configuration.
func doctor(hook: String, controlPath: String) -> String {
    var lines = ["HyprWM doctor"]
    let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "development"
    lines.append("Version: \(version)")
    let reply = try? ControlClient(path:controlPath).request("status")
    let status = reply.flatMap { try? JSON.parse($0) }
    let requested = ProcessInfo.processInfo.environment["HYPRWM_MODE"] ?? "auto"
    let mode = status?["mode"]?.string ?? status?["daemon"]?["mode"]?.string ?? status?["engine"]?["mode"]?.string
    lines.append("Mode: \(mode ?? (status == nil ? "not running (requested: \(requested))" : "engine"))")
    lines.append("Socket: \(controlPath) — \(status == nil ? "unavailable or invalid response" : "responding")")
    func permission(_ name: String, _ granted: Bool, _ pane: String, _ purpose: String) {
        lines.append("\(name): \(granted ? "granted" : "missing") — System Settings → Privacy & Security → \(pane) (\(purpose))")
    }
    lines.append("Permissions below apply to this executable or its responsible terminal app:")
    permission("Accessibility",AXIsProcessTrusted(),"Accessibility","tiling and focus")
    permission("Screen Recording",CGPreflightScreenCaptureAccess(),"Screen & System Audio Recording","window capture animations and recordings")
    permission("Input Monitoring",CGPreflightListenEventAccess(),"Input Monitoring","event-tap hotkeys; Carbon hotkeys do not require it")
    var address = AEAddressDesc()
    let target = "com.apple.systemevents"
    let created = target.withCString { AECreateDesc(DescType(typeApplicationBundleID),$0,target.utf8.count,&address) }
    if created == noErr {
        defer { AEDisposeDesc(&address) }
        let automation = AEDeterminePermissionToAutomateTarget(&address,AEEventClass(typeWildCard),AEEventID(typeWildCard),false)
        let state = automation == noErr ? "granted" : automation == errAEEventWouldRequireUserConsent ? "not requested" : "missing"
        lines.append("Automation: \(state) — System Settings → Privacy & Security → Automation → System Events (only needed for scripted desktop verification)")
    } else { lines.append("Automation: unavailable — System Settings → Privacy & Security → Automation → System Events") }
    let config = TextConfig.url(configDir:hook+"/config")
    lines.append("Config: \(config.path)")
    if !FileManager.default.fileExists(atPath:config.path) {
        lines.append("Config: missing; run hyprwm --init-config to create commented defaults")
    } else {
        do {
            let handle = try FileHandle(forReadingFrom:config); defer { try? handle.close() }
            let bytes = try handle.read(upToCount:262145) ?? Data()
            guard bytes.count <= 262144, let text = String(data:bytes,encoding:.utf8) else { throw CmdError("expected UTF-8, at most 256 KB") }
            let parsed = try TextConfig.parse(text,configDir:hook+"/config")
            if parsed.issues.isEmpty { lines.append("Config: valid") }
            else { for issue in parsed.issues { lines.append("Config: \(issue.description)") } }
        } catch { lines.append("Config: \(error)") }
    }
    return lines.joined(separator:"\n")
}
