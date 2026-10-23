@testable import HyprCore
import XCTest

final class RestorePlacementTests:XCTestCase {
    func testConfigureReceiptSurvivesLauncherOverlayUntilSelectionCompletes() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair())
        wm.cfgSink=SnapshotHandoffTests.Recorder();wm.sp(1).tree=Node(leaf:2)
        sys.front=101;sys.contexts[101]=(1,0);sys.alphaM[1]=0
        let record=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:windows[0].rect.arr,
            extra:.object([("swift_birth",.string("birth-1")),("tiled",.bool(true))]))
        wm.hidden=[record];wm.launcherAreas[1]=f.area
        wm.launcherIntent=LauncherIntent(sequence:7,space:1,frontPID:101,kind:1,started:sys.t)
        wm.activateOnCurrentSpace(f.area,1,windows,101)
        let plan=try XCTUnwrap(wm.restorePending[1]?.placement)
        var reply=CfgResult(wid:1,owner:"Fixture",to:plan.rect,got:plan.rect,e:0,pre:windows[0].rect)
        reply.pid=101;reply.birth="birth-1";reply.isCurrent={true};wm.cfgQ=[reply]
        var slot=EngWin(wid:1,pos:(plan.rect.x,plan.rect.y),size:(plan.rect.w,plan.rect.h),curAlpha:0,a:plan.rect)
        slot.geo=1;eng.ch.eng=[slot];sys.bounds[1]=plan.rect
        // A configure completion can arrive while Spotlight still owns input.
        sys.overlay=true;wm.completeRestores(f.area,1,windows);_=wm.configured()
        XCTAssertEqual(wm.hidden,[record]);XCTAssertTrue(wm.cfgQ.isEmpty)
        XCTAssertEqual(wm.restorePending[1]?.placement?.accepted,plan.rect)
        sys.overlay=false;wm.completeRestores(f.area,1,windows)
        XCTAssertTrue(wm.hidden.isEmpty);XCTAssertTrue(wm.restorePending.isEmpty)
        XCTAssertEqual(wm.launcherDisposition,"restored-local-window")
    }

    func testRestoreRetargetsSmallerAcceptedFrameBeforeReveal() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair())
        wm.cfgSink=SnapshotHandoffTests.Recorder();wm.sp(1).tree=Node(leaf:2)
        let record=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:windows[0].rect.arr,
            extra:.object([("swift_birth",.string("birth-1")),("tiled",.bool(true))]))
        wm.hidden=[record];sys.alphaM[1]=0
        _=wm.unhide(f.area,1,windows,which:.wids([1]))
        let first=try XCTUnwrap(wm.restorePending[1]?.placement)
        let actual=Rect(first.rect.x,first.rect.y,first.rect.w-9,first.rect.h)
        var reply=CfgResult(wid:1,owner:"Fixture",to:first.rect,got:actual,e:0,pre:actual)
        reply.pid=101;reply.birth="birth-1";reply.isCurrent={true};wm.cfgQ=[reply]
        sys.bounds[1]=actual;XCTAssertTrue(wm.configured())
        wm.completeRestores(f.area,1,windows)
        let revised=try XCTUnwrap(wm.restorePending[1]?.placement)
        XCTAssertEqual(revised.rect.w,actual.w);XCTAssertEqual(wm.hidden,[record],"Keep alpha0 until the revised native placement is acknowledged")
        reply.to=revised.rect;reply.got=revised.rect;wm.cfgQ=[reply];sys.bounds[1]=revised.rect
        var slot=EngWin(wid:1,pos:(revised.rect.x,revised.rect.y),size:(revised.rect.w,revised.rect.h),curAlpha:0,a:revised.rect)
        slot.geo=1;eng.ch.eng=[slot]
        wm.completeRestores(f.area,1,windows)
        XCTAssertTrue(wm.hidden.isEmpty);XCTAssertNil(wm.restorePending[1])
    }
    func testTransparentOrderedInWindowCanRevealButOrderedOutAndUnknownCannot() throws {
        for ordered in [true,false,nil] as [Bool?] {
            let f=ProductionPolicyTests(),(wm,sys,eng,original)=try f.world(f.pair())
            wm.cfgSink=SnapshotHandoffTests.Recorder();wm.sp(1).tree=Node(leaf:2)
            let record=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:original[0].rect.arr,
                extra:.object([("swift_birth",.string("birth-1")),("tiled",.bool(true))]))
            wm.hidden=[record];sys.alphaM[1]=0;sys.orderedInM[1]=ordered
            var windows=original;windows[0].on=false;windows[0].alpha=0
            _=wm.unhide(f.area,1,windows,which:.wids([1]))
            let plan=try XCTUnwrap(wm.restorePending[1]?.placement)
            var reply=CfgResult(wid:1,owner:"Fixture",to:plan.rect,got:plan.rect,e:0,pre:plan.rect)
            reply.pid=101;reply.birth="birth-1";reply.isCurrent={true};wm.cfgQ=[reply];sys.bounds[1]=plan.rect
            var slot=EngWin(wid:1,pos:(plan.rect.x,plan.rect.y),size:(plan.rect.w,plan.rect.h),curAlpha:0,a:plan.rect)
            slot.geo=1;eng.ch.eng=[slot]
            wm.completeRestores(f.area,1,windows)
            XCTAssertEqual(wm.hidden.isEmpty,ordered==true,"CG onscreen is false for an alpha0 window; exact native ordering must decide reveal eligibility")
        }
    }
    func testDeferredHideReleaseCannotCancelAnInFlightRestore() throws {
        final class Sink:ConfigureSink {
            var jobs:[CfgJob]=[],cancelled=Set<Int>()
            func submit(_ batch:[CfgJob]) {jobs+=batch}
            func cancel(_ wid:Int) {cancelled.insert(wid)}
        }
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair()),sink=Sink()
        wm.cfgSink=sink;wm.sp(1).tree=Node(leaf:2)
        let park=Rect(1430,41,720,495)
        wm.hidden=[Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:windows[0].rect.arr,
            extra:.object([("swift_birth",.string("birth-1")),("tiled",.bool(true))]))]
        sys.bounds[1]=park;sys.alphaM[1]=0
        eng.ch.eng=[EngWin(wid:1,pos:(park.x,park.y),size:(park.w,park.h),curAlpha:0,a:park)]
        wm.parkHidden(1,park,deadline:sys.t+30)
        XCTAssertEqual(wm.later.count,1)
        _=wm.unhide(f.area,1,windows,which:.wids([1]))
        let plan=try XCTUnwrap(wm.restorePending[1]?.placement)
        sink.cancelled=[];eng.ch.ops=[]
        sys.t+=0.02;wm.runDue()
        XCTAssertTrue(sink.cancelled.isEmpty,"An older hide callback must not invalidate the restore configure ACK")
        XCTAssertTrue(wm.later.isEmpty,"The superseded hide callback must stop retrying")
        var result=CfgResult(wid:1,owner:"Fixture",to:plan.rect,got:plan.rect,e:0,pre:park)
        result.pid=101;result.birth="birth-1";result.isCurrent={ !sink.cancelled.contains(1) };wm.cfgQ=[result]
        var slot=EngWin(wid:1,pos:(plan.rect.x,plan.rect.y),size:(plan.rect.w,plan.rect.h),curAlpha:0,a:plan.rect)
        slot.geo=1;eng.ch.eng=[slot];sys.bounds[1]=plan.rect
        wm.completeRestores(f.area,1,windows)
        XCTAssertTrue(wm.hidden.isEmpty);XCTAssertTrue(wm.restorePending.isEmpty)
        XCTAssertTrue(wm.sp(1).tree?.contains(1)==true)
    }

    func testUnhideSkipsUnverifiableTailAndPlacesMostRecentLiveWindow() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        let sink=SnapshotHandoffTests.Recorder();wm.cfgSink=sink
        wm.sp(1).tree=Node(leaf:2);wm.sp(1).focus=2
        let live=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:windows[0].rect.arr,
            extra:.object([("swift_birth",.string("birth-1")),("tiled",.bool(true))]))
        let unavailable=Hidden(wid:999,pid:101,owner:"Fixture",space:1,rect:windows[0].rect.arr,
            extra:.object([("swift_birth",.string("birth-1")),("tiled",.bool(true))]))
        wm.hidden=[live,unavailable];sys.alphaM[1]=0
        _=try wm.command("unhide",f.area,1,windows)
        XCTAssertNotNil(wm.restorePending[1],"An unavailable last window must not block an older live hidden window")
        XCTAssertEqual(sink.jobs.map(\.wid),[1])
        XCTAssertNil(wm.restorePending[999]);XCTAssertEqual(wm.hidden,[live,unavailable],"Unknown ownership is retained, never silently discarded or revealed")
    }

    func testCurrentConfigureMinimumRequiresExactDestinationAndNeverUsesCachedGuess() {
        let target=Rect(738,41,730,400),minimum=Rect(738,41,730,508)
        var result=CfgResult(wid:66,owner:"Fixture",to:target,got:minimum,e:0,pre:Rect(12,41,1446,508))
        result.pid=777;result.birth="777:1:2";result.isCurrent={true}
        func accepted(_ value:CfgResult)->Rect? {PlacementFrameAcceptance.accepted(value,wid:66,pid:777,birth:"777:1:2",target:target)}
        XCTAssertEqual(accepted(result),minimum)
        for actual in [Rect(12,41,730,508),Rect(738,60,730,508),Rect(738,41,710,508),Rect(738,41,730,380)] {
            var changed=result;changed.got=actual;XCTAssertNil(accepted(changed))
        }
        var changed=result;changed.isCurrent={false};XCTAssertNil(accepted(changed))
        changed=result;changed.e=1;XCTAssertNil(accepted(changed))
        changed=result;changed.birth="replacement";XCTAssertNil(accepted(changed))
        changed=result;changed.pid=778;XCTAssertNil(accepted(changed))
        changed=result;changed.to=minimum;XCTAssertNil(accepted(changed))
    }

    func testHiddenReturnConfiguresFinalTileBeforeRevealAndOnlyNeighborsAnimate() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,original)=try f.world(f.pair()),sink=SnapshotHandoffTests.Recorder()
        wm.cfgSink=sink;wm.sp(1).tree=Node(leaf:2);wm.sp(1).focus=2;sys.deferredFocus=true
        let old=Rect(800,40,380,400),park=Rect(1430,40,380,400)
        let hidden=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:old.arr,extra:.object([("swift_birth",.string("birth-1")),("tiled",.bool(true))]))
        wm.hidden=[hidden];sys.bounds[1]=park;sys.alphaM[1]=0
        let full=try XCTUnwrap(wm.layout(f.area,wm.sp(1))[2]);wm.target[2]=full;sys.bounds[2]=full
        var windows=original;windows[1].x=full.x;windows[1].y=full.y;windows[1].w=full.w;windows[1].h=full.h
        windows[0].x=park.x;windows[0].y=park.y;windows[0].w=park.w;windows[0].h=park.h;windows[0].alpha=0
        _=wm.unhide(f.area,1,windows,which:.wids([1]))
        let pending=try XCTUnwrap(wm.restorePending[1]),plan=try XCTUnwrap(pending.placement)
        XCTAssertEqual(wm.hidden,[hidden]);XCTAssertNil(wm.restoreFrom[1]);XCTAssertEqual(sink.jobs.map(\.to),[plan.rect])
        let warp=try XCTUnwrap(eng.ch.ops.first{$0["op"] == .string("warp") && $0["wid"] == .int(1)})
        XCTAssertEqual(warp["frm"],plan.rect.json);XCTAssertEqual(warp["to"],plan.rect.json)
        wm.completeRestores(f.area,1,windows);XCTAssertEqual(wm.hidden,[hidden])
        var reply=CfgResult(wid:1,owner:"Fixture",to:plan.rect,got:plan.rect,e:0,pre:old)
        reply.pid=101;reply.birth="birth-1";reply.isCurrent={true};wm.cfgQ=[reply]
        var slot=EngWin(wid:1,pos:(plan.rect.x,plan.rect.y),size:(plan.rect.w,plan.rect.h),curAlpha:0,a:plan.rect);slot.geo=1;eng.ch.eng=[slot]
        sys.bounds[1]=plan.rect;eng.ch.ringPending=true;wm.completeRestores(f.area,1,windows);XCTAssertEqual(wm.hidden,[hidden])
        eng.ch.ringPending=false;eng.ch.ops=[];wm.completeRestores(f.area,1,windows)
        XCTAssertTrue(wm.hidden.isEmpty);XCTAssertTrue(wm.restorePending.isEmpty);XCTAssertNil(wm.restoreFrom[1]);XCTAssertFalse(wm.restoring.contains(1))
        XCTAssertEqual(sys.focusCallbacks.count,1)
        XCTAssertEqual(sys.focusCallbacks.first?.0.wid,1);XCTAssertEqual(sys.focusCallbacks.first?.0.reason,.keyboard)
        XCTAssertEqual(wm.target[1],plan.rect);XCTAssertTrue(wm.sp(1).tree?.contains(1)==true)
        XCTAssertFalse(eng.ch.ops.contains{["geom","warp"].contains($0["op"]?.string ?? "") && $0["wid"] == .int(1)},"incoming actor never travels from saved old rect")
        XCTAssertTrue(eng.ch.ops.contains{$0["op"] == .string("geom") && $0["wid"] == .int(2)},"existing neighbor animates from its old full allocation")
        XCTAssertTrue(eng.ch.ops.contains{$0["op"] == .string("alpha") && $0["wid"] == .int(1) && ($0["a"]?.double ?? 0)>0})
    }
    func testRecycledHiddenOwnerCannotBeRevealedAndShutdownBypassesPendingPlacement() throws {
        for shutdown in [false,true] {
            let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair())
            wm.cfgSink=SnapshotHandoffTests.Recorder();wm.sp(1).tree=Node(leaf:2)
            let row=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:windows[0].rect.arr,extra:.object([("swift_birth",.string("birth-1")),("tiled",.bool(true))]))
            wm.hidden=[row];_=wm.unhide(f.area,1,windows,which:.wids([1]));eng.ch.ops=[]
            if shutdown {
                _=wm.unhide(f.area,1,windows,everything:true)
                XCTAssertTrue(wm.hidden.isEmpty);XCTAssertTrue(wm.restorePending.isEmpty)
            } else {
                sys.births[101]="recycled";wm.completeRestores(f.area,1,windows)
                XCTAssertEqual(wm.hidden,[row]);XCTAssertTrue(eng.ch.ops.isEmpty)
            }
        }
    }
}
