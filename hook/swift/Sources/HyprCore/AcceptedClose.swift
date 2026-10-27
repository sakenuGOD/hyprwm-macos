import CChan
import Foundation
import Dispatch

public struct AcceptedCloseBinding:Equatable {
    public let pid:Int,birth:String,space:Int,nonce:UInt64,generation:UInt32,marker:String
}

public struct AcceptedCloseNotice {
    public let wid:Int,nonce:UInt64,generation:UInt32,phase:Int
    public init?(_ event:EngEvent) {
        func word(_ value:Double)->UInt32? {
            guard value.isFinite,value>=0,value<=Double(UInt32.max),value.rounded()==value else{return nil}
            return UInt32(value)
        }
        guard event.type==Int(EV_CLOSE),event.wid>0,UInt32(exactly:event.wid) != nil,event.t.isFinite,
              let low=word(event.rect.x),let high=word(event.rect.y),let phase=word(event.rect.w),
              (UInt32(CLOSE_E_READY)...UInt32(CLOSE_E_REFUSED)).contains(phase),let generation=word(event.rect.h) else{return nil}
        let nonce=UInt64(low)|(UInt64(high)<<32);guard nonce != 0 else{return nil}
        if phase != UInt32(CLOSE_E_REFUSED),phase != UInt32(CLOSE_E_RETIRED),generation==0{return nil}
        self.wid=event.wid;self.nonce=nonce;self.generation=generation;self.phase=Int(phase)
    }
}

public enum AcceptedCloseCommand {
    case arm(epoch:(UInt64,UInt64),lifetime:Double)
    case disarm
    case prepare(wid:Int,nonce:UInt64)
    case cancel(wid:Int,nonce:UInt64,generation:UInt32)
    case release(wid:Int,nonce:UInt64,generation:UInt32,batch:UInt64,cohort:Int)
    func packet()->ch_cmd? {
        var k=ch_cmd();k.op=UInt32(OP_EDGE);k.flags=UInt32(CH_CLOSE)
        func identify(_ wid:Int,_ nonce:UInt64,_ generation:UInt32=0)->Bool {
            guard wid>0,let number=UInt32(exactly:wid),nonce != 0 else{return false}
            k.wid=number;k.pad0=UInt32(truncatingIfNeeded:nonce);k.pad1=UInt32(nonce>>32);k.csize=generation;return true
        }
        switch self {
        case let .arm(epoch,lifetime):
            guard epoch.0 != 0,epoch.1 != 0,lifetime.isFinite,(0.1...5).contains(lifetime) else{return nil}
            k.cpos=UInt32(CLOSE_ARM);k.x=Double(UInt32(truncatingIfNeeded:epoch.0));k.y=Double(UInt32(epoch.0>>32))
            k.w=Double(UInt32(truncatingIfNeeded:epoch.1));k.h=Double(UInt32(epoch.1>>32));k.dpos=lifetime
        case .disarm:k.cpos=UInt32(CLOSE_DISARM)
        case let .prepare(wid,nonce):guard identify(wid,nonce) else{return nil};k.cpos=UInt32(CLOSE_PREARM)
        case let .cancel(wid,nonce,generation):
            guard identify(wid,nonce,generation) else{return nil};k.cpos=UInt32(CLOSE_CANCEL)
        case let .release(wid,nonce,generation,batch,cohort):
            guard generation>0,batch != 0,(0...Int(CH_NW)).contains(cohort),identify(wid,nonce,generation) else{return nil}
            k.cpos=UInt32(CLOSE_RELEASE);k.x=Double(UInt32(truncatingIfNeeded:batch));k.y=Double(UInt32(batch>>32));k.w=Double(cohort)
        }
        return k
    }
}

extension LiveChannel {
    public var acceptedCloseSupported:Bool {raw.pointee.version&UInt32(CH_CAP_CLOSE) != 0}
    public func acceptedClose(_ command:AcceptedCloseCommand)->Bool {
        guard var packet=command.packet() else{return false};return hs_accepted_close(&packet)==0
    }
    public func acceptedClosePublication(_ releases:[AcceptedCloseCommand],geometry:[Int])->Bool {
        let packets=releases.compactMap{$0.packet()},ids=geometry.compactMap{UInt32(exactly:$0)}
        guard packets.count==releases.count,ids.count==geometry.count else {
            _=hs_accepted_close_batch(nil,0,nil,0);return false
        }
        return packets.withUnsafeBufferPointer {commands in ids.withUnsafeBufferPointer {windows in
            hs_accepted_close_batch(commands.baseAddress,UInt32(commands.count),windows.baseAddress,UInt32(windows.count))==0
        }}
    }
}

struct AcceptedCloseRow {
    let job:CfgJob,nonce:UInt64,started:Double
    var generation:UInt32=0,phase=0,lastRequest=0.0,lastReady=0.0
    var cancelling=false
}

extension WM {
    func acceptedCloseBatch(_ space:Int,rects:OrderedMap<Int,Rect>)->UInt64? {
        let held=acceptedCloseRows.filter{$0.value.phase==2 && !$0.value.cancelling && $0.value.job.expectedSpace==space && rects[$0.key]==nil}
        guard !held.isEmpty,eng.c.acceptedCloseSupported else{return nil}
        if let ready=ordinaryReadyNonce{return ready}
        let nonce=max(ordinaryNonce &+ 1,DispatchTime.now().uptimeNanoseconds)
        guard nonce>ordinaryNonce else{return nil};ordinaryNonce=nonce;return nonce
    }
    func releaseAcceptedClose(_ space:Int,rects:OrderedMap<Int,Rect>,batch:UInt64?,geometry:[Int])->Int {
        guard let batch else{return 0}
        let held=acceptedCloseRows.filter{$0.value.phase==2 && !$0.value.cancelling && $0.value.job.expectedSpace==space && rects[$0.key]==nil}
        guard !held.isEmpty else{return 0}
        let commands=held.sorted(by:{$0.key<$1.key}).map {wid,row in
            AcceptedCloseCommand.release(wid:wid,nonce:row.nonce,generation:row.generation,batch:batch,cohort:0)
        }
        guard eng.c.acceptedClosePublication(commands,geometry:geometry) else{return -1}
        for wid in held.keys {acceptedCloseRows[wid]?.phase=3}
        return 1
    }
    func stopAcceptedClose() {
        guard acceptedCloseArmed || !acceptedCloseRows.isEmpty else{return}
        if !eng.c.acceptedClose(.disarm) && eng.c.acceptedCloseSupported {
            acceptedCloseArmed=false
            for wid in acceptedCloseRows.keys {acceptedCloseRows[wid]?.cancelling=true}
            return
        }
        eng.c.commit()
        acceptedCloseRows.removeAll();acceptedCloseRetry.removeAll();acceptedCloseArmed=false;acceptedCloseHeartbeat=0
        acceptedCloseEpoch=(UInt64.random(in:1...UInt64.max),UInt64.random(in:1...UInt64.max))
    }
    func observeAcceptedClose(_ event:EngEvent)->Bool {
        guard let notice=AcceptedCloseNotice(event),var row=acceptedCloseRows[notice.wid],row.nonce==notice.nonce else{return false}
        if notice.generation != 0 && row.generation != 0 && notice.generation != row.generation{return false}
        switch notice.phase {
        case Int(CLOSE_E_READY):
            guard row.phase<=1 else{return false}
            row.generation=notice.generation;row.phase=1;row.lastReady=sys.now();acceptedCloseRows[notice.wid]=row
        case Int(CLOSE_E_HELD):
            guard row.phase<=2,notice.generation>0,let birth=row.job.birth,let space=row.job.expectedSpace,space>0,
                  sys.processBirth(row.job.pid)==birth || sys.processExited(row.job.pid) else{return false}
            row.generation=notice.generation;row.phase=2;acceptedCloseRows[notice.wid]=row
            closeDepartures[notice.wid]=CloseDeparture(pid:row.job.pid,birth:birth,space:space)
            lastSnap=0;return true
        case Int(CLOSE_E_RETIRED),Int(CLOSE_E_REFUSED):
            if notice.phase==Int(CLOSE_E_REFUSED) && row.phase>=2{return false}
            acceptedCloseRows[notice.wid]=nil;acceptedCloseRetry[notice.wid]=sys.now()+0.2
        default:break
        }
        return false
    }
    func acceptedCloseBindings(space:Int)->[Int:AcceptedCloseBinding] {
        guard acceptedCloseArmed,eng.c.acceptedCloseSupported else{return [:]}
        var result=[Int:AcceptedCloseBinding]();let now=sys.now()
        for (wid,row) in acceptedCloseRows where row.phase==1 && !row.cancelling && row.generation>0 && now-row.lastReady<1 {
            guard row.job.expectedSpace==space,let birth=row.job.birth,pids[wid]==row.job.pid,
                  sys.processBirth(row.job.pid)==birth,!hidden.contains(where:{$0.wid==wid}),!closing.contains(wid) else{continue}
            let marker=String(format:"HLC1:%016llx%016llx:%016llx%016llx:%016llx",
                acceptedCloseEpoch.0,acceptedCloseEpoch.1,row.nonce,UInt64(wid),UInt64(row.generation))
            result[wid]=AcceptedCloseBinding(pid:row.job.pid,birth:birth,space:space,nonce:row.nonce,generation:row.generation,marker:marker)
        }
        return result
    }
    func reconcileAcceptedClose(_ area:Rect,_ space:Int,_ windows:[WinInfo]) {
        let c=eng.c,now=sys.now()
        guard options.production,enabled,c.acceptedCloseSupported,c.ordinaryPrepareSupported,
              (cfg.anim("windowsOut").on || cfg.anim("fadeOut").on),dragSession==nil,ordinaryBatch==nil else {
            // A neighbor preparation may temporarily be in flight while an
            // accepted close already owns its immutable frame. Keep that row.
            if ordinaryBatch != nil && acceptedCloseArmed{return}
            stopAcceptedClose();return
        }
        var pending=false
        if !acceptedCloseArmed || now-acceptedCloseHeartbeat>=0.25 {
            if c.acceptedClose(.arm(epoch:acceptedCloseEpoch,lifetime:2)) {
                acceptedCloseArmed=true;acceptedCloseHeartbeat=now;pending=true
            }
        }
        guard acceptedCloseArmed else{return}
        acceptedCloseRetry=acceptedCloseRetry.filter{$0.value>now}
        let engine=Dictionary(c.wins().map{($0.wid,$0)},uniquingKeysWith:{$1})
        let tree=sp(space).tree;var eligible=[Int:(WinInfo,CfgJob)]()
        for window in windows where window.on && window.space==space && window.layer==0 && !window.nativeFullscreen {
            let wid=window.wid
            guard tree?.contains(wid)==true,!floating.contains(wid),!restoring.contains(wid),!closing.contains(wid),
                  !hidden.contains(where:{$0.wid==wid}),!nativeSuspendedWindows.contains(wid),!windowPolicy(window).noAnimation,
                  cfgSink?.busy(wid) != true,let slot=engine[wid],!slot.moving,slot.curAlpha==1,
                  let to=target[wid],to.maxDiff(slot.visible)<=1,var source=job(window.pid,wid,to),source.birth != nil else{continue}
            source.expectedSpace=space;eligible[wid]=(window,source)
        }
        for (wid,var row) in acceptedCloseRows {
            if !row.cancelling && row.phase>=2 {
                if row.job.expectedSpace==space && now-row.started<61 {continue}
            } else if !row.cancelling,let candidate=eligible[wid],candidate.1.pid==row.job.pid,candidate.1.birth==row.job.birth,
                      candidate.1.to==row.job.to,now-row.started<1 || row.phase==1 {continue}
            row.cancelling=true;acceptedCloseRows[wid]=row
            if now-row.lastRequest>=0.1 {
                let cancelled=c.acceptedClose(.cancel(wid:wid,nonce:row.nonce,generation:row.generation))
                let restored=c.ordinaryPrepare(wid,nonce:row.nonce,to:row.job.to,prepare:false)
                if cancelled || restored {row.lastRequest=now;acceptedCloseRows[wid]=row;pending=true}
            }
        }
        for (wid,candidate) in eligible where acceptedCloseRetry[wid]==nil {
            if acceptedCloseRows[wid]==nil {
                let nonce=max(acceptedCloseNonce &+ 1,DispatchTime.now().uptimeNanoseconds)
                guard nonce>acceptedCloseNonce else{continue};acceptedCloseNonce=nonce
                acceptedCloseRows[wid]=AcceptedCloseRow(job:candidate.1,nonce:nonce,started:now)
            }
            guard var row=acceptedCloseRows[wid],!row.cancelling,row.phase<2,now-row.lastRequest>=(row.phase==0 ? 0.04:0.25) else{continue}
            if c.acceptedClose(.prepare(wid:wid,nonce:row.nonce)) && c.ordinaryPrepare(wid,nonce:row.nonce,to:row.job.to,prepare:true) {
                row.lastRequest=now;acceptedCloseRows[wid]=row;pending=true
            }
        }
        if pending {c.commit()}
    }
}
