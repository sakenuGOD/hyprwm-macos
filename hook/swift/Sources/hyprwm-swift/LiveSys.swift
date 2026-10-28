// Live system: SkyLight/CG/AX through C targets (hook/src/axlib.c, winsnap.m, and sys.c wrappers).
// Everything here accesses WindowServer and is not used in tests.
import AppKit
import CAX
import CSnap
import CryptoKit
import Darwin
import Foundation
import HyprCore

private enum ConfigureStreamRoot {
    static func integer(_ value:JSON?) -> Int? {if case let .int(n)?=value{return n};return nil}
    static func number(_ value:JSON?) -> Double? {guard let n=value?.double,n.isFinite else{return nil};return n}
    static func hex(_ value:String,_ count:Int) -> Bool {value.utf8.count==count && value.allSatisfy{"0123456789abcdef".contains($0)}}
    static func uuid(_ value:JSON?) -> String? {
        guard let text=value?.string,let parsed=UUID(uuidString:text),parsed.uuidString==text else{return nil};return text
    }
    static func digest(_ data:Data) -> String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func cohort(_ values:JSON?) -> [Int:String]? {
        guard let rows=values?.array,!rows.isEmpty,rows.count<=32 else{return nil}
        var result:[Int:String]=[:]
        for row in rows {
            guard let wid=integer(row["wid"]),wid>0,wid<=Int(UInt32.max),result[wid]==nil,
                  let object=row["object"]?.string,!object.isEmpty,object.count<=16,
                  hex(object,object.count),let address=UInt64(object,radix:16),address>0,
                  String(address,radix:16)==object else{return nil}
            result[wid]=object
        }
        return result
    }
    static func frame(_ value:JSON?) -> Rect? {
        guard let values=value?.array,values.count==4 else{return nil}
        let numbers=values.compactMap{number($0)}
        guard numbers.count==4,numbers[2]>0,numbers[3]>0 else{return nil}
        return Rect(numbers[0],numbers[1],numbers[2],numbers[3])
    }
    static func stable(_ a:stat,_ b:stat) -> Bool {
        a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_size==b.st_size && a.st_mode==b.st_mode &&
        a.st_uid==b.st_uid && a.st_nlink==b.st_nlink && a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec &&
        a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec &&
        a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec
    }
    /// Each component is opened relative to its protected parent, never through
    /// a symlink or an environment/caller supplied authority override.
    static func read(_ path:String,maximum:Int,requiredMode:Int?=nil) -> Data? {
        guard path.hasPrefix("/") else{return nil}
        let parts=path.split(separator:"/",omittingEmptySubsequences:false).dropFirst().map(String.init)
        guard !parts.isEmpty,parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}) else{return nil}
        var directory=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard directory>=0 else{return nil}
        defer{close(directory)}
        var rootInfo=stat()
        guard fstat(directory,&rootInfo)==0,rootInfo.st_uid==0,rootInfo.st_mode&0o022==0 else{return nil}
        for part in parts.dropLast() {
            let next=openat(directory,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard next>=0 else{return nil}
            close(directory);directory=next
            var info=stat()
            guard fstat(directory,&info)==0,info.st_uid==0,info.st_mode&0o022==0 else{return nil}
        }
        guard let name=parts.last else{return nil}
        let fd=openat(directory,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else{return nil};defer{close(fd)}
        var before=stat(),after=stat(),named=stat()
        guard fstat(fd,&before)==0,before.st_mode&S_IFMT==S_IFREG,before.st_uid==0,
              before.st_mode&0o022==0,before.st_nlink==1,before.st_size>0,before.st_size<=maximum,
              requiredMode==nil || Int(before.st_mode&0o7777)==requiredMode else{return nil}
        var data=Data(count:Int(before.st_size)),used=0
        while used<data.count {
            let remaining=data.count-used
            let count=data.withUnsafeMutableBytes{Darwin.read(fd,$0.baseAddress!.advanced(by:used),remaining)}
            if count<0 && errno==EINTR {continue}
            guard count>0 else{return nil};used+=count
        }
        guard fstat(fd,&after)==0,fstatat(directory,name,&named,AT_SYMLINK_NOFOLLOW)==0,
              stable(before,after),stable(after,named) else{return nil}
        return data
    }
}

private extension LiveSys {
    func streamActorCurrent(_ actor:JSON?,pid:Int?=nil,sameUser:Bool=false) -> Bool {
        guard let actor,let birth=actor["birth"]?.array,birth.count==4,
              let process=ConfigureStreamRoot.integer(birth[0]),process>1,process<=Int(Int32.max),pid==nil || pid==process,
              let uid=ConfigureStreamRoot.integer(birth[1]),uid>=0,uid<=Int(UInt32.max),!sameUser || uid==Int(getuid()),
              let seconds=ConfigureStreamRoot.integer(birth[2]),seconds>0,seconds<=9_007_199_254_740_991,
              let micros=ConfigureStreamRoot.integer(birth[3]),micros>=0,micros<1_000_000,
              let path=actor["executable"]?.string,path.hasPrefix("/"),path.utf8.count<4096,
              let current=try? VerifiedPublicWorkspace.identity(process),let fields=current.array,fields.count==5,
              let after=try? VerifiedPublicWorkspace.identity(process),after==current else{return false}
        return Array(fields.prefix(4))==birth && fields[4] == .string(path)
    }
    func streamLoaderApproved(_ grant:JSON,cohort:[Int:String],uid:Int) -> Bool {
        guard let qualification=grant["qualification"],let path=qualification["loader_receipt"]?.string,
              let expected=qualification["loader_sha256"]?.string,ConfigureStreamRoot.hex(expected,64),
              let imageHash=qualification["module_sha256"]?.string,ConfigureStreamRoot.hex(imageHash,64) else{return false}
        let prefix="/Library/Application Support/HyprWM/Configure Stream Grants/\(uid)/receipts/"
        guard path.hasPrefix(prefix),path.hasSuffix("/loaded.json") else{return false}
        let nonce=String(path.dropFirst(prefix.count).dropLast("/loaded.json".count))
        guard !nonce.isEmpty,nonce.count<=128,ConfigureStreamRoot.hex(nonce,nonce.count),
              let bytes=ConfigureStreamRoot.read(path,maximum:65536,requiredMode:0o644),ConfigureStreamRoot.digest(bytes)==expected,
              let proof=try? JSON.parse(bytes),proof["schema"] == .int(1),proof["kind"] == .string("configure-stream-loader-v1"),
              proof["phase"] == .string("loaded-inspected"),proof["target"]==grant["target"],proof["manager"]==grant["manager"],
              proof["window_server"]==grant["window_server"],let handle=ConfigureStreamRoot.integer(proof["handle"]),handle>0,
              ["actual_main_thread","entry_memory_verified","signature_verified","detached","identity_after_detach",
               "not_stopped_after_detach","retained"].allSatisfy({proof[$0] == .bool(true)}),
              ["allow_activation","allow_input","allow_restart"].allSatisfy({proof[$0] == .bool(false)}),
              let module=proof["module"],module["uuid"]==grant["module_uuid"],module["sha256"] == .string(imageHash),
              module["entry"] == .string("hypr_configure_stream_v1_json"),
              module["architecture"] == .string("arm64") || module["architecture"] == .string("arm64e"),
              let entryPrefix=module["entry_prefix"]?.string,ConfigureStreamRoot.hex(entryPrefix,32),
              let sourceHash=module["source_sha256"]?.string,ConfigureStreamRoot.hex(sourceHash,64),
              let response=proof["inspection"],response["ok"] == .bool(true),let inspection=response["inspection"],
              inspection["ok"] == .bool(true),inspection["target"]==grant["target"],inspection["module_uuid"]==grant["module_uuid"],
              let inspected=ConfigureStreamRoot.cohort(inspection["windows"]) else{return false}
        return cohort.allSatisfy{inspected[$0.key]==$0.value}
    }
    func configureStreamLease(_ pid:Int,_ wid:Int,_ space:Int,minimumTTL:Double,probeEpoch:Int?) -> ConfigureStreamLease? {
        let clock=now()
        guard pid>1,pid<=Int(Int32.max),wid>0,wid<=Int(UInt32.max),space>0,
              minimumTTL.isFinite,minimumTTL>=0.25,minimumTTL<=30,!protectedProcess(pid),
              let identity=try? VerifiedPublicWorkspace.identity(pid),let fields=identity.array,fields.count==5,
              let uid=ConfigureStreamRoot.integer(fields[1]),uid==Int(getuid()),
              let seconds=ConfigureStreamRoot.integer(fields[2]),seconds>0,
              let micros=ConfigureStreamRoot.integer(fields[3]),micros>=0,micros<1_000_000 else{return nil}
        let path="/Library/Application Support/HyprWM/Configure Stream Grants/\(uid)/\(pid)-\(uid)-\(seconds)-\(micros).json"
        guard let bytes=ConfigureStreamRoot.read(path,maximum:16384),let grant=try? JSON.parse(bytes),
              grant["schema"] == .int(1),grant["kind"] == .string("configure-stream-v1"),grant["scope"] == .string("qualified-own-windows"),
              streamActorCurrent(grant["target"],pid:pid,sameUser:true),
              ConfigureStreamRoot.uuid(grant["target"]?["main_uuid"]) != nil,
              streamActorCurrent(grant["manager"],pid:Int(getpid()),sameUser:true),streamActorCurrent(grant["window_server"]),
              let serverBirth=grant["window_server"]?["birth"]?.array,serverBirth.count==4,
              ConfigureStreamRoot.integer(serverBirth[1])==88,
              let serverPath=grant["window_server"]?["executable"]?.string,
              URL(fileURLWithPath:serverPath).resolvingSymlinksInPath().path=="/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer",
              let module=ConfigureStreamRoot.uuid(grant["module_uuid"]),ConfigureStreamRoot.uuid(grant["skylight_uuid"]) != nil,
              let epoch=ConfigureStreamRoot.integer(grant["epoch"]),epoch>0,epoch<=9_007_199_254_740_991,probeEpoch==nil || epoch==probeEpoch,
              ConfigureStreamRoot.integer(grant["ordinary_space"])==space,
              let expires=ConfigureStreamRoot.number(grant["expires"]),expires-clock>=minimumTTL,expires<=clock+30,
              ["allow_activation","allow_input","allow_restart"].allSatisfy({grant[$0] == .bool(false)}),
              let cohort=ConfigureStreamRoot.cohort(grant["windows"]),let object=cohort[wid],
              streamLoaderApproved(grant,cohort:cohort,uid:uid),
              let snapshot=try? focusSnapshot(),snapshot.stable,!snapshot.locked,snapshot.spaceType==0,snapshot.space==space,
              activeSpace()==UInt64(space) else{return nil}
        var buffer=[CChar](repeating:0,count:16385),connection:Int32=0
        let count=hs_copy_configure_stream_json(UInt32(wid),Int32(pid),UInt64(seconds),UInt64(micros),&buffer,UInt32(buffer.count),&connection)
        guard count>0,let property=try? buffer.withUnsafeBytes({try JSON.parse(Data($0.prefix(Int(count))))}),
              property["schema"] == .int(1),property["version"] == .int(1),property["kind"] == .string("configure-stream"),
              property["installed"] == .bool(true),property["enabled"] == .bool(true),property["inactive"] == .bool(false),
              property["proof_kind"] == .string("synchronous-frame-readback-v1"),property["module_uuid"] == .string(module),
              property["grant_sha256"] == .string(ConfigureStreamRoot.digest(bytes)),property["epoch"] == .int(epoch),
              property["target"]==grant["target"],property["manager"]==grant["manager"],property["window_server"]==grant["window_server"],
              property["ordinary_space"] == .int(space),property["expires"]?.double==expires,property["connection"] == .int(Int(connection)),
              let generation=ConfigureStreamRoot.integer(property["generation"]),generation>0,
              let floor=ConfigureStreamRoot.number(property["not_before"]),floor>0,
              let observed=ConfigureStreamRoot.number(property["observed_at"]),floor<=observed,observed<=now(),now()-observed<=0.2,
              let rows=property["windows"]?.array,ConfigureStreamRoot.cohort(property["windows"])==cohort else{return nil}
        let ready=probeEpoch==nil
        guard property["capability"] == .int(ready ? 6:0) else{return nil}
        if !ready {
            guard property["in_flight"] == .int(0),property["drain_scheduled"] == .bool(false),
                  property["admitted_callbacks"] == .int(0) else{return nil}
        }
        var selectedMinimum:(Double,Double)?,selectedProbe:Rect?,selectedActual:Rect?
        for row in rows {
            guard let member=ConfigureStreamRoot.integer(row["wid"]),
                  hs_window_connection(UInt32(member),Int32(pid))==connection,
                  snapshot.windows.contains(where:{$0.wid==member && $0.pid==pid && $0.on && $0.space==space && $0.layer==0 && !$0.nativeFullscreen}),
                  let actual=winBounds(member),actual.arr.allSatisfy({$0.isFinite}),
                  let minimum=clientMinimum(pid,member),minimum.0>0,minimum.1>0,
                  actual.w+1>=minimum.0,actual.h+1>=minimum.1,
                  let packed=ConfigureStreamRoot.integer(row["minimum"]),packed>0,packed<=Int(UInt32.max),
                  Double(packed&0xffff)/2==minimum.0,Double((packed>>16)&0xffff)/2==minimum.1,
                  let sequence=ConfigureStreamRoot.integer(row["sequence"]),sequence>=0,
                  let dispatched=ConfigureStreamRoot.integer(row["dispatched_sequence"]),dispatched>=0,dispatched<=sequence,
                  let stamp=ConfigureStreamRoot.number(row["t0"]),stamp==0 || floor<stamp && stamp<=observed else{return nil}
            let rowReady=row["ready"] == .bool(true)
            guard ready ? rowReady : row["pending"] == .bool(false) && row["in_flight"] == .bool(false) && row["awaiting_readback"] == .bool(false) else{return nil}
            var probeFrame:Rect?
            if rowReady {
                guard let ack=row["initial_probe_ack"],let probe=ConfigureStreamRoot.integer(ack["sequence"]),probe>0,probe<=sequence,
                      let t0=ConfigureStreamRoot.number(ack["t0"]),floor<t0,
                      let time=ConfigureStreamRoot.number(ack["time"]),t0<=time,time<=observed,
                      let frame=ConfigureStreamRoot.frame(ack["frame"]),frame.w+1>=minimum.0,frame.h+1>=minimum.1,
                      let last=row["last_ack"],let lastSequence=ConfigureStreamRoot.integer(last["sequence"]),lastSequence>=probe,lastSequence<=dispatched,
                      let lastT0=ConfigureStreamRoot.number(last["t0"]),floor<lastT0,
                      let lastTime=ConfigureStreamRoot.number(last["time"]),lastT0<=lastTime,lastTime<=observed,
                      ConfigureStreamRoot.frame(last["frame"]) != nil else{return nil}
                probeFrame=frame
            }
            if member==wid {
                guard ready || !rowReady && sequence==0 && stamp==0 else{return nil}
                selectedMinimum=minimum;selectedProbe=probeFrame;selectedActual=actual
            }
        }
        guard let minimum=selectedMinimum,let actual=selectedActual,expires-now()>=minimumTTL,now()-observed<=0.2,
              activeSpace()==UInt64(space),hs_window_connection(UInt32(wid),Int32(pid))==connection,
              streamActorCurrent(grant["target"],pid:pid,sameUser:true),
              streamActorCurrent(grant["manager"],pid:Int(getpid()),sameUser:true),streamActorCurrent(grant["window_server"]),
              let again=ConfigureStreamRoot.read(path,maximum:16384),again==bytes else{return nil}
        let finalClock=now()
        guard expires-finalClock>=minimumTTL,finalClock>=observed,finalClock-observed<=0.2 else{return nil}
        return ConfigureStreamLease(pid:pid,wid:wid,space:space,epoch:epoch,birth:"\(pid):\(seconds):\(micros)",object:object,
            moduleUUID:module,grantSHA256:ConfigureStreamRoot.digest(bytes),expires:expires,observedAt:observed,
            minimum:minimum,cohort:cohort,initialProbeFrame:selectedProbe,currentFrame:actual)
    }
}

final class LiveSys: SysAPI {
    private var tabHintTokens: [Int: Int32] = [:]
    deinit { for token in tabHintTokens.values { hs_notify_cancel(token) } }
    private let publicOverview=PublicOverviewMonitor()
    private let ruleMetadata=AXWindowMetadata()
    private let windowClassification=AXWindowClassification()
    private let applicationMetadata=ApplicationMetadataCache()
    private func metadata(_ pid:Int) -> ApplicationMetadata? {
        guard let birth=processBirth(pid) else {applicationMetadata.remove(pid);return nil}
        if let cached=applicationMetadata.read(pid:pid,birth:birth) {
            guard processBirth(pid)==birth else {applicationMetadata.remove(pid);return nil}
            return cached
        }
        // Do not hold the cache lock during synchronous LaunchServices IPC.
        guard let app=NSRunningApplication(processIdentifier:pid_t(pid)),let url=app.executableURL else{return nil}
        let value=ApplicationMetadata(executable:url.resolvingSymlinksInPath().path,
            bundlePath:app.bundleURL?.resolvingSymlinksInPath().path,bundleIdentifier:app.bundleIdentifier)
        guard processBirth(pid)==birth else {applicationMetadata.remove(pid);return nil}
        applicationMetadata.store(pid:pid,birth:birth,value:value);return value
    }
    let launcherTransferWorker=NativeLauncherTransferWorker()
    private var buf = [CChar](repeating: 0, count: 1 << 21)
    private let closeQueue=DispatchQueue(label:"hyprwm.close",qos:.userInitiated)
    private let closeLock=NSLock()
    private var closeCount=0
    private let focusQueue=DispatchQueue(label:"hyprwm.focus",qos:.userInteractive),focusLock=NSLock()
    private let contextQueue=DispatchQueue(label:"hyprwm.focus.context",qos:.userInitiated)
    private let presenceQueue=DispatchQueue(label:"hyprwm.window.presence",qos:.userInitiated)
    private var contextCache:[Int:(birth:String,time:Double,wid:Int?,flags:Int)]=[:]
    private var contextPending=Set<Int>()
    private var presenceCache:[Int:(pid:Int,birth:String,time:Double,result:Int)]=[:]
    private var presencePending:[Int:UInt64]=[:]
    private var presenceSequence:UInt64=0
    private var focusSequence=0,focusWorkers=0
    private var floatRestackPending=false,floatRestackAt=0.0
    var raiseFloatingWindows:(([Int])->Void)?
    private var focusCovers:[Int:FocusCoverStamp]=[:]
    func setFocusCover(_ value:FocusCoverStamp?,wid:Int) {focusLock.lock();focusCovers[wid]=value;focusLock.unlock()}
    private func focusCover(_ request:FocusRequest) -> FocusCoverStamp? {
        focusLock.lock();let value=focusCovers[request.wid];focusLock.unlock()
        guard request.reason != .pointer,let value,value.pid==request.pid,value.birth==request.birth,value.space==request.space,value.deadline>=now() else{return nil}
        return value
    }
    var focusBusy:Bool {focusLock.lock();defer{focusLock.unlock()};return focusWorkers>0}
    func cancelFocus() {focusLock.lock();focusSequence+=1;focusLock.unlock()}
    func nativeFocusContext(_ pid:Int) -> (wid:Int?,flags:Int) {
        var wid:UInt32=0,flags:UInt32=4
        guard ax_focus_context(Int32(pid),&wid,&flags)==0 else{return(nil,4)}
        return(wid==0 ? nil:Int(wid),Int(flags))
    }
    func invalidateWindowPresence(_ wid:Int) {
        focusLock.lock();presenceCache[wid]=nil;presencePending[wid]=nil;focusLock.unlock()
    }
    func windowOrderedIn(_ pid:Int,_ wid:Int) -> Bool? {
        guard wid>0,wid<=Int(UInt32.max),let birth=processBirth(pid) else{return nil}
        let value=hs_window_ordered_in(Int32(pid),UInt32(wid))
        guard value>=0,processBirth(pid)==birth else{return nil}
        return value==1
    }
    func windowPresence(_ pid:Int,_ wid:Int) -> Int {
        guard wid>0,wid<=Int(UInt32.max),let birth=processBirth(pid) else{return -1}
        let time=now()
        focusLock.lock()
        if let cached=presenceCache[wid],cached.pid==pid,cached.birth==birth,
           cached.result==0 || time-cached.time<0.03 {focusLock.unlock();return cached.result}
        if presencePending[wid] != nil {focusLock.unlock();return -1}
        presenceSequence &+= 1;let sequence=presenceSequence;presencePending[wid]=sequence;focusLock.unlock()
        presenceQueue.async{[weak self] in
            guard let self else{return}
            let result=self.processBirth(pid)==birth ? Int(hs_window_presence(Int32(pid),UInt32(wid))):-1
            let fresh=self.processBirth(pid)==birth
            self.focusLock.lock();defer{self.focusLock.unlock()}
            guard self.presencePending[wid]==sequence else{return}
            self.presencePending[wid]=nil
            if fresh {self.presenceCache[wid]=(pid,birth,self.now(),result)}
            if self.presenceCache.count>256 {self.presenceCache[self.presenceCache.keys.sorted().first!]=nil}
        }
        return -1
    }
    func focusSnapshot() throws -> Snapshot {
        var buffer=[CChar](repeating:0,count:1<<21)
        let size=ws_snapshot(&buffer,Int32(buffer.count))
        guard size>0,size<=buffer.count else{throw CmdError("bounded independent focus census unavailable")}
        return ruleMetadata.enrich(try buffer.withUnsafeBufferPointer{pointer in Snapshot.parse(try JSON.parse(Array(UnsafeRawBufferPointer(start:pointer.baseAddress,count:Int(size))))) })
    }
    // AXRaise only restores stacking; it must never select the floating window as key.
    private func raiseAppFloats(_ tile:WinInfo,space:Int,windows:[WinInfo],birth:String,current:()->Bool) {
        func valid() -> Bool {current() && activeSpace()==UInt64(space) && !sessionLocked() && !interactionOverlay() &&
            !mouseDown() && frontPid()==tile.pid && processBirth(tile.pid)==birth && winPidLevel(tile.wid).pid==tile.pid}
        guard space>0,valid(),nativeFocusContext(tile.pid).wid==tile.wid,
              let fresh=try? focusSnapshot(),fresh.stable,!fresh.locked,fresh.spaceType==0,fresh.space==space,
              fresh.windows.contains(where:{$0.wid==tile.wid && $0.pid==tile.pid && $0.on && $0.space==space}) else{return}
        let liveIDs=Set(fresh.windows.filter{$0.on && $0.space==space && $0.pid==tile.pid && $0.alpha>=0.05}.map(\.wid))
        // Reverse census order preserves the relative order of sibling floats.
        for window in windows.reversed() where window.pid==tile.pid && window.wid != tile.wid && window.on &&
            window.space==space && window.layer==0 && window.alpha>=0.05 && !window.nativeFullscreen && liveIDs.contains(window.wid) {
            let flags=Int(ax_window_flags(Int32(window.pid),UInt32(window.wid)))
            // Only positive AX float evidence qualifies. Missing AX is never permission to raise.
            guard flags>=0,flags & (1<<7)==0,
                  flags & ((1<<3)|(1<<4)|(1<<5)|(1<<6)) != 0 || flags & (1<<0) != 0 && flags & (1<<2)==0 else{continue}
            guard valid(),winPidLevel(window.wid).pid==tile.pid else{return}
            let context=nativeFocusContext(tile.pid)
            guard context.wid==tile.wid,context.flags & (NativeFocusFlags.menu|NativeFocusFlags.unknown|NativeFocusFlags.fullscreen)==0 else{return}
            _=ax_raise(Int32(tile.pid),UInt32(window.wid))
        }
    }
    func preserveAppFloats(_ tile:WinInfo,space:Int,windows:[WinInfo]) {
        guard space>0,let birth=processBirth(tile.pid),!protectedProcess(tile.pid) else{return}
        focusLock.lock()
        guard !floatRestackPending,now()-floatRestackAt>=0.1 else{focusLock.unlock();return}
        floatRestackPending=true;floatRestackAt=now();let sequence=focusSequence;focusLock.unlock()
        focusQueue.async {[weak self] in
            guard let self else{return}
            defer{self.focusLock.lock();self.floatRestackPending=false;self.focusLock.unlock()}
            self.raiseAppFloats(tile,space:space,windows:windows,birth:birth) {
                self.focusLock.lock();defer{self.focusLock.unlock()};return self.focusSequence==sequence
            }
        }
    }
    func preserveFloatingWindows(_ windows:[WinInfo],space:Int) {
        guard !windows.isEmpty,space>0,let front=frontPid(),let frontBirth=processBirth(front),
              !sessionLocked(),!interactionOverlay(),!mouseDown() else{return}
        let owners=windows.compactMap{window -> (Int,Int,String)? in
            guard !protectedProcess(window.pid),let birth=processBirth(window.pid),winPidLevel(window.wid).pid==window.pid else{return nil}
            return(window.wid,window.pid,birth)
        }
        guard !owners.isEmpty else{return}
        focusLock.lock()
        guard !floatRestackPending,now()-floatRestackAt>=0.1 else{focusLock.unlock();return}
        floatRestackPending=true;floatRestackAt=now();let sequence=focusSequence;focusLock.unlock()
        focusQueue.async{[weak self] in
            guard let self else{return}
            defer{self.focusLock.lock();self.floatRestackPending=false;self.focusLock.unlock()}
            func valid()->Bool {
                self.focusLock.lock();let current=self.focusSequence==sequence;self.focusLock.unlock()
                return current && self.activeSpace()==UInt64(space) && !self.sessionLocked() && !self.interactionOverlay() &&
                    !self.mouseDown() && self.frontPid()==front && self.processBirth(front)==frontBirth
            }
            guard valid(),let fresh=try? self.focusSnapshot(),fresh.stable,!fresh.locked,fresh.spaceType==0,fresh.space==space else{return}
            let context=self.nativeFocusContext(front)
            guard context.flags & (NativeFocusFlags.positive|NativeFocusFlags.unknown)==0 else{return}
            // AppKit can keep an inactive application's AXRaise below the
            // active app. Use the engine's existing same-level order command,
            // on its sole writer, without changing native key/main selection.
            var ordered:[Int]=[]
            for window in fresh.windows.reversed() where window.on && window.space==space && window.layer==0 && window.alpha>=0.05 && !window.nativeFullscreen {
                guard let owner=owners.first(where:{$0.0==window.wid && $0.1==window.pid}) else{continue}
                guard valid(),self.winPidLevel(window.wid).pid==owner.1,self.processBirth(owner.1)==owner.2 else{return}
                let current=self.nativeFocusContext(front)
                guard current.wid==context.wid,current.flags==context.flags else{return}
                ordered.append(owner.0)
            }
            guard !ordered.isEmpty else{return}
            DispatchQueue.main.async {
                guard valid() else{return}
                let current=self.nativeFocusContext(front)
                guard current.wid==context.wid,current.flags==context.flags,
                      ordered.allSatisfy({wid in owners.contains{owner in owner.0==wid && self.winPidLevel(wid).pid==owner.1 && self.processBirth(owner.1)==owner.2}}) else{return}
                self.raiseFloatingWindows?(ordered)
            }
        }
    }
    private func redirectTargetModal(_ request:FocusRequest,context:(wid:Int?,flags:Int),source:Int?,allowed:()->Bool) throws {
        guard request.reason == .keyboard,context.flags & (NativeFocusFlags.menu|NativeFocusFlags.unknown|NativeFocusFlags.fullscreen)==0,
              context.flags & (NativeFocusFlags.modal|NativeFocusFlags.child) != 0,let wid=context.wid,wid != request.wid,
              let window=try focusSnapshot().windows.first(where:{$0.wid==wid && $0.pid==request.pid && $0.on &&
                  $0.space==request.space && $0.layer==0 && $0.alpha>=0.05 && !$0.nativeFullscreen}) else{return}
        let flags=Int(ax_window_flags(Int32(request.pid),UInt32(wid)))
        guard flags>=0,flags & ((1<<3)|(1<<4)|(1<<5)|(1<<6)) != 0,allowed(),
              activeSpace()==UInt64(request.space),frontPid()==source,winPidLevel(wid).pid==request.pid else{return}
        let fresh=nativeFocusContext(request.pid)
        guard fresh.wid==context.wid,fresh.flags==context.flags,allowed() else{return}
        _=axFocus(window.pid,window.wid,raise:true)
    }
    func requestFocus(_ request:FocusRequest,completion:@escaping(Bool)->Void) {
        focusLock.lock();focusSequence+=1;let sequence=focusSequence;focusWorkers+=1;focusLock.unlock()
        focusQueue.async {[weak self] in
            guard let self else{return}
            func current() -> Bool {self.focusLock.lock();defer{self.focusLock.unlock()};return sequence==self.focusSequence}
            func allowed() -> Bool {current()&&self.now()<request.deadline && !self.sessionLocked() && !self.interactionOverlay() &&
                self.activeSpace()==UInt64(request.space) &&
                !OverviewNativeMode.active(hs_overview10_mode()) && self.overviewGuard?() != true &&
                !self.mouseDown() && !self.protectedProcess(request.pid) && self.processBirth(request.pid)==request.birth &&
                self.winPidLevel(request.wid).pid==request.pid}
            func pointerAllows(_ snapshot:Snapshot)->Bool {
                guard request.reason == .pointer else{return true}
                return request.pointerAllows(self.mouse(),hint:self.pointerHit(),snapshot:snapshot,nativeBounds:self.winBounds(request.wid))
            }
            var accepted=false
            defer{let result=accepted;DispatchQueue.main.async{self.focusLock.lock();self.focusWorkers-=1;self.focusLock.unlock();completion(result)}}
            do {
                guard allowed() else{return}
                let source=self.frontPid()
                guard request.sourceMatches(source) else{return}
                let context:(wid:Int?,flags:Int)=source.map(self.nativeFocusContext) ?? (nil,NativeFocusFlags.noKey)
                guard context.flags&NativeFocusFlags.positive==0 else{return}
                let sourcePrimary=context.wid.map{key in source.map{self.axPrimaryWindow($0,key)} ?? false} ?? true
                let targetContext=source==request.pid ? context:self.nativeFocusContext(request.pid)
                guard request.targetAllows(targetContext) else {
                    try self.redirectTargetModal(request,context:targetContext,source:source,allowed:allowed)
                    return
                }
                guard self.axPrimaryWindow(request.pid,request.wid),allowed() else{return}
                var first=try self.focusSnapshot(),cover=self.focusCover(request)
                // A close fallback may be queued just before its final-layout
                // snapshot ACQUIRED receipt. Wait briefly for real authority.
                while request.target(in:first,covered:cover != nil)==nil && request.reason != .pointer && allowed() {
                    Thread.sleep(forTimeInterval:0.016)
                    guard self.frontPid()==source else{return}
                    first=try self.focusSnapshot();cover=self.focusCover(request)
                }
                guard request.target(in:first,covered:cover != nil) != nil,request.sourceAllows(context,snapshot:first,sourcePrimary:sourcePrimary),pointerAllows(first),allowed() else{return}
                if request.reason != .pointer {Thread.sleep(forTimeInterval:0.016)}
                guard allowed(),self.frontPid()==source else{return}
                if let source {let fresh=self.nativeFocusContext(source);guard fresh.wid==context.wid,fresh.flags==context.flags else{return}}
                let second=try self.focusSnapshot()
                guard self.focusCover(request)==cover,request.target(in:second,covered:cover != nil) != nil,request.sourceAllows(context,snapshot:second,sourcePrimary:sourcePrimary),pointerAllows(second),allowed(),self.frontPid()==source else{return}
                let commitTarget=self.nativeFocusContext(request.pid)
                guard request.targetAllows(commitTarget),allowed(),self.frontPid()==source else{return}
                if source==request.pid {
                    guard commitTarget.wid==context.wid,commitTarget.flags==context.flags else{return}
                } else if let source {
                    let commitSource=self.nativeFocusContext(source)
                    guard commitSource.wid==context.wid,commitSource.flags==context.flags else{return}
                }
                guard allowed(),self.frontPid()==source,self.activeSpace()==UInt64(request.space),self.axFocus(request.pid,request.wid,raise:false)==0,current(),self.frontPid()==request.pid else{return}
                let actual=self.nativeFocusContext(request.pid)
                accepted=actual.wid==request.wid && actual.flags&(NativeFocusFlags.positive|NativeFocusFlags.unknown)==0
                if accepted {
                    self.focusLock.lock()
                    self.contextCache[request.pid]=(request.birth,self.now(),actual.wid,actual.flags)
                    self.focusLock.unlock()
                    if let tile=second.windows.first(where:{$0.wid==request.wid && $0.pid==request.pid}) {
                        self.raiseAppFloats(tile,space:request.space,windows:second.windows,birth:request.birth,current:current)
                    }
                }
            }catch{return}
        }
    }
    func pointerHit() -> (wid:Int,pid:Int?)? {
        let point=mouse()
        var current:UInt32=0
        if ws_pointer_window(point.0,point.1,&current)==0 {
            // A successful empty hit must not resurrect an old event receiver.
            guard current>0 else{return(0,nil)}
            let owner=winPidLevel(Int(current))
            guard let pid=owner.pid,pid>0,owner.level != nil else{return(0,nil)}
            return(Int(current),pid)
        }
        guard ax_pointer_hit_available()==1 else{return nil}
        var value=ax_pointer_hit()
        guard ax_pointer_hit_read(&value)==1 else{return nil}
        let time=ax_launcher_now_ns()
        guard value.valid==3,value.wid>0,value.sequence>0,value.sequence&1==0,
              value.x.isFinite,value.y.isFinite,abs(value.x)<1_000_000,abs(value.y)<1_000_000,
              [UInt32(1),2,5,6,7,27].contains(value.event_type),
              time>=value.monotonic_ns,time-value.monotonic_ns<=250_000_000,
              hypot(point.0-value.x,point.1-value.y)<=2 else{return nil}
        // MouseMoved is delivered to the active application even when field92
        // names a window in another app. Event delivery PID is not WID ownership.
        // Resolve the input-capable window's owner from fresh native metadata.
        let owner=winPidLevel(Int(value.wid))
        guard let pid=owner.pid,pid>0,owner.level != nil else{return nil}
        return(Int(value.wid),pid)
    }
    var closeBusy:Bool { closeLock.lock();defer { closeLock.unlock() };return closeCount>0 }
    func requestClose(_ pid:Int,_ wid:Int,birth:String,completion:@escaping(CloseResult)->Void) {
        closeLock.lock();closeCount+=1;closeLock.unlock()
        closeQueue.async { [weak self] in
            guard let self else { return }
            var result=CloseResult(code:-1)
            if !self.sessionLocked(), !self.protectedProcess(pid), self.processBirth(pid) == birth, self.winPidLevel(wid).pid == pid {
                var metrics=hs_close_metrics();hs_close_request(Int32(pid),UInt32(wid),&metrics)
                result=CloseResult(code:Int(metrics.result),lookupMS:Double(metrics.lookup_ns)/1_000_000,buttonMS:Double(metrics.button_ns)/1_000_000,pressMS:Double(metrics.press_ns)/1_000_000)
            }
            let completed=result
            DispatchQueue.main.async {
                self.closeLock.lock();self.closeCount-=1;self.closeLock.unlock()
                completion(completed)
            }
        }
    }

    func now() -> Double { ProcessInfo.processInfo.systemUptime }
    func startLauncher() { _=ax_launcher_start() }
    func launcherAvailable() -> Int { Int(ax_launcher_available()) }
    func launcherIntent(after sequence:UInt64) -> LauncherIntent? {
        var value=ax_launcher_intent()
        guard ax_launcher_read(sequence,&value) == 1 else { return nil }
        let nativeNow=ax_launcher_now_ns()
        guard nativeNow >= value.monotonic_ns else { return nil }
        return LauncherIntent(sequence:value.sequence,space:Int(value.origin_space),frontPID:Int(value.front_pid),kind:Int(value.kind),started:now()-Double(nativeNow-value.monotonic_ns)/1_000_000_000)
    }
    func consumeLauncher(_ sequence:UInt64) { ax_launcher_clear(sequence) }
    func cacheLauncher(space:Int,frontPID:Int,windows:[WinInfo]) {
        let dock=windows.filter { w in w.on && metadata(w.pid)?.executable == "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock" }.prefix(16)
        let wids=dock.map { UInt32($0.wid) }, rectangles=dock.flatMap { $0.rect.arr }
        wids.withUnsafeBufferPointer { ids in rectangles.withUnsafeBufferPointer { bounds in ax_launcher_cache_dock(UInt64(max(0,space)),Int32(frontPID),ids.baseAddress,bounds.baseAddress,UInt32(ids.count)) } }
    }

    func appPath(_ pid: Int) -> String? { metadata(pid)?.bundlePath }
    func clientCapability(_ pid: Int) -> Int {
        guard let birth=processBirth(pid) else { return 0 };var value:UInt64=0
        let result="hyprwm.cap.\(pid)".withCString { hs_notify_state($0,&value) }
        return result == 0 && value <= 64 && processBirth(pid) == birth ? Int(value) : 0
    }
    func clientMinimum(_ pid:Int,_ wid:Int) -> (Double,Double)? {
        guard wid>0,wid<=Int(UInt32.max),let birth=processBirth(pid),!protectedProcess(pid),
              winPidLevel(wid).pid==pid else{return nil}
        var value:UInt64=0
        let result="hyprwm.min.\(wid)".withCString{hs_notify_state($0,&value)}
        guard result==0,value>0,value<=UInt64(UInt32.max),processBirth(pid)==birth,
              winPidLevel(wid).pid==pid else{return nil}
        return(Double(value&0xffff)/2,Double((value>>16)&0xffff)/2)
    }
    func streamLease(_ pid:Int,_ wid:Int,_ space:Int,minimumTTL:Double) -> ConfigureStreamLease? {
        configureStreamLease(pid,wid,space,minimumTTL:minimumTTL,probeEpoch:nil)
    }
    func streamProbeLease(_ pid:Int,_ wid:Int,_ space:Int,epoch:Int) -> ConfigureStreamLease? {
        configureStreamLease(pid,wid,space,minimumTTL:0.25,probeEpoch:epoch)
    }
    func nativeResize(_ pid: Int) -> NativeResizeContext? {
        guard let birth=processBirth(pid), !protectedProcess(pid) else { return nil }
        var value=hs_resize_context()
        guard hs_read_resize_context(Int32(pid),now(),&value) == 0, processBirth(pid) == birth else { return nil }
        return NativeResizeContext(pid:pid,birth:birth,wid:Int(value.wid),epoch:value.epoch,sequence:value.sequence,
            phase:Int(value.phase),frame:Rect(value.x,value.y,value.w,value.h),point:(value.mx,value.my),
            acceptedFrame:value.sample>0 ? Rect(value.accepted_x,value.accepted_y,value.accepted_w,value.accepted_h):nil,
            acceptedTime:value.sample>0 ? value.accepted_time:nil,sample:value.sample)
    }
    var overviewGuard:(()->Bool)?
    func overviewTransitionActive() -> Bool {publicOverview.active}
    func interactionOverlay() -> Bool {
        publicOverview.active || overviewGuard?() == true || OverviewNativeMode.active(hs_overview10_mode()) || ws_menu_tracking() != 0 || ws_input_overlay() != 0
    }
    func sessionLocked() -> Bool { hs_session_locked() != 0 }
    // A publisher hint only wakes the guarded reader; it supplies no identity
    // or tab authority. Periodic census remains the fallback for absent hints.
    func tabPropertiesChanged(_ pids: Set<Int>) -> Bool {
        guard Thread.isMainThread else { return true }
        for pid in Array(tabHintTokens.keys) where !pids.contains(pid) {
            if let token = tabHintTokens.removeValue(forKey: pid) { hs_notify_cancel(token) }
        }
        var changed = false
        for pid in pids where pid > 0 {
            if tabHintTokens[pid] == nil && tabHintTokens.count >= 128 { changed = true; continue }
            var token = tabHintTokens[pid] ?? -1
            let result = "hyprwm.identity.\(pid)".withCString { hs_notify_poll($0, &token) }
            if result < 0 {
                hs_notify_cancel(token); tabHintTokens[pid] = nil; changed = true
            } else {
                tabHintTokens[pid] = token
                if result != 0 { changed = true }
            }
        }
        return changed
    }
    func tabProperty(_ wid: Int, _ pid: Int) -> TabProperty? {
        let connection = hs_window_connection(UInt32(wid), Int32(pid))
        guard connection > 0 else { return nil }
        var error: Int32 = 0
        guard let pointer = hypridentity_copy_connection_json(hs_cid(), connection, Int32(pid), &error) else { return nil }
        defer { free(pointer) }
        guard hs_window_connection(UInt32(wid), Int32(pid)) == connection else { return nil }
        return TabProperty(connection: Int(connection), data: Data(bytes: pointer, count: strlen(pointer)))
    }
    func focusContext(_ pid: Int) -> (wid: Int?, flags: Int) {
        guard let birth=processBirth(pid) else{return(nil,4)}
        let time=now();focusLock.lock();let cached=contextCache[pid]
        if (cached?.birth != birth || time-(cached?.time ?? 0)>=0.03),contextPending.insert(pid).inserted {
            contextQueue.async{[weak self] in
                guard let self else{return};let value=self.nativeFocusContext(pid)
                let fresh=self.processBirth(pid)==birth;self.focusLock.lock()
                if fresh {self.contextCache[pid]=(birth,self.now(),value.wid,value.flags)}
                self.contextPending.remove(pid)
                if self.contextCache.count>128 {self.contextCache[self.contextCache.keys.sorted().first!]=nil}
                self.focusLock.unlock()
            }
        }
        focusLock.unlock()
        guard let cached,cached.birth==birth,time-cached.time<=0.15 else{return(nil,4)}
        return(cached.wid,cached.flags)
    }
    func processBirth(_ pid: Int) -> String? {
        var seconds: UInt64 = 0, micros: UInt64 = 0
        return hs_process_birth(Int32(pid), &seconds, &micros) == 0 ? "\(pid):\(seconds):\(micros)" : nil
    }
    func processUID(_ pid:Int) -> Int? {(try? VerifiedPublicWorkspace.identity(pid))?.array?[1].int}
    func processExited(_ pid:Int) -> Bool {guard pid>0 else{return false};return kill(pid_t(pid),0) != 0 && errno==ESRCH}
    func protectedProcess(_ pid: Int) -> Bool {
        if pid == getpid() { return true }
        guard let app=metadata(pid) else{return false}
        return SystemUI.protected(executable:app.executable,bundle:app.bundleIdentifier) ||
            (app.bundleIdentifier == "dev.hyprwm.HyprWM" && URL(fileURLWithPath:app.executable).lastPathComponent == "hyprwm-swift")
    }
    func sleep(_ s: Double) { usleep(useconds_t(max(0, s) * 1e6)) }

    func snapshot() throws -> Snapshot {
        var n = ws_snapshot(&buf, Int32(buf.count))
        if n < 0 {                                   // DIFFERENCE: Python failed when the buffer was too small; this implementation grows it
            buf = [CChar](repeating: 0, count: Int(-n) + 4096)
            n = ws_snapshot(&buf, Int32(buf.count))
            if n < 0 { throw CmdError("window snapshot exceeded the buffer") }
        }
        let j = try buf.withUnsafeBufferPointer { p in
            try JSON.parse(Array(UnsafeRawBufferPointer(start: p.baseAddress, count: Int(n))))
        }
        var snapshot = Snapshot.parse(j)
        snapshot.locked = sessionLocked()
        return ruleMetadata.enrich(snapshot)
    }

    func winPidLevel(_ wid: Int) -> (pid: Int?, level: Int?) {
        guard let nativeID=UInt32(exactly:wid),nativeID>0 else {return (nil,nil)}
        var p: Int32 = 0, lv: Int32 = 0
        if hs_win_pid_level(nativeID, &p, &lv) != 0 { return (nil, nil) }
        return (Int(p), Int(lv))
    }

    func frontPid() -> Int? {
        var p: Int32 = 0
        return hs_front_pid(&p) == 0 ? Int(p) : nil
    }

    func winBounds(_ wid: Int) -> Rect? {
        var r = [Double](repeating: 0, count: 4)
        return hs_win_bounds(UInt32(wid), &r) == 0 ? Rect(r[0], r[1], r[2], r[3]) : nil
    }

    func winAlpha(_ wid: Int) -> Double? {
        var a: Float = -1
        return hs_win_alpha(UInt32(wid), &a) == 0 ? Double(a) : nil
    }

    func moveToSpace(_ wids: [Int], _ space: Int) {
        let w = wids.map { Int32(truncatingIfNeeded: $0) }
        w.withUnsafeBufferPointer { hs_move_to_space($0.baseAddress, Int32(w.count), UInt64(space)) }
    }

    func activeSpace() -> UInt64 { hs_active_space() }
    func windowOnSpace(_ pid:Int,_ wid:Int,_ space:Int) -> Bool {
        guard let snapshot=try? focusSnapshot(),snapshot.stable,!snapshot.locked else{return false}
        return snapshot.windows.contains{$0.pid==pid && $0.wid==wid && $0.space==space && $0.layer==0 && !$0.nativeFullscreen}
    }

    func mouse() -> (Double, Double) {
        var x = 0.0, y = 0.0
        hs_mouse(&x, &y)
        return (x, y)
    }

    func mouseDown() -> Bool { hs_mouse_down() != 0 }

    private func windowFlags(_ pid:Int,_ wid:Int)->Int {
        // Focus workers still require fresh native evidence at their commit boundary.
        guard Thread.isMainThread else{return Int(ax_window_flags(Int32(pid),UInt32(wid)))}
        guard wid>0,wid<=Int(UInt32.max),let birth=processBirth(pid) else{return -1}
        return windowClassification.read(pid:pid,wid:wid,birth:birth) { [weak self] in
            guard let self,self.processBirth(pid)==birth,self.winPidLevel(wid).pid==pid else{return -1}
            let result=Int(ax_window_flags(Int32(pid),UInt32(wid)))
            guard self.processBirth(pid)==birth,self.winPidLevel(wid).pid==pid else{return -1}
            return result
        }
    }
    func axTileable(_ pid:Int,_ wid:Int)->Int {
        let flags=windowFlags(pid,wid)
        return flags<0 ? flags:flags & (1<<7) != 0 && flags & (1<<8)==0 ? 1:0
    }
    func axPrimaryWindow(_ pid:Int,_ wid:Int)->Bool {
        let flags=windowFlags(pid,wid)
        return flags>=0 && flags & (1<<7) != 0
    }
    func axFrame(_ pid: Int, _ wid: Int, _ r: Rect) -> Int { Int(ax_frame(Int32(pid), UInt32(wid), r.x, r.y, r.w, r.h)) }
    func axSize(_ pid:Int,_ wid:Int,_ width:Double,_ height:Double) -> Int {Int(ax_size(Int32(pid),UInt32(wid),width,height))}
    func axGetFrame(_ pid: Int, _ wid: Int) -> Rect? {
        var o = [Double](repeating: 0, count: 4)
        return ax_get_frame(Int32(pid), UInt32(wid), &o) == 0 ? Rect(o[0], o[1], o[2], o[3]) : nil
    }
    func axForget(_ wid: Int) { windowClassification.remove(wid);ax_forget(UInt32(wid)) }
    func axFocus(_ pid: Int, _ wid: Int, raise: Bool) -> Int {
        guard !interactionOverlay() else{return -1}
        return Int(ax_focus(Int32(pid),UInt32(wid),raise ? 1:0))
    }
    func axMenuPress(_ pid: Int, _ title: String) -> Int {
        guard title=="New Window",let birth=processBirth(pid),
              let info=metadata(pid),let bundlePath=info.bundlePath,let bundle=Bundle(path:bundlePath),
              let file=bundle.object(forInfoDictionaryKey:"OSAScriptingDefinition") as? String,
              (file as NSString).lastPathComponent==file,let url=bundle.url(forResource:file,withExtension:nil),
              let data=try? Data(contentsOf:url),data.count<=524288,
              let text=String(data:data,encoding:.utf8),let command=ScriptedWindowCommand(text) else{return Int(ax_menu_press(Int32(pid),title))}
        // Hidden native headings remove AX traversal, not the app's public scripting command.
        background { [weak self] in
            guard let self,self.processBirth(pid)==birth,self.metadata(pid)?.executable==info.executable else{return}
            let target=NSAppleEventDescriptor(processIdentifier:pid_t(pid))
            let event=NSAppleEventDescriptor(eventClass:command.eventClass,eventID:command.eventID,targetDescriptor:target,returnID:-1,transactionID:0)
            do {_=try event.sendEvent(options:[.noReply,.neverInteract],timeout:1)}
            catch {
                guard self.processBirth(pid)==birth else{return}
                let fallback=ax_menu_press(Int32(pid),title)
                if fallback != 0 {log("existing-instance New Window request refused: \(error); AX fallback \(fallback)")}
            }
        }
        return 0
    }

    func wsClose(_ pid: Int, _ wid: Int) -> Int { Int(ws_close(Int32(pid), UInt32(wid))) }
    func wsQuit(_ pid: Int) -> Int { Int(ws_quit(Int32(pid))) }

    func spotlight() { hs_spotlight() }

    func pgrep(_ name: String) -> Int? {
        let out = run(["/usr/bin/pgrep", "-x", name])
        return out.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }.first
    }

    func spawn(_ argv: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        do { try p.run() } catch { log("launch \(argv): \(error)") }
    }

    func background(_ f: @escaping () -> Void) { DispatchQueue.global(qos: .userInitiated).async(execute: f) }

    func run(_ argv: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
}
