import Foundation

/// A current configure ACK may report a larger AppKit minimum. Keep its A,
/// while the engine clips to final B; an old origin is never accepted.
enum PlacementFrameAcceptance {
    static func accepted(_ result:CfgResult,wid:Int,pid:Int,birth:String,target:Rect)->Rect? {
        guard result.wid==wid,result.pid==pid,result.birth==birth,result.to==target,
              result.isCurrent?()==true,result.e==0,let actual=result.got,
              actual.arr.allSatisfy(\.isFinite),actual.w>0,actual.h>0,
              abs(actual.x-target.x)<=TOL,abs(actual.y-target.y)<=TOL,
              actual.w+TOL>=target.w,actual.h+TOL>=target.h else{return nil}
        return actual
    }
}

struct RestorePlacement {
    let tree:JSON,baseTree:JSON,presel:String?,basePresel:String?,rect:Rect,birth:String,park:Rect?
    var accepted:Rect?
}
extension WM {
    func stageRestorePlacement(_ record:Hidden,_ window:WinInfo,_ area:Rect,_ space:Int)->RestorePlacement? {
        guard let pid=record.pid,let birth=sys.processBirth(pid),cfgSink != nil,!floating.contains(record.wid),
              tabFacts[record.wid].map({$0.members.count<=1}) ?? true else{return nil}
        let state=sp(space),copy=SpaceState()
        copy.tree=Dwindle.remove(Node.from(state.tree?.json),record.wid)
        copy.focus=state.focus.flatMap{copy.tree?.contains($0)==true ? $0:nil}
        copy.presel=state.presel;copy.full=state.full;copy.fullmode=state.fullmode
        _=layout(area,copy);copy.tree=insert(copy,record.wid,copy.focus,area,point:sys.mouse())
        guard let rect=layout(area,copy)[record.wid] else{return nil}
        var job=CfgJob(wid:record.wid,pid:pid,owner:record.owner,to:rect);job.birth=birth;job.requireOwnership=true
        let plan=RestorePlacement(tree:copy.tree!.json,baseTree:state.tree?.json ?? .null,presel:copy.presel,basePresel:state.presel,rect:rect,birth:birth,park:sys.winBounds(record.wid))
        cfgSink?.cancel(record.wid);target[record.wid]=rect;restoreFrom[record.wid]=nil
        eng.c.alpha(record.wid,0,16,0,frm:0);eng.c.geom(record.wid,rect,16,16,frm:rect,move:true,warp:true);eng.c.commit()
        configure([job]);return plan
    }
    func finishRestorePlacement(_ request:inout RestoreRequest,_ window:WinInfo,_ area:Rect,_ windows:[WinInfo])->Bool {
        guard var plan=request.placement,let pid=request.record.pid,sys.processBirth(pid)==plan.birth else{return false}
        let wid=request.record.wid,state=sp(request.space)
        guard (state.tree?.json ?? .null)==plan.baseTree,state.presel==plan.basePresel else{return false}
        if plan.accepted==nil,let result=cfgQ.first(where:{$0.wid==wid && $0.pid==pid && $0.birth==plan.birth && $0.to==plan.rect && $0.isCurrent?()==true}),
           let actual=PlacementFrameAcceptance.accepted(result,wid:wid,pid:pid,birth:plan.birth,target:plan.rect) {
            plan.accepted=actual;request.placement=plan
        }
        guard let actual=plan.accepted,!eng.c.pending,cfgSink?.busy(wid) != true,window.on,
              let slot=eng.c.wins().first(where:{$0.wid==wid}),slot.geo != 0,!slot.posActive,!slot.sizeActive,!slot.held,
              slot.visible.maxDiff(plan.rect)<=TOL,slot.real.maxDiff(actual)<=TOL,
              let native=sys.winBounds(wid),native.maxDiff(actual)<=TOL,sys.winPidLevel(wid).pid==pid,sys.processBirth(pid)==plan.birth else{return false}
        hidden.removeAll{$0.wid==wid};restorePending[wid]=nil;restoreChecks[wid]=nil;restoring.remove(wid);restoreFrom[wid]=nil
        cfgQ.removeAll{$0.wid==wid};state.tree=Node.from(plan.tree);state.focus=wid;state.presel=plan.presel;target[wid]=plan.rect
        let fade=eng.anim("fadeIn"),animated=fade.on && !windowPolicy(window).noAnimation
        eng.c.alpha(wid,windowOpacity(window,request.space),animated ? fade.curve:16,animated ? fade.dur:0,frm:0)
        // The actor already owns its final B. Existing neighbors alone animate.
        apply(area,request.space,windows);eng.c.commit();save()
        // Explicit restore owns keyboard intent only after final placement is
        // accepted. The focus worker waits for reveal and preserves modal/menu
        // focus or a newer native foreground choice.
        _=queueFocus(window,space:request.space,reason:.keyboard)
        return true
    }
    func cancelRestorePlacement(_ request:RestoreRequest) {
        let wid=request.record.wid
        cfgSink?.cancel(wid);cfgQ.removeAll{$0.wid==wid};target[wid]=nil;restoreFrom[wid]=nil
        guard let plan=request.placement,hiddenRecordLive(request.record),let pid=request.record.pid,
              sys.processBirth(pid)==plan.birth,!sys.sessionLocked(),overviewFrozen?() != true else{return}
        eng.c.alpha(wid,0,16,0,frm:0)
        if let park=plan.park {eng.c.geom(wid,park,16,16,frm:park,move:true,warp:true)}
        eng.c.commit()
    }
}
