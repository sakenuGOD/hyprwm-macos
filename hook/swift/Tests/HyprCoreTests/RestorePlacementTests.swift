@testable import HyprCore
import XCTest

final class RestorePlacementTests:XCTestCase {
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
