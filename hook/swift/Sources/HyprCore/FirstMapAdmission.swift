import Foundation

/// Immutable layout input. The socket worker never reads mutable WM state or calls AX.
public struct FirstMapLayout {
    public let area:Rect, space:Int, tree:JSON, focus:Int?, presel:String?, full:Int?, fullmode:String?
    public let cursor:(Double,Double), minima:[Int:(Double,Double)]
    public let gapsIn:Double, gapsOut:Gaps, splitWidthMult:Double, defaultRatio:Double, minimumPolicy:String
    public let rules:[JSON], owners:[Int:String],ownerMinima:[String:(Double,Double)]
    var topology:JSON {
        .object([("area",.array(area.arr.map(JSON.double))),("space",.int(space)),("tree",tree),
                 ("presel",presel.map(JSON.string) ?? .null),("full",full.map(JSON.int) ?? .null),
                 ("fullmode",fullmode.map(JSON.string) ?? .null),("gaps_in",.double(gapsIn)),
                 ("gaps_out",.array(gapsOut.values.map(JSON.double))),("split",.double(splitWidthMult)),
                 ("ratio",.double(defaultRatio)),("minimum_policy",.string(minimumPolicy)),
                 ("rules",.array(rules)),("owner_minima",.array(ownerMinima.keys.sorted().map{.array([.string($0),.double(ownerMinima[$0]!.0),.double(ownerMinima[$0]!.1)])})),("minima",.array(minima.keys.sorted().map { .array([.int($0),.double(minima[$0]!.0),.double(minima[$0]!.1)]) }))])
    }
    func inserting(_ wid:Int,minimum:(Double,Double)) -> FirstMapPlan? {
        let tree=Node.from(self.tree)
        guard tree?.contains(wid) != true else{return nil}
        let tile=Dwindle(gapsIn:gapsIn,gapsOut:gapsOut,splitWidthMult:splitWidthMult,defaultRatio:defaultRatio)
        tile.minimumPolicy=minimumPolicy;tile.mins=minima;tile.mins[wid]=minimum
        let target=focus.flatMap { tree?.contains($0)==true ? $0:nil }
        let boxes=tile.boxes(tree,area), inserted=tile.insert(tree,wid,target,area)
        var remaining=presel
        if target != nil,let parent=Dwindle.findParent(inserted,wid),parent.b.wid==wid {
            var first=false
            if let pre=presel,!pre.isEmpty {
                parent.split=(pre=="left" || pre=="right") ? "v":"h";first=pre=="left" || pre=="up";remaining=nil
            } else if let target,let box=boxes[target] {
                first=parent.split=="v" ? cursor.0<box.x+box.w/2:cursor.1<box.y+box.h/2
            }
            if first {swap(&parent.a,&parent.b)}
        }
        var rects=[Int:Rect]()
        for (id,box) in tile.boxes(inserted,area) {let r=tile.withGaps(box,area);rects[id]=Rect(pyRound(r.x),pyRound(r.y),pyRound(r.w),pyRound(r.h))}
        if let full,rects[full] != nil {
            if fullmode=="fullscreen" {rects[full]=area}
            else {rects[full]=Rect(area.x+gapsOut.left,area.y+gapsOut.top,area.w-gapsOut.left-gapsOut.right,area.h-gapsOut.top-gapsOut.bottom)}
        }
        guard let rect=rects[wid],rect.arr.allSatisfy({$0.isFinite && abs($0)<=65536}),rect.w>=1,rect.h>=1 else{return nil}
        return FirstMapPlan(tree:inserted.json,focus:wid,presel:remaining,rect:rect,minima:tile.mins)
    }
    func adopting(_ plan:FirstMapPlan) -> FirstMapLayout {
        FirstMapLayout(area:area,space:space,tree:plan.tree,focus:plan.focus,presel:plan.presel,full:full,fullmode:fullmode,
                       cursor:cursor,minima:plan.minima,gapsIn:gapsIn,gapsOut:gapsOut,splitWidthMult:splitWidthMult,
                       defaultRatio:defaultRatio,minimumPolicy:minimumPolicy,rules:rules,owners:owners,ownerMinima:ownerMinima)
    }
}
public struct FirstMapPlan {public let tree:JSON,focus:Int,presel:String?,rect:Rect,minima:[Int:(Double,Double)]}
public struct FirstMapKey:Equatable,Hashable {
    public let pid:Int,launch:String,generation:Int,object:Int,wid:Int,attempt:Int
    public var json:JSON {.object([("pid",.int(pid)),("launch",.string(launch)),("generation",.int(generation)),("object",.int(object)),("wid",.int(wid)),("attempt",.int(attempt))])}
    var objectKey:String {"\(pid):\(launch):\(generation):\(object)"}
    init?(_ json:JSON) {
        guard Set((json.object ?? []).map(\.0))==Set(["pid","launch","generation","object","wid","attempt"]),
              let launch=json["launch"]?.string,!launch.isEmpty,launch.count<=128 else{return nil}
        func integer(_ name:String)->Int? {guard case let .int(n)?=json[name],n>0 else{return nil};return n}
        guard let pid=integer("pid"),let generation=integer("generation"),let object=integer("object"),
              let wid=integer("wid"),let attempt=integer("attempt"),pid<=Int(Int32.max),wid<=Int(UInt32.max) else{return nil}
        self.pid=pid;self.launch=launch;self.generation=generation;self.object=object;self.wid=wid;self.attempt=attempt
    }
}
public struct FirstMapClaim {
    public let key:FirstMapKey,birth:String,lease:String,presentation:String,minimum:(Double,Double),plan:FirstMapPlan,space:Int
}
public struct FirstMapBatch {public let plan:FirstMapPlan?,claims:[FirstMapClaim],reserved:Set<Int>}

/// Same schema and leases as admission/protocol.py. One reservation writer under a short lock.
public final class FirstMapAdmission {
    public let service=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
    private let lock=NSLock()
    private var base:FirstMapLayout?,layout:FirstMapLayout?,revision=0
    private struct Pending {let key:FirstMapKey,birth:String,lease:String,presentation:String,deadline:Double,expires:Double,minimum:(Double,Double),plan:FirstMapPlan}
    private var pending:Pending?
    private var completed:[(FirstMapClaim,Double)]=[]
    private var handoffs:[Int:(FirstMapClaim,Double)]=[:]
    private var sources:[Int:(birth:String,launch:String,generation:Int)]=[:]
    private var sequences:[String:Int]=[:]
    private var admitted:[Int:(FirstMapKey,String)]=[:]
    private var claimTicks:[Int:Int]=[:]
    private var nativeMinima:[Int:(pid:Int,birth:String,value:(Double,Double))]=[:]
    public var signalClaim:((String)->Bool)?
    public var makePresentationName:((FirstMapKey,String)->String)?
    public init() {}
    public func suspend() {
        lock.lock();defer{lock.unlock()}
        base=nil;layout=nil;pending=nil;completed.removeAll();handoffs.removeAll();admitted.removeAll();claimTicks.removeAll();revision+=1
    }
    public func publish(_ snapshot:FirstMapLayout) {
        lock.lock();defer{lock.unlock()}
        if base?.topology != snapshot.topology {
            pending=nil;completed.removeAll();admitted.removeAll();layout=snapshot;revision+=1
        } else if pending==nil && completed.isEmpty {layout=snapshot}
        base=snapshot
    }
    public func handle(_ request:JSON,now:Double,pid:Int,birth:String,owner:String) -> JSON {
        lock.lock();defer{lock.unlock()}
        guard let key=FirstMapKey(request["key"] ?? .null) else{return .null}
        func reply(_ status:String,_ extra:[(String,JSON)]=[]) -> JSON {
            .object([("schema",.int(1)),("transport",.string("fixture-uds-v1")),("status",.string(status)),("key",key.json),
                     ("service",.string(service)),("revision",.int(revision))]+extra)
        }
        guard request["schema"] == .int(1),request["transport"]?.string=="fixture-uds-v1",key.pid==pid,
              let deadline=request["deadline"]?.double,deadline.isFinite,deadline>now,deadline-now<=0.100 else{return reply("expired")}
        guard let op=request["op"]?.string,["prepare","preview","mapped","cancel","closed"].contains(op) else{return reply("operation")}
        if pending.map({now >= $0.expires}) == true {pending=nil}
        if let source=sources[pid],source.birth != birth {
            sources[pid]=nil;sequences=sequences.filter{!$0.key.hasPrefix("\(pid):")}
            admitted=admitted.filter{$0.value.0.pid != pid};handoffs=handoffs.filter{$0.value.0.key.pid != pid};nativeMinima=nativeMinima.filter{$0.value.pid != pid}
            if completed.contains(where:{$0.0.key.pid==pid}) {completed.removeAll();pending=nil;layout=base;revision+=1}
            if pending?.key.pid==pid {pending=nil}
        }
        if op != "preview" {
            if let source=sources[pid],source.launch != key.launch || source.generation != key.generation {return reply("identity")}
            guard sources[pid] != nil || sources.count<4096 else{return reply("capacity")}
            sources[pid]=(birth,key.launch,key.generation)
        }
        guard let snapshot=layout,base != nil else{return reply("unmanaged")}
        if op=="prepare" || op=="preview" {
            guard let facts=request["facts"],facts.object != nil else{return reply("facts")}
            let names=["normal","resizable","panel","sheet","parent","modal","grouped","group_known"]
            guard names.allSatisfy({if case .bool?=facts[$0] {return true};return false}),
                  case let .int(level)?=facts["level"],let title=facts["title"]?.string,title.count<=512,
                  let minimum=request["minimum"]?.array,minimum.count==2,
                  minimum.allSatisfy({$0.double.map{$0.isFinite && $0>=0 && $0<=32768}==true}) else{return reply("facts")}
            var probe=WinInfo(wid:key.wid,pid:pid,owner:owner,name:title,x:0,y:0,w:1,h:1,on:true,space:snapshot.space)
            probe.layer=level
            var floated=false,ignored=false
            for rule in snapshot.rules where WindowProperties.matches(rule,probe) {
                if case let .bool(value)?=rule["ignore"] {ignored=value}
                if case let .bool(value)?=rule["float"] {floated=value}
            }
            guard facts["normal"] == .bool(true),facts["resizable"] == .bool(true),facts["group_known"] == .bool(true),level==0,
                  ["panel","sheet","parent","modal","grouped"].allSatisfy({facts[$0] == .bool(false)}),!floated,!ignored else{return reply("native")}
            if let owned=admitted[key.wid] {return reply(owned.0==key ? "already-admitted":"identity")}
            if let offer=pending,offer.key==key,op=="prepare" {return reply("offer",offerJSON(offer))}
            guard pending==nil else{return reply("busy")}
            if op=="prepare" {
                guard key.attempt>(sequences[key.objectKey] ?? 0),sequences.count<4096 || sequences[key.objectKey] != nil else{return reply("stale")}
                sequences[key.objectKey]=key.attempt
            }
            let cachedMinimum=snapshot.ownerMinima[owner] ?? (Dwindle.minW,Dwindle.minH)
            let mins=(max(minimum[0].double!,cachedMinimum.0),max(minimum[1].double!,cachedMinimum.1))
            guard let plan=snapshot.inserting(key.wid,minimum:mins) else{return reply("native")}
            guard let name=makePresentationName?(key,service) else{return reply("unmanaged")}
            let offer=Pending(key:key,birth:birth,lease:UUID().uuidString.replacingOccurrences(of:"-",with:""),presentation:name,
                              deadline:deadline,expires:now+0.250,minimum:mins,plan:plan)
            if op=="preview" {return reply("preview",[("rect",.array(plan.rect.arr.map(JSON.double))),("deadline",.double(deadline)),("epoch",.int(snapshot.space))])}
            pending=offer;return reply("offer",offerJSON(offer))
        }
        guard request["service"]?.string==service,let lease=request["lease"]?.string,!lease.isEmpty,lease.count<=128,
              case let .int(requestRevision)?=request["revision"] else{return reply("service")}
        if op=="closed" {
            guard let owned=admitted[key.wid],owned.0==key,owned.1==lease else{return reply("identity")}
            admitted[key.wid]=nil;handoffs[key.wid]=nil;nativeMinima[key.wid]=nil;completed.removeAll{$0.0.key.wid==key.wid};pending=nil
            return reply("closed")
        }
        guard let offer=pending,offer.key==key,offer.birth==birth,offer.lease==lease,requestRevision==revision else{return reply("stale")}
        if op=="cancel" {pending=nil;return reply("cancelled")}
        guard let actual=request["actual"]?.array,actual.count==4,actual.allSatisfy({$0.double?.isFinite==true}),
              zip(actual.compactMap(\.double),offer.plan.rect.arr).allSatisfy({abs($0.0-$0.1)<=1}) else{pending=nil;return reply("constraint-mismatch")}
        let claim=FirstMapClaim(key:key,birth:birth,lease:lease,presentation:offer.presentation,minimum:offer.minimum,plan:offer.plan,space:snapshot.space)
        nativeMinima[key.wid]=(pid,birth,offer.minimum)
        completed.append((claim,now));handoffs[key.wid]=(claim,now+0.5);admitted[key.wid]=(key,lease)
        layout=snapshot.adopting(offer.plan);revision+=1;pending=nil
        return reply("mapped")
    }
    private func offerJSON(_ offer:Pending)->[(String,JSON)] {
        [("lease",.string(offer.lease)),("deadline",.double(offer.deadline)),("expires",.double(offer.expires)),
         ("rect",.array(offer.plan.rect.arr.map(JSON.double))),("epoch",.int(layout!.space)),("presentation",.string(offer.presentation))]
    }
    public func reconcile(_ snapshot:FirstMapLayout,windows:[WinInfo],now:Double,valid:(FirstMapClaim)->Bool) -> FirstMapBatch {
        lock.lock();defer{lock.unlock()}
        if pending.map({now >= $0.expires})==true {pending=nil}
        if completed.contains(where:{now-$0.1>0.5 || !valid($0.0)}) {completed.removeAll();pending=nil;layout=base;revision+=1}
        let reserved=Set(completed.map{$0.0.key.wid}).union(pending.map{[$0.key.wid]} ?? [])
        guard let base,base.topology==snapshot.topology,!completed.isEmpty else{return FirstMapBatch(plan:nil,claims:[],reserved:reserved)}
        let live=Dictionary(windows.filter{$0.on && $0.space==snapshot.space}.map{($0.wid,$0)},uniquingKeysWith:{$1})
        guard completed.allSatisfy({live[$0.0.key.wid]?.pid==$0.0.key.pid && valid($0.0)}) else{return FirstMapBatch(plan:nil,claims:[],reserved:reserved)}
        let claims=completed.map(\.0),plan=claims.last!.plan;completed.removeAll();self.base=snapshot.adopting(plan)
        return FirstMapBatch(plan:plan,claims:claims,reserved:reserved.subtracting(claims.map{$0.key.wid}))
    }
    public func claims(now:Double)->[FirstMapClaim] {
        lock.lock();defer{lock.unlock()};handoffs=handoffs.filter{now<$0.value.1};claimTicks=claimTicks.filter{handoffs[$0.key] != nil};return handoffs.values.map(\.0)
    }
    public func claim(_ key:FirstMapKey,now:Double,birth:String)->Bool {
        lock.lock();defer{lock.unlock()}
        guard let handoff=handoffs[key.wid],handoff.0.key==key,handoff.0.birth==birth,now<handoff.1,
              signalClaim?(handoff.0.presentation)==true else{return false}
        handoffs[key.wid]=nil;claimTicks[key.wid]=nil;return true
    }
    public func minimum(_ wid:Int,pid:Int,birth:String?) -> (Double,Double)? {lock.lock();defer{lock.unlock()};guard let value=nativeMinima[wid],value.pid==pid,value.birth==birth else{return nil};return value.value}
    public var needsReconcile:Bool {lock.lock();defer{lock.unlock()};return pending != nil || !completed.isEmpty || !claimTicks.isEmpty}
    public var expectedSpace:Int? {lock.lock();defer{lock.unlock()};return base?.space}
    public func queueClaim(_ wid:Int,ticks:Int) {lock.lock();defer{lock.unlock()};if handoffs[wid] != nil && claimTicks[wid]==nil {claimTicks[wid]=ticks}}
    public func queuedTick(_ wid:Int)->Int? {lock.lock();defer{lock.unlock()};return claimTicks[wid]}
    public var status:JSON {lock.lock();defer{lock.unlock()};return .object([("service",.string(service)),("published",.bool(base != nil)),("pending",pending.map{.int($0.key.wid)} ?? .null),("waiting",.int(completed.count)),("handoffs",.int(handoffs.count))])}
}

extension WM {
    public func admissionLayout(_ area:Rect,_ space:Int,_ wins:[WinInfo]) -> FirstMapLayout {
        let state=sp(space);var minima=[Int:(Double,Double)]()
        for leaf in Dwindle.leaves(state.tree) {if let wid=leaf.wid {let values=mins[owner[wid] ?? ""] ?? [];let base=(values.first?.double ?? Dwindle.minW,values.dropFirst().first?.double ?? Dwindle.minH);if let pid=pids[wid],let accepted=admission?.minimum(wid,pid:pid,birth:sys.processBirth(pid)){minima[wid]=(max(base.0,accepted.0),max(base.1,accepted.1))}else{minima[wid]=base}}}
        return FirstMapLayout(area:area,space:space,tree:state.tree?.json ?? .null,focus:state.focus,presel:state.presel,full:state.full,fullmode:state.fullmode,
                              cursor:sys.mouse(),minima:minima,gapsIn:tile.gapsIn,gapsOut:tile.gapsOut,splitWidthMult:tile.splitWidthMult,
                              defaultRatio:tile.defaultRatio,minimumPolicy:tile.minimumPolicy,rules:cfg.raw["window_rules"]?.array ?? [],
                              owners:Dictionary(wins.map{($0.pid,$0.owner)},uniquingKeysWith:{$1}),
                              ownerMinima:Dictionary(mins.map{($0.0,($0.1.first?.double ?? Dwindle.minW,$0.1.dropFirst().first?.double ?? Dwindle.minH))},uniquingKeysWith:{$1}))
    }
    public func publishAdmission() {
        guard let admission else{return}
        guard options.production,enabled,let last,sys.now()-lastSnap<=0.3,sys.activeSpace()==UInt64(last.space),!sys.sessionLocked(),overviewFrozen?() != true,
              nativeSpaceType==0,dragSession==nil else{admission.suspend();return}
        admission.publish(admissionLayout(last.area,last.space,last.wins))
        claimAdmission([])
    }
    public func reconcileAdmission(_ area:Rect,_ space:Int,_ wins:[WinInfo])->(opened:[Int],reserved:Set<Int>) {
        guard options.production,let admission else{return([],[])}
        guard enabled,!sys.sessionLocked(),overviewFrozen?() != true,nativeSpaceType==0,dragSession==nil else{admission.suspend();return([],[])}
        let batch=admission.reconcile(admissionLayout(area,space,wins),windows:wins,now:sys.now()) {claim in
            !self.sys.protectedProcess(claim.key.pid) && self.sys.processBirth(claim.key.pid)==claim.birth &&
                self.sys.winPidLevel(claim.key.wid).pid==claim.key.pid && self.sys.winPidLevel(claim.key.wid).level==0
        }
        if let plan=batch.plan {
            let state=sp(space);state.tree=Node.from(plan.tree);state.focus=plan.focus;state.presel=plan.presel
            for claim in batch.claims {
                let key=claim.key;guard let window=wins.first(where:{$0.wid==key.wid && $0.pid==key.pid}) else{continue}
                pids[key.wid]=key.pid;owner[key.wid]=window.owner
                info[key.pid,default:[:]][key.wid]=WinTypeInfo(type:"primary",style:RESIZABLE,t:sys.now(),n:1)
                target[key.wid]=nil;deco.ensure(key.wid,window.owner,0)
            }
        }
        return(batch.claims.map{$0.key.wid},batch.reserved)
    }
    public func claimAdmission(_ posted:[Int]) {
        guard let admission else{return}
        for wid in posted {admission.queueClaim(wid,ticks:eng.c.stats.ticks)}
        guard !eng.c.pending,enabled,overviewFrozen?() != true,!sys.sessionLocked(),let last else{return}
        let slots=Dictionary(eng.c.wins().map{($0.wid,$0)},uniquingKeysWith:{$1})
        for claim in admission.claims(now:sys.now()) {
            let wid=claim.key.wid
            guard let tick=admission.queuedTick(wid),eng.c.stats.ticks>tick,last.space==claim.space,
                  sp(last.space).tree?.contains(wid)==true,!hidden.contains(where:{$0.wid==wid}),
                  let target=target[wid],let slot=slots[wid],slot.geo != 0,slot.real.maxDiff(target)<=1,
                  let native=sys.winBounds(wid),native.maxDiff(target)<=1,
                  sys.processBirth(claim.key.pid)==claim.birth,sys.winPidLevel(wid).pid==claim.key.pid,
                  sys.processBirth(claim.key.pid)==claim.birth else{continue}
            _=admission.claim(claim.key,now:sys.now(),birth:claim.birth)
        }
    }
}
