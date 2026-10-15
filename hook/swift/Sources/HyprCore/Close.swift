import Foundation

public struct CloseResult {
    public var code:Int
    public var lookupMS,buttonMS,pressMS:Double
    public init(code:Int,lookupMS:Double=0,buttonMS:Double=0,pressMS:Double=0) {
        self.code=code;self.lookupMS=lookupMS;self.buttonMS=buttonMS;self.pressMS=pressMS
    }
}
struct CloseRequest {
    let pid:Int,birth:String,started:Double
    let space:Int
    var pressed=false
}
struct CloseDeparture {
    let pid:Int,birth:String,space:Int
}
extension WM {
    func finishCloseDeparture(_ wid:Int) {
        closeDepartures[wid]=nil;closePresenceTransitions.remove(wid);sys.invalidateWindowPresence(wid)
    }
    func pruneCloseDepartures(_ windows:[WinInfo],_ space:Int) {
        for wid in closePresenceTransitions.union(closeDepartures.keys) {
            if let window=windows.first(where:{$0.wid==wid}),window.on || (window.space>0 && window.space != space) {finishCloseDeparture(wid)}
        }
    }
    func confirmedCloseDeparture(_ wid:Int,space:Int,windows:[WinInfo]) -> Bool {
        guard !hidden.contains(where:{$0.wid==wid}),!nativeConfirmed.contains(wid),
              let pid=pids[wid],let source=spaces[String(space)],source.tree?.contains(wid)==true else{return false}
        let window=windows.first{$0.wid==wid}
        guard window==nil || (window!.pid==pid && !window!.on && !window!.nativeFullscreen &&
            window!.layer==0 && (window!.space==0 || window!.space==space)) else{return false}
        let prior=nativeFocusedIdentities[wid],request=closeRequests[wid]
        if let prior,prior.pid != pid || prior.space != space {return false}
        if let request,request.pid != pid || request.space != space {return false}
        let birth=request?.birth ?? prior?.birth ?? sys.processBirth(pid)
        guard let birth else{return false}
        let exited=sys.processExited(pid)
        guard exited || sys.processBirth(pid)==birth else{return false}
        let owner=sys.winPidLevel(wid).pid
        guard owner==nil || owner==pid else{return false}
        if let known=closeDepartures[wid] {return known.pid==pid && known.birth==birth && known.space==space}
        if exited || (window==nil && owner==nil && goneT[wid] != nil) {
            closeDepartures[wid]=CloseDeparture(pid:pid,birth:birth,space:space);return true
        }
        let context=sys.focusContext(pid)
        guard context.flags&NativeFocusFlags.positive==0 else{return false}
        // Native unmap can precede the asynchronous AX press reply. A window
        // missing from this Space is sufficient for its exact close request;
        // transient Space-zero/fullscreen gaps still require stronger evidence.
        if request != nil && (window==nil || window?.space==space) {
            closeDepartures[wid]=CloseDeparture(pid:pid,birth:birth,space:space);return true
        }
        guard context.flags&NativeFocusFlags.unknown==0 else{return false}
        // An AX press ACK alone may mean Save opened. Require actual unmap too.
        if request?.pressed==true || retiredFocusedWindow(wid,space:space,windows:windows) {
            closeDepartures[wid]=CloseDeparture(pid:pid,birth:birth,space:space);return true
        }
        // Ambiguous native Cmd-W/tab/fullscreen transitions use one cached,
        // background public AXWindows read. Present/unknown never count as close.
        guard prior != nil || info[pid]?[wid]?.type=="primary" else{return false}
        closePresenceTransitions.insert(wid)
        guard sys.windowPresence(pid,wid)==0,sys.processBirth(pid)==birth else{return false}
        closeDepartures[wid]=CloseDeparture(pid:pid,birth:birth,space:space);return true
    }
    func requestClose(_ window:WinInfo) -> String {
        guard let birth=sys.processBirth(window.pid), closeRequests[window.wid] == nil, closeRequests.count < 16 else { return "close already pending or unavailable" }
        let start=sys.now(),wid=window.wid,pid=window.pid
        cfgSink?.cancel(wid)
        closeRequests[wid]=CloseRequest(pid:pid,birth:birth,started:start,space:window.space)
        closeMetrics = .object([("wid",.int(wid)),("pid",.int(pid)),("started",.double(start))])
        sys.requestClose(pid,wid,birth:birth) { [weak self] result in
            guard let self, self.sys.processBirth(pid) == birth else { return }
            if self.closeMetrics["wid"] == .int(wid), self.closeMetrics["started"] == .double(start) {
                self.closeMetrics = self.closeMetrics.setting("result",.int(result.code)).setting("request_ms",.double((self.sys.now()-start)*1000)).setting("lookup_ms",.double(result.lookupMS)).setting("button_ms",.double(result.buttonMS)).setting("press_ms",.double(result.pressMS))
            }
            guard let request=self.closeRequests[wid], request.birth == birth, request.started == start else { return }
            if result.code != 0 { self.closeRequests[wid]=nil }
            else { self.closeRequests[wid]?.pressed=true }
            self.lastSnap=0
        }
        return "запрошено закрытие \(wid) (queued)"
    }
    func observeCloseRequests(_ windows:[WinInfo],_ space:Int) {
        for (wid,request) in closeRequests {
            let window=windows.first { $0.wid == wid && $0.pid == request.pid }
            if sys.processBirth(request.pid) != request.birth || sys.now()-request.started > 2 { closeRequests[wid]=nil;continue }
            let context=sys.focusContext(request.pid)
            if context.flags&NativeFocusFlags.positive != 0 {
                if closeMetrics["wid"] == .int(wid) { closeMetrics=closeMetrics.setting("native_departure",.bool(false)).setting("deferred_to_dialog",.bool(true)) }
                closeRequests[wid]=nil
            } else if confirmedCloseDeparture(wid,space:space,windows:windows) {
                if closeMetrics["wid"] == .int(wid) { closeMetrics=closeMetrics.setting("unmap_ms",.double((sys.now()-request.started)*1000)).setting("native_departure",.bool(true)) }
                closeRequests[wid]=nil
            } else if request.pressed,context.flags&NativeFocusFlags.noKey != 0 {
                focusAfterClose(last?.area ?? window?.rect ?? Rect(0,0,1,1),space,windows,window?.rect)
            }
        }
    }
}
