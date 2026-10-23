import AppKit
import CAX
import Foundation
import HyprCore
import CoreGraphics

/// Authenticated existing Source10 service client. Installation, loading and all native hooks remain Root-owned.
/// Every socket exchange happens on this worker queue; the daemon never blocks on Dock's main queue.
final class OverviewBridge {
    private let sys: LiveSys
    private let queue=DispatchQueue(label:"hyprwm.overview10",qos:.userInitiated)
    private let lock=NSLock()
    private var desired: [OverviewHidden]=[]
    private var hiddenWindowsEnabled=false
    private var emptyAcknowledgmentScope=false
    private var hiddenIntents:Set<String>?
    private var hiddenIntentsAt=0.0
    private var activityFence=OverviewActivityFence()
    private var binding: OverviewBinding?
    private var sequence=0
    private var configured=""
    private var configuredPool=OverviewConfiguredPool()
    private var grantedIDs=Set<Int>()
    private var cachedEntryBinding:OverviewBinding?
    private var cachedEntryRecords:[OverviewHidden]=[]
    var ordinarySceneBusy:()->Bool={false}
    var ordinarySceneStatus:()->JSON={.object([])}
    private var attested=false
    private var selections: [OverviewSelection]=[]
    private var pending: (sequence:Int,operation:String)?
    private var pendingSignature: String?
    private var pendingSelection: OverviewSelection?
    private var lastRead=0.0, lastRenew=0.0
    private var snapshotCounter=0
    private var stopping=false, stopped=false
    private var timer: DispatchSourceTimer?
    private var errorMessage="binding-unavailable"
    private var statusValue=JSON.object([("bound",.bool(false)),("frozen",.bool(false)),("status",.string("binding-unavailable")),("pending",.bool(false)),("pending_operation",.null),("pending_sequence",.null)])
    init(sys: LiveSys) {
        self.sys=sys
        let timer=DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now(),repeating:.milliseconds(25),leeway:.milliseconds(2))
        timer.setEventHandler { [weak self] in self?.poll() }; timer.resume(); self.timer=timer
    }
    deinit { timer?.cancel() }
    var active: Bool {
        // The scalar comes from the native controller hook, independently of
        // the hidden-body service. Freeze at entry before any socket/binding IO.
        let native=OverviewNativeMode.active(hs_overview10_mode())
        lock.lock();defer { lock.unlock() }; return native || activityFence.active(raw:0,time:sys.now()) || ordinarySceneBusy()
    }
    func updateHiddenWindowsEnabled(_ enabled:Bool) {
        lock.lock();hiddenWindowsEnabled=enabled
        if enabled {emptyAcknowledgmentScope=false}
        lock.unlock()
    }
    var canAcknowledgeEmpty:Bool {lock.lock();defer{lock.unlock()};return emptyAcknowledgmentScope}
    func update(_ records: [OverviewHidden]) { lock.lock();desired=records;if !records.isEmpty {emptyAcknowledgmentScope=false};lock.unlock() }
    func updateHiddenIntents(_ values:Set<String>?) {lock.lock();hiddenIntents=values;hiddenIntentsAt=sys.now();lock.unlock()}
    var grantedWindowIDs:Set<Int> {lock.lock();defer{lock.unlock()};return grantedIDs}
    var entryBinding:OverviewBinding? {lock.lock();defer{lock.unlock()};return cachedEntryBinding}
    var entryRecords:[OverviewHidden] {lock.lock();defer{lock.unlock()};return cachedEntryRecords}
    private func configurePayload(_ candidate:OverviewBinding,_ records:[OverviewHidden]) throws -> JSON {
        let pid=Int(getpid())
        guard let birth=sys.processBirth(pid)?.split(separator:":").compactMap({Int($0)}),birth.count==3,birth[0]==pid else {throw CmdError("overview11: daemon birth unavailable")}
        var rows=records.map(\.json)
        if candidate.supportsOrdinaryPreentry {
            let screen=CGDisplayBounds(CGMainDisplayID()),display=Rect(screen.origin.x,screen.origin.y,screen.size.width,screen.size.height)
            rows=try records.map{source in
                guard let frame=source.ordinaryVisibleBounds(display:display) else{throw CmdError("overview13: ordinary visible frame unavailable")}
                return source.json.setting("visible_bounds",frame.json)
            }
        }
        var payload=JSON.object([("nonce",.string(candidate.nonce)),("dock_birth",candidate.generation),("windows",.array(rows))])
        if candidate.supportsEntryBarrier {payload=payload.setting("daemon_birth",.array([.int(pid),.int(Int(getuid())),.int(birth[1]),.int(birth[2])]))}
        if candidate.supportsOrdinaryPreentry {payload=payload.setting("ordinary_pre_entry",.bool(true))}
        return payload
    }
    func takeSelections() -> [OverviewSelection] { lock.lock();defer { lock.unlock() }; let value=selections;selections=[];return value }
    var status: JSON {
        lock.lock();defer { lock.unlock() }
        let transition=sys.overviewTransitionActive()
        return statusValue.setting("ordinary_scene",ordinarySceneStatus())
            .setting("public_transition",.bool(transition))
            .setting("frozen",.bool(statusValue["frozen"]?.truthy == true || transition))
    }
    /// Releases the existing native overview authority before the daemon reveals
    /// hidden sources. Pending replies are recovered by sequence rather than replayed.
    func prepareShutdown(_ completion:@escaping(Bool)->Void) {
        queue.async { [weak self] in
            guard let self else { DispatchQueue.main.async { completion(false) };return }
            func finish(_ result:Bool) { DispatchQueue.main.async { completion(result) } }
            if self.stopped { finish(true);return }
            self.stopping=true
            guard self.pending == nil, !self.active, !self.ordinarySceneBusy(), hs_overview10_mode() == 0 else { finish(false);return }
            do {
                if self.binding == nil {
                    guard !FileManager.default.fileExists(atPath:"/tmp/hyprwm.overview10.runtime.json") else { finish(false);return }
                    self.stopped=true;finish(true);return
                }
                let reply=try self.exchange("disable")
                guard OverviewProtocol.succeeded(reply,operation:"disable"),
                      reply["result"]?["original_dispatch_restored"] == .bool(true),
                      reply["result"]?["snapshot"]?["enabled"] == .bool(false) else { finish(false);return }
                self.configuredPool.reset();self.configured=""
                self.stopped=true;self.timer?.cancel();finish(true)
            } catch { finish(false) }
        }
    }
    func cancelShutdown() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopping=false;self.configured=""
            if self.stopped {
                self.stopped=false
                let timer=DispatchSource.makeTimerSource(queue:self.queue)
                timer.schedule(deadline:.now(),repeating:.milliseconds(25),leeway:.milliseconds(2))
                timer.setEventHandler { [weak self] in self?.poll() };timer.resume();self.timer=timer
            }
        }
    }
    private func readBinding() throws -> OverviewBinding {
        let path="/tmp/hyprwm.overview10.runtime.json"
        var before=stat(), after=stat()
        guard lstat(path,&before) == 0, before.st_mode&S_IFMT == S_IFREG, before.st_mode&0o777 == 0o600,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_size > 0, before.st_size <= 8192 else { throw CmdError("overview10: private Root binding unavailable") }
        let data=try Data(contentsOf:URL(fileURLWithPath:path))
        guard lstat(path,&after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_size == after.st_size else { throw CmdError("overview10: binding changed while reading") }
        let candidate=try OverviewBinding(JSON.parse(data))
        try fresh(candidate); return candidate
    }
    private func fresh(_ binding: OverviewBinding) throws {
        guard sys.processBirth(binding.pid) == binding.processBirth,
              NSRunningApplication(processIdentifier:pid_t(binding.pid))?.executableURL?.resolvingSymlinksInPath().path == binding.path,
              sys.processBirth(binding.pid) == binding.processBirth else { throw CmdError("overview10: Dock incarnation changed") }
    }
    private func socketIdentity(_ binding: OverviewBinding) throws -> [UInt64] {
        let directory=URL(fileURLWithPath:binding.endpoint).deletingLastPathComponent().path
        var parent=stat(), socket=stat()
        guard let canonical=directory.withCString({realpath($0,nil)}) else{throw CmdError("overview10: private endpoint parent unavailable")}
        defer{free(canonical)}
        guard String(cString:canonical)==directory,
              lstat(directory,&parent) == 0, parent.st_mode&S_IFMT == S_IFDIR, parent.st_mode&0o777 == 0o700,
              parent.st_uid == getuid(), lstat(binding.endpoint,&socket) == 0,
              socket.st_mode&S_IFMT == S_IFSOCK, socket.st_mode&0o777 == 0o600, socket.st_uid == getuid() else { throw CmdError("overview10: private endpoint identity unavailable") }
        return [UInt64(parent.st_dev),UInt64(parent.st_ino),UInt64(socket.st_dev),UInt64(socket.st_ino)]
    }
    private func exchange(_ operation: String, payload: JSON = .object([]), result: (Int,String)? = nil) throws -> JSON {
        lock.lock();emptyAcknowledgmentScope=false;lock.unlock()
        guard let binding else { throw CmdError("overview10: binding absent") }
        try fresh(binding); let identity=try socketIdentity(binding)
        sequence+=1
        let wire=try binding.request(operation,sequence:sequence,payload:payload)
        let fd=socket(AF_UNIX,SOCK_STREAM,0);guard fd >= 0 else { throw CmdError("overview10: socket failed") };defer { close(fd) }
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
        let bytes=Array(binding.endpoint.utf8)
        withUnsafeMutableBytes(of:&address.sun_path) { $0.copyBytes(from:bytes);$0[bytes.count]=0 }
        var timeout=timeval(tv_sec:1,tv_usec:0), one:Int32=1
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout<Int32>.size))
        let connected=withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { throw CmdError("overview10: connection failed") }
        var uid:uid_t=0,gid:gid_t=0,pid:pid_t=0,size=socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd,&uid,&gid) == 0, uid == getuid(), getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&pid,&size) == 0,
              pid == binding.pid, try socketIdentity(binding) == identity else { throw CmdError("overview10: socket peer changed") }
        try fresh(binding)
        if ["configure","renew","ack-selection","disable"].contains(operation) { pending=(sequence,operation) }
        let output=Array((wire.dumps()+"\n").utf8);var sent=0
        while sent < output.count {
            let count=output.withUnsafeBufferPointer { write(fd,$0.baseAddress!.advanced(by:sent),output.count-sent) }
            guard count > 0 else { throw CmdError("overview10: write incomplete; completion unknown") };sent+=count
        }
        var input: [UInt8]=[],buffer=[UInt8](repeating:0,count:16384)
        while input.count <= 262144 {
            let count=read(fd,&buffer,buffer.count);guard count > 0 else { throw CmdError("overview10: response incomplete; completion unknown") }
            input.append(contentsOf:buffer.prefix(count));if input.contains(10) { break }
        }
        guard input.count <= 262145, input.last == 10, input.filter({$0 == 10}).count == 1 else { throw CmdError("overview10: bounded single JSON response required") }
        try fresh(binding);guard try socketIdentity(binding) == identity else { throw CmdError("overview10: endpoint changed during exchange") }
        let reply=try JSON.parse(Array(input.dropLast()))
        let value=try binding.response(reply,sequence:result?.0 ?? sequence,operation:result?.1 ?? operation)
        if operation != "result", value["completed"] == .bool(true), pending?.sequence == sequence { pending=nil }
        return value
    }
    private func poll() {
        if stopped { return }
        let raw=hs_overview10_mode(),nativeActive=OverviewNativeMode.active(raw)
        // Raw mode is independent; do not overwrite authenticated controller
        // authority during the 150ms gaps between native socket snapshots.
        defer {
            lock.lock();emptyAcknowledgmentScope=configuredPool.canAcknowledgeEmpty(hiddenWindowsEnabled:hiddenWindowsEnabled,attested:attested,pending:pending != nil,configured:!configured.isEmpty,desired:desired);cachedEntryBinding=attested ? binding:nil;cachedEntryRecords=attested ? configuredPool.records:[];grantedIDs=Set(configuredPool.records.map{$0.wid});statusValue = .object([("bound",.bool(binding != nil)),("frozen",.bool(activityFence.active(raw:raw,time:sys.now()) || ordinarySceneBusy())),("status",.string(errorMessage)),("pending",.bool(pending != nil)),("pending_operation",pending.map{.string($0.operation)} ?? .null),("pending_sequence",pending.map{.int($0.sequence)} ?? .null),("hidden_windows_enabled",.bool(hiddenWindowsEnabled)),("empty_pool_acknowledgment",.bool(emptyAcknowledgmentScope)),("desired_count",.int(desired.count)),("configured_count",.int(configuredPool.records.count))]);lock.unlock()
        }
        do {
            let candidate=try readBinding()
            if binding != candidate { binding=candidate;attested=false;configured="";pending=nil;pendingSelection=nil;pendingSignature=nil;configuredPool.reset();snapshotCounter=0;lock.lock();activityFence.reset();lock.unlock() }
            if !attested {
                let reply=try exchange("hello")
                sequence=max(sequence,max(reply["service_info"]?["latest_request_seq"]?.int ?? 0,reply["service_info"]?["latest_mutation_seq"]?.int ?? 0));attested=true
            }
            lock.lock();let records=desired;lock.unlock()
            if let operation=pending {
                let reply=try exchange("result",payload:.object([("request_seq",.int(operation.sequence))]),result:(operation.sequence,operation.operation))
                if OverviewProtocol.canceledBeforeMain(reply,binding:candidate,sequence:operation.sequence,operation:operation.operation) {
                    pending=nil;pendingSelection=nil;pendingSignature=nil;configuredPool.pendingRecords=nil
                    lock.lock();errorMessage="native-request-canceled-before-main";lock.unlock()
                    return // Next poll allocates a fresh sequence; cancellation is not a native success ACK.
                }
                guard reply["completed"] == .bool(true) else { return }
                guard OverviewProtocol.succeeded(reply,operation:operation.operation) else {pending=nil;pendingSelection=nil;pendingSignature=nil;configuredPool.pendingRecords=nil;throw CmdError("overview10: recovered native request refused") }
                if operation.operation == "configure",let signature=pendingSignature {
                    try configuredPool.confirm(reply);configured=signature;lastRenew=sys.now()
                }
                if operation.operation == "renew" {lastRenew=sys.now()}
                if operation.operation == "disable" {configuredPool.reset();configured=""}
                if operation.operation == "ack-selection", let selection=pendingSelection { publish(selection) }
                pending=nil;pendingSelection=nil;pendingSignature=nil;configuredPool.pendingRecords=nil
            }
            guard nativeActive || sys.now()-lastRead >= 0.15 else { return }
            lastRead=sys.now()
            let reply=try exchange("snapshot")
            guard reply["completed"] == .bool(true) else { pending=(sequence,"snapshot");return }
            guard OverviewProtocol.succeeded(reply,operation:"snapshot"), let snapshot=reply["result"]?["snapshot"] else { throw CmdError("overview10: native snapshot refused") }
            if OverviewProtocol.requiresEmptyBootstrap(reply,hasConfiguredScope:!configured.isEmpty || !configuredPool.records.isEmpty,
                rawMode:hs_overview10_mode(),locked:sys.sessionLocked(),pending:pending != nil) {
                let payload=try configurePayload(candidate,[])
                let signature=payload.dumps()
                pendingSignature=signature;configuredPool.pendingRecords=[]
                let bootstrap=try exchange("configure",payload:payload)
                guard bootstrap["completed"] == .bool(true) else {pending=(sequence,"configure");return}
                guard OverviewProtocol.succeeded(bootstrap,operation:"configure") else {
                    pendingSignature=nil;configuredPool.pendingRecords=nil;throw CmdError("overview10: empty inactive bootstrap refused")
                }
                try configuredPool.confirm(bootstrap)
                configured=signature;pendingSignature=nil;lastRenew=sys.now();return
            }
            let wall=Int(Date().timeIntervalSince1970*1_000_000)
            guard case let .int(stamp)?=snapshot["sampled_wall_us"], abs(Double(stamp)-Double(wall)) <= 2_000_000,
                  case let .int(counter)?=snapshot["snapshot_counter"], counter > snapshotCounter else { throw CmdError("overview10: stale retained snapshot refused") }
            snapshotCounter=counter
            let selected=ordinarySceneBusy() ? [] : try OverviewProtocol.selections(snapshot:snapshot,binding:candidate,hidden:configuredPool.records)
            for selection in selected {
                pendingSelection=selection
                let acknowledged=try exchange("ack-selection",payload:selection.acknowledge)
                guard acknowledged["completed"] == .bool(true) else { pending=(sequence,"ack-selection");return }
                guard OverviewProtocol.succeeded(acknowledged,operation:"ack-selection") else { pendingSelection=nil;throw CmdError("overview10: exact selection ACK refused") }
                publish(selection);pendingSelection=nil
            }
            let observed=snapshot["controller_observed"] == .bool(true)
            lock.lock();activityFence.observe(snapshot,time:sys.now())
            let active=activityFence.active(raw:raw,time:sys.now()) || ordinarySceneBusy()
            errorMessage=observed ? "ready" : "controller-not-observed";lock.unlock()
            if stopping { return }
            if active,!configuredPool.records.isEmpty,sys.now()-lastRenew>=10 {
                let renewed=try exchange("renew")
                guard renewed["completed"] == .bool(true) else {pending=(sequence,"renew");return}
                guard OverviewProtocol.succeeded(renewed,operation:"renew") else {throw CmdError("overview10: active exact pool renewal refused")}
                lastRenew=sys.now()
            }
            // Consume persistent commits before replacing a pool. An unknown controller may
            // arm verified parked sources but never authorizes a selected-window restore.
            lock.lock();let inventory=sys.now()-hiddenIntentsAt<=0.3 ? hiddenIntents:nil;lock.unlock()
            let retire = !sys.sessionLocked() && OverviewRetirement.permitted(snapshot,nonce:candidate.nonce,liveIntents:inventory)
            if !active && selected.isEmpty && (!OverviewProtocol.hasCurrentPoolCommits(snapshot) || retire) {
                // Native configure only replaces inactive observation metadata.
                // Withdraw the old generation without fabricating a selection ACK.
                let configuredRecords=retire ? []:records
                let payload=try configurePayload(candidate,configuredRecords)
                let signature=payload.dumps()
                if signature != configured {
                    pendingSignature=signature;configuredPool.pendingRecords=configuredRecords
                    let configuredReply=try exchange("configure",payload:payload)
                    guard configuredReply["completed"] == .bool(true) else { pending=(sequence,"configure");return }
                    guard OverviewProtocol.succeeded(configuredReply,operation:"configure") else {pendingSignature=nil;configuredPool.pendingRecords=nil;throw CmdError("overview10: native configure refused") }
                    try configuredPool.confirm(configuredReply)
                    configured=signature;pendingSignature=nil;lastRenew=sys.now()
                } else if sys.now()-lastRenew >= 10 {
                    let renewed=try exchange("renew")
                    guard renewed["completed"] == .bool(true) else { pending=(sequence,"renew");return }
                    guard OverviewProtocol.succeeded(renewed,operation:"renew") else { throw CmdError("overview10: verified pool renewal refused") };lastRenew=sys.now()
                }
            }
        } catch {
            lock.lock();errorMessage=String(describing:error);lock.unlock()
        }
    }
    private func publish(_ selection: OverviewSelection) {
        lock.lock();if !selections.contains(selection) { selections.append(selection) };lock.unlock()
    }
}
