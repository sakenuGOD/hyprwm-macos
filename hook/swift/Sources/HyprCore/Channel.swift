// Daemon -> engine channel: port of chan.py over hook/src/chanlib.c (the same code Python loads through
// ctypes). Structures come from hook/src/chan.h via CChan; no manual duplicates.
// WARNING: chanlib.c keeps one channel per process (static ch), as in Python.
import CChan
import Foundation

public enum ChannelCapabilities {
    public static let mask=UInt32(CH_CAP_EFFECTS)|UInt32(CH_CAP_SHADOW)|UInt32(CH_CAP_SNAPSHOT)|UInt32(CH_CAP_SNAPSHOT_COVER)|UInt32(CH_CAP_TERMINAL_MOVE)|UInt32(CH_CAP_BIRTH)|UInt32(CH_CAP_ORDINARY_PREPARE)|UInt32(CH_CAP_VIEWPORT)|UInt32(CH_CAP_CLOSE)
    public static func abi(_ version:UInt32) -> UInt32 { version & ~mask }
}

public final class LiveChannel: ChannelAPI {
    public let path: String
    public let base: UnsafeMutableRawPointer
    let hdr: UnsafeMutablePointer<ch_hdr>
    let winArr: UnsafeMutablePointer<ch_win>
    private var fullLogged = false

    /// create=true creates a NEW file (O_EXCL inside ch_open); otherwise attach to an existing file.
    public init(path: String, create: Bool) throws {
        guard let p = ch_open(path, create ? 1 : 0) else {
            throw CmdError("cannot open \(path)")
        }
        // chan.py asserts that Python structures match chan.h; here the structures ARE chan.h, so verify
        // only that Swift sees the same sizes as the C compiler.
        guard MemoryLayout<ch_win>.stride == Int(ch_off(0)), MemoryLayout<ch_var>.stride == Int(ch_off(3)),
              MemoryLayout<ch_hdr>.stride == Int(ch_off(7)) else {
            throw CmdError("chan.h: Swift and C structure sizes differ")
        }
        self.path = path
        base = p
        hdr = p.assumingMemoryBound(to: ch_hdr.self)
        winArr = (p + Int(ch_off(1))).assumingMemoryBound(to: ch_win.self)
    }

    public var magicOK: Bool { hdr.pointee.magic == CH_MAGIC }
    public var sizeOK: Bool { hdr.pointee.size == ch_abi() }
    public var ticks: UInt32 { hdr.pointee.ticks }
    public var engineTime:Double { hdr.pointee.now }
    public var snapshotBatchTime:Double {
        let header=hdr.pointee
        return NativeBatchClock.lowerBound(now:header.now,presentation:header.te,period:header.period)
    }
    public func setStop() { hdr.pointee.stop = 1 }
    public var raw: UnsafeMutablePointer<ch_hdr> { hdr }
    public func curvesCompatible(_ configuration:HyprConfig) -> Bool {
        let scale=configuration.timeScale
        return configuration.sortedCurves().enumerated().allSatisfy { index,entry in
            guard index<Int(CH_NCURVE) else{return false}
            switch entry.1 {
            case let .spring(mass,k,d):return hs_curve_compatible(UInt32(index),UInt32(CV_SPRING),mass,k/(scale*scale),d/scale,0)==1
            case let .bezier(p1,p2):return hs_curve_compatible(UInt32(index),UInt32(CV_BEZIER),p1.0,p1.1,p2.0,p2.1)==1
            }
        }
    }

    public struct CurveBootstrap {
        fileprivate let mapping:UnsafeMutableRawPointer
        fileprivate let records:[ch_curve]
        fileprivate let count:UInt32
        fileprivate let device:UInt64
        fileprivate let inode:UInt64
    }

    public func bootstrapPristineCurves(_ configuration:HyprConfig) throws -> CurveBootstrap? {
        if curvesCompatible(configuration) {return nil}
        let curves=configuration.sortedCurves(),scale=configuration.timeScale
        guard !curves.isEmpty,curves.count<=Int(CH_NCURVE),scale.isFinite,scale>0 else {
            throw CmdError("invalid startup animation curves")
        }
        var records=[ch_curve](repeating:ch_curve(),count:Int(CH_NCURVE))
        for (index,entry) in curves.enumerated() {
            let valid:Int32
            switch entry.1 {
            case let .spring(mass,k,d):valid=hs_curve_record(&records[index],UInt32(CV_SPRING),mass,k/(scale*scale),d/scale,0)
            case let .bezier(p1,p2):valid=hs_curve_record(&records[index],UInt32(CV_BEZIER),p1.0,p1.1,p2.0,p2.1)
            }
            guard valid==1 else {throw CmdError("invalid startup animation curve: \(entry.0)")}
        }
        let attributes=try FileManager.default.attributesOfItem(atPath:path)
        guard let device=attributes[.systemNumber] as? NSNumber,let inode=attributes[.systemFileNumber] as? NSNumber else {
            throw CmdError("engine channel file identity unavailable")
        }
        guard records.withUnsafeBufferPointer({hs_curves_bootstrap(base,$0.baseAddress,UInt32(curves.count))})==1 else {
            throw CmdError("existing engine curves differ or channel is not pristine; adoption refused")
        }
        return CurveBootstrap(mapping:base,records:records,count:UInt32(curves.count),device:device.uint64Value,inode:inode.uint64Value)
    }

    public func rollbackCurves(_ token:CurveBootstrap) throws {
        let attributes=try FileManager.default.attributesOfItem(atPath:path)
        guard token.mapping==base,(attributes[.systemNumber] as? NSNumber)?.uint64Value==token.device,
              (attributes[.systemFileNumber] as? NSNumber)?.uint64Value==token.inode,
              token.records.withUnsafeBufferPointer({hs_curves_rollback(base,$0.baseAddress,token.count)})==1 else {
            throw CmdError("startup curve rollback refused: channel changed or check resources remain")
        }
    }

    private func full() {
        if !fullLogged { log("command ring full (engine is not consuming)") }
        fullLogged = true
    }

    // Commands
    public var viewportSupported:Bool {hdr.pointee.version & UInt32(CH_CAP_VIEWPORT) != 0}
    public func viewport(_ wid:Int,nonce:UInt64,offset:(Double,Double),box:Rect,enabled:Bool) -> Bool {
        hs_viewport(UInt32(wid),nonce,enabled ? 1:0,offset.0,offset.1,box.x,box.y,box.w,box.h)==0
    }
    public var ordinaryPrepareSupported:Bool {hdr.pointee.version & UInt32(CH_CAP_ORDINARY_PREPARE) != 0}
    public func ordinaryPrepare(_ wid:Int,nonce:UInt64,to:Rect,prepare:Bool) -> Bool {
        hs_ordinary_prepare(UInt32(wid),nonce,prepare ? 1:0,to.x,to.y,to.w,to.h)==0
    }
    public var terminalGeometrySupported:Bool {hdr.pointee.version & UInt32(CH_CAP_TERMINAL_MOVE) != 0}
    public func geomTerminal(_ wid:Int,to:Rect,curves:(Int,Int),durations:(Double,Double),from:Rect?) -> Bool {
        guard terminalGeometrySupported else{return false}
        let flags=UInt32(F_MOVE_END)|(from != nil ? UInt32(F_FROM):0),initial=from ?? Rect(0,0,0,0)
        let result=ch_geom(Int32(OP_GEOM),UInt32(wid),flags,to.x,to.y,to.w,to.h,initial.x,initial.y,initial.w,initial.h,
            UInt32(curves.0),UInt32(curves.1),durations.0,durations.1)
        if result != 0 {full();return false}
        fullLogged=false;return true
    }
    public func geom(_ wid: Int, _ to: Rect, _ cpos: Int, _ csize: Int, dpos: Double, dsize: Double, frm: Rect?,
                     move: Bool, warp: Bool, stretch: Bool) {
        let fl = (frm != nil ? UInt32(F_FROM) : 0) | (move ? UInt32(F_MOVE) : 0) | (stretch ? UInt32(F_STRETCH) : 0)
        let f = frm ?? Rect(0, 0, 0, 0)
        // DIFFERENCE: Python raised RuntimeError when the ring was full (crashing the daemon in the main loop);
        // here we log and drop the command (the engine is dead anyway; the alive() watchdog reinstalls it).
        if ch_geom(Int32(warp ? OP_WARP : OP_GEOM), UInt32(wid), fl, to.x, to.y, to.w, to.h, f.x, f.y, f.w, f.h,
                   UInt32(cpos), UInt32(csize), dpos, dsize) != 0 { full() } else { fullLogged = false }
    }

    public func alpha(_ wid: Int, _ a: Double, _ curve: Int, _ dur: Double, frm: Double?) {
        if ch_alpha(UInt32(wid), frm != nil ? UInt32(F_FROM) : 0, a, frm ?? 0, UInt32(dur <= 0 ? Int(CH_INSTANT) : curve), dur) != 0 { full() }
    }

    public func geometry(_ wid: Int,to: Rect,curves: (Int,Int),durations: (Double,Double),from: Rect?,warp: Bool,stretch: Bool,native: Bool,wait: Bool,hold: Bool) {
        let flags: UInt32=(from != nil ? UInt32(F_FROM) : 0)|UInt32(F_MOVE)|(stretch ? UInt32(F_STRETCH) : 0)|(native ? UInt32(F_NATIVE) : 0)|(wait ? UInt32(F_WAIT) : 0)|(hold ? UInt32(F_HOLD) : 0)
        let initial=from ?? Rect(0,0,0,0)
        if ch_geom(Int32(warp ? OP_WARP : OP_GEOM),UInt32(wid),flags,to.x,to.y,to.w,to.h,initial.x,initial.y,initial.w,initial.h,
            UInt32(curves.0),UInt32(curves.1),durations.0,durations.1) != 0 { full() }
    }
    public func configureNative(_ wid: Int, _ frame: Rect) { if ch_cfg(UInt32(wid),frame.x,frame.y,frame.w,frame.h) != 0 { full() } }
    public func streamGeometry(_ wid:Int,to:Rect,curves:(Int,Int),durations:(Double,Double),from:Rect?,hold:Bool) -> Bool {
        let initial=from ?? Rect(0,0,0,0)
        let flags=UInt32(F_MOVE)|UInt32(F_NATIVE)|UInt32(F_STREAM)|(from != nil ? UInt32(F_FROM):0)|(hold ? UInt32(F_HOLD):0)
        guard ch_geom(Int32(OP_GEOM),UInt32(wid),flags,to.x,to.y,to.w,to.h,initial.x,initial.y,initial.w,initial.h,
                      UInt32(curves.0),UInt32(curves.1),durations.0,durations.1)==0 else {full();return false}
        fullLogged=false;return true
    }
    public func configureStreamProbe(_ wid:Int,_ frame:Rect) -> Bool {
        guard ch_cfg_flags(UInt32(wid),UInt32(F_STREAM),frame.x,frame.y,frame.w,frame.h)==0 else {full();return false}
        fullLogged=false;return true
    }
    /// Native springs stop by displacement/velocity thresholds, independently
    /// of dur. Bound a spring starting at rest; callers reject moving retargets.
    public func streamMotionHorizon(curve:Int,duration:Double,from:Rect,to:Rect,minimum:(Double,Double),hold:Bool) -> Double? {
        guard curve>=0,curve<Int(CH_NCURVE),duration.isFinite,duration>0,
              from.arr.allSatisfy({$0.isFinite}),to.arr.allSatisfy({$0.isFinite}),minimum.0>0,minimum.1>0 else{return nil}
        let records=(base + MemoryLayout<CChan.ch>.offset(of:\CChan.ch.curve)!).assumingMemoryBound(to:ch_curve.self)
        let record=records[curve],header=hdr.pointee
        guard header.hold_max.isFinite,(-1.0...2.0).contains(header.hold_max),header.period.isFinite,
              header.period>0,header.period<=0.1 else{return nil}
        var lifetime=duration,lower=0.0,upper=1.0
        if record.type==UInt32(CV_SPRING) {
            guard record.mass.isFinite,record.k.isFinite,record.d.isFinite,record.d>0 else{return nil}
            let mass=max(0.0001,record.mass),stiffness=max(0.0001,record.k)
            let omega=sqrt(stiffness/mass),gamma=record.d/(2*mass),epsilon=0.00025
            guard omega.isFinite,gamma.isFinite,omega>0,gamma>0 else{return nil}
            if gamma<omega {
                let frequency=sqrt(omega*omega-gamma*gamma)
                guard frequency.isFinite,frequency>0 else{return nil}
                let amplitude=max(hypot(1,gamma/frequency),omega*omega/frequency)
                lifetime=max(lifetime,log(max(1,amplitude/epsilon))/gamma)
                upper=1+exp(-gamma*Double.pi/frequency)
            } else if abs(gamma-omega)<=max(omega,1)*0.0001 {
                // t*exp(-g*t) <= 2/(g*e)*exp(-g*t/2).
                let amplitude=max(1+2/exp(1),2*gamma/exp(1))
                lifetime=max(lifetime,2*log(max(1,amplitude/epsilon))/gamma)
            } else {
                let root=sqrt(gamma*gamma-omega*omega),slow = -gamma+root,fast = -gamma-root
                guard root.isFinite,slow<0,fast<slow else{return nil}
                let a=fast/(slow-fast),b = -1-a
                let amplitude=max(abs(a)+abs(b),abs(a*slow)+abs(b*fast))
                lifetime=max(lifetime,log(max(1,amplitude/epsilon))/(-slow))
            }
        } else if record.type==UInt32(CV_BEZIER) {
            let samples=withUnsafeBytes(of:record.by){Array($0.bindMemory(to:Double.self))}
            let xs=withUnsafeBytes(of:record.bx){Array($0.bindMemory(to:Double.self))}
            guard samples.count>=2,xs.count==samples.count,samples.allSatisfy({$0.isFinite}),
                  xs.allSatisfy({$0.isFinite && $0>=0 && $0<=1}),zip(xs,xs.dropFirst()).allSatisfy({$0.0<=$0.1}) else{return nil}
            lower=min(0,samples.min() ?? 0);upper=max(1,samples.max() ?? 1)
            // The native evaluator extrapolates its first baked segment for
            // 0<x<bx[0]; the table itself omits t=0.
            let dx=xs[1]-xs[0]
            if dx>0.000001 {
                let intercept=samples[0]-xs[0]*(samples[1]-samples[0])/dx
                guard intercept.isFinite else{return nil}
                lower=min(lower,intercept);upper=max(upper,intercept)
            }
        } else {return nil}
        // Every interpolated sample must satisfy the receiver's actual minimum,
        // including an underdamped shrink's first overshoot and Bezier overshoot.
        func smallest(_ start:Double,_ goal:Double) -> Double {
            min(start+(goal-start)*lower,start+(goal-start)*upper)
        }
        let minWidth=smallest(from.w,to.w),minHeight=smallest(from.h,to.h)
        guard minWidth>=1,minHeight>=1,minWidth+0.01>=minimum.0,minHeight+0.01>=minimum.1 else{return nil}
        let horizon=max(duration+0.25,lifetime+(hold ? max(0.15,header.hold_max):0)+1+0.5)
        guard horizon.isFinite,horizon<=30 else{return nil};return horizon
    }
    public var snapshotSupported:Bool {
        let required=UInt32(CH_CAP_SNAPSHOT)|UInt32(CH_CAP_SNAPSHOT_COVER)
        return (hdr.pointee.version & required) == required
    }
    public func snapshotGeometry(_ wid:Int,to:Rect,curves:(Int,Int),durations:(Double,Double),from:Rect?) -> Bool {
        let initial=from ?? Rect(0,0,0,0),flags=from != nil ? UInt32(F_FROM) : 0
        return hs_snapshot_final(UInt32(wid),flags,to.x,to.y,to.w,to.h,initial.x,initial.y,initial.w,initial.h,
            UInt32(curves.0),UInt32(curves.1),durations.0,durations.1) == 0
    }
    public func space(_ wid: Int, _ sid: Int) { if ch_space(UInt32(wid), UInt64(sid)) != 0 { full() } }
    public func under(_ wid: Int, _ under: Int) { _ = ch_under(UInt32(wid), UInt32(under)) }
    public func forget(_ wid: Int) { _ = ch_forget(UInt32(wid)) }
    public func raise(_ wid:Int) { if ch_raise(UInt32(wid),0) != 0 {full()} }
    public func commit() { ch_commit() }

    // Curves
    public func bezier(_ i: Int, _ p1: (Double, Double), _ p2: (Double, Double)) {
        ch_curve_bezier(Int32(i), Float(p1.0), Float(p1.1), Float(p2.0), Float(p2.1))
    }
    public func spring(_ i: Int, _ mass: Double, _ k: Double, _ d: Double) { ch_curve_spring(Int32(i), mass, k, d) }

    // State
    public func events() -> [EngEvent] {
        var out: [EngEvent] = []
        var e = ch_evt()
        while ch_event(&e) != 0 {
            out.append(EngEvent(type: Int(e.type), wid: Int(e.wid), t: e.t, rect: Rect(e.x, e.y, e.w, e.h)))
        }
        return out
    }

    public func wins() -> [EngWin] {
        var out: [EngWin] = []
        for i in 0..<Int(CH_NW) {
            let w = winArr[i]
            if w.used == 0 { continue }
            var window=EngWin(wid: Int(w.wid), pos: (w.pos.v.0, w.pos.v.1), size: (w.size.v.0, w.size.v.1),
                              posActive: w.pos.active != 0, sizeActive: w.size.active != 0,
                              alphaActive: w.alpha.active != 0, settling: w.settling != 0, curAlpha: w.cur_alpha,
                              held: w.held != 0, radius: w.radius, a: Rect(w.ax, w.ay, w.aw, w.ah))
            window.geo=Int(w.geo);out.append(window)
        }
        return out
    }

    public var stats: EngStats {
        let h = hdr.pointee
        var s = EngStats()
        s.holding = Int(h.holding)
        s.ticks = Int(h.ticks); s.nactive = Int(h.nactive); s.errors = Int(h.errors)
        s.ticksLate = Int(h.ticks_late); s.teSkips = Int(h.te_skips)
        s.tickUsMax = h.tick_us_max; s.tickUsLast = h.tick_us_last
        return s
    }

    static let offTail = MemoryLayout<ch_hdr>.offset(of: \ch_hdr.cmd_tail)!
    static let offHead = MemoryLayout<ch_hdr>.offset(of: \ch_hdr.cmd_head)!
    public var pending: Bool {
        // The engine writes cmd_tail; we write cmd_head. Read shared memory on every call.
        base.load(fromByteOffset: LiveChannel.offTail, as: UInt32.self) !=
            base.load(fromByteOffset: LiveChannel.offHead, as: UInt32.self)
    }

    public var widMax: Int {
        get { Int(hdr.pointee.wid_max) }
        set { hdr.pointee.wid_max = UInt32(truncatingIfNeeded: newValue) }
    }
}


extension LiveChannel {
    public func decorationFocus(_ wid: Int, fullscreen: Int) {
        let channel=base.assumingMemoryBound(to: CChan.ch.self)
        channel.pointee.deco.focus=UInt32(max(0,wid)); channel.pointee.deco.nofull=UInt32(max(0,fullscreen))
    }
    /// Writes the public legacy decoration carrier and capability-gated GPU effect packets.
    /// No new capabilities are advertised by this writer.
    public func configureAppearance(_ config: HyprConfig) throws {
        let appearance=try Appearance(config), channel=base.assumingMemoryBound(to: CChan.ch.self)
        var decoration=channel.pointee.deco
        func copy<T>(_ values: [Double], _ tuple: inout T) {
            withUnsafeMutableBytes(of: &tuple) { raw in
                let target=raw.bindMemory(to:Double.self)
                for index in 0..<min(target.count,values.count) { target[index]=values[index] }
            }
        }
        let border=config.anim("border"), shadow=config.anim("fadeShadow")
        decoration.ngrad=8
        copy(appearance.gradient.flatMap(\.values), &decoration.grad)
        copy(appearance.inactive.values, &decoration.inact)
        copy(appearance.endpoints.0, &decoration.start); copy(appearance.endpoints.1, &decoration.end)
        decoration.width=appearance.width; decoration.radius=appearance.radius
        decoration.curve=UInt32(border.curve); decoration.dur=border.on ? border.dur : 0
        decoration.sh_on=appearance.shadowOn ? 1 : 0; decoration.srad=appearance.shadowRange/3.1
        decoration.soff=appearance.shadowOffset.1; decoration.sop_act=appearance.shadowActive.a; decoration.sop_in=appearance.shadowInactive.a
        decoration.scurve=UInt32(shadow.curve); decoration.sdur=shadow.on ? shadow.dur : 0
        decoration.sys_off=3; decoration.inset10=10
        for (leaf, isBorder) in [("border",true),("fadeShadow",false)] {
            let curve=config.curves()[config.animation(leaf).curve]
            let points: [Double]
            if case let .bezier(p1,p2)?=curve { points=[p1.0,p1.1,p2.0,p2.1] } else { points=[0.25,1,0.5,1] }
            if isBorder { copy(points,&decoration.bez) } else { copy(points,&decoration.sbez) }
        }
        decoration.on=appearance.width > 0 ? 1 : 0
        channel.pointee.deco=decoration
        let close=config.anim("windowsOut"), fade=config.anim("fadeOut")
        let closeScale=config.animation("windowsOut").style == "fade" ? 1 : (config.popin("windowsOut") ?? 0)
        var flags: UInt64=3 | UInt64(close.on ? close.curve : Int(CH_INSTANT))<<8 | UInt64(fade.on ? fade.curve : Int(CH_INSTANT))<<16
        if config.raw["config"]?["animations"]?["enabled"]?.truthy == false { flags |= 1<<24 }
        if config.raw["runtime"]?["window_resize_mode"]?.string == "buffer" { flags |= 1<<25 }
        hdr.pointee.reserved.0=flags
        hdr.pointee.reserved.1=(close.on ? close.dur : 0).bitPattern
        hdr.pointee.reserved.2=(fade.on ? fade.dur : 0).bitPattern
        hdr.pointee.reserved.3=closeScale.bitPattern
        if hdr.pointee.version & UInt32(CH_CAP_EFFECTS) != 0 {
            let glow=config.anim("fadeGlow"), disabled=config.raw["config"]?["animations"]?["enabled"]?.truthy == false
            let values=appearance.effectsPacket(glow.on ? glow.dur : 0)
            let flags: UInt32=1 | (appearance.glowOn ? 2 : 0) | (disabled ? 4 : 0)
            let result=values.withUnsafeBufferPointer { ch_effects(flags,UInt32(glow.curve),$0.baseAddress) }
            if result != 0 { throw CmdError("native effects command ring unavailable") }
        }
        if hdr.pointee.version & UInt32(CH_CAP_SHADOW) != 0 {
            let values=appearance.exactShadow ? appearance.shadowPacket : [1,3,1,0,0,0,0,0,0,0,0,0,0]
            let flags: UInt32=appearance.shadowOn && appearance.exactShadow ? 1 : 0
            let result=values.withUnsafeBufferPointer { ch_shadow(flags,UInt32(shadow.curve),shadow.on ? shadow.dur : 0,$0.baseAddress) }
            if result != 0 { throw CmdError("native shadow command ring unavailable") }
        }
        commit()
    }
}
