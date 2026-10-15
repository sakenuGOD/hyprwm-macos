import Foundation

/// One exact launcher actor is placed while concealed; its old Space frame
/// never becomes the start of a destination animation.
struct LauncherArrival {
    let tree:JSON,baseTree:JSON,rect:Rect,presel:String?,basePresel:String?
    var accepted:Rect?
}
extension WM {
    func launcherArrivalPlan(_ window:WinInfo,_ origin:Int,_ area:Rect)->LauncherArrival? {
        guard !floating.contains(window.wid),!ignored(window),tabFacts[window.wid].map({$0.members.count<=1}) ?? true else{return nil}
        let original=sp(origin),copy=SpaceState()
        copy.tree=Dwindle.remove(Node.from(original.tree?.json),window.wid)
        copy.focus=original.focus.flatMap{copy.tree?.contains($0)==true ? $0:nil}
        copy.presel=original.presel;copy.full=original.full==window.wid ? nil:original.full;copy.fullmode=original.fullmode
        _=layout(area,copy)
        copy.tree=insert(copy,window.wid,copy.focus,area,point:sys.mouse())
        guard let rect=layout(area,copy)[window.wid],rect.arr.allSatisfy({$0.isFinite}),rect.w>0,rect.h>0 else{return nil}
        return LauncherArrival(tree:copy.tree!.json,baseTree:original.tree?.json ?? .null,rect:rect,presel:copy.presel,basePresel:original.presel)
    }
    func prepareLauncherArrival(_ window:WinInfo,_ transfer:inout LauncherTransfer,_ area:Rect)->Bool {
        guard transfer.arrival==nil,cfgSink != nil,let arrival=launcherArrivalPlan(window,transfer.request.origin,area) else{return false}
        let request=transfer.request
        var job=CfgJob(wid:window.wid,pid:window.pid,owner:window.owner,to:arrival.rect)
        job.birth=request.birth;job.requireOwnership=true
        cfgSink?.cancel(window.wid);target[window.wid]=arrival.rect
        eng.c.alpha(window.wid,0,16,0,frm:0)
        eng.c.geom(window.wid,arrival.rect,16,16,frm:arrival.rect,move:true,warp:true)
        eng.c.commit();configure([job]);transfer.arrival=arrival
        return true
    }
    func launcherArrivalAccepted(_ transfer:inout LauncherTransfer)->Bool {
        guard var arrival=transfer.arrival else{return false}
        let request=transfer.request,wid=request.wid,state=sp(request.origin)
        guard (state.tree?.json ?? .null)==arrival.baseTree,state.presel==arrival.basePresel else{return false}
        if arrival.accepted==nil,
           let result=cfgQ.first(where:{$0.wid==wid && $0.pid==request.pid && $0.birth==request.birth && $0.to==arrival.rect && $0.isCurrent?()==true}),
           let actual=PlacementFrameAcceptance.accepted(result,wid:wid,pid:request.pid,birth:request.birth,target:arrival.rect) {
            arrival.accepted=actual;transfer.arrival=arrival
        }
        guard let accepted=arrival.accepted,!eng.c.pending,cfgSink?.busy(wid) != true,
              let slot=eng.c.wins().first(where:{$0.wid==wid}),slot.geo != 0,!slot.posActive,!slot.sizeActive,!slot.held,
              slot.visible.maxDiff(arrival.rect)<=TOL,slot.real.maxDiff(accepted)<=TOL,
              let native=sys.winBounds(wid),native.maxDiff(accepted)<=TOL,
              sys.processBirth(request.pid)==request.birth,sys.winPidLevel(wid).pid==request.pid else{return false}
        return true
    }
    func cancelLauncherArrival(_ transfer:LauncherTransfer) {
        let request=transfer.request,wid=request.wid
        cfgSink?.cancel(wid);cfgQ.removeAll{$0.wid==wid};target[wid]=nil;restoreFrom[wid]=nil
        guard sys.processBirth(request.pid)==request.birth,sys.winPidLevel(wid).pid==request.pid else{return}
        guard !sys.sessionLocked(),overviewFrozen?() != true else {
            later.append((sys.now()+0.05,{[weak self] in guard let self,self.launcherTransfers[wid]==nil else{return};self.cancelLauncherArrival(transfer)}));return
        }
        eng.c.forget(wid)
        if transfer.wasHidden,hidden.contains(where:{$0.wid==wid && hiddenRecordLive($0)}),let original=transfer.nativeFrame {
            eng.c.alpha(wid,0,16,0,frm:0);eng.c.geom(wid,original,16,16,frm:original,move:true,warp:true)
        } else {eng.c.alpha(wid,transfer.wasHidden ? 1:transfer.originalAlpha,16,0)}
        eng.c.commit()
    }
}
