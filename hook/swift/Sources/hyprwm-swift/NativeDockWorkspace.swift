import AppKit
import Darwin
import Foundation
import HyprCore

/// One direct native switch. The constructor-free Dock service owns the actor,
/// maps SID/UUID to its own ordinal and serializes the call on Dock's main queue.
final class NativeDockWorkspace {
    private let sys:LiveSys
    private let queue=DispatchQueue(label:"hyprwm.native.workspace",qos:.userInitiated),lock=NSLock()
    private let leasePath=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HyprWM/native-spaces/lease.json").path
    private var serial=0,workers=0,revocations=0,pending:(Int,PublicWorkspaceACK)?
    private var phase="idle",credential:JSON?
    private var dispatchMayHaveBegun=false
    private var sessionLeaseAvailable:Bool?
    private var state=JSON.object([("state",.string("not-loaded")),("backend",.string("native-Dock-existing-v1")),("acknowledged",.bool(false))])
    init(sys:LiveSys){self.sys=sys}
    var configured:Bool {lock.lock();let cached=sessionLeaseAvailable;lock.unlock();return cached ?? FileManager.default.fileExists(atPath:leasePath)}
    var busy:Bool {lock.lock();defer{lock.unlock()};return workers>0 || revocations>0}
    var ownsRequest:Bool {lock.lock();defer{lock.unlock()};return workers>0 || revocations>0 || (dispatchMayHaveBegun && phase != "acknowledged")}
    // Validate only at command boundaries. Status reads use the cached result.
    func available()->Bool {
        let valid:Bool
        do { _=try lease(PublicWorkspaceCatalog(VerifiedPublicWorkspace.diagnostic()));valid=true }
        catch {valid=false}
        lock.lock();sessionLeaseAvailable=valid;lock.unlock();return valid
    }
    var status:JSON {lock.lock();defer{lock.unlock()};return state.setting("worker_busy",.bool(workers>0 || revocations>0))}
    private func current(_ epoch:Int)->Bool {lock.lock();defer{lock.unlock()};return epoch==serial}
    func cancel(){
        lock.lock();serial+=1;let epoch=serial,lease=workers>0 ? credential:nil
        if lease != nil{revocations+=1}
        let mayHaveDispatched=workers>0 && dispatchMayHaveBegun;pending=nil
        phase=mayHaveDispatched ? "cancel-requested":"cancelled"
        state=state.setting("state",.string(mayHaveDispatched ? "cancel-requested-outcome-unconfirmed":"cancelled-before-dispatch")).setting("acknowledged",.bool(false));lock.unlock()
        if let lease {DispatchQueue.global(qos:.userInitiated).async{[weak self] in
            guard let self else{return};let revoked=(try? self.send(lease,"cancel"))?["queued_cancelled"] == .bool(true)
            self.lock.lock();self.revocations-=1;if self.serial==epoch{self.state=self.state.setting("remote_queue_revoked",.bool(revoked))};self.lock.unlock()
        }}
    }
    func observe(_ snapshot:Snapshot,fresh:Bool){
        guard fresh,let native=snapshot.nativeMetadata else{return}
        lock.lock();defer{lock.unlock()};guard var request=pending else{return}
        request.1.observeManager(native,time:ProcessInfo.processInfo.systemUptime);pending=request
    }
    func request(_ sid:Int,preflight:Bool)->Bool {
        if preflight{return configured && !busy}
        return enqueue(sid:sid,ordinal:nil,source:nil)
    }
    func enqueueExplicit(_ selector:String,source:Int)->Bool {
        guard let ordinal=Int(selector),(1...10).contains(ordinal) else{return false}
        return enqueue(sid:nil,ordinal:ordinal,source:source)
    }
    private func enqueue(sid:Int?,ordinal:Int?,source:Int?)->Bool {
        guard configured,!sys.sessionLocked(),let front=sys.frontPid(),let foreground=try? VerifiedPublicWorkspace.identity(front) else{return false}
        lock.lock();guard workers==0,revocations==0 else{lock.unlock();return false}
        // A failed recovery attempt must not forget an earlier unconfirmed send.
        if phase=="acknowledged"{dispatchMayHaveBegun=false}
        serial+=1;let epoch=serial;workers+=1;phase="queued";credential=nil
        state=JSON.object([("state",.string("queued")),("backend",.string("native-Dock-existing-v1")),("acknowledged",.bool(false))]);lock.unlock()
        queue.async{[weak self] in self?.execute(epoch,sid:sid,ordinal:ordinal,source:source,foreground:foreground)}
        return true
    }
    private static func identity(_ array:JSON)->JSON {
        guard let a=array.array,a.count==5 else{return .null}
        return .object([("pid",a[0]),("uid",a[1]),("sec",a[2]),("usec",a[3]),("path",a[4])])
    }
    private func lease(_ catalog:PublicWorkspaceCatalog)throws->JSON {
        var before=stat(),after=stat(),directory=stat()
        let parent=URL(fileURLWithPath:leasePath).deletingLastPathComponent().path
        guard lstat(parent,&directory)==0,directory.st_mode&S_IFMT==S_IFDIR,directory.st_uid==getuid(),directory.st_mode&0o077==0,
              lstat(leasePath,&before)==0,before.st_mode&S_IFMT==S_IFREG,before.st_uid==getuid(),before.st_mode&0o077==0,before.st_size>0,before.st_size<=65536 else{throw CmdError("private native workspace lease unavailable")}
        let bytes=try Data(contentsOf:URL(fileURLWithPath:leasePath))
        guard bytes.count<=65536,lstat(leasePath,&after)==0,before.st_dev==after.st_dev,before.st_ino==after.st_ino,before.st_size==after.st_size,
              before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec else{throw CmdError("native workspace lease changed during read")}
        let value=try JSON.parse(bytes)
        guard value["schema"] == .int(1),value["kind"] == .string("native-Dock-existing-v1"),
              value["owner"]==Self.identity(catalog.generation.array![3]),
              value["generation"]?["window_server"]==Self.identity(catalog.generation.array![2]),
              let nonce=value["nonce"]?.string,nonce.count==64,nonce.allSatisfy({$0.isHexDigit}),
              let epoch=value["epoch"]?.string,!epoch.isEmpty,epoch.utf8.count<=128,
              let path=value["socket"]?.string,path.hasPrefix(parent+"/"),path.utf8.count<104,
              URL(fileURLWithPath:path).resolvingSymlinksInPath().path==path else{throw CmdError("exact native workspace owner/session/endpoint lease required")}
        return value
    }
    private func send(_ lease:JSON,_ operation:String,_ extra:[(String,JSON)]=[],commit:(()throws->Void)?=nil)throws->JSON {
        guard let path=lease["socket"]?.string else{throw CmdError("native workspace endpoint absent")}
        var file=stat();guard lstat(path,&file)==0,file.st_mode&S_IFMT==S_IFSOCK,file.st_uid==getuid(),file.st_mode&0o077==0 else{throw CmdError("private native workspace socket required")}
        let fd=socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else{throw CmdError("native workspace socket failed")};defer{Darwin.close(fd)}
        _=fcntl(fd,F_SETFD,FD_CLOEXEC)
        var timeout=timeval(tv_sec:0,tv_usec:500_000),one:Int32=1
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size));setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout<Int32>.size))
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX);address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes=Array(path.utf8);guard bytes.count<MemoryLayout.size(ofValue:address.sun_path) else{throw CmdError("native workspace path overflow")}
        withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes);$0[bytes.count]=0}
        let connected=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
        guard connected==0 else{throw CmdError("native workspace service unavailable")}
        var uid:uid_t=0,gid:gid_t=0,pid:pid_t=0,length=socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd,&uid,&gid)==0,uid==getuid(),getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&pid,&length)==0,
              length==MemoryLayout<pid_t>.size,Self.identity(try VerifiedPublicWorkspace.identity(Int(pid)))==lease["owner"] else{throw CmdError("native workspace server identity differs")}
        let command=JSON.object([("op",.string(operation)),("owner",lease["owner"]!),("nonce",lease["nonce"]!),("epoch",lease["epoch"]!)]+extra)
        let data=Array((command.dumps()+"\n").utf8);guard data.count<=16384 else{throw CmdError("native workspace command overflow")}
        try commit?() // Last source/epoch fence, after connect and server identity verification.
        var offset=0
        while offset<data.count {
            let count=data.withUnsafeBufferPointer{Darwin.write(fd,$0.baseAddress!.advanced(by:offset),data.count-offset)}
            if count<0 && errno==EINTR{continue};guard count>0 else{throw CmdError("native workspace write unconfirmed")};offset+=count
        }
        var output=[UInt8](),buffer=[UInt8](repeating:0,count:4096)
        while output.count<=32768 {
            let count=Darwin.read(fd,&buffer,min(buffer.count,32769-output.count))
            if count<0 && errno==EINTR{continue};guard count>0 else{throw CmdError("native workspace reply unconfirmed")}
            output.append(contentsOf:buffer.prefix(count));if let newline=output.firstIndex(of:10){guard newline<=32768 else{throw CmdError("native workspace reply overflow")};return try JSON.parse(Data(output.prefix(newline)))}
        }
        throw CmdError("native workspace reply overflow")
    }
    private func observation(_ raw:JSON,original:PublicWorkspaceCatalog,epoch:Int)throws->PublicWorkspaceCatalog? {
        let result=try PublicWorkspaceCatalog.duringTransition(raw,from:original)
        if result==nil {
            lock.lock();defer{lock.unlock()}
            if serial==epoch, var request=pending,request.0==epoch {
                request.1.resetTransitionSamples();pending=request
                let count=(OverviewBinding.integer(state["unstable_observations"]) ?? 0)+1
                state=state.setting("unstable_observations",.int(count)).setting("last_unstable_observation",.object([("active_before",raw["active_before"] ?? .null),("active_after",raw["active_after"] ?? .null),("displays",raw["displays"] ?? .null)]))
            }
        }
        return result
    }
    private func independent(_ original:PublicWorkspaceCatalog,epoch:Int)throws->PublicWorkspaceCatalog? {
        let task=Process(),pipe=Pipe();task.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);task.arguments=["--workspace-observe"];task.standardOutput=pipe;task.standardError=FileHandle.nullDevice
        let done=DispatchSemaphore(value:0);task.terminationHandler={_ in done.signal()};try task.run()
        guard done.wait(timeout:.now()+1) == .success else{if task.isRunning{task.terminate()};throw CmdError("own workspace observer timeout")}
        let data=pipe.fileHandleForReading.readDataToEndOfFile();guard task.terminationStatus==0,data.count<=262144 else{throw CmdError("own workspace observer failed")}
        return try observation(JSON.parse(data),original:original,epoch:epoch)
    }
    private func execute(_ epoch:Int,sid:Int?,ordinal:Int?,source:Int?,foreground:JSON){
        defer{lock.lock();workers-=1;lock.unlock()}
        var dispatchBegan=false,observing=false
        do {
            guard current(epoch) else{throw CmdError("native workspace request cancelled")}
            let original=try PublicWorkspaceCatalog(VerifiedPublicWorkspace.diagnostic())
            guard source==nil || original.active==source else{throw CmdError("native workspace source changed")}
            let ordinary=original.spaces.filter{$0.kind==0}
            let targetID:Int
            if let sid{targetID=sid}else if let ordinal,ordinary.indices.contains(ordinal-1){targetID=ordinary[ordinal-1].sid}else{throw CmdError("existing native workspace target required")}
            let target=try original.target(targetID),credential=try lease(original)
            lock.lock();if serial==epoch{self.credential=credential};lock.unlock()
            var reply=try send(credential,"status")
            if reply["error"] == .string("peer_identity") {
                let rebound=try send(credential,"rebind");guard rebound["rebound"] == .bool(true) else{throw CmdError("native workspace manager rebind refused: "+(rebound["error"]?.string ?? "invalid-rebind-reply"))};reply=try send(credential,"status")
            }
            lock.lock();if serial==epoch{state=state.setting("native_readback",.object([("busy",reply["busy"] ?? .null),("pending",reply["pending"] ?? .null),("ticket_present",.bool(!(reply["ticket"]?.string ?? "").isEmpty)),("native_dispatches",reply["native_dispatches"] ?? .null)]))};lock.unlock()
            guard reply["ok"] == .bool(true) else{throw CmdError("native workspace status refused: "+(reply["error"]?.string ?? "unknown"))}
            // The v1 Objective-C comparison boxes `pending` as NSNumber 0/1;
            // accept exactly its false value as well as a JSON boolean.
            guard reply["busy"] == .bool(false),(reply["pending"] == .bool(false) || reply["pending"] == .int(0)),
                  let ticket=reply["ticket"]?.string,!ticket.isEmpty,let native=reply["catalog"] else{throw CmdError("native workspace busy/pending/ticket fence refused")}
            guard native["display"] == .string(original.display),native["current"] == .int(original.active),native["spaces"] == .array(original.spaces.map(\.json)) else{throw CmdError("native workspace Dock/manager catalog fence refused")}
            guard current(epoch),!sys.sessionLocked(),!sys.mouseDown(),let front=sys.frontPid(),try VerifiedPublicWorkspace.identity(front)==foreground else{throw CmdError("native workspace epoch/session/foreground fence refused")}
            guard try PublicWorkspaceCatalog(VerifiedPublicWorkspace.diagnostic())==original else{throw CmdError("native workspace manager catalog changed before dispatch")}
            let ack=try PublicWorkspaceACK(before:original,sid:targetID,managerIdentity:original.observer,ordinaryRequired:true)
            lock.lock();guard serial==epoch else{lock.unlock();throw CmdError("native workspace cancelled before dispatch")};pending=(epoch,ack);lock.unlock()
            let requestID=UUID().uuidString
            let sent=try send(credential,"switch-existing",[("ticket",.string(ticket)),("source",native),("target",target.json.setting("display",.string(original.display))),("request_id",.string(requestID))],commit:{
                guard self.current(epoch),!self.sys.sessionLocked(),!self.sys.mouseDown(),let pid=self.sys.frontPid(),
                      try VerifiedPublicWorkspace.identity(pid)==foreground,
                      try PublicWorkspaceCatalog(VerifiedPublicWorkspace.diagnostic())==original else{throw CmdError("native workspace source changed at send fence")}
                self.lock.lock();defer{self.lock.unlock()};guard self.serial==epoch else{throw CmdError("native workspace cancelled before frame write")}
                self.phase="writing";self.dispatchMayHaveBegun=true;dispatchBegan=true
                self.state=self.state.setting("state",.string("dispatching")).setting("request_id",.string(requestID))
            })
            guard sent["ok"] == .bool(true),sent["native_dispatched"] == .bool(true) || sent["already_current"] == .bool(true) else{throw CmdError("native workspace single dispatch refused; no retry")}
            observing=true;lock.lock();if serial==epoch{phase="observing"};lock.unlock()
            let deadline=ProcessInfo.processInfo.systemUptime+4
            while current(epoch),ProcessInfo.processInfo.systemUptime<deadline {
                let fresh=try observation(VerifiedPublicWorkspace.diagnostic(),original:original,epoch:epoch)
                if let fresh {guard fresh.sameSession(original) else{throw CmdError("native workspace session/topology changed")}}
                if fresh?.active==targetID,let witness=try independent(original,epoch:epoch) {
                    lock.lock();guard var request=pending,request.0==epoch else{lock.unlock();throw CmdError("native workspace observation cancelled")}
                    do{try request.1.observeIndependent(witness,time:ProcessInfo.processInfo.systemUptime)}catch{lock.unlock();throw error}
                    pending=request;let complete=request.1.acknowledged
                    state=state.setting("state",.string("pending")).setting("sid",.int(targetID)).setting("acknowledged",.bool(false)).setting("witnesses",request.1.status)
                    lock.unlock()
                    if complete {
                        // Finish Dock's bookkeeping before this manager may exit.
                        // A native dispatch is never repeated while observing it.
                        let settled=try send(credential,"status")
                        guard settled["ok"] == .bool(true),settled["catalog"]?["current"] == .int(targetID),
                              settled["catalog"]?["display"] == .string(original.display),settled["catalog"]?["spaces"] == .array(original.spaces.map(\.json)) else{throw CmdError("native workspace final status unavailable")}
                        if settled["busy"] == .bool(false),(settled["pending"] == .bool(false) || settled["pending"] == .int(0)) {
                            lock.lock();guard serial==epoch else{lock.unlock();throw CmdError("native workspace final observation cancelled")}
                            pending=nil;phase="acknowledged";state=state.setting("state",.string("acknowledged")).setting("acknowledged",.bool(true)).setting("native_idle_confirmed",.bool(true)).setting("native_dispatches",settled["native_dispatches"] ?? .null);lock.unlock();return
                        }
                    }
                }
                Thread.sleep(forTimeInterval:0.02) // Bounded predicate observation; never schedules the native switch.
            }
            throw CmdError("native workspace independent/manager ACK timed out")
        }catch{
            // Witness failure is not a second native command. While this exact
            // manager still owns the lease, let one read-only status retire a
            // completed Dock request before a subsequent manager handover.
            lock.lock();let recoveryLease=serial==epoch && observing ? credential:nil;lock.unlock()
            let readback=recoveryLease.flatMap{try? send($0,"status")}
            lock.lock()
            if serial==epoch {
                pending=nil;phase=observing ? "ack-unconfirmed":dispatchBegan ? "outcome-unconfirmed":"refused-before-dispatch"
                state=state.setting("state",.string(phase)).setting("reason",.string(String(describing:error))).setting("acknowledged",.bool(false))
                if let readback {
                    state=state.setting("native_readback_on_failure",.object([
                        ("ok",readback["ok"] ?? .null),("busy",readback["busy"] ?? .null),
                        ("pending",readback["pending"] ?? .null),("sid",readback["catalog"]?["current"] ?? .null),
                        ("native_dispatches",readback["native_dispatches"] ?? .null)]))
                }
            }
            lock.unlock()
        }
    }
}
