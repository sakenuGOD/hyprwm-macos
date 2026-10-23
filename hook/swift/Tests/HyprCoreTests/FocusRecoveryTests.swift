@testable import HyprCore
import XCTest

final class FocusRecoveryTests:XCTestCase {
    func testNativeKeySurvivesUnchangedCGStackingOrder() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        sys.front=102;sys.contexts[102]=(2,0);wm.sp(1).focus=2
        _=wm.sync(f.area,1,windows)
        XCTAssertEqual(wm.sp(1).focus,2,"CG order is not native keyboard focus")
    }

    func testAcceptedFocusUpdatesDecorationImmediately() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair())
        sys.front=101;sys.contexts[101]=(1,0);sys.deferredFocus=true
        XCTAssertTrue(wm.queueFocus(windows.first{$0.wid==2}!,space:1,reason:.pointer,pointer:(800,300)))
        sys.focusCallbacks.removeFirst().1(true)
        XCTAssertEqual(eng.ch.decorationFocused,2,"The ring must not wait for the250ms opacity guard")
    }
    func testFloatChoosesNativeFloatingPrimaryOutsideTreeAndPreservesGlobalLedger() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        wm.sp(1).tree=Node(leaf:1);wm.floating=[2,4080,11421]
        sys.front=102;sys.contexts[102]=(2,0);sys.activeSpaceID=1
        XCTAssertNil(wm.nativeCommandWindow(1,windows,wm.layout(f.area,wm.sp(1))))
        XCTAssertEqual(wm.nativeCommandWindow(1,windows,wm.layout(f.area,wm.sp(1)),requiresTile:false)?.wid,2)
        XCTAssertEqual(try wm.command("float",f.area,1,windows),"ok")
        XCTAssertEqual(wm.floating,Set([4080,11421]))
        XCTAssertEqual(try wm.command("float 2",f.area,1,windows),"ok")
        XCTAssertEqual(wm.floating,Set([2,4080,11421]))
    }
    func testExplicitFloatRefusesForeignMissingHiddenProtectedAndUnknownWithoutLedgerMutation() throws {
        for failure in ["foreign","missing","hidden","protected","modal","unknown","owner","birth"] {
            let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
            wm.floating=[2,4080,11421];sys.front=102;sys.contexts[102]=(2,0);sys.activeSpaceID=1
            wm.rememberNativeFocus(102,windows)
            var candidates=windows
            switch failure {
            case "foreign":candidates[1].space=2
            case "missing":candidates.removeAll{$0.wid==2}
            case "hidden":wm.hidden=[Hidden(wid:2,pid:102,owner:"Fixture",space:1,rect:windows[1].rect.arr)]
            case "protected":sys.protectedPIDs.insert(102)
            case "modal":sys.contexts[102]=(2,2)
            case "unknown":sys.contexts[102]=(2,4)
            case "owner":sys.pidlevel[2]=(999,0)
            default:sys.births[102]="reused-owner"
            }
            XCTAssertTrue(try wm.command("float 2",f.area,1,candidates).hasPrefix("float refused"),failure)
            XCTAssertEqual(wm.floating,Set([2,4080,11421]),failure)
        }
    }
    func testImplicitFloatFallbackSkipsHiddenFrontWindow() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        sys.activeSpaceID=1;wm.floating=[4080]
        wm.hidden=[Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:windows[0].rect.arr)]
        XCTAssertEqual(try wm.command("float",f.area,1,windows),"ok")
        XCTAssertEqual(wm.floating,Set([2,4080]))
    }
    func testMoveLeftUsesActualNativeRightKeyWhileCGFrontRemainsLeft() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        sys.front=102;sys.contexts[102]=(2,0);sys.activeSpaceID=1
        XCTAssertEqual(windows.first?.wid,1)
        XCTAssertEqual(try wm.command("move l",f.area,1,windows),"ok")
        let layout=wm.layout(f.area,wm.sp(1))
        XCTAssertLessThan(try XCTUnwrap(layout[2]).x,try XCTUnwrap(layout[1]).x)
        XCTAssertFalse(sys.calls.contains{$0.array?.first == .string("ax_focus")}) // No raise workaround.
    }
    func testCommandNativeKeyRejectsModalUnknownForeignSpaceAndBirthOrOwnerMismatch() throws {
        for failure in ["menu","modal","unknown","child","fullscreen","space","offscreen","owner","birth","role","front"] {
            let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
            sys.front=102;sys.contexts[102]=(2,0);sys.activeSpaceID=1
            wm.rememberNativeFocus(102,windows)
            var candidates=windows
            switch failure {
            case "menu":sys.contexts[102]=(2,1)
            case "modal":sys.contexts[102]=(2,2)
            case "unknown":sys.contexts[102]=(2,4)
            case "child":sys.contexts[102]=(2,8)
            case "fullscreen":sys.contexts[102]=(2,16)
            case "space":sys.activeSpaceID=2
            case "offscreen":candidates[1].on=false
            case "owner":sys.pidlevel[2]=(999,0)
            case "birth":sys.births[102]="reused-owner"
            case "role":sys.tileableM[2]=0
            default:sys.front=101;sys.contexts[101]=(2,0)
            }
            XCTAssertNil(wm.nativeCommandWindow(1,candidates,wm.layout(f.area,wm.sp(1))),failure)
        }
    }
    func testCloseWithoutExplicitIDUsesNativeKeyboardWindowInsteadOfCGFront() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        sys.front=102;sys.contexts[102]=(2,0);sys.activeSpaceID=1;sys.deferredClose=true
        XCTAssertTrue(try wm.command("close",f.area,1,windows).contains("2"))
        XCTAssertNotNil(wm.closeRequests[2]);XCTAssertNil(wm.closeRequests[1])
    }
    func testOrderedOutFormerNativeKeyRecoversBeforeWindowServerDisposal() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        sys.front=101;sys.contexts[101]=(1,0);wm.sp(1).focus=1
        wm.rememberNativeFocus(101,windows)
        var orderedOut=windows;orderedOut[0].on=false;orderedOut[0].space=0
        sys.contexts[101]=(nil,32)
        _=wm.sync(f.area,1,orderedOut)
        XCTAssertEqual(sys.winPidLevel(1).pid,101) // Native object still exists.
        XCTAssertEqual(wm.sp(1).tree?.wid,2)
        XCTAssertEqual(sys.calls.filter{$0.array?.first == .string("ax_focus")}.count,1)
        XCTAssertEqual(wm.sp(1).focus,2)
    }
    func testOrderedOutFocusEvidenceRejectsForeignSpaceUnknownDialogsAndOwnerReuse() throws {
        for failure in ["foreign-space","unknown","modal","menu","child","fullscreen","birth","owner","hidden"] {
            let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
            sys.front=101;sys.contexts[101]=(1,0);wm.sp(1).focus=1
            wm.rememberNativeFocus(101,windows)
            var orderedOut=windows;orderedOut[0].on=false;orderedOut[0].space=0
            sys.contexts[101]=(nil,32)
            switch failure {
            case "foreign-space":orderedOut[0].space=2
            case "unknown":sys.contexts[101]=(nil,32|4)
            case "modal":sys.contexts[101]=(nil,32|2)
            case "menu":sys.contexts[101]=(nil,32|1)
            case "child":sys.contexts[101]=(nil,32|8)
            case "fullscreen":sys.contexts[101]=(nil,32|16)
            case "birth":sys.births[101]="reused-owner"
            case "owner":sys.pidlevel[1]=(999,0)
            default:wm.hidden=[Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:windows[0].rect.arr)]
            }
            XCTAssertFalse(wm.retiredFocusedWindow(1,space:1,windows:orderedOut),failure)
            _=wm.sync(f.area,1,orderedOut)
            XCTAssertFalse(sys.calls.contains{$0.array?.first == .string("ax_focus")},failure)
        }
    }
    func testCloseFocusRetriesAfterTemporaryUnknownWithoutAnotherCloseEvent() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        let remaining=windows.filter{$0.wid==2};wm.sp(1).tree=Node(leaf:2)
        sys.front=101;sys.contexts[101]=(nil,4)
        wm.focusAfterClose(f.area,1,remaining,windows.first{$0.wid==1}?.rect)
        XCTAssertNotNil(wm.closeFocusRetry)
        let snapshot=Snapshot(space:1,stable:true,area:f.area,windows:remaining)
        wm.pollCloseFocusRetry(snapshot);sys.t+=0.1
        XCTAssertFalse(sys.calls.contains{$0.array?.first == .string("ax_focus")})
        sys.contexts[101]=(nil,32);wm.pollCloseFocusRetry(snapshot)
        XCTAssertEqual(sys.calls.filter{$0.array?.first == .string("ax_focus")}.count,1)
        XCTAssertEqual(wm.sp(1).focus,2);XCTAssertNil(wm.closeFocusRetry)
    }
    func testCloseFocusRetryKeepsDialogsAndNewNativeKeyAndHasBoundedLifetime() throws {
        for blocked in [1,2,4,8,16] {
            let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
            let remaining=windows.filter{$0.wid==2};wm.sp(1).tree=Node(leaf:2)
            sys.front=101;sys.contexts[101]=(nil,4)
            wm.focusAfterClose(f.area,1,remaining,nil)
            let snapshot=Snapshot(space:1,stable:true,area:f.area,windows:remaining)
            sys.contexts[101]=(nil,blocked);wm.pollCloseFocusRetry(snapshot);wm.pollCloseFocusRetry(snapshot)
            XCTAssertFalse(sys.calls.contains{$0.array?.first == .string("ax_focus")})
            sys.t+=1.51;wm.pollCloseFocusRetry(snapshot);XCTAssertNil(wm.closeFocusRetry)
        }
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        let remaining=windows.filter{$0.wid==2};wm.sp(1).tree=Node(leaf:2)
        sys.front=101;sys.contexts[101]=(nil,4);wm.focusAfterClose(f.area,1,remaining,nil)
        sys.front=102;sys.contexts[102]=(2,0)
        let snapshot=Snapshot(space:1,stable:true,area:f.area,windows:remaining)
        wm.pollCloseFocusRetry(snapshot);wm.pollCloseFocusRetry(snapshot)
        XCTAssertNil(wm.closeFocusRetry)
        XCTAssertFalse(sys.calls.contains{$0.array?.first == .string("ax_focus")})
        sys.contexts[102]=(nil,4);wm.focusAfterClose(f.area,1,remaining,nil)
        XCTAssertNotNil(wm.closeFocusRetry)
        _=wm.queueFocus(remaining[0],space:1,reason:.keyboard)
        XCTAssertNil(wm.closeFocusRetry) // Explicit user selection supersedes fallback.
    }
    func testFailedCloseFocusRequestCanRetryAndCapsWorkerDeadline() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        let remaining=windows.filter{$0.wid==2};wm.sp(1).tree=Node(leaf:2)
        sys.front=101;sys.contexts[101]=(nil,32);sys.focusResult = -1
        wm.focusAfterClose(f.area,1,remaining,nil)
        XCTAssertEqual(wm.closeFocusRetry?.queued,false)
        sys.t+=0.11;sys.deferredFocus=true
        let snapshot=Snapshot(space:1,stable:true,area:f.area,windows:remaining)
        wm.pollCloseFocusRetry(snapshot);wm.pollCloseFocusRetry(snapshot)
        XCTAssertEqual(sys.focusCallbacks.count,1)
        XCTAssertLessThanOrEqual(sys.focusCallbacks[0].0.deadline,try XCTUnwrap(wm.closeFocusRetry).deadline)
        sys.focusCallbacks[0].1(true)
        XCTAssertNil(wm.closeFocusRetry);XCTAssertEqual(wm.sp(1).focus,2)
    }
    func testContinuousPointerPositionKeepsInflightReceiverTicketAndSourceKeyRaceDoesNotRetry() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        wm.cfg=try NativeRuntimeConfig.build(base:wm.cfg,document:JSON.parse("{\"runtime\":{\"pointer_focus_pause_ms\":0}}"))
        let target=try XCTUnwrap(windows.first{$0.wid==2})
        sys.front=101;sys.contexts[101]=(1,0);sys.deferredFocus=true;sys.pointerHint=(2,102)
        sys.m=(target.x+40,target.y+40);wm.followMouse(1,windows)
        sys.m=(target.x+45,target.y+40);wm.followMouse(1,windows)
        XCTAssertEqual(sys.focusCallbacks.count,1)
        XCTAssertEqual(wm.focusPending?.pointer?.0,target.x+40)
        sys.contexts[101]=(3,2) // A newer user dialog owns focus.
        sys.focusCallbacks[0].1(false)
        XCTAssertNil(wm.focusPending);XCTAssertNil(wm.pointerFocusRetryPoint)
    }
    func testMovingPointerRetainsExactReceiverAndDifferentWindowSupersedesTicket() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        sys.deferredFocus=true;sys.front=101;sys.contexts[101]=(1,0)
        let target=windows.first{$0.wid==2}!
        for x in stride(from:target.x+10,to:target.x+200,by:5) {
            sys.m=(x,target.y+30);sys.pointerHint=(2,102)
            XCTAssertTrue(wm.queueFocus(target,space:1,reason:.pointer,pointer:sys.m))
        }
        XCTAssertEqual(sys.focusCallbacks.count,1)
        let first=windows.first{$0.wid==1}!;sys.m=(first.x+30,first.y+30);sys.pointerHint=(1,101)
        XCTAssertTrue(wm.queueFocus(first,space:1,reason:.pointer,pointer:sys.m))
        XCTAssertEqual(sys.focusCallbacks.count,2)
        sys.focusCallbacks[0].1(true);XCTAssertEqual(wm.focusPending?.wid,1)
    }
    func testCurrentNativeReceiverAllowsMotionButFallbackNeverPassesAnOverlay() {
        let target=WinInfo(wid:20,pid:2,owner:"Fixture",x:100,y:0,w:300,h:200,on:true,space:1)
        let request=FocusRequest(pid:2,wid:20,space:1,birth:"b",sourcePID:1,reason:.pointer,deadline:1,pointer:(110,10))
        var snapshot=Snapshot(space:1,stable:true,area:Rect(0,0,800,600),windows:[target])
        XCTAssertTrue(request.pointerAllows((350,150),hint:(20,2),snapshot:snapshot,nativeBounds:target.rect))
        XCTAssertFalse(request.pointerAllows((350,150),hint:(21,2),snapshot:snapshot,nativeBounds:target.rect))
        XCTAssertFalse(request.pointerAllows((350,150),hint:(20,9),snapshot:snapshot,nativeBounds:target.rect))
        XCTAssertFalse(request.pointerAllows((350,150),hint:(20,nil),snapshot:snapshot,nativeBounds:target.rect))
        XCTAssertTrue(request.pointerAllows((350,150),hint:nil,snapshot:snapshot,nativeBounds:target.rect))
        var overlay=WinInfo(wid:33,pid:9,owner:"NotificationCenter",x:100,y:0,w:300,h:200,on:true,space:1);overlay.layer=21
        snapshot.windows.insert(overlay,at:0)
        XCTAssertFalse(request.pointerAllows((350,150),hint:nil,snapshot:snapshot,nativeBounds:target.rect))
        XCTAssertTrue(request.pointerAllows((350,150),hint:(20,2),snapshot:snapshot,nativeBounds:target.rect),"fresh native receiver may identify the real window below a phantom CG box")
        snapshot.space=2;XCTAssertFalse(request.pointerAllows((350,150),hint:(20,2),snapshot:snapshot,nativeBounds:target.rect))
    }
    func testExplicitPointerCanReplaceVisiblePrimaryKeyButFallbackCannot() {
        let source=WinInfo(wid:10,pid:1,owner:"Fixture",x:0,y:0,w:100,h:100,on:true,space:1)
        let target=WinInfo(wid:20,pid:2,owner:"Fixture",x:100,y:0,w:100,h:100,on:true,space:1)
        let snapshot=Snapshot(space:1,stable:true,area:Rect(0,0,200,100),windows:[source,target])
        let pointer=FocusRequest(pid:2,wid:20,space:1,birth:"2:1:0",sourcePID:1,reason:.pointer,deadline:1,pointer:(150,50))
        XCTAssertTrue(pointer.sourceAllows((10,0),snapshot:snapshot,sourcePrimary:true))
        XCTAssertFalse(pointer.sourceAllows((10,0),snapshot:snapshot,sourcePrimary:false))
        for flags in [1,2,4,8,16] {XCTAssertFalse(pointer.sourceAllows((10,flags),snapshot:snapshot,sourcePrimary:true))}
        for reason in [FocusReason.close,.space] {
            let automatic=FocusRequest(pid:2,wid:20,space:1,birth:"2:1:0",sourcePID:1,reason:reason,deadline:1)
            XCTAssertFalse(automatic.sourceAllows((10,0),snapshot:snapshot,sourcePrimary:true))
        }
        let noPointer=FocusRequest(pid:2,wid:20,space:1,birth:"2:1:0",sourcePID:1,reason:.pointer,deadline:1)
        XCTAssertFalse(noPointer.sourceAllows((10,0),snapshot:snapshot,sourcePrimary:true))
    }
    func testFailedPointerFocusRetriesStationaryPointAndTrustsNativeKeyOverRememberedFocus() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair())
        wm.cfg=try NativeRuntimeConfig.build(base:wm.cfg,document:JSON.parse("{\"runtime\":{\"pointer_focus_pause_ms\":0}}"))
        let target=try XCTUnwrap(windows.first{$0.wid==2})
        sys.front=101;sys.contexts[101]=(1,0);sys.focusResult = -1
        sys.m=(target.x+40,target.y+40);sys.pointerHint=(2,102)
        // This old requested focus used to short circuit the real native key.
        wm.fwant=2;wm.frontPid=102;wm.ft=sys.t
        wm.followMouse(1,windows)
        XCTAssertEqual(sys.calls.filter{$0.array?.first == .string("ax_focus")}.count,1)
        XCTAssertNotNil(wm.pointerFocusRetryPoint)
        wm.followMouse(1,windows)
        XCTAssertEqual(sys.calls.filter{$0.array?.first == .string("ax_focus")}.count,1)
        sys.t+=0.11;sys.focusResult=0
        wm.followMouse(1,windows)
        XCTAssertEqual(sys.calls.filter{$0.array?.first == .string("ax_focus")}.count,2)
        XCTAssertNil(wm.pointerFocusRetryPoint);XCTAssertEqual(wm.sp(1).focus,2)
        sys.contexts[101]=(2,0);wm.mp=nil
        wm.followMouse(1,windows)
        XCTAssertEqual(sys.calls.filter{$0.array?.first == .string("ax_focus")}.count,2)
    }
    func testCoveredTargetStillRequiresFreshOrdinarySpaceAndExactOwner() {
        var window=WinInfo(wid:20,pid:2,owner:"Fixture",x:0,y:0,w:100,h:100,on:false,space:1);window.alpha=0
        var snapshot=Snapshot(space:1,stable:true,area:window.rect,windows:[window])
        let request=FocusRequest(pid:2,wid:20,space:1,birth:"2:1:0",sourcePID:1,reason:.close,deadline:1)
        XCTAssertNil(request.target(in:snapshot));XCTAssertNotNil(request.target(in:snapshot,covered:true))
        snapshot.windows[0].pid=3;XCTAssertNil(request.target(in:snapshot,covered:true))
        snapshot.windows[0].pid=2;snapshot.windows[0].nativeFullscreen=true;XCTAssertNil(request.target(in:snapshot,covered:true))
        snapshot.windows[0].nativeFullscreen=false;snapshot.space=2;XCTAssertNil(request.target(in:snapshot,covered:true))
        snapshot.space=1;snapshot.stable=false;XCTAssertNil(request.target(in:snapshot,covered:true))
    }
    func testNoKeyAllowsRecoveryWhileUnknownAndPositiveGuardsBlock() {
        let snapshot=Snapshot(space:1,stable:true,area:Rect(0,0,100,100),windows:[])
        let request=FocusRequest(pid:2,wid:20,space:1,birth:"2:1:0",sourcePID:1,reason:.close,deadline:1)
        XCTAssertTrue(request.sourceAllows((nil,32),snapshot:snapshot,sourcePrimary:true))
        for flags in [4,1|32,2|32,8|32,16|32,4|32] {
            XCTAssertFalse(request.sourceAllows((nil,flags),snapshot:snapshot,sourcePrimary:true))
        }
    }
    func testNilSourceKeyboardIntentRetainsPositiveGuardsAndFreshTargetFence() {
        let window=WinInfo(wid:20,pid:2,owner:"Fixture",x:0,y:0,w:100,h:100,on:true,space:1)
        var snapshot=Snapshot(space:1,stable:true,area:window.rect,windows:[window])
        let request=FocusRequest(pid:2,wid:20,space:1,birth:"2:1:0",sourcePID:nil,reason:.keyboard,deadline:1)
        XCTAssertTrue(request.sourceMatches(nil));XCTAssertFalse(request.sourceMatches(9))
        XCTAssertTrue(request.targetAllows((nil,NativeFocusFlags.noKey)))
        for flags in [NativeFocusFlags.menu,NativeFocusFlags.modal,NativeFocusFlags.child,NativeFocusFlags.fullscreen,NativeFocusFlags.unknown] {
            XCTAssertFalse(request.targetAllows((20,flags)))
        }
        XCTAssertTrue(request.sourceAllows((nil,4),snapshot:snapshot,sourcePrimary:true))
        XCTAssertFalse(request.sourceAllows((nil,1|32),snapshot:snapshot,sourcePrimary:true))
        XCTAssertNotNil(request.target(in:snapshot))
        snapshot.space=2;XCTAssertNil(request.target(in:snapshot))
        snapshot.space=1;snapshot.locked=true;XCTAssertNil(request.target(in:snapshot))
    }
}
