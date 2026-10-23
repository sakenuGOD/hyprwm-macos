@testable import HyprCore
import XCTest

final class ExternalActivationRestoreTests:XCTestCase {
    func testLinkActivationRestoresExactHiddenKeyWhilePreviousPrimaryStillLives() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,original)=try f.world(f.pair())
        var windows=original
        let index=try XCTUnwrap(windows.firstIndex{$0.wid==1})
        let saved=windows[index].rect
        windows[index].alpha=0;windows[index].x=1400;sys.bounds[1]=windows[index].rect;sys.alphaM[1]=0
        wm.hidden=[Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:saved.arr,extra:.object([("swift_birth",.string("birth-1")),("tiled",.bool(true))]))]
        wm.sp(1).tree=Node(leaf:2);wm.sp(1).focus=2;wm.frontPid=102
        wm.focusHistory=[2];wm.nativeFocusedIdentities[2]=(102,"birth-2",1)
        wm.lastSpace=1;wm.rescued=true;sys.front=101;sys.contexts[101]=(1,0)
        sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:windows)
        sys.m=(900,500);wm.mp=sys.m;wm.pointerMovedAt=sys.t-1;sys.pointerHint=(2,102)
        wm.tick(socketReady:false)
        XCTAssertTrue(!wm.hidden.contains{$0.wid==1} || wm.restorePending[1] != nil,"External URL/open activation must not leave its exact native key alpha0 forever")
        XCTAssertFalse(sys.calls.contains{$0.array?.first == .string("ax_focus") && $0.array?[2].int==2},"Stationary source pointer must not steal the external activation")
    }
    func testColdFocusContextPreservesSourceForDelayedHiddenActivation() throws {
        for replacedSource in [false,true] {
            let f=ProductionPolicyTests(),(wm,sys,_,original)=try f.world(f.pair())
            var windows=original
            let index=try XCTUnwrap(windows.firstIndex{$0.wid==1})
            let saved=windows[index].rect
            windows[index].alpha=0;windows[index].x=1400;sys.bounds[1]=windows[index].rect;sys.alphaM[1]=0
            wm.hidden=[Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:saved.arr,extra:.object([("swift_birth",.string("birth-1")),("tiled",.bool(true))]))]
            wm.sp(1).tree=Node(leaf:2);wm.sp(1).focus=2;wm.frontPid=102
            wm.focusHistory=[2];wm.nativeFocusedIdentities[2]=(102,"birth-2",1)
            wm.lastSpace=1;wm.rescued=true;sys.front=101;sys.contexts[101]=(nil,4)
            sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:windows)
            sys.m=(900,500);wm.mp=sys.m;wm.pointerMovedAt=sys.t-1;sys.pointerHint=(2,102)
            wm.tick(socketReady:false)
            XCTAssertNotNil(wm.activationIntent)
            sys.t+=0.05;sys.contexts[101]=(1,0)
            if replacedSource {sys.births[102]="replacement"}
            wm.tick(socketReady:false)
            let restoring = !wm.hidden.contains{$0.wid==1} || wm.restorePending[1] != nil
            XCTAssertEqual(restoring,!replacedSource,"Cold AX lookup must preserve the original live source fence until the exact key arrives")
        }
    }
    func testExternalActivationRestoresExactHiddenKeyFromAnotherOrdinarySpace() throws {
        for transfer in [false,true] {
            let f=ProductionPolicyTests(),(wm,sys,_,original)=try f.world(f.pair())
            var windows=original
            let index=try XCTUnwrap(windows.firstIndex{$0.wid==1})
            let saved=windows[index].rect
            windows[index].alpha=0;windows[index].x=1400;windows[index].space=4
            sys.bounds[1]=windows[index].rect;sys.alphaM[1]=0
            wm.hidden=[Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:saved.arr,extra:.object([("swift_birth",.string("birth-1")),("tiled",.bool(true))]))]
            wm.sp(1).tree=Node(leaf:2);wm.sp(1).focus=2;wm.frontPid=102
            wm.focusHistory=[2];wm.nativeFocusedIdentities[2]=(102,"birth-2",1)
            wm.lastSpace=1;wm.rescued=true;sys.front=101;sys.contexts[101]=(1,0)
            wm.options.transferOnActivation=transfer
            sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:windows)
            wm.tick(socketReady:false)
            if transfer {
                XCTAssertEqual(wm.restorePending[1]?.space,1,"Opening the exact hidden key must restore it to the current desktop through existing transfer ACKs")
            } else {
                XCTAssertNil(wm.restorePending[1]);XCTAssertTrue(wm.hidden.contains{$0.wid==1})
            }
        }
    }
    func testCloseFallbackOrReplacedSourceCannotAuthorizeHiddenRestore() throws {
        for replaced in [false,true] {
            let f=ProductionPolicyTests(),(wm,sys,_,original)=try f.world(f.pair())
            let record=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:original[0].rect.arr,extra:.object([("swift_birth",.string("birth-1")),("tiled",.bool(true))]))
            wm.hidden=[record];wm.sp(1).tree=Node(leaf:2);wm.sp(1).focus=2;wm.frontPid=102
            wm.focusHistory=[2];wm.nativeFocusedIdentities[2]=(102,"birth-2",1)
            var windows=original
            if replaced {sys.births[102]="replacement"} else {windows.removeAll{$0.wid==2}}
            wm.lastSpace=1;wm.rescued=true;sys.front=101;sys.contexts[101]=(1,0)
            sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:windows)
            wm.tick(socketReady:false)
            XCTAssertTrue(wm.hidden.contains{$0.wid==1});XCTAssertNil(wm.restorePending[1])
        }
    }
    func testStationaryPointerDoesNotOverrideNewNativePrimary() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        sys.front=101;sys.contexts[101]=(1,0);sys.m=(900,500);sys.pointerHint=(2,102)
        wm.mp=sys.m;wm.pointerMovedAt=sys.t-1
        wm.followMouse(1,windows)
        XCTAssertFalse(sys.calls.contains{$0.array?.first == .string("ax_focus")})
    }
    func testMovedPointerStillFocusesAfterConfiguredDwell() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        sys.front=101;sys.contexts[101]=(1,0);sys.m=(900,500);sys.pointerHint=(2,102)
        wm.mp=(100,100);wm.followMouse(1,windows)
        XCTAssertFalse(sys.calls.contains{$0.array?.first == .string("ax_focus")})
        sys.t+=0.11;wm.followMouse(1,windows)
        XCTAssertTrue(sys.calls.contains{$0.array?.first == .string("ax_focus") && $0.array?[2].int==2})
    }
}
