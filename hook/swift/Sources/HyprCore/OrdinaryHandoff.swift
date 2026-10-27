import Foundation
import Dispatch

struct OrdinaryBatch {
    let nonce:UInt64,space:Int,goals:[Int:Rect],participants:[Int:CfgJob],started:Double
    var openings:[Int:CfgJob]=[:]
    var unboundOpening=false
    var ready=Set<Int>(),restored=Set<Int>()
    var cancelling=false,rejected=false,lastCancel=0.0
}

extension WM {
    // Sync reports an opening once. Retain its classification while existing
    // neighbors wait for ownership, including cancellation and retargets.
    func ordinaryOpenings(_ incoming:[Int],space:Int,wins:[WinInfo],rects:OrderedMap<Int,Rect>) -> [Int] {
        guard let batch=ordinaryBatch else{return incoming}
        let current=Dictionary(wins.map{($0.wid,$0)},uniquingKeysWith:{$1})
        var result=incoming
        for (wid,job) in batch.openings.sorted(by:{$0.key<$1.key}) {
            guard !result.contains(wid),rects[wid] != nil,job.expectedSpace==space,
                  let window=current[wid],window.on,window.space==space,window.pid==job.pid,
                  pids[wid]==job.pid,job.birth != nil,sys.processBirth(job.pid)==job.birth,
                  sys.winPidLevel(wid).pid==job.pid,
                  !hidden.contains(where:{$0.wid==wid}),!closing.contains(wid) else{continue}
            result.append(wid)
        }
        return result
    }

    func observeOrdinary(_ event:EngEvent) {
        let a=event.rect.arr
        guard var batch=ordinaryBatch,event.t.isFinite,a.count==4,a[3]==1,
              a[0].isFinite,a[1].isFinite,a[0]>=0,a[1]>=0,
              a[0]<=Double(UInt32.max),a[1]<=Double(UInt32.max),
              a[0].rounded(.towardZero)==a[0],a[1].rounded(.towardZero)==a[1],
              UInt64(a[0])|(UInt64(a[1])<<32)==batch.nonce,batch.participants[event.wid] != nil else{return}
        switch a[2] {
        case 1:if !batch.cancelling {batch.ready.insert(event.wid)}
        case 2:batch.ready.remove(event.wid);batch.restored.insert(event.wid);batch.rejected=true
        case 3:batch.rejected=true
        default:return
        }
        ordinaryBatch=batch
    }

    // The entire geometry publication waits for real Update adoption of its
    // old pixels. Tail consumption or a completed GPU encode is not an ACK.
    func prepareOrdinaryBatch(_ space:Int,_ wins:[WinInfo],rects:OrderedMap<Int,Rect>,
                              real:[Int:Rect],engine:[Int:EngWin],opening:[Int],force:Bool,motion:Bool) -> Bool {
        let goals=Dictionary(uniqueKeysWithValues:rects.map{($0.0,$0.1)})
        let now=sys.now(),c=eng.c
        if ordinaryBatch==nil && !(options.production && c.ordinaryPrepareSupported && motion && dragSession==nil) {return false}
        let current=Dictionary(wins.map{($0.wid,$0)},uniquingKeysWith:{$1})
        var arrivals:[Int:CfgJob]=[:],unboundOpening=false
        for wid in opening {
            guard let to=goals[wid] else{continue}
            guard let window=current[wid],var arrival=job(window.pid,wid,to),arrival.birth != nil else {
                unboundOpening=true;continue
            }
            arrival.expectedSpace=space;arrivals[wid]=arrival
        }
        if var batch=ordinaryBatch {
            batch.openings=arrivals;batch.unboundOpening = batch.unboundOpening || unboundOpening
            let same=batch.space==space && batch.goals==goals && batch.participants.allSatisfy {wid,job in
                pids[wid]==job.pid && job.birth != nil && sys.processBirth(job.pid)==job.birth &&
                    sys.winPidLevel(wid).pid==job.pid && !hidden.contains(where:{$0.wid==wid}) && !closing.contains(wid)
            }
            if !same || batch.rejected || batch.unboundOpening || now-batch.started>0.6 || !c.ordinaryPrepareSupported {batch.cancelling=true}
            if batch.cancelling {
                if batch.restored.count==batch.participants.count {
                    ordinaryBatch=nil
                    if same || batch.unboundOpening {ordinaryFallback=Set(goals.keys);return false}
                    return prepareOrdinaryBatch(space,wins,rects:rects,real:real,engine:engine,opening:opening,force:force,motion:motion)
                }
                if now-batch.lastCancel>=0.1 {
                    for (wid,job) in batch.participants where !batch.restored.contains(wid) {
                        _=c.ordinaryPrepare(wid,nonce:batch.nonce,to:job.to,prepare:false)
                    }
                    c.commit();batch.lastCancel=now
                }
                ordinaryBatch=batch;return true
            }
            if batch.ready.count==batch.participants.count {ordinaryBatch=nil;ordinaryReadyNonce=batch.nonce;return false}
            ordinaryBatch=batch;return true
        }
        guard options.production,c.ordinaryPrepareSupported,motion,!unboundOpening,dragSession==nil else{return false}
        var participants:[Int:CfgJob]=[:]
        for (wid,to) in rects {
            guard !opening.contains(wid),let window=current[wid],let slot=engine[wid],!slot.moving,slot.curAlpha==1,
                  !windowPolicy(window).noAnimation,!restoring.contains(wid),cfgSink?.busy(wid) != true,
                  (target[wid] != to || force && (real[wid] ?? window.rect).maxDiff(to)>1),
                  (real[wid] ?? window.rect).maxDiff(to)>1,let job=job(window.pid,wid,to) else{continue}
            participants[wid]=job
        }
        guard !participants.isEmpty else{return false}
        let nonce=max(ordinaryNonce &+ 1,DispatchTime.now().uptimeNanoseconds)
        guard nonce>ordinaryNonce else{return false}
        ordinaryNonce=nonce
        var batch=OrdinaryBatch(nonce:nonce,space:space,goals:goals,participants:participants,started:now,openings:arrivals)
        for (wid,job) in participants {
            if !c.ordinaryPrepare(wid,nonce:nonce,to:job.to,prepare:true) {batch.rejected=true}
        }
        ordinaryBatch=batch;c.commit();return true
    }
}
