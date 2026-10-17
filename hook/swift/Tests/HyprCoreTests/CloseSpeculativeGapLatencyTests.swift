@testable import HyprCore
import XCTest

final class CloseSpeculativeGapLatencyTests:XCTestCase {
    func testFirstConfirmedCloseCensusOverridesSpeculativeNativeReturnAndSubmitsPeerExpansion() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,initial)=try f.world(f.pair()),sink=SnapshotHandoffTests.Recorder()
        wm.cfgSink=sink;wm.rescued=true;wm.lastSpace=1;wm.frontPid=101;sys.activeSpaceID=1;sys.front=101
        sys.contexts[101]=(1,0);wm.sp(1).focus=1;wm.rememberNativeFocus(101,initial)
        let before=try XCTUnwrap(wm.target[2])
        // An ordinary order-out first looks like an ambiguous fullscreen gap.
        var gap=initial;gap[0].on=false;gap[0].space=0;sys.contexts[101]=(nil,4)
        sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:gap)
        wm.tick(socketReady:false)
        XCTAssertTrue(wm.nativeSuspendedSpaces.contains("1"));XCTAssertTrue(sink.jobs.isEmpty)
        // The retained CG object regains ordinary membership while AppKit has
        // positively retired the exact old key window. No close AX reply needed.
        var retired=initial;retired[0].on=false;sys.contexts[101]=(nil,32);sys.windowPresenceM[1]=0;sys.t+=0.01
        sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:retired)
        wm.tick(socketReady:false)
        XCTAssertFalse(wm.nativeSuspendedSpaces.contains("1"))
        XCTAssertEqual(wm.sp(1).tree?.wid,2)
        let expanded=try XCTUnwrap(wm.target[2]);XCTAssertGreaterThan(expanded.w,before.w)
        XCTAssertEqual(sink.jobs.filter{$0.wid==2}.map(\.to),[expanded],"Actual production tick must submit expansion in this census")
        XCTAssertEqual(sys.t,1000.01,accuracy:0.000001,"No one-second return timer or extra census")
    }
    func testAmbiguousModalRecycledAndConfirmedNativeActorsRetainReturnFence() throws {
        for mode in 0..<4 {
            let f=ProductionPolicyTests(),(wm,sys,_,initial)=try f.world(f.pair()),sink=SnapshotHandoffTests.Recorder()
            wm.cfgSink=sink;wm.rescued=true;wm.lastSpace=1;wm.frontPid=101;sys.activeSpaceID=1;sys.front=101
            sys.contexts[101]=(1,0);wm.sp(1).focus=1;wm.rememberNativeFocus(101,initial)
            var gap=initial;gap[0].on=false;gap[0].space=0;sys.contexts[101]=(nil,4)
            sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:gap);wm.tick(socketReady:false)
            var retired=initial;retired[0].on=false;sys.contexts[101]=(nil,mode==0 ? 4:mode==1 ? 2:32)
            sys.windowPresenceM[1]=0;sys.t+=0.01
            if mode==2 {sys.births[101]="recycled"}
            if mode==3 {wm.nativeConfirmed.insert(1)}
            sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:retired);wm.tick(socketReady:false)
            XCTAssertTrue(wm.nativeSuspendedSpaces.contains("1"),"mode \(mode)")
            XCTAssertTrue(wm.sp(1).tree?.contains(1)==true,"mode \(mode)")
            XCTAssertTrue(sink.jobs.isEmpty,"mode \(mode)")
        }
    }
    func testExplicitCloseAndExitedProcessAlsoReleaseSpeculativeReturnInFirstCensus() throws {
        for exited in [false,true] {
            let f=ProductionPolicyTests(),(wm,sys,_,initial)=try f.world(f.pair()),sink=SnapshotHandoffTests.Recorder()
            wm.cfgSink=sink;wm.rescued=true;wm.lastSpace=1;wm.frontPid=101;sys.activeSpaceID=1;sys.front=101
            sys.contexts[101]=(1,0);wm.sp(1).focus=1;wm.rememberNativeFocus(101,initial)
            let before=try XCTUnwrap(wm.target[2])
            if !exited {
                sys.deferredClose=true
                _=wm.closeAnim(f.area,1,initial,try XCTUnwrap(initial.first{$0.wid==1}))
            }
            var gap=initial;gap[0].on=false;gap[0].space=0;sys.contexts[101]=(nil,4)
            sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:gap);wm.tick(socketReady:false)
            XCTAssertTrue(wm.nativeSuspendedSpaces.contains("1"));XCTAssertTrue(sink.jobs.isEmpty)
            var retired=initial;retired[0].on=false;sys.t+=0.01
            if exited {
                sys.exitedPIDs.insert(101);sys.births[101]=nil;sys.front=102;sys.contexts[102]=(2,0)
            }
            // Explicit close still has no AX press callback and unknown focus.
            // Process exit instead supplies positive native departure evidence.
            sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:retired);wm.tick(socketReady:false)
            XCTAssertFalse(wm.nativeSuspendedSpaces.contains("1"),"exited \(exited)")
            XCTAssertEqual(wm.sp(1).tree?.wid,2)
            let expanded=try XCTUnwrap(wm.target[2]);XCTAssertGreaterThan(expanded.w,before.w)
            XCTAssertEqual(sink.jobs.filter{$0.wid==2}.map(\.to),[expanded])
            XCTAssertEqual(sys.t,1000.01,accuracy:0.000001)
        }
    }

}
