@testable import HyprCore
import XCTest

final class LauncherFocusCancellationTests:XCTestCase {
    func testFreshLauncherInputCancelsAlreadyQueuedFocusBeforeOverlayWindowExists() throws {
        for (kind,origin) in [(1,1),(2,1),(3,1),(1,999)] {
            let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
            wm.rescued=true;wm.lastSpace=1;wm.frontPid=101;wm.sp(1).focus=1
            sys.activeSpaceID=1;sys.front=101;sys.contexts[101]=(nil,NativeFocusFlags.noKey);sys.deferredFocus=true
            XCTAssertTrue(wm.queueFocus(windows[1],space:1,reason:.space))
            XCTAssertEqual(sys.focusCallbacks.count,1);let before=sys.focusCancels
            // The physical launcher input precedes its visible overlay. Existing
            // native-overlay guards deliberately still read false in this census.
            sys.launch=LauncherIntent(sequence:1,space:origin,frontPID:101,kind:kind,started:sys.t)
            sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:windows)
            wm.tick(socketReady:false)
            XCTAssertNil(wm.focusPending,"kind \(kind), origin \(origin)")
            XCTAssertGreaterThan(sys.focusCancels,before,"Runtime worker epoch must cancel, not just UI callback")
            let callback=sys.focusCallbacks.removeFirst().1;callback(true)
            XCTAssertEqual(wm.sp(1).focus,1,"Old completion cannot replace the newer launcher choice")
            XCTAssertNotEqual(wm.fwant,2)
        }
    }
    func testPendingLauncherRefusesNewAutomaticFocusButAllowsExplicitKeyboardIntent() throws {
        for reason in [FocusReason.space,.close] {
            let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
            sys.activeSpaceID=1;sys.front=101;sys.contexts[101]=(nil,NativeFocusFlags.noKey);sys.deferredFocus=true
            sys.launch=LauncherIntent(sequence:1,space:1,frontPID:101,kind:1,started:sys.t)
            wm.observeLauncher(f.area,1,windows)
            XCTAssertFalse(wm.queueFocus(windows[1],space:1,reason:reason))
            XCTAssertTrue(sys.focusCallbacks.isEmpty)
            XCTAssertTrue(wm.queueFocus(windows[1],space:1,reason:.keyboard))
            XCTAssertEqual(sys.focusCallbacks.count,1)
        }
    }
    func testCancelAndAlreadyConsumedLauncherEventsDoNotCancelANewerFocusRequest() throws {
        for stale in [false,true] {
            let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
            wm.rescued=true;wm.lastSpace=1;wm.frontPid=101;wm.sp(1).focus=1
            sys.activeSpaceID=1;sys.front=101;sys.contexts[101]=(nil,NativeFocusFlags.noKey);sys.deferredFocus=true
            if stale {wm.launcherSequence=4}
            XCTAssertTrue(wm.queueFocus(windows[1],space:1,reason:.space));let before=sys.focusCancels
            sys.launch=LauncherIntent(sequence:stale ? 4:1,space:1,frontPID:101,kind:stale ? 1:0,started:sys.t)
            sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:windows);wm.tick(socketReady:false)
            XCTAssertNotNil(wm.focusPending);XCTAssertEqual(sys.focusCancels,before)
            sys.focusCallbacks.removeFirst().1(true);XCTAssertEqual(wm.sp(1).focus,2)
        }
    }
}
