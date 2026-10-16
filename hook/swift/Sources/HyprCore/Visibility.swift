import Foundation

struct RestoreRequest {
    let record: Hidden
    let space: Int
    let deadline: Double
    let everything: Bool
    var placement:RestorePlacement?
    var launcherSequence:UInt64?
}

extension WM {
    public func pruneDepartedHidden() {
        var removed=Set<Int>()
        hidden.removeAll {record in
            guard let pid=record.pid else{return false}
            let owner=sys.winPidLevel(record.wid).pid
            if let owner,owner != pid {removed.insert(record.wid);return true}
            var expected=record.extra["swift_birth"]?.string
            if expected==nil,let g=OverviewBinding.integers(record.extra["generation"]),g.count==4,g[0]==pid {expected="\(pid):\(g[2]):\(g[3])"}
            let current=sys.processBirth(pid)
            let departed=sys.processExited(pid) || (expected != nil && current != nil && expected != current)
            guard departed else{return false} // Failed/unknown metadata is never proof of departure.
            removed.insert(record.wid);return true
        }
        guard !removed.isEmpty else{return}
        for wid in removed {restorePending[wid]=nil;restoreChecks[wid]=nil;restoring.remove(wid)}
        save()
    }
    public func shutdownWitnesses() -> [(Int,Int,String)] {
        hidden.compactMap { record in
            guard hiddenRecordLive(record), let pid=record.pid, let birth=sys.processBirth(pid) else { return nil }
            return (record.wid,pid,birth)
        }
    }
    public var shutdownDrained:Bool {
        !enabled && !engineRecoveryActive && pauseLandingWitnesses.isEmpty && hidden.isEmpty && restorePending.isEmpty && restoring.isEmpty && cfgQ.isEmpty &&
            cfgSink?.idle != false && !sys.closeBusy && !sys.focusBusy && !sys.transferFocusBusy && workspaceBusy?() != true && !eng.c.pending && eng.c.stats.holding == 0
    }
    func restoreHidden(_ area: Rect, _ destination: Int?, _ windows: [WinInfo]?, everything: Bool, which: HiddenPick?) -> String {
        guard !hidden.isEmpty else { return "no hidden windows" }
        let todo: [Hidden]
        switch which {
        case let .filter(f)?: todo=hidden.filter(f)
        case let .wids(ids)?: todo=hidden.filter { ids.contains($0.wid) }
        case nil: todo=everything ? hidden : Array(hidden.filter { $0.extra["scratch"]?.truthy != true && hiddenRecordLive($0) }.suffix(1))
        }
        let c=eng.c
        var restored: [Int]=[], requested: [Int]=[]
        for record in todo {
            if everything,restorePending[record.wid] != nil {cfgSink?.cancel(record.wid);restorePending[record.wid]=nil}
            guard hiddenRecordLive(record), restorePending[record.wid] == nil else { continue }
            let wid=record.wid, window=windows?.first { $0.wid == wid && $0.pid == record.pid }
            let source=window.map { $0.space > 0 ? $0.space : record.space } ?? record.space
            if !everything, let destination, source != destination {
                // Alpha and server Space command are one publication. Keep the hide record until a fresh native ACK.
                c.alpha(wid,0,16,0,frm:0)
                c.space(wid,destination)
                restorePending[wid]=RestoreRequest(record:record,space:destination,deadline:sys.now()+2,everything:everything)
                requested.append(wid); continue
            }
            let tiled=record.extra["tiled"]?.truthy ?? (window.map(tileable) ?? true)
            if !everything,tiled,let destination,let window,
               let placement=stageRestorePlacement(record,window,area,destination) {
                restorePending[wid]=RestoreRequest(record:record,space:destination,deadline:sys.now()+2,everything:false,placement:placement)
                requested.append(wid);continue
            }
            hidden.removeAll { $0.wid == wid }
            if !everything { c.alpha(wid,0,16,0,frm:0) }
            if let frame=Rect(record.rect) {
                c.geom(wid,frame,16,16,move:true,warp:true)
                restoreFrom[wid]=frame
            }
            let wasTiled=record.extra["tiled"]?.truthy ?? (window.map(tileable) ?? true)
            let goal=windowOpacity(window ?? WinInfo(wid:wid,pid:record.pid ?? 0,owner:record.owner,x:0,y:0,w:0,h:0,on:true,space:destination ?? record.space ?? 0),destination)
            if everything { c.alpha(wid,goal,16,0) }
            else if !wasTiled {
                floating.insert(wid)
                let fade=eng.anim("fadeIn"); c.alpha(wid,goal,fade.on ? fade.curve : 16,fade.on ? fade.dur : 0,frm:0)
            } else {
                restoring.insert(wid); target[wid]=nil; restoreChecks[wid]=record
                later.append((sys.now()+1.5,{ [unowned self] in self.restoreCheck(wid) }))
            }
            restored.append(wid)
        }
        if !restored.isEmpty || !requested.isEmpty { c.commit(); save() }
        if !requested.isEmpty { return "waiting for transfer \(pyList(requested)); restored \(pyList(restored))" }
        return "restored \(pyList(restored))"
    }

    func completeRestores(_ area: Rect, _ space: Int, _ windows: [WinInfo]) {
        for (wid,var request) in restorePending {
            if let sequence=request.launcherSequence,
               launcherIntent?.sequence != sequence || sys.frontPid() != request.record.pid {
                if launcherIntent?.sequence==sequence {consumeLauncher("local-restore-superseded")}
                cancelRestorePlacement(request);restorePending[wid]=nil;continue
            }
            guard request.space == space, sys.now() < request.deadline,
                  hidden.contains(where: { $0.wid == wid }), hiddenRecordLive(request.record) else {
                if let sequence=request.launcherSequence,launcherIntent?.sequence==sequence {consumeLauncher("local-restore-cancelled")}
                cancelRestorePlacement(request);restorePending[wid]=nil;continue
            }
            if request.launcherSequence != nil,let pid=request.record.pid {
                guard !sys.sessionLocked(),!sys.interactionOverlay() else{continue}
                let context=sys.focusContext(pid)
                guard context.flags&(NativeFocusFlags.positive|NativeFocusFlags.unknown)==0 else{continue}
                guard context.wid==wid else {
                    if launcherIntent?.sequence==request.launcherSequence {consumeLauncher("local-restore-superseded")}
                    cancelRestorePlacement(request);restorePending[wid]=nil;continue
                }
            }
            guard let window=windows.first(where: { $0.wid == wid && $0.pid == request.record.pid && $0.space == space && $0.layer==0 && !$0.nativeFullscreen }) else { continue }
            if request.placement != nil {
                if !finishRestorePlacement(&request,window,area,windows) {restorePending[wid]=request}
                continue
            }
            restorePending[wid]=nil
            _=restoreHidden(area,space,[window],everything:request.everything,which:.wids([wid]))
        }
    }

    /// Parking follows the fade's actual completion, not a guessed duration or stale command ACK.
    func parkHidden(_ wid: Int, _ frame: Rect, deadline: Double) {
        guard let record=hidden.first(where: { $0.wid == wid }), restorePending[wid] == nil,
              enabled, sys.now() < deadline, hiddenRecordLive(record) else { return }
        let window=eng.c.wins().first { $0.wid == wid }
        let alpha=window?.curAlpha ?? sys.winAlpha(wid)
        if eng.c.pending || window?.alphaActive == true || window?.held == true || alpha == nil || alpha! > 0.001 {
            later.append((sys.now()+0.016,{ [unowned self] in self.parkHidden(wid,frame,deadline:deadline) })); return
        }
        // A new native geometry publication invalidates earlier parking samples.
        hiddenParkSamples[wid]=nil
        eng.c.geom(wid,frame,16,16,move:true,warp:true); eng.c.commit()
        later.append((sys.now()+0.016,{[unowned self] in self.releaseHiddenGeometry(wid,frame:frame,deadline:deadline)}))
    }
    /// AppKit may clamp an offscreen park. Exact alpha0 hides it; release
    /// ownership only after two bounded stable actual native frames.
    func hiddenParkSettled(_ record:Hidden,_ bounds:Rect) -> Bool {
        guard hiddenRecordLive(record),restorePending[record.wid]==nil,
              let pid=record.pid,let birth=sys.processBirth(pid),
              let intent=try? record.intentFingerprint(),
              bounds.arr.allSatisfy({$0.isFinite}),bounds.w>0,bounds.h>0,bounds.w<=32768,bounds.h<=32768,abs(bounds.x)<=1_048_576,abs(bounds.y)<=1_048_576,
              cfgSink?.busy(record.wid) != true,
              (sys.winAlpha(record.wid) ?? 1)<=0.001 else {hiddenParkSamples[record.wid]=nil;return false}
        let now=sys.now()
        if let previous=hiddenParkSamples[record.wid],previous.birth==birth,previous.intent==intent,
           bounds.maxDiff(previous.frame)<=TOL,now>=previous.time,now-previous.time<=0.5,
           previous.accepted || now-previous.time>=0.008 {
            hiddenParkSamples[record.wid]=(birth,intent,bounds,now,true);return true
        }
        if let previous=hiddenParkSamples[record.wid],previous.birth==birth,previous.intent==intent,
           bounds.maxDiff(previous.frame)<=TOL,now-previous.time<0.008 {return false}
        hiddenParkSamples[record.wid]=(birth,intent,bounds,now,false);return false
    }
    func releaseHiddenGeometry(_ wid:Int,frame:Rect,deadline:Double) {
        guard enabled,sys.now()<deadline,restorePending[wid]==nil,
              let record=hidden.first(where:{$0.wid==wid}),hiddenRecordLive(record) else{return}
        cfgSink?.cancel(wid)
        let slot=eng.c.wins().first{$0.wid==wid}
        if cfgSink?.busy(wid) == true || eng.c.pending || slot?.posActive == true || slot?.sizeActive == true || slot?.alphaActive == true || slot?.held == true ||
            (sys.winAlpha(wid) ?? 1)>0.001 || (sys.winBounds(wid).map({!hiddenParkSettled(record,$0)}) ?? true) {
            later.append((sys.now()+0.016,{[unowned self] in self.releaseHiddenGeometry(wid,frame:frame,deadline:deadline)}));return
        }
        guard slot?.geo != 0 else{return}
        // Same native publication: clear transform/clip ownership while safely
        // parked, then recreate only the alpha0 idle slot. Never forget alone.
        hiddenParkSamples[wid]=nil
        eng.c.forget(wid);eng.c.alpha(wid,0,16,0,frm:0);eng.c.commit()
    }

    func windowOpacity(_ window: WinInfo, _ space: Int? = nil) -> Double {
        let decoration=cfg.raw["config"]?["decoration"] ?? .object([])
        let policy=windowPolicy(window)
        if window.nativeFullscreen || sp(space ?? window.space).full == window.wid { return policy.fullscreen.apply(decoration["fullscreen_opacity"]?.double ?? 1) }
        let active=sp(space ?? window.space).focus == window.wid
        return (active ? policy.active : policy.inactive).apply(decoration[active ? "active_opacity" : "inactive_opacity"]?.double ?? 1)
    }

    func refreshWindowOpacity(_ space: Int, _ windows: [WinInfo]) {
        let hiddenIDs=Set(hidden.map(\.wid)), busy=closing.union(restoring).union(newbies.keys).union(optimistic.keys)
        let slots=Dictionary(eng.c.wins().map { ($0.wid,$0) },uniquingKeysWith: { first,_ in first })
        let fade=eng.anim("fadeSwitch")
        var posted=false
        for window in windows where window.space == space && window.on && window.layer == 0 && !window.nativeFullscreen &&
            !hiddenIDs.contains(window.wid) && !busy.contains(window.wid) && !nativeSuspendedWindows.contains(window.wid) && !sys.protectedProcess(window.pid) && !ignored(window) {
            guard let slot=slots[window.wid], !slot.alphaActive, !slot.held else { continue }
            let goal=windowOpacity(window,space)
            if abs(goal-slot.curAlpha) > 0.001 { eng.c.alpha(window.wid,goal,fade.on && !windowPolicy(window).noAnimation ? fade.curve : 16,fade.on && !windowPolicy(window).noAnimation ? fade.dur : 0); posted=true }
        }
        eng.c.decorationFocus(sp(space).focus ?? 0,fullscreen:sp(space).fullmode == "fullscreen" ? sp(space).full ?? 0 : 0)
        if posted { eng.c.commit() }
    }
}
