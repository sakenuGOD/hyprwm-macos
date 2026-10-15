import Foundation

/// Exact apply_cmd clock in anim4.c: t0=min(te-period,now).
/// Capture this native lower bound before enqueueing, not the later tick clock.
public enum NativeBatchClock {
    public static func lowerBound(now:Double,presentation:Double,period:Double) -> Double {
        guard now.isFinite,presentation.isFinite,period.isFinite,period>0,presentation>=period else{return now}
        return min(presentation-period,now)
    }
}

public enum SnapshotReceiptResult:Int { case acquired=1,deferred=2,revealed=3,cancelled=4,configured=5 }
struct SnapshotConfigure {
    let job:CfgJob
    let engineTime,started:Double
    let minimumEpoch:Int
    var timeout:Double=2
    var space:Int?=nil
    var epoch:Int?
    var verified=false
    var revealed=false
}
struct SnapshotSourceLease {
    let job:CfgJob,epoch:Int
    let space:Int?
    let deadline:Double
}
extension WM {
    func revokeSnapshotLease(_ wid:Int) {snapshotLeases[wid]=nil;sys.setFocusCover(nil,wid:wid)}
    func clearSnapshotLeases() {for wid in snapshotLeases.keys{sys.setFocusCover(nil,wid:wid)};snapshotLeases.removeAll()}
    func snapshotSourceCovered(_ window:WinInfo,space:Int) -> Bool {
        guard options.production,let lease=snapshotLeases[window.wid],sys.now()<=lease.deadline,
              lease.space.map({$0==space}) ?? true,window.space==space,window.pid==lease.job.pid,window.layer==0,!window.nativeFullscreen,
              sp(space).tree?.contains(window.wid)==true,!hidden.contains(where:{$0.wid==window.wid}),!closing.contains(window.wid),
              !floating.contains(window.wid),!ignored(window),ruleFloat(window)==nil,
              !sys.protectedProcess(window.pid),sys.winPidLevel(window.wid).pid==window.pid,
              lease.job.birth != nil,sys.processBirth(window.pid)==lease.job.birth else{return false}
        return true
    }
    func snapshotJobLive(_ job:CfgJob) -> Bool {
        job.requireOwnership && job.birth != nil && target[job.wid]==job.to &&
            pids[job.wid]==job.pid && !sys.protectedProcess(job.pid) && !sys.sessionLocked() &&
            sys.winPidLevel(job.wid).pid==job.pid && sys.processBirth(job.pid)==job.birth
    }
    func observeSnapshot(_ event:EngEvent) {
        let fields=event.rect.arr
        guard event.t.isFinite,fields.allSatisfy({ $0.isFinite && $0>=0 && $0<=Double(UInt32.max) && $0.rounded(.towardZero)==$0 }),
              let result=SnapshotReceiptResult(rawValue:Int(fields[1])), fields[3]>0 else { return }
        let epoch=Int(fields[3]), previous=snapshotReceipts[event.wid]
        guard epoch >= (previous?.epoch ?? 0) else { return }
        if snapshotReceipts.count>=64,previous==nil { snapshotReceipts[snapshotReceipts.keys.sorted().first!]=nil }
        snapshotReceipts[event.wid]=(epoch,JSON.object([("epoch",.int(epoch)),("clone",.int(Int(fields[0]))),
            ("result",.int(result.rawValue)),("mode",.int(Int(fields[2]))),("time",.double(event.t))]))
        if result == .revealed || result == .cancelled,let lease=snapshotLeases[event.wid],lease.epoch==epoch {
            revokeSnapshotLease(event.wid)
        }
        guard var pending=snapshotConfigures[event.wid],event.t>=pending.engineTime,epoch>pending.minimumEpoch,
              snapshotJobLive(pending.job) else { return }
        switch result {
        case .acquired,.deferred:
            guard pending.epoch==nil || pending.epoch==epoch else { return }
            pending.epoch=epoch;snapshotConfigures[event.wid]=pending
            if result == .acquired,Int(fields[2])==3,snapshotLeases[event.wid]?.epoch != epoch {
                snapshotLeases[event.wid]=SnapshotSourceLease(job:pending.job,epoch:epoch,space:pending.space,deadline:sys.now()+max(5,pending.timeout+1))
                if let birth=pending.job.birth,let space=pending.space {sys.setFocusCover(FocusCoverStamp(wid:event.wid,pid:pending.job.pid,epoch:epoch,space:space,birth:birth,deadline:sys.now()+max(5,pending.timeout+1)),wid:event.wid)}
            }
        case .configured:
            guard pending.epoch==epoch,!pending.verified else { return }
            pending.verified=true;snapshotConfigures[event.wid]=pending
            var verification=pending.job;verification.verifyOnly=true
            configure([verification]) // One native configure was posted by C5, never repeat it via AX.
        case .revealed:
            guard pending.epoch==epoch else { return }
            guard Int(fields[2])==3 else { return }
            if pending.verified {snapshotConfigures[event.wid]=nil}
            else {pending.revealed=true;snapshotConfigures[event.wid]=pending}
        case .cancelled:
            guard pending.epoch==epoch else { return }
            snapshotConfigures[event.wid]=nil
        }
    }
    /// Native cover handoff is a second legitimate completion path when EVT5
    /// was lost/rejected. Wait for an ACTUAL fresh ordinary main-loop census.
    func verifySnapshotHandoffs(_ snapshot:Snapshot) {
        guard snapshot.stable,!snapshot.locked,snapshot.spaceType==0 else{return}
        for (wid,pending) in snapshotConfigures where pending.revealed && !pending.verified {
            guard snapshotJobLive(pending.job),!hidden.contains(where:{$0.wid==wid}),
                  let window=snapshot.windows.first(where:{$0.wid==wid&&$0.pid==pending.job.pid}),
                  window.on,window.space==snapshot.space,pending.space.map({$0==snapshot.space}) ?? true,
                  !window.nativeFullscreen else {snapshotConfigures[wid]=nil;continue}
            var verification=pending.job;verification.verifyOnly=true
            snapshotConfigures[wid]=nil;configure([verification])
        }
    }
    @discardableResult func expireSnapshotJobs() -> Bool {
        for (wid,lease) in snapshotLeases where sys.now()>lease.deadline || sys.processBirth(lease.job.pid) != lease.job.birth || sys.winPidLevel(wid).pid != lease.job.pid {revokeSnapshotLease(wid)}
        var changed=false
        for (wid,pending) in snapshotConfigures where sys.now()-pending.started>pending.timeout {
            snapshotConfigures[wid]=nil
            if snapshotJobLive(pending.job) { target[wid]=nil;changed=true }
        }
        return changed
    }
    public var snapshotHandoffStatus:JSON {
        .object([("enabled",.bool(options.snapshotFrames)),("waiting",.array(snapshotConfigures.keys.sorted().map(JSON.int))),
            ("covered_sources",.array(snapshotLeases.keys.sorted().map(JSON.int))),
            ("receipts",.object(snapshotReceipts.keys.sorted().map { (String($0),snapshotReceipts[$0]!.value) }))])
    }
}
