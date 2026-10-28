import AppKit
import CAX
import CSnap
import Foundation
import HyprCore

enum StartupQualification {
    static func fingerprint() -> JSON {
        guard let raw=hs_platform_fingerprint_json() else {
            return .object([("verified",.bool(false)),("stage",.string("fingerprint")),("reason",.string("macOS build information unavailable"))])
        }
        defer{free(raw)}
        return (try? JSON.parse(String(cString:raw))) ?? .object([("verified",.bool(false))])
    }

    /// This runtime owns no WM, engine channel, recovery pump or native helper.
    static func unverifiedStatus(_ result:JSON,statePath:String,nativeWorkUnknown:Bool) -> JSON {
        let base=JSON.object([("enabled",.bool(false)),("runtime",.string("swift")),("mode",.string("unverified")),
            ("compatibility",result)])
        let state:JSON?
        do {state=try EngineStatePreflight.read(statePath)} catch {
            return base.setting("hidden",.null).setting("recovery",.string(String(describing:error)))
        }
        let hidden=state?["hidden"]?.array ?? []
        let pending=hidden.compactMap{$0["wid"]?.int}.map(JSON.int)
        let retainedHandover=state?["handover"].map{!$0.isNull} ?? false
        return base.setting("hidden",.array(pending))
            .setting("engine",.object([("active",nativeWorkUnknown ? .null:.int(0)),("holding",nativeWorkUnknown ? .null:.int(0)),
                ("pending_commands",.bool(nativeWorkUnknown))]))
            .setting("visibility",.object([("restore_pending",.array(pending)),("restoring",.array([])),
                ("engine_recovery_active",.bool(nativeWorkUnknown || !hidden.isEmpty || retainedHandover))]))
    }

    static func unverified(_ result:JSON,hook:String,controlPath:String,statePath:String,nativeWorkUnknown:Bool) -> Never {
        let application=NSApplication.shared;application.setActivationPolicy(.accessory)
        let server:CommandServer
        do {server=try CommandServer(path:controlPath)}catch{FileHandle.standardError.write(Data("startup: \(error)\n".utf8));exit(1)}
        func handle(_ command:String) throws -> String {
            switch command {
            case "status","diagnose","doctor":return unverifiedStatus(result,statePath:statePath,nativeWorkUnknown:nativeWorkUnknown).dumps()
            case "pause","restore-all":
                let status=unverifiedStatus(result,statePath:statePath,nativeWorkUnknown:nativeWorkUnknown)
                guard status["visibility"]?["engine_recovery_active"] == .bool(false) else {
                    throw CmdError("Engine restoration pending: saved state requires a supported build")
                }
                return command == "pause" ? "paused":"no hidden windows"
            default:throw CmdError("Unverified on this macOS build: \(result["reason"]?.string ?? "startup checks failed")")
            }
        }
        let timer=DispatchSource.makeTimerSource(queue:.main)
        timer.schedule(deadline:.now(),repeating:.milliseconds(20))
        timer.setEventHandler{server.drain(handle)};timer.resume()
        let menu=MenuBarController(hook:hook,companion:false,startupAnimation:false){command,done in done(Result{try handle(command)})}
        menu.onQuit={done in done(true)}
        withExtendedLifetime((server,timer,menu)){application.run()};exit(0)
    }

    static func census(_ sys:LiveSys) throws -> Snapshot {
        guard ax_trusted() != 0 else{throw CmdError("Accessibility permission is required for the startup check")}
        let snapshot=try sys.snapshot()
        guard snapshot.stable,!snapshot.locked,snapshot.space>0,snapshot.spaceType==0,
              [snapshot.area.x,snapshot.area.y,snapshot.area.w,snapshot.area.h].allSatisfy(\.isFinite),
              snapshot.area.w>=320,snapshot.area.h>=240 else{throw CmdError("a stable, unlocked desktop is required")}
        guard snapshot.windows.count<=8192,snapshot.windows.allSatisfy({row in
            row.wid>0 && row.wid<=Int(UInt32.max) && row.pid>0 &&
            [row.x,row.y,row.w,row.h].allSatisfy(\.isFinite) && row.w>=0 && row.h>=0
        }) else{throw CmdError("invalid window information")}
        return snapshot
    }
}
