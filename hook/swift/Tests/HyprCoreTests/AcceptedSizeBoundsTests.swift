@testable import HyprCore
import XCTest

final class AcceptedSizeBoundsTests:XCTestCase {
    func response(_ wm:WM,_ goal:Rect,_ got:Rect,_ pre:Rect) {
        var r=CfgResult(wid:1,owner:"Fixture",to:goal,got:got,e:0,pre:pre)
        r.pid=101;r.birth="birth-1";r.isCurrent={true};wm.cfgQ=[r]
    }
    func testChangedHeightDoesNotInventAnUnchangedWidthMinimum() throws {
        let f=ProductionPolicyTests(),(wm,_,_,_)=try f.world(f.pair())
        wm.tile.minimumPolicy="ratio";wm.sp(1).tree!.manualRatio=true
        let goal=wm.target[1]!,got=Rect(goal.x,goal.y,845,goal.h)
        response(wm,goal,got,Rect(goal.x,goal.y,845,320))
        XCTAssertFalse(wm.configured())
        XCTAssertEqual(wm.layout(f.area,wm.sp(1))[1],goal)
    }
    func testNativePolicyFitsDurablyAcceptedLargerFrameWithoutLearningAppMinimum() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,_)=try f.world(f.pair())
        wm.tile.minimumPolicy="native";wm.sp(1).tree!.manualRatio=true
        let goal=wm.target[1]!,got=Rect(goal.x,goal.y,845,goal.h)
        let before=JSON.object(wm.mins.map{($0.0,.array($0.1))})
        let sink=SnapshotHandoffTests.Recorder();wm.cfgSink=sink;sys.bounds[1]=got
        response(wm,goal,got,got)
        XCTAssertFalse(wm.configured(),"One unchanged setter response is not enough")
        sys.t+=0.2;wm.runDue()
        XCTAssertTrue(sink.jobs.last?.verifyOnly == true,"The confirmation reads fresh AX state without a second resize")
        response(wm,goal,got,got)
        XCTAssertTrue(wm.configured())
        let fitted=try XCTUnwrap(wm.layout(f.area,wm.sp(1))[1])
        XCTAssertGreaterThanOrEqual(fitted.w,845);XCTAssertEqual(JSON.object(wm.mins.map{($0.0,.array($0.1))}),before,"Current native acceptance must never become an app-wide minimum")
        sys.births[101]="replacement"
        XCTAssertEqual(wm.layout(f.area,wm.sp(1))[1],goal,"A reused process cannot inherit a current-window fit")
    }
    func testDeferredFitRefusesTransientFrameNewTargetAndReusedOwner() throws {
        for mode in 0..<3 {
            let f=ProductionPolicyTests(),(wm,sys,_,_)=try f.world(f.pair())
            wm.tile.minimumPolicy="native"
            let goal=wm.target[1]!,got=Rect(goal.x,goal.y,845,goal.h),sink=SnapshotHandoffTests.Recorder()
            wm.cfgSink=sink;sys.bounds[1]=got
            response(wm,goal,got,got);XCTAssertFalse(wm.configured())
            if mode==0 {sys.bounds[1]=goal}
            if mode==1 {wm.target[1]=Rect(goal.x,goal.y,goal.w-20,goal.h)}
            if mode==2 {sys.births[101]="replacement"}
            sys.t+=0.2;wm.runDue()
            XCTAssertTrue(sink.jobs.isEmpty);XCTAssertNil(wm.acceptedFloors[1]);XCTAssertNil(wm.acceptedFrameProbes[1])
        }
    }
    func testNewCurrentConfigureSupersedesTheOlderDeferredRead() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,_)=try f.world(f.pair())
        wm.tile.minimumPolicy="native"
        let goal=wm.target[1]!,got=Rect(goal.x,goal.y,845,goal.h),sink=SnapshotHandoffTests.Recorder()
        wm.cfgSink=sink;sys.bounds[1]=got
        var firstCurrent=true
        response(wm,goal,got,got);wm.cfgQ[0].isCurrent={firstCurrent}
        XCTAssertFalse(wm.configured())
        firstCurrent=false;sys.t+=0.05
        response(wm,goal,got,got);XCTAssertFalse(wm.configured())
        sys.t+=0.2;wm.runDue()
        XCTAssertEqual(sink.jobs.count,1);XCTAssertTrue(sink.jobs[0].verifyOnly)
        response(wm,goal,got,got);XCTAssertTrue(wm.configured())
    }
    func testSmallerAcceptedWidthCapsPresentationAndDecorationEvenWithUnchangedNativeFrame() throws {
        let f=ProductionPolicyTests(),(wm,_,_,_)=try f.world(Node(leaf:1))
        let goal=wm.target[1]!,got=Rect(goal.x,goal.y,845,goal.h)
        response(wm,goal,got,got)
        XCTAssertTrue(wm.configured())
        XCTAssertEqual(wm.layout(f.area,wm.sp(1))[1]!.w,845)
    }
    func testRecycledOrObsoleteReplyCannotConstrainAnotherWindow() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,_)=try f.world(Node(leaf:1))
        let goal=wm.target[1]!,got=Rect(goal.x,goal.y,845,goal.h)
        response(wm,goal,got,got);sys.births[101]="new-birth"
        XCTAssertFalse(wm.configured());XCTAssertEqual(wm.layout(f.area,wm.sp(1))[1],goal)
    }
}
