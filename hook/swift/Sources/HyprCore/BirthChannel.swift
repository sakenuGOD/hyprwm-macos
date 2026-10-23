import CChan
import Foundation

public enum BirthPhase:Int {
    case held=1, preparing, ready, presenting, revealed, cancelled, gone, conflict
}

public struct BirthNotice:Equatable {
    public let wid:Int, pid:Int, token:UInt64, phase:BirthPhase
    public init?(_ event:EngEvent) {
        func word(_ value:Double) -> UInt32? {
            guard value.isFinite,value>=0,value<=Double(UInt32.max),value.rounded()==value else{return nil}
            return UInt32(value)
        }
        guard event.type==Int(EV_BIRTH),event.wid>0,UInt32(exactly:event.wid) != nil,
              let low=word(event.rect.x),let high=word(event.rect.y),
              let pid=word(event.rect.w),pid>0,pid<=UInt32(Int32.max),
              let raw=word(event.rect.h),let phase=BirthPhase(rawValue:Int(raw)) else{return nil}
        let token=UInt64(low)|(UInt64(high)<<32)
        guard token != 0 else{return nil}
        self.wid=event.wid;self.pid=Int(pid);self.token=token;self.phase=phase
    }
}

public struct BirthClaim {
    public let wid:Int,token:UInt64,target:Rect,from:Rect
    public let positionCurve:Int,sizeCurve:Int,alphaCurve:Int
    public let positionDuration:Double,sizeDuration:Double,alphaDuration:Double
    public let opacity:Double,fromOpacity:Double
    public init(wid:Int,token:UInt64,target:Rect,from:Rect,positionCurve:Int,sizeCurve:Int,alphaCurve:Int,
                positionDuration:Double,sizeDuration:Double,alphaDuration:Double,opacity:Double,fromOpacity:Double=0) {
        self.wid=wid;self.token=token;self.target=target;self.from=from
        self.positionCurve=positionCurve;self.sizeCurve=sizeCurve;self.alphaCurve=alphaCurve
        self.positionDuration=positionDuration;self.sizeDuration=sizeDuration;self.alphaDuration=alphaDuration
        self.opacity=opacity;self.fromOpacity=fromOpacity
    }
}

public enum BirthCommand {
    case policy(epoch:UInt64,enabled:Bool)
    case prepare(wid:Int,token:UInt64,target:Rect)
    case claim(BirthClaim)
    case cancel(wid:Int,token:UInt64)
    case acknowledge(wid:Int,token:UInt64,phase:BirthPhase)
    case query

    func packet() -> ch_cmd? {
        var packet=ch_cmd();packet.op=UInt32(OP_BIRTH)
        func identify(_ wid:Int,_ token:UInt64) -> Bool {
            guard wid>0,let window=UInt32(exactly:wid),token != 0 else{return false}
            packet.wid=window;packet.pad0=UInt32(truncatingIfNeeded:token);packet.pad1=UInt32(token>>32)
            return true
        }
        func rectangle(_ r:Rect) -> Bool {[r.x,r.y,r.w,r.h].allSatisfy(\.isFinite) && r.w>=1 && r.h>=1}
        switch self {
        case let .policy(epoch,enabled):
            guard epoch != 0 else{return nil}
            packet.flags=UInt32(enabled ? BIRTH_ARM:BIRTH_DISARM)
            packet.pad0=UInt32(truncatingIfNeeded:epoch);packet.pad1=UInt32(epoch>>32);packet.x=0.5
        case let .prepare(wid,token,target):
            guard identify(wid,token),rectangle(target) else{return nil}
            packet.flags=UInt32(BIRTH_PREPARE)
            packet.x=target.x;packet.y=target.y;packet.w=target.w;packet.h=target.h
        case let .claim(claim):
            guard identify(claim.wid,claim.token),rectangle(claim.target),rectangle(claim.from),
                  [claim.positionCurve,claim.sizeCurve,claim.alphaCurve].allSatisfy({0...Int(CH_INSTANT) ~= $0}),
                  [claim.positionDuration,claim.sizeDuration,claim.alphaDuration].allSatisfy({$0.isFinite && $0>=0 && $0<=40}),
                  claim.opacity.isFinite,claim.fromOpacity.isFinite,0...1 ~= claim.opacity,0...1 ~= claim.fromOpacity else{return nil}
            packet.flags=UInt32(BIRTH_CLAIM)|UInt32(F_FROM)|UInt32(F_MOVE)|UInt32(F_STRETCH)
            packet.x=claim.target.x;packet.y=claim.target.y;packet.w=claim.target.w;packet.h=claim.target.h
            packet.fx=claim.from.x;packet.fy=claim.from.y;packet.fw=claim.from.w;packet.fh=claim.from.h
            packet.cpos=UInt32(claim.positionCurve);packet.csize=UInt32(claim.sizeCurve);packet.calpha=UInt32(claim.alphaCurve)
            packet.dpos=claim.positionDuration;packet.dsize=claim.sizeDuration;packet.dalpha=claim.alphaDuration
            packet.a=claim.opacity;packet.fa=claim.fromOpacity
        case let .cancel(wid,token):
            guard identify(wid,token) else{return nil};packet.flags=UInt32(BIRTH_CANCEL)
        case let .acknowledge(wid,token,phase):
            guard identify(wid,token) else{return nil};packet.flags=UInt32(BIRTH_ACK);packet.x=Double(phase.rawValue)
        case .query:packet.flags=UInt32(BIRTH_QUERY)
        }
        return packet
    }
}

extension LiveChannel {
    public var birthSupported:Bool {raw.pointee.version&UInt32(CH_CAP_BIRTH) != 0}
    public func birth(_ command:BirthCommand) -> Bool {
        guard birthSupported,var packet=command.packet() else{return false}
        return ch_birth(&packet)==0
    }
}
