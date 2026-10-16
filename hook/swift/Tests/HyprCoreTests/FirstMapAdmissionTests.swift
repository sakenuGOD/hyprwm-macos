@testable import HyprCore
import XCTest

final class FirstMapAdmissionTests:XCTestCase {
    let area=Rect(0,30,1200,870)
    func layout(_ tree:JSON = .null,presel:String?=nil)->FirstMapLayout {
        FirstMapLayout(area:area,space:1,tree:tree,focus:tree["wid"]?.int,presel:presel,full:nil,fullmode:nil,cursor:(1100,400),minima:[:],
                       gapsIn:5,gapsOut:Gaps(top:8,right:12,bottom:12,left:12),splitWidthMult:1,defaultRatio:0.5,minimumPolicy:"native",rules:[],owners:[101:"Fixture"],ownerMinima:[:])
    }
    func gateway()->FirstMapAdmission {
        let gateway=FirstMapAdmission();gateway.makePresentationName={key,service in "hyprwm.admit.\(key.pid).\(key.wid).\(service)"};return gateway
    }
    func prepare(_ wid:Int=2,pid:Int=102,attempt:Int=1,now:Double=1,facts:[(String,JSON)]=[])->JSON {
        var values=[("normal",JSON.bool(true)),("resizable",.bool(true)),("panel",.bool(false)),("sheet",.bool(false)),("parent",.bool(false)),("modal",.bool(false)),("grouped",.bool(false)),("group_known",.bool(true)),("level",.int(0)),("title",.string("Fixture"))]
        for value in facts {values.removeAll{$0.0==value.0};values.append(value)}
        return .object([("schema",.int(1)),("transport",.string("fixture-uds-v1")),("op",.string("prepare")),
                        ("key",.object([("pid",.int(pid)),("launch",.string("native-launch")),("generation",.int(1)),("object",.int(wid)),("wid",.int(wid)),("attempt",.int(attempt))])),
                        ("deadline",.double(now+0.012)),("facts",.object(values)),("minimum",.array([.double(200),.double(150)]))])
    }
    func confirm(_ request:JSON,_ offer:JSON,now:Double=1.01)->JSON {
        .object([("schema",.int(1)),("transport",.string("fixture-uds-v1")),("op",.string("mapped")),("key",request["key"]!),
                 ("deadline",.double(now+0.012)),("lease",offer["lease"] ?? .null),("service",offer["service"]!),
                 ("revision",offer["revision"]!), ("actual",offer["rect"] ?? .null)])
    }
    func window(_ rect:Rect,wid:Int=2,pid:Int=102)->WinInfo {
        var window=WinInfo(wid:wid,pid:pid,owner:"Fixture",x:rect.x,y:rect.y,w:rect.w,h:rect.h,on:true,space:1);window.alpha=0;return window
    }
    func testNativeFirstMapPlansExactPreselectedTileBeforeMappedAdoption() throws {
        let gateway=gateway(),base=layout(Node(leaf:1).json,presel:"left");gateway.publish(base)
        let request=prepare(),offer=gateway.handle(request,now:1,pid:102,birth:"birth2",owner:"Fixture")
        XCTAssertEqual(offer["status"],.string("offer"));let rect=try XCTUnwrap(Rect.j(offer["rect"]))
        XCTAssertEqual(rect,Rect(12,38,583,850))
        let pending=gateway.reconcile(base,windows:[],now:1.001,valid:{_ in true})
        XCTAssertNil(pending.plan);XCTAssertEqual(pending.reserved,Set([2]))
        let mapped=gateway.handle(confirm(request,offer),now:1.01,pid:102,birth:"birth2",owner:"Fixture")
        XCTAssertEqual(mapped["status"],.string("mapped"))
        let batch=gateway.reconcile(base,windows:[window(rect)],now:1.02,valid:{$0.birth=="birth2"})
        XCTAssertEqual(batch.claims.count,1);XCTAssertEqual(batch.plan?.focus,2);XCTAssertNil(batch.plan?.presel)
        XCTAssertEqual(Node.from(batch.plan?.tree)?.a.wid,2);XCTAssertTrue(batch.reserved.isEmpty)
        XCTAssertNil(gateway.reconcile(base.adopting(batch.plan!),windows:[window(rect)],now:1.03,valid:{_ in true}).plan,"one mapped request is adopted once")
    }
    func testDialogsNativeTabsUnknownMembershipAndNumericBoolsCannotBeReserved() {
        let cases:[[(String,JSON)]] = [[("sheet",.bool(true))],[("modal",.bool(true))],[("parent",.bool(true))],[("panel",.bool(true))],[("grouped",.bool(true))],[("group_known",.bool(false))],[("normal",.int(1))],[("level",.int(21))]]
        for facts in cases {
            let gateway=gateway();gateway.publish(layout());let result=gateway.handle(prepare(facts:facts),now:1,pid:102,birth:"b",owner:"Fixture")
            XCTAssertNotEqual(result["status"],.string("offer"));XCTAssertTrue(gateway.claims(now:1).isEmpty)
        }
    }
    func testConstraintMismatchAndTopologyChangeRevokeOnlyPendingOffer() {
        let gateway=gateway(),base=layout();gateway.publish(base);let request=prepare()
        let offer=gateway.handle(request,now:1,pid:102,birth:"b",owner:"Fixture")
        let wrong=confirm(request,offer).setting("actual",.array([.double(0),.double(0),.double(50),.double(50)]))
        XCTAssertEqual(gateway.handle(wrong,now:1.01,pid:102,birth:"b",owner:"Fixture")["status"],.string("constraint-mismatch"))
        XCTAssertTrue(gateway.reconcile(base,windows:[],now:1.02,valid:{_ in true}).reserved.isEmpty)
        let next=prepare(attempt:2,now:1.02),nextOffer=gateway.handle(next,now:1.02,pid:102,birth:"b",owner:"Fixture")
        gateway.publish(layout(Node(leaf:9).json))
        XCTAssertEqual(gateway.handle(confirm(next,nextOffer,now:1.03),now:1.03,pid:102,birth:"b",owner:"Fixture")["status"],.string("stale"))
    }
    func testDeadPeerIncarnationCannotAdoptOrClaimOldMappedWindow() throws {
        let gateway=gateway(),base=layout();gateway.publish(base);let request=prepare(),offer=gateway.handle(request,now:1,pid:102,birth:"old",owner:"Fixture")
        _=gateway.handle(confirm(request,offer),now:1.01,pid:102,birth:"old",owner:"Fixture")
        let rect=try XCTUnwrap(Rect.j(offer["rect"])),batch=gateway.reconcile(base,windows:[window(rect)],now:1.02,valid:{_ in false})
        XCTAssertNil(batch.plan);XCTAssertTrue(batch.claims.isEmpty)
        var calls=0;gateway.signalClaim={_ in calls+=1;return true}
        let key=try XCTUnwrap(FirstMapKey(request["key"]!))
        XCTAssertFalse(gateway.claim(key,now:1.03,birth:"new"));XCTAssertEqual(calls,0)
    }
    func testPresentationAcknowledgedOnlyAfterActualEngineConsumptionAndNativeGeometry() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,original)=try f.world(Node(leaf:1)),gateway=gateway()
        wm.admission=gateway;let base=wm.admissionLayout(f.area,1,original);gateway.publish(base)
        let request=prepare(),offer=gateway.handle(request,now:1,pid:102,birth:"birth-2",owner:"Fixture")
        _=gateway.handle(confirm(request,offer),now:1.01,pid:102,birth:"birth-2",owner:"Fixture")
        let rect=try XCTUnwrap(Rect.j(offer["rect"])),new=window(rect)
        sys.t=1.02;sys.pidlevel[2]=(102,0);sys.births[102]="birth-2";sys.bounds[2]=rect
        let result=wm.reconcileAdmission(f.area,1,original+[new]);XCTAssertEqual(result.opened,[2]);wm.target[2]=rect
        wm.last=(f.area,1,original+[new]);var signals=0;gateway.signalClaim={_ in signals+=1;return true}
        eng.ch.ringPending=true;wm.claimAdmission([2]);XCTAssertEqual(signals,0)
        eng.ch.ringPending=false;wm.claimAdmission([]);XCTAssertEqual(signals,0,"same consumer tick is not a consumed publication")
        eng.ch.nativeTick+=1
        var slot=EngWin(wid:2,pos:(rect.x,rect.y),size:(rect.w,rect.h),a:rect);slot.geo=1;eng.ch.eng=[slot]
        sys.bounds[2]=Rect(rect.x+20,rect.y,rect.w,rect.h);wm.claimAdmission([]);XCTAssertEqual(signals,0)
        sys.bounds[2]=rect;wm.claimAdmission([]);XCTAssertEqual(signals,1)
        wm.claimAdmission([]);XCTAssertEqual(signals,1)
    }
    func testReadOnlyPreviewCannotPinAnActualFirstMapClientIncarnation() {
        let gateway=gateway();gateway.publish(layout())
        let request=prepare(),preview=request.setting("op",.string("preview")).setting("key",request["key"]!.setting("launch",.string("preview-only-source")))
        XCTAssertEqual(gateway.handle(preview,now:1,pid:102,birth:"b",owner:"Fixture")["status"],.string("preview"))
        XCTAssertFalse(gateway.needsReconcile)
        XCTAssertEqual(gateway.handle(request,now:1,pid:102,birth:"b",owner:"Fixture")["status"],.string("offer"))
    }
    func testExpiredDeadlineAndPeerPidMismatchNeverOffer() {
        let gateway=gateway();gateway.publish(layout())
        XCTAssertNotEqual(gateway.handle(prepare(),now:1.02,pid:102,birth:"b",owner:"Fixture")["status"],.string("offer"))
        XCTAssertNotEqual(gateway.handle(prepare(),now:1,pid:999,birth:"b",owner:"Fixture")["status"],.string("offer"))
    }
    func testCrowdedFirstMapOfferMatchesTheProductionAllocation() throws {
        let f=ProductionPolicyTests(),tree=Node(split:"v",ratio:0.02,a:Node(leaf:1),b:Node(leaf:2))
        tree.manualRatio=true
        let (wm,_,_,windows)=try f.world(tree)
        wm.sp(1).focus=1;wm.sp(1).presel="down"
        let layout=wm.admissionLayout(f.area,1,windows)
        let plan=try XCTUnwrap(layout.inserting(3,minimum:(200,150)))
        let state=SpaceState();state.tree=Node.from(plan.tree)
        XCTAssertEqual(plan.rect,wm.layout(f.area,state)[3],"The concealed first frame must use the same bounded slot as mapped tiling")
        XCTAssertEqual(wm.sp(1).tree?.json,tree.json,"Planning must not mutate the live tree")
    }
    func testFirstMapRemainsAvailableBesideRetainedFullscreenReturnSlot() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,original)=try f.world(f.pair()),gateway=gateway()
        wm.admission=gateway;wm.nativeFullscreenWindows=[1];wm.nativeSuspendedWindows=[];wm.sp(1).focus=2
        var windows=original;let owner=windows.firstIndex{$0.wid==1}!
        windows[owner].nativeFullscreen=true;windows[owner].space=99;windows[owner].on=false
        sys.activeSpaceID=1;sys.t=1;wm.lastSnap=1;wm.last=(f.area,1,windows)
        wm.publishAdmission()
        XCTAssertEqual(gateway.status["published"],.bool(true),"A settled fullscreen neighbour must not disable first-order placement")
        let request=prepare(3,pid:103),offer=gateway.handle(request,now:1,pid:103,birth:"birth-3",owner:"Fixture")
        XCTAssertEqual(offer["status"],.string("offer"))
        guard let rect=Rect.j(offer["rect"]) else{return}
        _=gateway.handle(confirm(request,offer),now:1.01,pid:103,birth:"birth-3",owner:"Fixture")
        let new=WinInfo(wid:3,pid:103,owner:"Fixture",x:rect.x,y:rect.y,w:rect.w,h:rect.h,on:true,space:1)
        sys.t=1.02;sys.pidlevel[3]=(103,0);sys.births[103]="birth-3";sys.bounds[3]=rect
        let admitted=wm.reconcileAdmission(f.area,1,windows+[new])
        XCTAssertEqual(admitted.opened,[3]);XCTAssertTrue(wm.sp(1).tree?.contains(1)==true)
        XCTAssertEqual(wm.layout(f.area,wm.sp(1))[3],rect,"The pre-order offer must equal the actual projected tile")
        XCTAssertFalse(wm.layout(f.area,wm.sp(1)).contains(1))
    }
    func testAdmissionWaitsWhileNativeFullscreenDepartureIsUnsettled() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair()),gateway=gateway()
        wm.admission=gateway;wm.last=(f.area,1,windows);wm.lastSnap=sys.now();sys.activeSpaceID=1
        wm.nativeFullscreenWindows=[1];wm.nativeSuspendedWindows=[]
        wm.nativeSuspendedSpaces=["1"]
        wm.publishAdmission()
        XCTAssertEqual(gateway.status["published"],.bool(false),"An unsettled fullscreen departure cannot authorize a first-map allocation")
        wm.nativeSuspendedSpaces=[];wm.publishAdmission()
        XCTAssertEqual(gateway.status["published"],.bool(true))
    }
}
