import Foundation

struct SilentSpaceMove {
    let pid:Int,birth:String,source:Int,destination:Int,catalog:PublicWorkspaceCatalog,deadline:Double
    var samples=0,lastSample=0
}
extension WM {
    func sendWindowToSpace(_ args:[String],_ current:Int) throws -> String {
        guard (2...3).contains(args.count),let destination=Int(args[1]),destination>0,destination<1<<53 else {throw CmdError("sendws <existing SID> [wid]")}
        guard silentSpaceMoves.isEmpty,launcherTransfers.isEmpty,!sys.interactionOverlay(),!sys.sessionLocked(),!sys.mouseDown() else{return "sendws refused: native interaction is active"}
        let snapshot=try sys.snapshot()
        guard snapshot.stable,!snapshot.locked,snapshot.spaceType==0,snapshot.space==current,
              let catalog=sys.launcherCatalog(),catalog.active==current,(try? catalog.target(destination)) != nil else{return "sendws refused: fresh ordinary catalog required"}
        let requested=args.count==3 ? try CommandArguments.windowID(args[2]):nil
        let window=requested.flatMap{wid in snapshot.windows.first{$0.wid==wid}} ?? (requested==nil ? front(snapshot.windows,current):nil)
        guard let window,window.space==current,window.on,window.alpha>=0.05,window.layer==0,!window.nativeFullscreen,
              !hidden.contains(where:{$0.wid==window.wid}),!ignored(window),tileable(window),!sys.protectedProcess(window.pid),
              sys.processUID(window.pid)==Int(getuid()),let birth=sys.processBirth(window.pid),sys.winPidLevel(window.wid).pid==window.pid else{return "sendws refused: exact visible application window required"}
        guard destination != current else{return "sendws already current"}
        cfgSink?.cancel(window.wid);revokeSnapshotLease(window.wid);cancelFocusRecovery()
        silentSpaceMoves[window.wid]=SilentSpaceMove(pid:window.pid,birth:birth,source:current,destination:destination,catalog:catalog,deadline:sys.now()+3)
        silentSpaceMoveLast = .object([("state",.string("queued")),("wid",.int(window.wid)),("pid",.int(window.pid)),("source",.int(current)),("destination",.int(destination)),("native_samples",.int(0))])
        eng.c.space(window.wid,destination);eng.c.commit()
        return "sendws queued \(window.wid) -> \(destination)"
    }
    @discardableResult func pollSilentSpaceMoves(_ snapshot:Snapshot) -> Bool {
        var changed=false
        for (wid,var request) in silentSpaceMoves {
            guard sys.now()<request.deadline,!snapshot.locked,!sys.sessionLocked(),!sys.interactionOverlay(),
                  sys.processBirth(request.pid)==request.birth,sys.processUID(request.pid)==Int(getuid()),sys.winPidLevel(wid).pid==request.pid,
                  let catalog=sys.launcherCatalog(),catalog.sameSession(request.catalog),catalog.active==snapshot.space else {
                silentSpaceMoves[wid]=nil;silentSpaceMoveLast=silentSpaceMoveLast.setting("state",.string("cancelled"));continue
            }
            guard snapshot.stable,snapshot.spaceType==0,let window=snapshot.windows.first(where:{$0.wid==wid && $0.pid==request.pid && $0.space==request.destination && $0.layer==0 && !$0.nativeFullscreen}) else{continue}
            guard window.alpha>=0.05 else{continue} // Off-current native membership may be on=false.
            if request.lastSample != workspaceSampleSequence {request.lastSample=workspaceSampleSequence;request.samples+=1}
            silentSpaceMoveLast=silentSpaceMoveLast.setting("native_samples",.int(request.samples))
            if request.samples>=2 {
                let source=sp(request.source);source.tree=Dwindle.remove(source.tree,wid)
                if source.focus==wid {source.focus=nil};if source.full==wid {source.full=nil}
                target[wid]=nil;newbies[wid]=nil;optimistic[wid]=nil;restoreFrom[wid]=nil;restoring.remove(wid)
                silentSpaceMoves[wid]=nil;silentSpaceMoveLast=silentSpaceMoveLast.setting("state",.string("acknowledged"));save()
                // Detaching before sync means sync cannot discover this layout change.
                if request.source==snapshot.space {changed=true}
                else {reflowBackgroundLauncherSource(request.source,snapshot)}
            } else {silentSpaceMoves[wid]=request}
        }
        return changed
    }
    var silentSpaceMoveStatus:JSON {
        .object([("pending",.array(silentSpaceMoves.sorted{$0.key<$1.key}.map{wid,r in .object([("wid",.int(wid)),("pid",.int(r.pid)),("source",.int(r.source)),("destination",.int(r.destination)),("native_samples",.int(r.samples))])})),("last",silentSpaceMoveLast)])
    }
}
