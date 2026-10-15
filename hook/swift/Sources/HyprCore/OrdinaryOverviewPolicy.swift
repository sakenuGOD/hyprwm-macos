import Foundation

public struct OrdinaryOverviewPose:Equatable {
    public let source:OverviewHidden
    public let visible:Rect
    public init(source:OverviewHidden,visible:Rect){self.source=source;self.visible=visible}
}

/// AppKit may clamp a concealed off-screen origin while WindowServer retains the
/// exact authorized park. This never substitutes for physical native readback.
public enum OrdinaryOverviewFrameReadback {
    public static func acceptsAppKit(_ app:Rect,pose:OrdinaryOverviewPose,parked:Bool,sourceCurrent:Bool,alpha:Double?) -> Bool {
        let goal=parked ? pose.source.parked:pose.visible
        guard sourceCurrent,let alpha,alpha.isFinite,alpha>=0,alpha<=0.001,
              app.arr.allSatisfy(\.isFinite),goal.arr.allSatisfy(\.isFinite),app.w>0,app.h>0 else{return false}
        if app.maxDiff(goal)<0.01 {return true}
        // AppKit keeps a strip on-screen: accept only x clamped toward the saved
        // visible origin. Size and vertical position remain exact.
        guard parked,pose.visible.arr.allSatisfy(\.isFinite),
              abs(app.y-goal.y)<0.01,abs(app.w-goal.w)<0.01,abs(app.h-goal.h)<0.01 else{return false}
        return app.x>=min(goal.x,pose.visible.x) && app.x<=max(goal.x,pose.visible.x)
    }
}

extension WM {
    public func ordinaryGeometryAuthority(_ poses:[OrdinaryOverviewPose],parked:Bool,dockCurrent:Bool) -> Bool {
        // The retained scene cannot present without its original Dock actor.
        // Rollback instead belongs to the still-current hidden intent; it must
        // remain possible after that actor has exited or been replaced.
        guard parked || dockCurrent else{return false}
        return ordinaryGeometryLive(poses,parked:parked)
    }
    public func ordinaryDockDeparted(pid:Int,birth:String) -> Bool {
        if sys.processExited(pid) {return true}
        return sys.processBirth(pid).map{$0 != birth} ?? false
    }
    /// A dead Dock cannot run its alpha0 inverse. Reclaim only this scene's
    /// unchanged hidden sources, in its exact known poses and native Spaces.
    public func ordinaryRollbackConcealed(_ poses:[OrdinaryOverviewPose],dockPID:Int,dockBirth:String) -> Bool {
        guard ordinaryDockDeparted(pid:dockPID,birth:dockBirth),enabled,options.production,
              overviewFrozen?()==true,!sys.sessionLocked(),!eng.c.pending else{return false}
        if poses.isEmpty {return true}
        guard let census=try? sys.snapshot(),census.stable,!census.locked,census.spaceType==0 else{return false}
        var conceal:[Int]=[]
        let slots=Dictionary(eng.c.wins().map{($0.wid,$0)},uniquingKeysWith:{$1})
        for pose in poses {
            let source=pose.source
            guard ordinaryOverviewIntentLive(source),sys.winPidLevel(source.wid).level==0,
                  census.windows.contains(where:{$0.wid==source.wid && $0.pid==source.pid && source.spaces.contains($0.space) && $0.layer==0 && !$0.nativeFullscreen}),
                  let bounds=sys.winBounds(source.wid),bounds.maxDiff(source.parked)<0.01 || bounds.maxDiff(pose.visible)<0.01,
                  let alpha=sys.winAlpha(source.wid),alpha.isFinite else{return false}
            if alpha>0.001 || slots[source.wid].map({$0.curAlpha>0.001 || $0.alphaActive}) == true {conceal.append(source.wid)}
        }
        if conceal.isEmpty {return true}
        for wid in conceal {
            hiddenParkSamples[wid]=nil
            // Recreate the alpha slot so an externally exposed source cannot
            // inherit a stale logical curAlpha0 and skip the actual hide.
            eng.c.forget(wid);eng.c.alpha(wid,0,16,0,frm:1)
        }
        eng.c.commit();return false // Next independent read must prove alpha0.
    }
    private func ordinaryGeometryLive(_ poses:[OrdinaryOverviewPose],parked:Bool) -> Bool {
        guard enabled,options.production,overviewFrozen?()==true,!sys.sessionLocked() else{return false}
        return poses.allSatisfy {pose in
            ordinaryOverviewIntentLive(pose.source) && sys.winPidLevel(pose.source.wid).level==0 &&
            (sys.winAlpha(pose.source.wid) ?? 1)<=0.001 &&
            (parked ? pose.source.parked:pose.visible).arr.allSatisfy(\.isFinite)
        }
    }
    /// Main-thread, one publication. An accepted AX frame does not move an
    /// alpha-only managed source's physical WindowServer origin by itself.
    public func ordinaryGeometryStart(_ poses:[OrdinaryOverviewPose],parked:Bool) -> Bool {
        guard !eng.c.pending,ordinaryGeometryLive(poses,parked:parked) else{return false}
        for pose in poses {
            let wid=pose.source.wid
            cfgSink?.cancel(wid);hiddenParkSamples[wid]=nil
            eng.c.alpha(wid,0,16,0,frm:0)
            eng.c.geom(wid,parked ? pose.source.parked:pose.visible,16,16,move:true,warp:true)
        }
        eng.c.commit();return true
    }
    public func ordinaryGeometryRelease(_ poses:[OrdinaryOverviewPose],parked:Bool) -> Bool {
        guard !eng.c.pending,ordinaryGeometryLive(poses,parked:parked) else{return false}
        let slots=Dictionary(eng.c.wins().map{($0.wid,$0)},uniquingKeysWith:{$1})
        for pose in poses {
            let wid=pose.source.wid,goal=parked ? pose.source.parked:pose.visible
            guard let actual=sys.winBounds(wid),actual.maxDiff(goal)<0.01,
                  let slot=slots[wid],slot.geo != 0,!slot.posActive,!slot.sizeActive,!slot.alphaActive,!slot.held else{return false}
        }
        for pose in poses {eng.c.forget(pose.source.wid);eng.c.alpha(pose.source.wid,0,16,0,frm:0)}
        eng.c.commit();return true
    }
    public func ordinaryGeometryConsumed(_ poses:[OrdinaryOverviewPose],parked:Bool) -> Bool {
        guard !eng.c.pending,ordinaryGeometryLive(poses,parked:parked) else{return false}
        let slots=Dictionary(eng.c.wins().map{($0.wid,$0)},uniquingKeysWith:{$1})
        return poses.allSatisfy {pose in
            let goal=parked ? pose.source.parked:pose.visible
            guard let actual=sys.winBounds(pose.source.wid),actual.maxDiff(goal)<0.01 else{return false}
            if let slot=slots[pose.source.wid] {return slot.geo==0 && !slot.posActive && !slot.sizeActive && !slot.alphaActive && !slot.held && !slot.settling}
            return false // The paired alpha0 recreation must also be consumed.
        }
    }
    public func ordinaryOverviewIntentLive(_ grant:OverviewHidden) -> Bool {
        guard let record=hidden.first(where:{$0.wid==grant.wid && $0.pid==grant.pid}),
              hiddenRecordLive(record),restorePending[grant.wid]==nil,
              (try? record.intentFingerprint())==grant.intent else{return false}
        return sys.processBirth(grant.pid)=="\(grant.pid):\(grant.birth[2]):\(grant.birth[3])"
    }
    /// Temporary AppKit presentation does not consume the persistent hide intent.
    public func ordinaryOverviewRefusal(_ grants:[OverviewHidden],display:Rect) -> String? {
        let live=hidden.filter{hiddenRecordLive($0) && restorePending[$0.wid]==nil}
        guard live.count==grants.count else{return "hidden-count-mismatch:\(live.count):\(grants.count)"}
        guard !sys.sessionLocked() else{return "session-locked"}
        for grant in grants {
            guard ordinaryOverviewIntentLive(grant) else{return "hidden-intent-or-identity:\(grant.wid)"}
            guard grant.ordinaryVisibleBounds(display:display) != nil else{return "visible-frame-unavailable:\(grant.wid)"}
        }
        return nil
    }
    public func ordinaryOverviewPoses(_ grants:[OverviewHidden],display:Rect) -> [OrdinaryOverviewPose]? {
        let live=hidden.filter{hiddenRecordLive($0) && restorePending[$0.wid]==nil}
        guard live.count==grants.count,!sys.sessionLocked() else{return nil}
        var result:[OrdinaryOverviewPose]=[]
        for grant in grants {
            guard ordinaryOverviewIntentLive(grant),
                  let visible=grant.ordinaryVisibleBounds(display:display) else{return nil}
            result.append(OrdinaryOverviewPose(source:grant,visible:visible))
        }
        return result
    }
}
