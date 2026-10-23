import Foundation

struct LiveBufferShrink {
    let job:CfgJob,space:Int,deadline:Double
    var terminalMove=false
    var requiresFinalSize=false
    var lastTick:Int?,settledSamples=0
}
extension WM {
    /// Final logical size once, at the beginning. The live surface stays 1:1;
    /// physical origin moves only in the engine's atomic terminal handoff.
    func prepareLiveBuffer(_ job:CfgJob,actual:Rect,space:Int,duration:Double,terminalMove:Bool=false) -> CfgJob? {
        let resized=abs(job.to.w-actual.w)>1 || abs(job.to.h-actual.h)>1
        let grows=job.to.w>actual.w+1 || job.to.h>actual.h+1
        let moves=abs(job.to.x-actual.x)>1 || abs(job.to.y-actual.y)>1
        if moves || grows {liveBufferShrinks[job.wid]=LiveBufferShrink(job:job,space:space,deadline:sys.now()+max(5,duration+2),terminalMove:terminalMove,requiresFinalSize:grows)}
        guard resized || job.forceWrite else{return nil}
        // At a right/bottom edge AppKit clamps growth against the old origin.
        // Position + final size ONCE at entry avoids that clamp. F_FROM keeps
        // B at its original visual allocation while frame_win resamples A.
        var early=job;early.sizeOnly = !grows;return early
    }
    func pollLiveBufferShrinks() {
        guard options.production,!liveBufferShrinks.isEmpty,!sys.sessionLocked(),!sys.interactionOverlay(),overviewFrozen?() != true else{return}
        let slots=Dictionary(eng.c.wins().map{($0.wid,$0)},uniquingKeysWith:{first,_ in first}),tick=eng.c.stats.ticks
        for (wid,var pending) in liveBufferShrinks {
            let job=pending.job
            guard enabled,sys.now()<pending.deadline,target[wid]==job.to,pids[wid]==job.pid,
                  sys.processBirth(job.pid)==job.birth,sys.winPidLevel(wid).pid==job.pid,job.birth != nil,
                  sp(pending.space).tree?.contains(wid)==true,!hidden.contains(where:{$0.wid==wid}),!closing.contains(wid),
                  !floating.contains(wid),!nativeSuspendedWindows.contains(wid) else {liveBufferShrinks[wid]=nil;continue}
            guard !eng.c.pending,let slot=slots[wid],(slot.geo==1 || slot.geo==3 || slot.geo==4),!slot.posActive,!slot.sizeActive,!slot.held,
                  slot.visible.maxDiff(job.to)<=TOL else {pending.settledSamples=0;pending.lastTick=nil;liveBufferShrinks[wid]=pending;continue}
            if pending.terminalMove {
                if abs(slot.ax-job.to.x)<=TOL && abs(slot.ay-job.to.y)<=TOL &&
                    (!pending.requiresFinalSize || abs(slot.aw-job.to.w)<=TOL && abs(slot.ah-job.to.h)<=TOL) {liveBufferShrinks[wid]=nil}
                continue // C7 alone owns this position. Never append a late AX frame.
            }
            if pending.lastTick != tick {pending.lastTick=tick;pending.settledSamples+=1}
            guard pending.settledSamples>=2,cfgSink?.busy(wid) != true else {liveBufferShrinks[wid]=pending;continue}
            liveBufferShrinks[wid]=nil
            // C6 compatibility: F_MOVE + warp applies the physical origin and
            // resets projection in one WindowServer frame, with no AppKit resize.
            eng.c.geom(wid,job.to,16,16,move:true,warp:true,stretch:false);eng.c.commit()
        }
    }
}
