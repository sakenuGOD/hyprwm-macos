import Foundation

public struct LauncherTransferFocus {
    public let pid,wid,origin,source:Int
    public let birth:String
    public let sequence:UInt64
    public let deadline:Double
    public let catalog:PublicWorkspaceCatalog
    public init(pid:Int,wid:Int,birth:String,origin:Int,source:Int,sequence:UInt64,deadline:Double,catalog:PublicWorkspaceCatalog) {
        self.pid=pid;self.wid=wid;self.birth=birth;self.origin=origin;self.source=source;self.sequence=sequence;self.deadline=deadline;self.catalog=catalog
    }
    public func member(in snapshot:Snapshot) -> WinInfo? {
        guard snapshot.stable,!snapshot.locked,snapshot.spaceType==0,[source,origin].contains(snapshot.space) else{return nil}
        return snapshot.windows.first{$0.wid==wid && $0.pid==pid && $0.space==origin && $0.layer==0 && !$0.nativeFullscreen && $0.alpha>=0.05}
    }
}
struct LauncherTransfer {
    let request:LauncherTransferFocus,frame:Rect
    let wasHidden:Bool
    let nativeFrame:Rect?,originalAlpha:Double
    var arrival:LauncherArrival?
    var samples=0,lastSample=0,focusQueued=false,focusAccepted=false
    var revealQueued=false,revealSamples=0,lastRevealSample=0
}
extension WM {
    @discardableResult func beginLauncherTransfer(_ launcher:LauncherIntent,_ window:WinInfo,_ current:Int,_ frame:Rect,_ wasHidden:Bool) -> Bool {
        guard launcherTransfers.isEmpty,sys.frontPid()==window.pid,let birth=sys.processBirth(window.pid),
              sys.winPidLevel(window.wid).pid==window.pid,let catalog=sys.launcherCatalog(),catalog.active==current,
              (try? catalog.target(launcher.space)) != nil,(try? catalog.target(window.space)) != nil else{return false}
        let request=LauncherTransferFocus(pid:window.pid,wid:window.wid,birth:birth,origin:launcher.space,source:window.space,
            sequence:launcher.sequence,deadline:sys.now()+8,catalog:catalog)
        guard !floating.contains(window.wid),hidden.first(where:{$0.wid==window.wid})?.extra["tiled"] != .bool(false),
              tabFacts[window.wid].map({$0.members.count<=1}) ?? true else{return false}
        cfgSink?.cancel(window.wid);cancelFocusRecovery();revokeSnapshotLease(window.wid)
        let alpha=sys.winAlpha(window.wid) ?? window.alpha
        launcherTransfers[window.wid]=LauncherTransfer(request:request,frame:frame,wasHidden:wasHidden,
            nativeFrame:sys.winBounds(window.wid),originalAlpha:wasHidden ? 0:alpha)
        eng.c.alpha(window.wid,0,16,0,frm:alpha)
        if window.space != launcher.space {eng.c.space(window.wid,launcher.space)}
        eng.c.commit()
        return true
    }
    func cancelLauncherTransfers() {let pending=Array(launcherTransfers.values);launcherTransfers.removeAll();sys.cancelTransferFocus();for transfer in pending{cancelLauncherArrival(transfer)}}
    func pollLauncherTransfers(_ snapshot:Snapshot) {
        for (wid,var transfer) in launcherTransfers {
            let request=transfer.request
            guard sys.now()<request.deadline,launcherIntent?.sequence==request.sequence,
                  sys.processBirth(request.pid)==request.birth,sys.winPidLevel(wid).pid==request.pid else {
                if launcherIntent?.sequence==request.sequence {consumeLauncher()}
                cancelLauncherTransfers();continue
            }
            // Spotlight/AltTab/menu dismissal can briefly overlap activation.
            // Keep this bounded intent; never re-hide its actor merely because
            // the selecting overlay has not finished closing.
            if sys.interactionOverlay() {continue}
            guard !sys.sessionLocked(),sys.frontPid().map({$0==request.pid}) ?? true,
                  let catalog=sys.launcherCatalog(),catalog.sameSession(request.catalog),
                  [request.source,request.origin].contains(snapshot.space),catalog.active==snapshot.space else {
                if launcherIntent?.sequence==request.sequence {consumeLauncher()}
                cancelLauncherTransfers();continue
            }
            guard snapshot.stable,!snapshot.locked,snapshot.spaceType==0,
                  let window=snapshot.windows.first(where:{$0.wid==wid && $0.pid==request.pid && $0.space==request.origin && $0.layer==0 && !$0.nativeFullscreen}) else{continue}
            let context=sys.focusContext(request.pid)
            // Native modal/menu focus is not a new selected primary window.
            // Wait within the original deadline and leave its focus untouched.
            if context.flags&NativeFocusFlags.positive != 0 {continue}
            if context.wid != nil && context.wid != wid {
                consumeLauncher();cancelLauncherTransfers();continue
            }
            guard context.flags&NativeFocusFlags.unknown==0,
                  context.wid==wid || context.wid==nil && context.flags&NativeFocusFlags.noKey != 0 else {continue}
            if transfer.lastSample != workspaceSampleSequence {transfer.lastSample=workspaceSampleSequence;transfer.samples+=1}
            if transfer.samples>=2,transfer.arrival==nil {
                guard prepareLauncherArrival(window,&transfer,launcherAreas[request.origin] ?? snapshot.area) else {launcherTransfers[wid]=transfer;continue}
                launcherTransfers[wid]=transfer;continue
            }
            let placed=launcherArrivalAccepted(&transfer)
            if placed,!transfer.revealQueued {
                eng.c.alpha(wid,windowOpacity(window,request.origin),16,0);eng.c.commit()
                transfer.revealQueued=true;launcherTransfers[wid]=transfer;continue
            }
            var revealed=false
            if placed,transfer.revealQueued {
                let slot=eng.c.wins().first{$0.wid==wid}
                let consumed = !eng.c.pending && window.alpha>=0.05 &&
                    (sys.winAlpha(wid) ?? 0)>=0.05 && slot.map{!$0.alphaActive && $0.curAlpha>=0.05} == true
                if consumed {
                    if transfer.lastRevealSample != workspaceSampleSequence {transfer.lastRevealSample=workspaceSampleSequence;transfer.revealSamples+=1}
                    revealed=transfer.revealSamples>=2
                } else {transfer.revealSamples=0;transfer.lastRevealSample=0}
            }
            if transfer.samples>=2,revealed,!transfer.focusQueued,!transfer.focusAccepted {
                transfer.focusQueued=true;launcherTransfers[wid]=transfer
                sys.requestTransferFocus(request) {[weak self] accepted in
                    guard let self,var current=self.launcherTransfers[wid],current.request.sequence==request.sequence,current.request.birth==request.birth else{return}
                    current.focusQueued=false;current.focusAccepted=accepted;self.launcherTransfers[wid]=current
                }
                continue
            }
            if transfer.focusAccepted,snapshot.space==request.origin,catalog.active==request.origin,window.on,window.alpha>=0.05,context.wid==wid {
                guard placed,let arrival=transfer.arrival else{launcherTransfers[wid]=transfer;continue}
                let source=sp(request.source)
                if request.source != request.origin {source.tree=Dwindle.remove(source.tree,wid);if source.focus==wid{source.focus=nil};if source.full==wid{source.full=nil}}
                let destination=sp(request.origin);destination.tree=Node.from(arrival.tree);destination.focus=wid;destination.presel=arrival.presel
                hidden.removeAll{$0.wid==wid};restoring.remove(wid);restoreFrom[wid]=nil;restoreChecks[wid]=nil;restorePending[wid]=nil
                target[wid]=arrival.rect;newbies[wid]=nil;optimistic[wid]=nil
                cfgQ.removeAll{$0.wid==wid};launcherTransfers[wid]=nil;consumeLauncher();ownFocus=(request.pid,sys.now());save()
            } else {launcherTransfers[wid]=transfer}
        }
    }
}
