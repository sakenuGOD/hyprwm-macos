// Live system: SkyLight/CG/AX through C targets (hook/src/axlib.c, winsnap.m, and sys.c wrappers).
// Everything here accesses WindowServer and is not used in tests.
import AppKit
import CAX
import CSnap
import Foundation
import HyprCore

final class LiveSys: SysAPI {
    private let ruleMetadata=AXWindowMetadata()
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
    private var contextCache:[Int:(birth:String,time:Double,wid:Int?,flags:Int)]=[:]
    private var contextPending=Set<Int>()
    private var presenceCache:[Int:(pid:Int,birth:String,result:Int)]=[:]
    private var presencePending:[Int:UInt64]=[:]
    private var presenceSequence:UInt64=0
    private var focusSequence=0,focusWorkers=0
    private var floatRestackPending=false,floatRestackAt=0.0
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
    func windowPresence(_ pid:Int,_ wid:Int) -> Int {
        guard wid>0,wid<=Int(UInt32.max),let birth=processBirth(pid) else{return -1}
        focusLock.lock()
        if let cached=presenceCache[wid],cached.pid==pid,cached.birth==birth {focusLock.unlock();return cached.result}
        if presencePending[wid] != nil {focusLock.unlock();return -1}
        presenceSequence &+= 1;let sequence=presenceSequence;presencePending[wid]=sequence;focusLock.unlock()
        contextQueue.async{[weak self] in
            guard let self else{return}
            let result=self.processBirth(pid)==birth ? Int(hs_window_presence(Int32(pid),UInt32(wid))):-1
            let fresh=self.processBirth(pid)==birth
            self.focusLock.lock();defer{self.focusLock.unlock()}
            guard self.presencePending[wid]==sequence else{return}
            self.presencePending[wid]=nil
            if fresh {self.presenceCache[wid]=(pid,birth,result)}
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
                let sourcePrimary=context.wid.map{key in source.map{self.axTileable($0,key)==1} ?? false} ?? true
                let targetContext=source==request.pid ? context:self.nativeFocusContext(request.pid)
                guard request.targetAllows(targetContext) else {
                    try self.redirectTargetModal(request,context:targetContext,source:source,allowed:allowed)
                    return
                }
                guard self.axTileable(request.pid,request.wid)==1,allowed() else{return}
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
        guard ax_pointer_hit_available()==1 else{return nil}
        var value=ax_pointer_hit()
        guard ax_pointer_hit_read(&value)==1 else{return nil}
        let time=ax_launcher_now_ns(),point=mouse()
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
    func interactionOverlay() -> Bool {
        overviewGuard?() == true || OverviewNativeMode.active(hs_overview10_mode()) || ws_menu_tracking() != 0 || ws_input_overlay() != 0
    }
    func sessionLocked() -> Bool { hs_session_locked() != 0 }
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
        var p: Int32 = 0, lv: Int32 = 0
        if hs_win_pid_level(UInt32(wid), &p, &lv) != 0 { return (nil, nil) }
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

    func mouse() -> (Double, Double) {
        var x = 0.0, y = 0.0
        hs_mouse(&x, &y)
        return (x, y)
    }

    func mouseDown() -> Bool { hs_mouse_down() != 0 }

    func axTileable(_ pid: Int, _ wid: Int) -> Int { Int(ax_tileable(Int32(pid), UInt32(wid))) }
    func axFrame(_ pid: Int, _ wid: Int, _ r: Rect) -> Int { Int(ax_frame(Int32(pid), UInt32(wid), r.x, r.y, r.w, r.h)) }
    func axSize(_ pid:Int,_ wid:Int,_ width:Double,_ height:Double) -> Int {Int(ax_size(Int32(pid),UInt32(wid),width,height))}
    func axGetFrame(_ pid: Int, _ wid: Int) -> Rect? {
        var o = [Double](repeating: 0, count: 4)
        return ax_get_frame(Int32(pid), UInt32(wid), &o) == 0 ? Rect(o[0], o[1], o[2], o[3]) : nil
    }
    func axForget(_ wid: Int) { ax_forget(UInt32(wid)) }
    func axFocus(_ pid: Int, _ wid: Int, raise: Bool) -> Int {
        guard !interactionOverlay() else{return -1}
        return Int(ax_focus(Int32(pid),UInt32(wid),raise ? 1:0))
    }
    func axMenuPress(_ pid: Int, _ title: String) -> Int { Int(ax_menu_press(Int32(pid), title)) }

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
