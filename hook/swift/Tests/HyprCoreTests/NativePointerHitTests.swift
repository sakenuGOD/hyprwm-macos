@testable import HyprCore
import XCTest

final class NativePointerHitTests:XCTestCase {
    func testTemporaryMissingNativeReceiverRetriesSamePointerAfterRoutingSettles() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        wm.cfg=try NativeRuntimeConfig.build(base:wm.cfg,document:JSON.parse("{\"runtime\":{\"pointer_focus_pause_ms\":0}}"))
        let target=try XCTUnwrap(windows.first{$0.wid==2})
        sys.front=101;sys.contexts[101]=(1,0);sys.deferredFocus=true
        sys.m=(target.x+40,target.y+40);sys.pointerHint=(999,102)
        wm.followMouse(1,windows)
        XCTAssertTrue(sys.focusCallbacks.isEmpty)
        XCTAssertNotNil(wm.pointerFocusRetryPoint,"Exercise receiver retry independently of pointer dwell")
        sys.t+=0.02;sys.pointerHint=(2,102)
        wm.followMouse(1,windows)
        XCTAssertEqual(sys.focusCallbacks.count,1,"A settled receiver must not require another physical mouse movement")
        XCTAssertEqual(wm.focusPending?.wid,2)
    }

    func testKeyboardIntentCancelsUnresolvedPointerRouting() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        wm.cfg=try NativeRuntimeConfig.build(base:wm.cfg,document:JSON.parse("{\"runtime\":{\"pointer_focus_pause_ms\":0}}"))
        let target=try XCTUnwrap(windows.first{$0.wid==2})
        sys.front=101;sys.contexts[101]=(1,0);sys.deferredFocus=true
        sys.m=(target.x+40,target.y+40);sys.pointerHint=(999,102)
        wm.followMouse(1,windows)
        XCTAssertNotNil(wm.pointerFocusRetryPoint)
        XCTAssertTrue(wm.queueFocus(windows.first{$0.wid==1}!,space:1,reason:.keyboard))
        sys.t+=0.02;sys.pointerHint=(2,102);wm.followMouse(1,windows)
        XCTAssertEqual(sys.focusCallbacks.count,1)
        XCTAssertEqual(wm.focusPending?.wid,1)
    }
    func scene() throws -> (WM,FakeWorld,[WinInfo],Rect) {
        let fixture=ProductionPolicyTests(),(wm,sys,_,windows)=try fixture.world(fixture.pair())
        let actor=sys.bounds[1]!
        sys.front=101;sys.contexts[101]=(1,0);sys.m=(actor.x+actor.w-1,actor.y+100);sys.md=true
        sys.pidlevel[33]=(734,21);sys.protectedPIDs.insert(734)
        var phantom=WinInfo(wid:33,pid:734,owner:"NotificationCenter",x:fixture.area.x,y:fixture.area.y,
                            w:fixture.area.w,h:fixture.area.h,on:true,space:1)
        phantom.layer=21
        return(wm,sys,[phantom]+windows,fixture.area)
    }

    func testActualInputReceiverArmsResizeBelowPhantomNotificationBounds() throws {
        let (wm,sys,windows,area)=try scene();sys.pointerHint=(1,101)
        wm.beginInteraction(area,1,windows)
        XCTAssertEqual(wm.dragSession?.wid,1)
        XCTAssertFalse(wm.dragSession?.cuts.isEmpty ?? true)
    }

    func testActualNotificationAndUnknownNativeHitDoNotSelectTileBehindOverlay() throws {
        let hints:[(wid:Int,pid:Int?)?]=[(33,734),nil]
        for hint in hints {
            let (wm,sys,windows,area)=try scene();sys.pointerHint=hint
            wm.beginInteraction(area,1,windows)
            XCTAssertNil(wm.dragSession)
        }
    }

    func testNativeOwnerMismatchMissingReceiverAndOtherSpaceDoNotFallThrough() throws {
        for hint in [(1,999),(99,101)] {
            let (wm,sys,windows,area)=try scene();sys.pointerHint=(hint.0,hint.1)
            wm.beginInteraction(area,1,windows)
            XCTAssertNil(wm.dragSession)
        }
        let (wm,sys,windows,area)=try scene();sys.pointerHint=(1,101)
        let other=windows.map {window -> WinInfo in var result=window;if result.wid==1{result.space=2};return result}
        wm.beginInteraction(area,1,other)
        XCTAssertNil(wm.dragSession)
    }

    func testExactNativeResizeEpochRemainsAuthoritativeWhenInputHintUnavailable() throws {
        let (wm,sys,windows,area)=try scene();sys.pointerHint=nil
        let frame=sys.bounds[1]!
        wm.beginInteraction(area,1,windows,native:NativeResizeContext(pid:101,birth:"birth-1",wid:1,
            epoch:7,sequence:2,phase:1,frame:frame,point:sys.m))
        XCTAssertEqual(wm.dragSession?.wid,1)
        XCTAssertEqual(wm.dragSession?.nativeEpoch,7)
    }
}
