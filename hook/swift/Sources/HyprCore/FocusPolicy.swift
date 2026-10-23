import Foundation

struct CloseFocusRetry {
    let space:Int,deadline:Double,previous:Rect?
    var fresh=0,queued=false,retryAt=0.0
}
extension WM {
    func primaryCommandWindow(_ window:WinInfo,space:Int) -> Bool {
        guard space>0,sys.activeSpace()==UInt64(space),!sys.sessionLocked(),!sys.interactionOverlay(),
              window.on,window.space==space,window.layer==0,window.alpha>=0.05,!window.nativeFullscreen,
              !hidden.contains(where:{$0.wid==window.wid}),!closing.contains(window.wid),
              !sys.protectedProcess(window.pid),!ignored(window),let birth=sys.processBirth(window.pid),
              sys.winPidLevel(window.wid).pid==window.pid,sys.axTileable(window.pid,window.wid)==1 else{return false}
        if let prior=nativeFocusedIdentities[window.wid],prior.pid != window.pid || prior.birth != birth {return false}
        return sys.processBirth(window.pid)==birth && sys.winPidLevel(window.wid).pid==window.pid && sys.activeSpace()==UInt64(space)
    }
    func nativeCommandWindow(_ space:Int,_ windows:[WinInfo],_ rects:OrderedMap<Int,Rect>,requiresTile:Bool=true) -> WinInfo? {
        guard space>0,sys.activeSpace()==UInt64(space),!sys.sessionLocked(),!sys.interactionOverlay(),
              let pid=sys.frontPid(),let birth=sys.processBirth(pid) else{return nil}
        let context=sys.focusContext(pid)
        guard context.flags==0,let wid=context.wid,
              let window=windows.first(where:{$0.wid==wid && $0.pid==pid && $0.on && $0.space==space &&
                  $0.layer==0 && !$0.nativeFullscreen && (!requiresTile || rects.contains($0.wid))}),
              primaryCommandWindow(window,space:space) else{return nil}
        let fresh=sys.focusContext(pid)
        guard fresh.wid==wid,fresh.flags==0,sys.frontPid()==pid,sys.processBirth(pid)==birth,
              sys.winPidLevel(wid).pid==pid,sys.activeSpace()==UInt64(space) else{return nil}
        return window
    }
    func rememberNativeFocus(_ pid:Int?,_ windows:[WinInfo]) {
        guard let pid else{return}
        let context=sys.focusContext(pid)
        guard context.flags&(NativeFocusFlags.positive|NativeFocusFlags.unknown)==0,let wid=context.wid,
              let window=windows.first(where: { $0.wid == wid && $0.pid == pid && $0.on && $0.layer==0 && !$0.nativeFullscreen }),
              !hidden.contains(where:{$0.wid==wid}),!sys.protectedProcess(pid),
              let role=wmInfo(pid,wid),role.type=="primary",role.style&RESIZABLE != 0,
              let birth=sys.processBirth(pid),sys.winPidLevel(wid).pid==pid else { return }
        nativeFocusedIdentities[wid]=(pid,birth,window.space)
        if window.space>0,sys.activeSpace()==UInt64(window.space) {
            let selection=ToolbarWindowSelection(wid:wid,pid:pid,birth:birth,source:"native-focus-history")
            let state=sp(window.space)
            if state.toolbarSelection != selection {state.toolbarSelection=selection;save()}
        }
        focusHistory.removeAll { $0 == wid };focusHistory.append(wid)
        if focusHistory.count > 128 {
            focusHistory.removeFirst(focusHistory.count-128)
            let retained=Set(focusHistory);nativeFocusedIdentities=nativeFocusedIdentities.filter{retained.contains($0.key)}
        }
    }
    func retiredFocusedWindow(_ wid:Int,space:Int,windows:[WinInfo]) -> Bool {
        guard let prior=nativeFocusedIdentities[wid],prior.space==space,
              prior.pid==pids[wid],sys.frontPid()==prior.pid,sys.processBirth(prior.pid)==prior.birth,
              !hidden.contains(where:{$0.wid==wid}),!nativeConfirmed.contains(wid),
              let window=windows.first(where:{$0.wid==wid && $0.pid==prior.pid}),
              !window.on,window.layer==0,!window.nativeFullscreen,
              window.space==0 || window.space==space,
              sys.winPidLevel(wid).pid==prior.pid else{return false}
        let context=sys.focusContext(prior.pid)
        // WindowServer may retain an ordered-out object long after AppKit has
        // closed it. The former exact primary key and explicit NO_KEY are the
        // evidence; an offscreen window on another Space is never a close.
        return context.wid==nil && context.flags&NativeFocusFlags.noKey != 0 &&
            context.flags&(NativeFocusFlags.positive|NativeFocusFlags.unknown)==0
    }
    func focusAfterClose(_ area:Rect,_ space:Int,_ windows:[WinInfo],_ previous:Rect?) {
        guard !sys.sessionLocked(), !sys.interactionOverlay(), nativeSpaceType == 0,
              !nativeSuspendedSpaces.contains(String(space)),cfg.raw["config"]?["general"]?["no_focus_fallback"]?.truthy != true else { return }
        if closeFocusRetry==nil || closeFocusRetry?.space != space {
            closeFocusRetry=CloseFocusRetry(space:space,deadline:sys.now()+1.5,previous:previous)
        }
        if let pid=sys.frontPid(), sys.focusContext(pid).flags&(1|2|4|8|16) != 0 { return }
        let state=sp(space), rects=layout(area,state), hiddenIDs=Set(hidden.map(\.wid))
        let candidates=windows.filter {window in let covered=snapshotSourceCovered(window,space:space)
            return window.space==space && (window.on || covered) && rects.contains(window.wid) && !hiddenIDs.contains(window.wid) && closeRequests[window.wid]==nil && (covered || tileable(window))}
        guard !candidates.isEmpty else { state.focus=nil;closeFocusRetry=nil;return }
        let mode=cfg.raw["config"]?["input"]?["focus_on_close"]?.int ?? 0
        let point=sys.mouse()
        let under=candidates.first { w in let r=rects[w.wid]!;return point.0>=r.x && point.0<r.x+r.w && point.1>=r.y && point.1<r.y+r.h }
        let mru=focusHistory.reversed().compactMap { wid in candidates.first { $0.wid == wid } }.first
        let origin=previous ?? area, cx=origin.x+origin.w/2,cy=origin.y+origin.h/2
        func distance(_ window:WinInfo) -> Double {
            let r=rects[window.wid]!,dx=max(r.x-cx,0,cx-r.x-r.w),dy=max(r.y-cy,0,cy-r.y-r.h)
            return dx*dx+dy*dy
        }
        let nearest=candidates.min { distance($0)<distance($1) }!
        let chosen=mode == 1 ? under ?? nearest : mode == 2 ? mru ?? nearest : nearest
        guard sys.winPidLevel(chosen.wid).pid == chosen.pid, sys.processBirth(chosen.pid) != nil else { return }
        if var retry=closeFocusRetry {retry.queued=true;closeFocusRetry=retry}
        if !queueFocus(chosen,space:space,reason:.close),var retry=closeFocusRetry {retry.queued=false;closeFocusRetry=retry}
    }
    func pollCloseFocusRetry(_ snapshot:Snapshot) {
        guard var retry=closeFocusRetry else{return}
        guard enabled,snapshot.space==retry.space,sys.now()<retry.deadline,launcherIntent==nil else{closeFocusRetry=nil;return}
        retry.fresh+=1;closeFocusRetry=retry
        guard retry.fresh>=2,!retry.queued,sys.now()>=retry.retryAt,!sys.mouseDown(),
              snapshot.stable,!snapshot.locked,snapshot.spaceType==0,!sys.interactionOverlay(),!sys.sessionLocked() else{return}
        let context:(wid:Int?,flags:Int)=sys.frontPid().map(sys.focusContext) ?? (nil,NativeFocusFlags.noKey)
        guard context.flags&(NativeFocusFlags.positive|NativeFocusFlags.unknown)==0 else{return}
        if let key=context.wid,snapshot.windows.contains(where:{$0.wid==key && $0.on && $0.space==snapshot.space && $0.alpha>=0.05}) {
            closeFocusRetry=nil;return // A new native key already owns focus.
        }
        retry.retryAt=sys.now()+0.1;closeFocusRetry=retry
        focusAfterClose(snapshot.area,snapshot.space,snapshot.windows,retry.previous)
    }
    func releaseIgnored(_ windows:[WinInfo],_ state:SpaceState) {
        var changed=false
        for window in windows where ignored(window) && (state.tree?.contains(window.wid) == true || target[window.wid] != nil) {
            guard !sys.protectedProcess(window.pid), sys.winPidLevel(window.wid).pid == window.pid else { continue }
            cfgSink?.cancel(window.wid);target[window.wid]=nil;newbies[window.wid]=nil;optimistic[window.wid]=nil
            revokeSnapshotLease(window.wid)
            restoring.remove(window.wid);dimSince[window.wid]=nil
            eng.c.alpha(window.wid,1,16,0);eng.c.forget(window.wid);deco.drop(window.wid);changed=true
        }
        if changed { eng.c.commit() }
    }
}
