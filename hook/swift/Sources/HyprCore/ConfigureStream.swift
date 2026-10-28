import Foundation

/// A read result from the authenticated additive receiver. Construction supplies
/// no authority; the live adapter verifies the protected grant and loader proof.
public struct ConfigureStreamLease {
    public let pid,wid,space,epoch:Int
    public let birth,object,moduleUUID,grantSHA256:String
    public let expires,observedAt:Double
    public let minimum:(Double,Double)
    public let cohort:[Int:String]
    public let initialProbeFrame:Rect?
    public let currentFrame:Rect
    public init(pid:Int,wid:Int,space:Int,epoch:Int,birth:String,object:String,moduleUUID:String,grantSHA256:String,
                expires:Double,observedAt:Double,minimum:(Double,Double),cohort:[Int:String],initialProbeFrame:Rect?,currentFrame:Rect) {
        self.pid=pid;self.wid=wid;self.space=space;self.epoch=epoch;self.birth=birth;self.object=object
        self.moduleUUID=moduleUUID;self.grantSHA256=grantSHA256;self.expires=expires;self.observedAt=observedAt;self.minimum=minimum
        self.cohort=cohort;self.initialProbeFrame=initialProbeFrame
        self.currentFrame=currentFrame
    }
}

extension WM {
    /// Select the whole changed survivor cohort before publishing any geometry.
    /// A failed participant leaves every participant on its existing path.
    func configureStreamCohort(_ rects:OrderedMap<Int,Rect>,current:[Int:WinInfo],engine:[Int:EngWin],real:[Int:Rect],
                               space:Int,opening:[Int],force:Bool,curve:Int,duration:Double,motionOn:Bool,hold:Bool) -> [Int:ConfigureStreamLease] {
        guard options.production,options.nativeFrames,motionOn,duration.isFinite,duration>0,
              dragSession==nil,pendingDragSession==nil,!engineRecoveryActive,
              !sys.mouseDown(),!sys.sessionLocked(),!sys.interactionOverlay(),!sys.overviewTransitionActive(),
              overviewFrozen?() != true,nativeSpaceType==0,sys.activeSpace()==UInt64(space) else{return [:]}
        var changed:[(Int,Rect)]=[]
        for (wid,to) in rects where !opening.contains(wid) && !restoring.contains(wid) {
            guard let window=current[wid] else{return [:]}
            if target[wid]==to && (!force || engine[wid]?.moving==true || cfgSink?.busy(wid)==true ||
                (real[wid] ?? window.rect).maxDiff(to)<=1) {continue}
            changed.append((wid,to))
        }
        guard !changed.isEmpty else{return [:]}
        var result:[Int:ConfigureStreamLease]=[:],generations:[Int:String]=[:],horizons:[Int:Double]=[:]
        for (wid,to) in changed {
            guard let window=current[wid],window.on,window.space==space,window.layer==0,!window.nativeFullscreen,
                  !hidden.contains(where:{$0.wid==wid}),!closing.contains(wid),!nativeSuspendedWindows.contains(wid),
                  !windowPolicy(window).noAnimation,!ordinaryFallback.contains(wid),cfgSink?.busy(wid) != true,
                  liveBufferShrinks[wid]==nil,snapshotConfigures[wid]==nil,
                  clientPolicy?.admitted(window,sys)==true,sys.winPidLevel(wid).pid==window.pid,
                  engine[wid]?.moving != true,
                  sys.focusContext(window.pid).flags&(NativeFocusFlags.positive|NativeFocusFlags.unknown)==0,
                  sys.nativeResize(window.pid).map({$0.phase>2}) ?? true,
                  !(options.snapshotFrames && eng.c.snapshotSupported && sys.clientCapability(window.pid)>=6),
                  (sys.winAlpha(wid) ?? window.alpha)>0.001,(engine[wid]?.curAlpha ?? 1)>0.001,
                  let lease=sys.streamLease(window.pid,wid,space,minimumTTL:duration+0.25),lease.initialProbeFrame != nil,
                  lease.pid==window.pid,lease.wid==wid,lease.space==space,lease.cohort[wid]==lease.object,
                  sys.processBirth(window.pid)==lease.birth,lease.minimum.0>0,lease.minimum.1>0,
                  to.w+0.01>=lease.minimum.0,to.h+0.01>=lease.minimum.1,
                  engine[wid]?.geo != 2 || engine[wid]!.visible.maxDiff(lease.currentFrame)<=0.01,
                  let horizon=eng.c.streamMotionHorizon(curve:curve,duration:duration,from:lease.currentFrame,to:to,minimum:lease.minimum,hold:hold),
                  lease.expires-sys.now()>=horizon else{return [:]}
            let stamp="\(lease.epoch):\(lease.grantSHA256)"
            guard generations[window.pid]==nil || generations[window.pid]==stamp else{return [:]}
            generations[window.pid]=stamp;result[wid]=lease;horizons[wid]=horizon
        }
        let now=sys.now()
        guard result.values.allSatisfy({$0.expires-now>=(horizons[$0.wid] ?? .infinity) && now>=$0.observedAt && now-$0.observedAt<=0.2 &&
            sys.processBirth($0.pid)==$0.birth && sys.winPidLevel($0.wid).pid==$0.pid}) else{return [:]}
        return result
    }

    func configureStreamProbe(_ arguments:[String],space:Int,wins:[WinInfo],rects:OrderedMap<Int,Rect>) throws -> String {
        guard options.production,arguments.count==6,enabled,!engineRecoveryActive,
              let wid=UInt32(arguments[1]),wid>0,let pid=Int(arguments[2]),pid>1,pid<=Int(Int32.max),
              let requestedSpace=Int(arguments[4]),requestedSpace==space,space>0,
              let epoch=Int(arguments[5]),epoch>0,epoch<=9_007_199_254_740_991 else {
            throw CmdError("configure-stream-probe: expected window ID, PID, process identity, Space and generation")
        }
        let id=Int(wid),c=eng.c
        guard dragSession==nil,pendingDragSession==nil,!sys.mouseDown(),!sys.sessionLocked(),
              !sys.interactionOverlay(),!sys.overviewTransitionActive(),overviewFrozen?() != true,nativeSpaceType==0,
              sys.activeSpace()==UInt64(space),!c.pending,c.stats.nactive==0,c.stats.holding==0,
              !c.wins().contains(where:{$0.moving || $0.alphaActive || $0.held}),cfgSink?.idle != false,cfgQ.isEmpty,
              liveBufferShrinks.isEmpty,snapshotConfigures.isEmpty,closeRequests.isEmpty,closing.isEmpty,
              rects.contains(id),!restoring.contains(id),!hidden.contains(where:{$0.wid==id}),
              let window=wins.first(where:{$0.wid==id && $0.pid==pid && $0.on && $0.space==space && $0.layer==0 && !$0.nativeFullscreen}),
              clientPolicy?.admitted(window,sys)==true,!sys.protectedProcess(pid),sys.winPidLevel(id).pid==pid,
              sys.processBirth(pid)==arguments[3],
              sys.focusContext(pid).flags&(NativeFocusFlags.positive|NativeFocusFlags.unknown)==0,
              sys.nativeResize(pid).map({$0.phase>2}) ?? true,
              let lease=sys.streamProbeLease(pid,id,space,epoch:epoch),lease.birth==arguments[3],lease.epoch==epoch,
              lease.pid==pid,lease.wid==id,lease.space==space,lease.initialProbeFrame==nil,
              lease.minimum.0>0,lease.minimum.1>0,lease.expires-sys.now()>=0.25,
              let actual=sys.winBounds(id),actual.arr.allSatisfy({$0.isFinite}),actual.w>0,actual.h>0,
              actual.w+1>=lease.minimum.0,actual.h+1>=lease.minimum.1,
              let engineWindow=c.wins().first(where:{$0.wid==id}),engineWindow.geo != 2,engineWindow.real.maxDiff(actual)<=1,
              sys.winPidLevel(id).pid==pid,sys.processBirth(pid)==arguments[3],sys.activeSpace()==UInt64(space),
              lease.expires-sys.now()>=0.25,
              c.configureStreamProbe(id,actual) else {throw CmdError("configure-stream-probe: authenticated staged lease and idle current native frame required")}
        c.commit()
        return JSON.object([("queued",.bool(true)),("ready",.bool(false)),("wid",.int(id)),("pid",.int(pid)),
            ("birth",.string(lease.birth)),("space",.int(space)),("epoch",.int(epoch)),("frame",actual.json)]).dumps()
    }
}
