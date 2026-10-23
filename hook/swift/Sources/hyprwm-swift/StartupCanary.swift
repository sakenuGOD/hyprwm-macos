import AppKit
import Darwin
import Foundation
import HyprCore

/// The helper owns the only window that startup is permitted to change.
enum StartupCanary {
    static func helper() -> Never {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        let window=NSWindow(contentRect:NSRect(x:40,y:80,width:208,height:150),
            styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.title="HyprWM startup check";window.isReleasedWhenClosed=false
        window.collectionBehavior=[.transient,.ignoresCycle];window.ignoresMouseEvents=true
        window.orderFront(nil)
        print(JSON.object([("pid",.int(Int(getpid()))),("wid",.int(window.windowNumber))]).dumps())
        FileHandle.standardInput.readabilityHandler={handle in
            if handle.availableData.isEmpty {DispatchQueue.main.async{window.close();app.terminate(nil)}}
        }
        let timeout=Timer.scheduledTimer(withTimeInterval:12,repeats:false){_ in window.close();app.terminate(nil)}
        withExtendedLifetime((window,timeout)){app.run()};exit(0)
    }

    static func check(sys:LiveSys,engine:LiveEngine,cfg:HyprConfig,snapshot:Snapshot) throws {
        let helper=Process(),input=Pipe(),output=Pipe()
        helper.executableURL=Bundle.main.executableURL ?? URL(fileURLWithPath:CommandLine.arguments[0])
        helper.arguments=["--startup-canary-helper"];helper.standardInput=input;helper.standardOutput=output
        helper.standardError=FileHandle.nullDevice
        try helper.run()
        defer {try? input.fileHandleForWriting.close();if helper.isRunning{helper.terminate()}}
        let fd=output.fileHandleForReading.fileDescriptor
        _=fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK)
        var bytes=Data();let readyDeadline=sys.now()+3
        while !bytes.contains(10),sys.now()<readyDeadline,helper.isRunning {
            var buffer=[UInt8](repeating:0,count:512);let n=read(fd,&buffer,buffer.count)
            if n>0 {bytes.append(contentsOf:buffer.prefix(n))}
            guard bytes.count<=1024 else{throw CmdError("startup canary response exceeded limit")}
            _=RunLoop.current.run(mode:.default,before:Date(timeIntervalSinceNow:0.01))
        }
        guard let newline=bytes.firstIndex(of:10),
              let row=try? JSON.parse(bytes.prefix(upTo:newline)),
              row["pid"]?.int==Int(helper.processIdentifier),let wid=row["wid"]?.int,wid>0,
              let birth=sys.processBirth(Int(helper.processIdentifier)) else{throw CmdError("startup canary identity unavailable")}
        let scoped=CanarySystem(sys:sys,pid:Int(helper.processIdentifier),wid:wid,birth:birth,space:snapshot.space)
        var mapped:WinInfo?
        let mapDeadline=sys.now()+2
        while sys.now()<mapDeadline,helper.isRunning,sys.processBirth(scoped.pid)==birth {
            if scoped.current,let fresh=try? scoped.snapshot(),fresh.stable,
               let row=fresh.windows.first(where:{$0.wid==wid && $0.pid==scoped.pid && $0.on && $0.space==snapshot.space}) {
                mapped=row;break
            }
            _=RunLoop.current.run(mode:.default,before:Date(timeIntervalSinceNow:0.01))
        }
        guard let own=mapped else{throw CmdError("startup canary missing from native map (wid \(wid), owner \(sys.winPidLevel(wid).pid ?? 0), active Space \(sys.activeSpace()))")}
        let channel=CanaryChannel(base:engine.c,scope:scoped)
        let probeEngine=CanaryEngine(base:engine,channel:channel)
        let absent=NSTemporaryDirectory()+"hyprwm-canary-"+UUID().uuidString
        let probe=WM(sys:scoped,eng:probeEngine,deco:NullDeco(),cfg:cfg,statePath:absent,minsizePath:absent+".mins")
        probe.saveEnabled=false;probe.options = .standard
        probe.tile.gapsIn=0;probe.tile.gapsOut=Gaps(top:0,right:0,bottom:0,left:0)
        probe.sp(snapshot.space).tree=Node(leaf:wid);probe.pids[wid]=scoped.pid;probe.owner[wid]=own.owner
        let classifyDeadline=sys.now()+2
        while probe.wmInfo(scoped.pid,wid)?.type != "primary",sys.now()<classifyDeadline,scoped.current {
            _=RunLoop.current.run(mode:.default,before:Date(timeIntervalSinceNow:0.02))
        }
        guard probe.wmInfo(scoped.pid,wid)?.type=="primary" else{throw CmdError("startup canary AX map/classification failed")}
        let target=Rect(min(snapshot.area.x+snapshot.area.w-272,max(snapshot.area.x+12,own.x+12)),
            min(snapshot.area.y+snapshot.area.h-214,max(snapshot.area.y+12,own.y+12)),max(240,own.w+32),max(180,own.h+24))
        var accepted=false
        let sink=Configurer(sys:scoped){result in DispatchQueue.main.async {
            accepted=result.e==0 && result.pid==scoped.pid && result.birth==birth &&
                result.isCurrent?()==true && result.got.map{$0.maxDiff(target)<=1}==true
            probe.cfgQ.append(result);_=probe.configured()
        }}
        probe.cfgSink=sink
        defer {sink.cancelAll()}
        probe.apply(target,snapshot.space,[own],force:true)
        let deadline=sys.now()+3;var previousTick:Int?,settled=0,passed=false
        while sys.now()<deadline,scoped.current {
            _=RunLoop.current.run(mode:.default,before:Date(timeIntervalSinceNow:0.01))
            guard accepted,sink.idle,!channel.pending,let pose=channel.wins().first,
                  !pose.moving,!pose.held,pose.visible.maxDiff(target)<=1,pose.real.maxDiff(target)<=1,
                  sys.winBounds(wid).map({$0.maxDiff(target)<=1})==true,
                  sys.activeSpace()==UInt64(snapshot.space) else{settled=0;continue}
            let tick=channel.stats.ticks
            if tick != previousTick {previousTick=tick;settled+=1}
            if settled>=2 {passed=true;break}
        }
        sink.cancelAll()
        let workerDeadline=sys.now()+1
        while !sink.idle,sys.now()<workerDeadline {_=RunLoop.current.run(mode:.default,before:Date(timeIntervalSinceNow:0.01))}
        if scoped.current {channel.forget(wid);channel.commit()}
        let releaseDeadline=sys.now()+1
        while (channel.pending || !channel.wins().isEmpty),sys.now()<releaseDeadline {
            _=RunLoop.current.run(mode:.default,before:Date(timeIntervalSinceNow:0.01))
        }
        guard sink.idle,!channel.pending,channel.wins().isEmpty else{throw CmdError("startup canary resources did not drain")}
        guard passed else{throw CmdError("startup canary did not reach its actual target rectangle")}
        // Exercise the same idle precondition that the real startup uses next.
        try engine.attachForCanary()
    }
}

private final class CanarySystem:SysAPI {
    let sys:LiveSys,pid:Int,wid:Int,birth:String,space:Int
    init(sys:LiveSys,pid:Int,wid:Int,birth:String,space:Int){self.sys=sys;self.pid=pid;self.wid=wid;self.birth=birth;self.space=space}
    var current:Bool {sys.processBirth(pid)==birth && sys.winPidLevel(wid).pid==pid && sys.activeSpace()==UInt64(space) && !sys.sessionLocked()}
    func owns(_ p:Int,_ w:Int)->Bool {p==pid && w==wid && current}
    func now()->Double{sys.now()};func sleep(_ s:Double){sys.sleep(s)}
    func snapshot()throws->Snapshot{var value=try sys.snapshot();value.windows=value.windows.filter{$0.pid==pid && $0.wid==wid};return value}
    func winPidLevel(_ w:Int)->(pid:Int?,level:Int?){w==wid ? sys.winPidLevel(w):(nil,nil)}
    func frontPid()->Int?{nil};func winBounds(_ w:Int)->Rect?{w==wid ? sys.winBounds(w):nil}
    func winAlpha(_ w:Int)->Double?{w==wid ? sys.winAlpha(w):nil}
    func moveToSpace(_ w:[Int],_ s:Int){};func activeSpace()->UInt64{sys.activeSpace()}
    func mouse()->(Double,Double){sys.mouse()};func mouseDown()->Bool{false}
    func axTileable(_ p:Int,_ w:Int)->Int{owns(p,w) ? sys.axTileable(p,w):-1}
    func axFrame(_ p:Int,_ w:Int,_ r:Rect)->Int{owns(p,w) ? sys.axFrame(p,w,r):-1}
    func axSize(_ p:Int,_ w:Int,_ x:Double,_ y:Double)->Int{owns(p,w) ? sys.axSize(p,w,x,y):-1}
    func axGetFrame(_ p:Int,_ w:Int)->Rect?{owns(p,w) ? sys.axGetFrame(p,w):nil}
    func axForget(_ w:Int){if w==wid{sys.axForget(w)}}
    func axFocus(_ p:Int,_ w:Int,raise:Bool)->Int{-1};func axMenuPress(_ p:Int,_ t:String)->Int{-1}
    func wsClose(_ p:Int,_ w:Int)->Int{-1};func wsQuit(_ p:Int)->Int{-1}
    func spotlight(){};func pgrep(_ s:String)->Int?{nil};func spawn(_ argv:[String]){}
    func background(_ f:@escaping()->Void){sys.background(f)}
    func processBirth(_ p:Int)->String?{p==pid ? sys.processBirth(p):nil}
    func protectedProcess(_ p:Int)->Bool{p != pid || !current}
    func windowOnSpace(_ p:Int,_ w:Int,_ s:Int)->Bool{owns(p,w) && s==space}
    func sessionLocked()->Bool{sys.sessionLocked()}
}

private final class CanaryChannel:ChannelAPI {
    let base:ChannelAPI,scope:CanarySystem
    init(base:ChannelAPI,scope:CanarySystem){self.base=base;self.scope=scope}
    func geom(_ w:Int,_ to:Rect,_ p:Int,_ s:Int,dpos:Double,dsize:Double,frm:Rect?,move:Bool,warp:Bool,stretch:Bool){
        if w==scope.wid && scope.current {base.geom(w,to,p,s,dpos:dpos,dsize:dsize,frm:frm,move:move,warp:warp,stretch:stretch)}
    }
    func configureNative(_ w:Int,_ r:Rect){if w==scope.wid && scope.current{base.configureNative(w,r)}}
    func alpha(_ w:Int,_ a:Double,_ c:Int,_ d:Double,frm:Double?){if w==scope.wid && scope.current{base.alpha(w,a,c,d,frm:frm)}}
    func under(_ w:Int,_ u:Int){};func forget(_ w:Int){if w==scope.wid && scope.current{base.forget(w)}}
    func commit(){base.commit()};func events()->[EngEvent]{[]}
    func wins()->[EngWin]{base.wins().filter{$0.wid==scope.wid}}
    var stats:EngStats{base.stats};var pending:Bool{base.pending}
    var widMax:Int{get{base.widMax}set{}}
}

private final class CanaryEngine:EngineAPI {
    let base:LiveEngine,channel:CanaryChannel
    init(base:LiveEngine,channel:CanaryChannel){self.base=base;self.channel=channel}
    var c:ChannelAPI{channel};func anim(_ leaf:String)->(curve:Int,dur:Double,on:Bool){base.anim(leaf)}
    func alive()->Bool{base.alive()};func ensure(startup:Bool)throws{}
}
