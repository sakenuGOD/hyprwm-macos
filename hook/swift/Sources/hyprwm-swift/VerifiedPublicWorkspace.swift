import AppKit
import CoreGraphics
import CryptoKit
import CSnap
import Darwin
import Foundation
import HyprCore

/// Native Swift consumer of an explicitly reviewed public AX helper. It never
/// invokes Python, a Space setter, coordinates, injection, or a fallback action.
/// Preflight IO and all helper/independent processes run away from the WM queue.
final class VerifiedPublicWorkspace {
    static let pythonSources=["hook/hyprwm.py","hook/src/winsnap.m","hook/build/libwinsnap.dylib",
        "hook/public_workspace.py","hook/public_workspace_factory.py","hook/scripts/tools/public_workspace_switch.py"]
    static let ordinarySources=["hook/ordinary_workspace_witness.py","hook/system_ui.py","hook/own_ui.py","hook/lifecycle.py"]
    static let swiftSources=["hook/swift/Sources/CSnap/workspace.m","hook/swift/Sources/HyprCore/PublicWorkspace.swift",
        "hook/swift/Sources/HyprCore/WM.swift","hook/swift/Sources/HyprCore/Interfaces.swift",
        "hook/swift/Sources/HyprCore/WMProduction.swift","hook/swift/Sources/HyprCore/WorkspaceCommand.swift","hook/swift/Sources/hyprwm-swift/VerifiedPublicWorkspace.swift",
        "hook/swift/Sources/hyprwm-swift/main.swift"]
    private let sys:LiveSys
    private let hook:String,queue=DispatchQueue(label:"hyprwm.public.workspace",qos:.userInitiated),lock=NSLock()
    private var serial=0,preparing=false,workerCount=0
    private var retryAfter=0.0
    private var prepared:(sid:Int,catalog:PublicWorkspaceCatalog,expires:Double,ordinaryRequired:Bool)?
    private var pending:(epoch:Int,ack:PublicWorkspaceACK)?
    private var child:Process?
    private var state=JSON.object([("state",.string("not-loaded")),("acknowledged",.bool(false)),("backend",.string("public-Mission-Control-AX"))])
    init(hook:String,sys:LiveSys) { self.hook=hook;self.sys=sys }
    var status:JSON { lock.lock();defer{lock.unlock()};return state.setting("worker_busy",.bool(workerCount>0)) }
    var busy:Bool { lock.lock();defer{lock.unlock()};return workerCount>0 || child?.isRunning==true }
    private func current(_ epoch:Int) -> Bool { lock.lock();defer{lock.unlock()};return serial==epoch }
    private func finish(_ epoch:Int,_ error:Error?=nil) {
        lock.lock();defer{lock.unlock()};workerCount-=1
        guard serial==epoch else{return}
        if let error { prepared=nil;pending=nil;preparing=false;retryAfter=ProcessInfo.processInfo.systemUptime+0.25;state=state.setting("state",.string("refused")).setting("reason",.string(String(describing:error))).setting("acknowledged",.bool(false)) }
    }
    func cancel() {
        lock.lock();serial+=1;prepared=nil;pending=nil;preparing=false
        state=state.setting("state",.string("cancelled")).setting("acknowledged",.bool(false))
        let process=child;lock.unlock()
        if process?.isRunning==true { process?.terminate() } // Only this bridge's own exact helper process.
    }
    static func diagnostic() throws -> JSON {
        guard let raw=hs_workspace_diagnostic_json() else{throw CmdError("native public workspace catalog/build/image unknown")}
        defer{free(raw)};return try JSON.parse(String(cString:raw))
    }
    static func identity(_ pid:Int) throws -> JSON {
        guard let raw=hs_workspace_identity_json(Int32(pid)) else{throw CmdError("native process identity unavailable")}
        defer{free(raw)};let result=try JSON.parse(String(cString:raw))
        guard PublicWorkspaceCatalog.identity(result) else{throw CmdError("exact native process identity required")};return result
    }
    private func catalog() throws -> PublicWorkspaceCatalog { try PublicWorkspaceCatalog(Self.diagnostic()) }
    private func data(_ path:String,maximum:Int=16*1024*1024) throws -> Data {
        var first=stat(),last=stat()
        guard path.hasPrefix("/"),lstat(path,&first)==0,(first.st_mode&S_IFMT)==S_IFREG,first.st_uid==getuid(),
              first.st_size>0,first.st_size<=maximum else{throw CmdError("bounded owned regular public permission/source required")}
        let bytes=try Data(contentsOf:URL(fileURLWithPath:path))
        guard bytes.count<=maximum,lstat(path,&last)==0,first.st_dev==last.st_dev,first.st_ino==last.st_ino,
              first.st_size==last.st_size,first.st_mtimespec.tv_sec==last.st_mtimespec.tv_sec,
              first.st_mtimespec.tv_nsec==last.st_mtimespec.tv_nsec else{throw CmdError("public permission/source changed during read")}
        return bytes
    }
    private func hash(_ path:String,maximum:Int=16*1024*1024) throws -> String {
        SHA256.hash(data:try data(path,maximum:maximum)).map{String(format:"%02x",$0)}.joined()
    }
    /// Bounded stdout and timeout; only the owned subprocess is terminated.
    private func run(_ executable:String,_ arguments:[String],timeout:Double,epoch:Int) throws -> Data {
        guard current(epoch) else{throw CmdError("public request cancelled")}
        let process=Process(),pipe=Pipe(),done=DispatchSemaphore(value:0),readDone=DispatchSemaphore(value:0),capture=NSLock()
        var output=Data(),overflow=false
        process.executableURL=URL(fileURLWithPath:executable);process.arguments=arguments
        process.standardOutput=pipe;process.standardError=FileHandle.nullDevice;process.terminationHandler={_ in done.signal()}
        lock.lock();child=process;lock.unlock()
        defer{lock.lock();if child===process && !process.isRunning{child=nil};lock.unlock()}
        try process.run()
        guard current(epoch) else {if process.isRunning{process.terminate()};throw CmdError("public request cancelled before helper start")}
        DispatchQueue.global(qos:.userInitiated).async {
            defer{readDone.signal()}
            while let bytes=try? pipe.fileHandleForReading.read(upToCount:16384),!bytes.isEmpty {
                capture.lock()
                if output.count+bytes.count>262144{overflow=true}else{output.append(bytes)}
                let failed=overflow;capture.unlock()
                if failed {if process.isRunning{process.terminate()};break}
            }
        }
        guard done.wait(timeout:.now()+timeout) == .success else {
            if process.isRunning{process.terminate()};_=done.wait(timeout:.now()+0.25)
            throw CmdError("owned public helper timed out")
        }
        guard readDone.wait(timeout:.now()+0.25) == .success else{throw CmdError("bounded public helper output did not finish")}
        capture.lock();let result=output,failed=overflow;capture.unlock()
        guard !failed,process.terminationStatus==0,current(epoch) else{throw CmdError("owned public helper failed/cancelled")}
        return result
    }
    private func verify(_ epoch:Int) throws -> JSON {
        guard current(epoch) else{throw CmdError("public request cancelled")}
        let proof=try JSON.parse(data(hook+"/workspace-public-permission.json",maximum:262144))
        let manager=try Self.identity(Int(getpid())),generation=try catalog().generation
        let executable=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath().path
        try PublicWorkspacePermission.validate(proof,manager:manager,imageHash:hash(executable,maximum:32*1024*1024),generation:generation)
        let root=URL(fileURLWithPath:hook).deletingLastPathComponent().path
        if proof["schema"] == .int(2),proof["manager_image"]?["path"] != .string(executable) {throw CmdError("exact reviewed Swift executable path differs")}
        let nativeSources=Self.pythonSources+(proof["schema"] == .int(2) ? Self.ordinarySources:[])
        for (key,names) in [("sources",nativeSources),("swift_sources",Self.swiftSources)] {
            guard let gates=proof[key]?.object,Set(gates.map{$0.0})==Set(names) else{throw CmdError("exact public native/Swift source gate absent")}
            for path in names { guard proof[key]?[path]?.string == (try hash(root+"/"+path)) else{throw CmdError("public source gate differs: "+path)} }
        }
        guard let helper=proof["helper"]?.string,helper.hasPrefix("/"),
              proof["source"] == .string(hook+"/scripts/tools/mission_control_ax.m"),
              proof["helper_sha"]?.string == (try hash(helper)),proof["source_sha"]?.string == (try hash(hook+"/scripts/tools/mission_control_ax.m")),
              proof["identity_library_sha"]?.string == (try hash(hook+"/build/libmanaged_process_identity.dylib")),
              proof["identity_source_sha"]?.string == (try hash(hook+"/src/managed_process_identity.c")) else{throw CmdError("public helper/Swift image/native identity hashes differ")}
        _=try run("/usr/bin/codesign",["--verify","--strict",helper],timeout:1,epoch:epoch)
        _=try run("/usr/bin/codesign",["--verify","--strict",hook+"/build/libmanaged_process_identity.dylib"],timeout:1,epoch:epoch)
        guard try catalog().generation==proof["generation"] else{throw CmdError("public native session generation changed")}
        return proof
    }
    func request(_ sid:Int,preflight:Bool) -> Bool {
        let now=ProcessInfo.processInfo.systemUptime
        lock.lock()
        if preflight {
            if let prepared,prepared.sid==sid,now<=prepared.expires,pending==nil {lock.unlock();return true}
            guard workerCount==0,!preparing,pending==nil,now>=retryAfter,child?.isRunning != true else{lock.unlock();return false}
            serial+=1;let epoch=serial;preparing=true;workerCount+=1
            state=state.setting("state",.string("preparing")).setting("acknowledged",.bool(false));lock.unlock()
            queue.async { [weak self] in
                guard let self else{return}
                do {
                    let proof=try self.verify(epoch);let before=try self.catalog();_=try before.target(sid)
                    self.lock.lock()
                    if self.serial==epoch {self.preparing=false;self.prepared=(sid,before,ProcessInfo.processInfo.systemUptime+1,proof["schema"] == .int(2));self.state=self.state.setting("state",.string("prepared"))}
                    self.lock.unlock();self.finish(epoch)
                } catch{self.finish(epoch,error)}
            }
            return false // Main loop retries origin intent after asynchronous preparation.
        }
        guard let ticket=prepared,ticket.sid==sid,now<=ticket.expires,pending==nil else{lock.unlock();return false}
        let epoch=serial
        guard let ack=try? PublicWorkspaceACK(before:ticket.catalog,sid:sid,managerIdentity:ticket.catalog.observer,ordinaryRequired:ticket.ordinaryRequired) else{prepared=nil;lock.unlock();return false}
        prepared=nil;pending=(epoch,ack);workerCount+=1
        state=state.setting("state",.string("pending")).setting("acknowledged",.bool(false)).setting("sid",.int(sid));lock.unlock()
        queue.async { [weak self] in self?.execute(epoch,sid,ticket.catalog) }
        return true // Accepted request; ACK remains false until independent + manager receipts.
    }
    /// One explicit request is retained through asynchronous verification. It
    /// never turns preflight-in-progress into a first-click refusal.
    func enqueueExplicit(_ selector:String,source:Int) -> Bool {
        guard selector=="new" || (1...10).contains(where:{String($0)==selector}),
              let original=try? catalog(),original.active==source,!sys.sessionLocked(),
              let front=sys.frontPid(),let foreground=try? Self.identity(front) else{return false}
        lock.lock()
        guard workerCount==0,pending==nil,!preparing else{lock.unlock();return false}
        serial+=1;let epoch=serial;workerCount+=1;prepared=nil
        state=state.setting("state",.string("queued")).setting("acknowledged",.bool(false))
            .setting("operation",.string(selector=="new" ? "create-and-switch":"switch-existing"))
        lock.unlock()
        queue.async{[weak self] in self?.executeExplicit(epoch,selector,original,foreground)}
        return true
    }
    private func executeExplicit(_ epoch:Int,_ selector:String,_ original:PublicWorkspaceCatalog,_ foreground:JSON) {
        do {
            var ownsOverview=false
            func frontCurrent() -> Bool {
                guard let pid=sys.frontPid(),let current=try? Self.identity(pid) else{return false}
                if current==foreground{return true}
                guard ownsOverview,let actor=current.array,actor[1].int==Int(getuid()) else{return false}
                return current==original.generation.array?[3] || actor[4].string=="/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"
            }
            func sourceCurrent() -> Bool {
                guard current(epoch),!sys.sessionLocked(),!sys.mouseDown(),frontCurrent(),let fresh=try? catalog() else{return false}
                return fresh.sameSession(original)&&fresh.active==original.active
            }
            let release=ProcessInfo.processInfo.systemUptime+2
            let modifiers:CGEventFlags=[.maskCommand,.maskShift,.maskAlternate,.maskControl,.maskSecondaryFn]
            while !CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty || CGEventSource.keyState(.hidSystemState,key:36) {
                guard sourceCurrent(),ProcessInfo.processInfo.systemUptime<release else{throw CmdError("explicit workspace modifier release/source fence expired")}
                Thread.sleep(forTimeInterval:0.01)
            }
            let proof=try verify(epoch)
            guard proof["schema"] == .int(2),proof["explicit_commands"]?["switch_existing"] == .bool(true),
                  selector != "new" || proof["explicit_commands"]?["create_ordinary"] == .bool(true),sourceCurrent() else{
                throw CmdError("reviewed explicit command/create scope or source/foreground changed")
            }
            var before=original
            let sid:Int
            if selector=="new" {
                guard before.spaces.filter({$0.kind==0}).count<10 else{throw CmdError("public ordinary workspace capacity1..10 reached; no creation")}
                _=try run("/usr/bin/open",["/System/Applications/Mission Control.app"],timeout:2,epoch:epoch);ownsOverview=true
                let pid=OverviewBinding.integer(before.dock["pid"])!,end=ProcessInfo.processInfo.systemUptime+3
                var inspection:JSON
                while true {
                    guard sourceCurrent(),ProcessInfo.processInfo.systemUptime<end else{throw CmdError("fresh unique add-desktop control/source unavailable")}
                    inspection=try helper(proof,["--inspect",String(pid)],epoch)
                    guard inspection["dock"]==before.dock,inspection["truncated"] == .bool(false) else{throw CmdError("complete exact Dock inspection required")}
                    let add=(inspection["controls"]?.array ?? []).filter{$0["identifier"] == .string("mc.spaces.add")}
                    if add.count==1,add[0]["role"] == .string("AXButton"),add[0]["press"] == .bool(true){break}
                    guard add.isEmpty else{throw CmdError("ambiguous add-desktop control")};Thread.sleep(forTimeInterval:0.05)
                }
                let folder=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("hyprwm.create."+UUID().uuidString)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:folder)}
                let receipt=folder.appendingPathComponent("inspection.json");try inspection.dumps().data(using:.utf8)!.write(to:receipt)
                guard sourceCurrent() else{throw CmdError("explicit creation source/foreground changed before AXPress")}
                let result=try helper(proof,["--press",String(pid),"mc.spaces.add","--receipt",receipt.path],epoch)
                guard result["dock"]==before.dock,result["dock_fence_after"] == .bool(true),result["ax_error"] == .int(0),
                      result["control"]?["identifier"] == .string("mc.spaces.add"),before.matchesPublicSnapshot(result["before_spaces"]) else{throw CmdError("single public add receipt refused; no retry")}
                lock.lock();state=state.setting("creation_receipt",result);lock.unlock()
                let deadline=ProcessInfo.processInfo.systemUptime+2
                var after:PublicWorkspaceCatalog?
                while ProcessInfo.processInfo.systemUptime<deadline {
                    guard current(epoch),!sys.sessionLocked(),frontCurrent() else{throw CmdError("creation session/foreground changed")}
                    if let fresh=try? catalog() {
                        if fresh != before { _=try before.appendedOrdinary(fresh);after=fresh;break }
                    }
                    Thread.sleep(forTimeInterval:0.02)
                }
                guard let after else{throw CmdError("one add yielded no exact appended ordinary Space; no retry")}
                sid=try before.appendedOrdinary(after).sid;before=after
            } else {
                let rows=before.spaces.filter{$0.kind==0},ordinal=Int(selector)!
                guard rows.indices.contains(ordinal-1) else{throw CmdError("existing ordinary workspace required")};sid=rows[ordinal-1].sid
            }
            let ack=try PublicWorkspaceACK(before:before,sid:sid,managerIdentity:before.observer,ordinaryRequired:true)
            lock.lock();pending=(epoch,ack);state=state.setting("state",.string("pending")).setting("sid",.int(sid));lock.unlock()
            execute(epoch,sid,before,overviewAlreadyOpened:ownsOverview,overviewOpened:{ownsOverview=true},commandFence:{[weak self] in
                guard let self,self.current(epoch),!self.sys.sessionLocked(),frontCurrent() else{return false}
                return true
            })
        } catch{finish(epoch,error)}
    }
    func observe(_ snapshot:Snapshot,fresh:Bool) {
        guard fresh,let raw=snapshot.nativeMetadata else{return}
        lock.lock();defer{lock.unlock()}
        guard var request=pending else{return}
        request.ack.observeManager(raw,time:ProcessInfo.processInfo.systemUptime);pending=request
    }
    private func helper(_ proof:JSON,_ arguments:[String],_ epoch:Int) throws -> JSON {
        guard let path=proof["helper"]?.string else{throw CmdError("reviewed public helper absent")}
        _=try verify(epoch)
        let raw=try JSON.parse(run(path,arguments,timeout:8,epoch:epoch))
        guard raw.object != nil,raw["error"] == nil || raw["error"] == .null else{throw CmdError("public AX helper refused")};return raw
    }
    private func execute(_ epoch:Int,_ sid:Int,_ original:PublicWorkspaceCatalog,overviewAlreadyOpened:Bool=false,overviewOpened:(()->Void)?=nil,commandFence:(()->Bool)?=nil) {
        do {
            guard commandFence?() ?? true else{throw CmdError("explicit workspace foreground changed")}
            let proof=try verify(epoch),before=try catalog()
            guard before.sameSession(original),before.active==original.active || before.active==sid else{throw CmdError("public source/current changed before commit")}
            let request=try before.request(sid),pid=OverviewBinding.integer(before.dock["pid"])!
            if before.active != sid {
                // Match the Russian accessibility label emitted by the verified Dock session.
                let description="\u{432}\u{44b}\u{439}\u{442}\u{438} \u{43d}\u{430} \u{420}\u{430}\u{431}\u{43e}\u{447}\u{438}\u{439} \u{441}\u{442}\u{43e}\u{43b} \(try before.ordinal(sid))"
                let expected=JSON.object([("identifier",.string("")),("role",.string("AXButton")),("description",.string(description)),("press",.bool(true))])
                var inspection=try helper(proof,["--inspect",String(pid)],epoch)
                if !overviewAlreadyOpened {
                    _=try run("/usr/bin/open",["/System/Applications/Mission Control.app"],timeout:2,epoch:epoch);overviewOpened?()
                }
                let deadline=ProcessInfo.processInfo.systemUptime+3
                while true {
                    guard current(epoch),try catalog()==before else{throw CmdError("public pre-action source changed")}
                    inspection=try helper(proof,["--inspect",String(pid)],epoch)
                    guard inspection["dock"]==before.dock,inspection["truncated"] == .bool(false) else{throw CmdError("complete exact Dock inspection required")}
                    let matches=(inspection["controls"]?.array ?? []).filter{$0==expected}
                    if matches.count==1{break}
                    guard matches.isEmpty,ProcessInfo.processInfo.systemUptime<deadline else{throw CmdError("unique exact ordinary Desktop control unavailable")}
                    Thread.sleep(forTimeInterval:0.05)
                }
                let directory=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("hyprwm.public."+UUID().uuidString)
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:directory)}
                let target=directory.appendingPathComponent("target.json"),receipt=directory.appendingPathComponent("inspection.json")
                try request.dumps().data(using:.utf8)!.write(to:target);try inspection.dumps().data(using:.utf8)!.write(to:receipt)
                guard commandFence?() ?? true else{throw CmdError("explicit workspace foreground changed before select")}
                let result=try helper(proof,["--select-ordinary",String(pid),"--target",target.path,"--receipt",receipt.path],epoch)
                guard result["mode"] == .string("select-ordinary"),result["dock"]==before.dock,result["target"]==request["target"],
                      OverviewBinding.integer(result["ax_error"])==0,result["native_current_ack"] == .bool(true),result["dock_fence_after"] == .bool(true),
                      before.matchesPublicSnapshot(result["before_spaces"]) else{throw CmdError("public AX sender receipt refused")}
            }
            let deadline=ProcessInfo.processInfo.systemUptime+6
            while ProcessInfo.processInfo.systemUptime<deadline {
                guard current(epoch) else{throw CmdError("public request cancelled")}
                let native=try catalog();guard native.sameSession(before) else{throw CmdError("public native topology/session changed")}
                if native.active==sid {
                    let observer=try PublicWorkspaceCatalog(JSON.parse(run(CommandLine.arguments[0],["--workspace-observe"],timeout:1,epoch:epoch)))
                    lock.lock()
                    guard var request=pending,request.epoch==epoch else{lock.unlock();throw CmdError("public request epoch invalidated")}
                    do{try request.ack.observeIndependent(observer,time:ProcessInfo.processInfo.systemUptime)}catch{lock.unlock();throw error}
                    pending=request;state=state.setting("witnesses",request.ack.status)
                    if request.ack.acknowledged {pending=nil;state=state.setting("state",.string("acknowledged")).setting("acknowledged",.bool(true));lock.unlock();finish(epoch);return}
                    lock.unlock()
                }
                Thread.sleep(forTimeInterval:0.05)
            }
            throw CmdError("independent/manager durable native ACK timed out")
        } catch{finish(epoch,error)}
    }
}
