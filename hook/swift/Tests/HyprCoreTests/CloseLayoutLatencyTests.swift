@testable import HyprCore
import XCTest

final class CloseLayoutLatencyTests:XCTestCase {
    func testConfirmedWMCloseStartsNeighborExpansionInFirstNativeGoneCensus() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        sys.front=101;sys.contexts[101]=(1,0);wm.sp(1).focus=1
        wm.rememberNativeFocus(101,windows);sys.deferredClose=true
        _=wm.closeAnim(f.area,1,windows,windows[0])
        sys.closeCallbacks.removeFirst()(CloseResult(code:0))
        sys.contexts[101]=(nil,32)
        let remaining=windows.filter{$0.wid==2},before=wm.layout(f.area,wm.sp(1))[2]!
        wm.observeCloseRequests(remaining,1)
        let result=wm.sync(f.area,1,remaining)
        XCTAssertTrue(result.0);XCTAssertEqual(wm.sp(1).tree?.wid,2)
        XCTAssertGreaterThan(try XCTUnwrap(wm.layout(f.area,wm.sp(1))[2]).w,before.w)
        XCTAssertEqual(sys.t,1000) // No artificial wait or extra tick.
    }
    func testNativeSameAppCloseWithAnotherKeySkipsSpeculativeFullscreenGap() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,initial)=try f.world(f.pair())
        var windows=initial;windows[1].pid=101;sys.pidlevel[2]=(101,0);wm.pids[2]=101
        sys.front=101;sys.contexts[101]=(1,0);wm.sp(1).focus=1
        wm.rememberNativeFocus(101,windows)
        windows[0].on=false;windows[0].space=0;sys.contexts[101]=(2,0);sys.windowPresenceM[1]=0
        let before=wm.layout(f.area,wm.sp(1))[2]!
        _=wm.sync(f.area,1,windows)
        XCTAssertFalse(wm.nativeSuspendedSpaces.contains("1"))
        XCTAssertEqual(wm.sp(1).tree?.wid,2)
        XCTAssertGreaterThan(try XCTUnwrap(wm.layout(f.area,wm.sp(1))[2]).w,before.w)
    }
    func testPresentUnknownAndSaveParentDoNotAuthorizeEarlyClose() throws {
        for mode in [0,1,2] {
            let f=ProductionPolicyTests(),(wm,sys,_,initial)=try f.world(f.pair())
            sys.front=101;sys.contexts[101]=(1,0);wm.sp(1).focus=1
            wm.rememberNativeFocus(101,initial)
            var windows=initial;windows[0].on=false;windows[0].space=0
            sys.contexts[101]=(nil,mode==2 ? 2:4)
            sys.windowPresenceM[1]=mode==0 ? 1:mode==1 ? -1:0
            let before=wm.sp(1).tree!.json
            _=wm.sync(f.area,1,windows)
            XCTAssertEqual(wm.sp(1).tree?.json,before)
        }
    }
}
