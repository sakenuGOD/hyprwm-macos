@testable import HyprCore
import XCTest

final class NativeSpaceFocusEpochTests:XCTestCase {
    func testUnstableNativeCensusInvalidatesQueuedAutomaticFocusBeforeSpaceChanged() throws {
        for reason in [FocusReason.space,.close] {
            for observedSpace in [1,2] {
                let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
                let target=try XCTUnwrap(windows.first{$0.wid==2})
                wm.rescued=true;wm.lastSpace=1;wm.frontPid=101;wm.sp(1).focus=1
                sys.activeSpaceID=1;sys.front=101;sys.contexts[101]=(nil,NativeFocusFlags.noKey);sys.deferredFocus=true
                XCTAssertTrue(wm.queueFocus(target,space:1,reason:reason))
                let before=sys.focusCancels
                // Horizontal native transitions need not expose Mission Control.
                // The census can become unstable while its SID is still the old SID.
                sys.nativeSnapshot=Snapshot(space:observedSpace,stable:false,area:f.area,windows:windows)
                wm.tick(socketReady:false)
                XCTAssertNil(wm.focusPending,"reason \(reason), observedSID \(observedSpace)")
                XCTAssertGreaterThan(sys.focusCancels,before,"Cancel actual asynchronous worker epoch")
                sys.focusCallbacks.removeFirst().1(true)
                XCTAssertEqual(wm.sp(1).focus,1,"Stale accepted callback must not change previous Space focus")
                XCTAssertNotEqual(wm.fwant,2)
            }
        }
    }
    func testStableSameSpaceCensusPreservesQueuedAutomaticFocus() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        let target=try XCTUnwrap(windows.first{$0.wid==2})
        wm.rescued=true;wm.lastSpace=1;wm.frontPid=101;wm.sp(1).focus=1
        sys.activeSpaceID=1;sys.front=101;sys.contexts[101]=(nil,NativeFocusFlags.noKey);sys.deferredFocus=true
        XCTAssertTrue(wm.queueFocus(target,space:1,reason:.space));let before=sys.focusCancels
        sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:windows);wm.tick(socketReady:false)
        XCTAssertNotNil(wm.focusPending);XCTAssertEqual(sys.focusCancels,before)
        sys.focusCallbacks.removeFirst().1(true);XCTAssertEqual(wm.sp(1).focus,2)
    }
}
