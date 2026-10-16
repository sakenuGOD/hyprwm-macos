import CChan
@testable import HyprCore
import XCTest

final class MigrationParityTests: XCTestCase {
    func world() throws -> (WM,FakeWorld,FakeEngine,[WinInfo]) {
        let fixture=ProductionPolicyTests()
        return try fixture.world(fixture.pair())
    }
    var area: Rect { ProductionPolicyTests().area }
    func record(_ window: WinInfo, space: Int, tiled: Bool = true) -> Hidden {
        Hidden(wid:window.wid,pid:window.pid,owner:window.owner,space:space,rect:window.rect.arr,
               extra:.object([("swift_birth",.string("birth-\(window.wid)")),("tiled",.bool(tiled))]))
    }
    func testSaveRefusalRetainsVisibleTileAndDoesNotStartCloseAnimation() throws {
        let (wm,sys,eng,windows)=try world(), before=wm.sp(1).tree!.json
        let response=wm.closeAnim(area,1,windows,windows[0])
        XCTAssertTrue(response.contains("requested")); XCTAssertEqual(wm.sp(1).tree!.json,before)
        XCTAssertTrue(wm.closing.isEmpty); XCTAssertTrue(wm.later.isEmpty); XCTAssertTrue(eng.ch.ops.isEmpty)
        XCTAssertTrue(sys.calls.contains(.array([.string("ws_close"),.int(101),.int(1)])))
        var sheet=windows[0]; sheet.wid=9; sheet.name="Save"; sys.tileableM[9]=0
        _=wm.sync(area,1,[sheet]+windows)
        XCTAssertEqual(wm.sp(1).tree!.json,before); XCTAssertFalse(wm.restoring.contains(1))
    }
    func testForeignHiddenRestoreCannotRevealBeforeSpaceACK() throws {
        let (wm,sys,eng,windows)=try world()
        var foreign=windows[0]; foreign.space=2
        wm.hidden=[record(foreign,space:2)]
        _=wm.unhide(area,1,[foreign],which:.wids([foreign.wid]))
        XCTAssertEqual(wm.hidden.count,1); XCTAssertNotNil(wm.restorePending[1]); XCTAssertFalse(wm.restoring.contains(1))
        XCTAssertEqual(eng.ch.ops.filter { $0["op"]?.string == "space" }.count,1)
        XCTAssertFalse(eng.ch.ops.contains { $0["op"]?.string == "alpha" && $0["a"]?.double == 1 })
        wm.completeRestores(area,1,[foreign]); XCTAssertEqual(wm.hidden.count,1)
        foreign.space=1; wm.completeRestores(area,1,[foreign])
        XCTAssertTrue(wm.hidden.isEmpty); XCTAssertTrue(wm.restoring.contains(1)); XCTAssertTrue(wm.restorePending.isEmpty)
        XCTAssertNotNil(wm.restoreFrom[1]); XCTAssertFalse(sys.calls.contains(.string("spawn?")))
    }
    func testInterruptedRestoreRemainsHiddenAndRetryable() throws {
        let (wm,sys,_,windows)=try world()
        var foreign=windows[0]; foreign.space=2; wm.hidden=[record(foreign,space:2)]
        _=wm.unhide(area,1,[foreign]); sys.t+=2.1
        wm.completeRestores(area,1,[foreign]); XCTAssertEqual(wm.hidden.count,1); XCTAssertTrue(wm.restorePending.isEmpty)
        _=wm.unhide(area,1,[foreign]); XCTAssertNotNil(wm.restorePending[1])
    }
    func testFloatingRestoreUsesCapturedClassificationWhileAXIsUnavailable() throws {
        let (wm,sys,eng,windows)=try world(), window=windows[0]
        wm.hidden=[record(window,space:1,tiled:false)]; sys.tileableM[window.wid] = -1
        _=wm.unhide(area,1,windows)
        XCTAssertTrue(wm.floating.contains(window.wid)); XCTAssertFalse(wm.restoring.contains(window.wid))
        XCTAssertTrue(eng.ch.ops.contains { $0["op"]?.string == "alpha" && $0["a"]?.double == 1 && ($0["dur"]?.double ?? 0) > 0 })
    }
    func testParkingWaitsForRealFadeCompletionAndCommandDrain() throws {
        let (wm,_,eng,windows)=try world(), window=windows[0]
        wm.hidden=[record(window,space:1)]
        let park=Rect(1500,window.y,window.w,window.h)
        eng.ch.eng=[EngWin(wid:1,pos:(window.x,window.y),size:(window.w,window.h),alphaActive:true,curAlpha:0.2,a:window.rect)]
        wm.parkHidden(1,park,deadline:2000)
        XCTAssertFalse(eng.ch.ops.contains { $0["op"]?.string == "warp" }); XCTAssertEqual(wm.later.count,1)
        eng.ch.eng=[EngWin(wid:1,pos:(window.x,window.y),size:(window.w,window.h),curAlpha:0,a:window.rect)]
        wm.parkHidden(1,park,deadline:2000)
        XCTAssertTrue(eng.ch.ops.contains { $0["op"]?.string == "warp" })
    }
    func testNativeFullscreenPinsWholeSourceThroughDepartureAndReturn() throws {
        let (wm,_,eng,windows)=try world(), before=wm.sp(1).tree!.json
        var entering=windows; entering[0].space=0; entering[0].nativeFullscreen=true
        XCTAssertTrue(wm.updateNativeFullscreen(entering,1))
        XCTAssertTrue(wm.nativeSuspendedSpaces.contains("1"))
        let result=wm.sync(area,1,entering)
        XCTAssertTrue(result.1.isEmpty); XCTAssertEqual(wm.sp(1).tree!.json,before)
        XCTAssertTrue(eng.ch.ops.contains { $0["op"]?.string == "forget" && $0["wid"]?.int == 2 })
        var returning=windows; returning[0].on=false
        _=wm.updateNativeFullscreen(returning,1)
        XCTAssertTrue(wm.nativeFullscreenWindows.contains(1)); XCTAssertEqual(wm.sp(1).tree!.json,before)
        _=wm.updateNativeFullscreen(windows,1)
        XCTAssertTrue(wm.nativeSuspendedSpaces.isEmpty); XCTAssertFalse(wm.nativeFullscreenWindows.contains(1))
        _=wm.sync(area,1,windows); XCTAssertEqual(wm.sp(1).tree!.json,before)
    }
    func testNativeFullscreenSpaceCannotRetileOrRestoreHiddenWindow() throws {
        let (wm,_,eng,windows)=try world(), before=wm.sp(1).tree!.json
        wm.nativeSpaceType=4
        _=wm.sync(area,1,windows); wm.apply(area,1,windows,force:true)
        XCTAssertEqual(wm.sp(1).tree!.json,before); XCTAssertFalse(eng.ch.ops.contains { $0["op"]?.string == "geom" })
    }
    func testConfirmedFullscreenOnAnotherSpaceReleasesSourceAllocationAndRestoresItsSlotOnReturn() throws {
        let (wm,sys,_,windows)=try world(),before=wm.sp(1).tree!.json
        var departing=windows;departing[0].space=0;departing[0].nativeFullscreen=true
        _=wm.updateNativeFullscreen(departing,1)
        var settled=windows;settled[0].space=99;settled[0].nativeFullscreen=true
        sys.front=102;sys.contexts[102]=(2,0);wm.nativeSpaceType=0
        _=wm.sync(area,1,settled)
        XCTAssertFalse(wm.nativeSuspendedSpaces.contains("1"),"A confirmed fullscreen window on another Space must not freeze its source desktop")
        let rects=wm.layout(area,wm.sp(1))
        XCTAssertEqual(rects.keys,[2]);XCTAssertGreaterThan(try XCTUnwrap(rects[2]).w,area.w*0.9)
        XCTAssertEqual(wm.sp(1).tree!.json,before,"Keep the return position without reserving its pixels")
        _=wm.sync(area,1,windows)
        XCTAssertEqual(wm.layout(area,wm.sp(1)).keys,[1,2]);XCTAssertEqual(wm.sp(1).tree!.json,before)
    }
    func testLockAndOverlayPreserveNativeInputOwnership() throws {
        let (wm,sys,eng,windows)=try world()
        sys.locked=true; XCTAssertTrue(try wm.command("hide",area,1,windows).contains("locked"))
        wm.apply(area,1,windows,force:true); XCTAssertTrue(eng.ch.ops.isEmpty)
        sys.locked=false; sys.overlay=true; sys.m=(windows[1].x+20,windows[1].y+20)
        wm.followMouse(1,windows)
        XCTAssertFalse(sys.calls.contains { $0.array?.first?.string == "ax_focus" })
    }
    func testFullscreenChildDoesNotConvertItsBackgroundAppPeerIntoFullscreen() throws {
        let f=ProductionPolicyTests(),tree=Node(split:"v",ratio:0.5,a:Node(leaf:1),b:f.pair("h"))
        tree.b.a.wid=2;tree.b.b.wid=3
        let (wm,sys,_,original)=try f.world(tree),saved=tree.json
        var windows=original;let manager=windows.firstIndex{$0.wid==1}!,vm=windows.firstIndex{$0.wid==3}!
        windows[vm].pid=windows[manager].pid;windows[vm].space=99;windows[vm].nativeFullscreen=true
        sys.front=999;sys.contexts[999]=(nil,32)
        for background in [true,false,true] {
            for i in windows.indices where windows[i].wid != 3 {windows[i].on = !background}
            _=wm.updateNativeFullscreen(windows,background ? 2:1)
            XCTAssertEqual(wm.nativeFullscreenWindows,Set([3]),"Offscreen on an ordinary desktop is not native fullscreen")
            XCTAssertFalse(wm.nativeSuspendedSpaces.contains("1"),"An inactive source does not lose its ordinary peers")
            XCTAssertEqual(wm.sp(1).tree?.json,saved,"Keep the VM return position without changing the manager's identity")
        }
    }
    func testFullscreenSourceReconcilesClosedOrTransferredPeerAndAdmitsNewWindow() throws {
        for transferred in [false,true] {
            let (wm,sys,_,original)=try world()
            wm.cfgSink=SnapshotHandoffTests.Recorder();wm.rescued=true;wm.lastSpace=2;wm.frontPid=103
            var windows=original;let owner=windows.firstIndex{$0.wid==1}!,peer=windows.firstIndex{$0.wid==2}!
            windows[owner].space=99;windows[owner].on=false;windows[owner].nativeFullscreen=true
            if transferred {windows[peer].space=2;windows[peer].on=false}
            else {windows.remove(at:peer);sys.bounds[2]=nil}
            let new=WinInfo(wid:3,pid:103,owner:"Fixture",x:40,y:50,w:500,h:400,on:true,space:1)
            windows.append(new);sys.tileableM[3]=1;sys.pidlevel[3]=(103,0);sys.bounds[3]=new.rect;sys.births[103]="birth-3"
            sys.front=103;sys.contexts[103]=(3,0);sys.activeSpaceID=1
            sys.nativeSnapshot=Snapshot(space:1,stable:true,area:area,windows:windows)
            wm.tick(socketReady:false);sys.t+=0.1;wm.tick(socketReady:false)
            XCTAssertFalse(wm.nativeSuspendedSpaces.contains("1"),"A departed ordinary peer must not permanently freeze a fullscreen window's source desktop")
            XCTAssertTrue(wm.sp(1).tree?.contains(3)==true,"New windows must enter the source tiling without clicks")
            XCTAssertFalse(wm.sp(1).tree?.contains(2)==true)
            XCTAssertEqual(wm.layout(area,wm.sp(1)).keys,[3])
        }
    }
    func testFullscreenDepartureExpandsSourcePeerInFullTickWithoutClick() throws {
        for visitedFullscreenDesktop in [false,true] {
            let (wm,sys,eng,original)=try world(),sink=SnapshotHandoffTests.Recorder()
            wm.cfgSink=sink;wm.rescued=true;wm.lastSpace=1;wm.frontPid=101
            sys.front=101;sys.contexts[101]=(1,NativeFocusFlags.fullscreen)
            var windows=original;let owner=windows.firstIndex{$0.wid==1}!
            windows[owner].space=99;windows[owner].nativeFullscreen=true
            if visitedFullscreenDesktop {
                for i in windows.indices {windows[i].on=windows[i].wid==1}
                var full=Snapshot(space:99,stable:true,area:area,windows:windows);full.spaceType=4
                sys.activeSpaceID=99;sys.nativeSnapshot=full
                wm.tick(socketReady:false)
            }
            for i in windows.indices {windows[i].on=windows[i].wid==2}
            sys.front=102;sys.contexts[102]=(2,0);sys.activeSpaceID=1
            sys.nativeSnapshot=Snapshot(space:1,stable:true,area:area,windows:windows)
            eng.ch.ops=[];sink.jobs=[];sys.t+=0.1;wm.tick(socketReady:false)
            let full=try XCTUnwrap(wm.layout(area,wm.sp(1))[2])
            XCTAssertGreaterThan(full.w,area.w*0.9)
            XCTAssertEqual(wm.target[2],full,"The retained fullscreen return slot must not leave its peer at half width")
            XCTAssertTrue(sink.jobs.contains{$0.wid==2 && $0.to==full})
            XCTAssertTrue(eng.ch.ops.contains{$0["wid"] == .int(2) && $0["to"]==full.json})
        }
    }
    func testFullscreenSourceExpandsInBackgroundWithoutReturningToOrdinaryDesktop() throws {
        let (wm,sys,eng,original)=try world(),sink=SnapshotHandoffTests.Recorder(),saved=wm.sp(1).tree!.json
        wm.cfgSink=sink;wm.rescued=true;wm.lastSpace=1;wm.frontPid=101;wm.launcherAreas[1]=area
        sys.front=101;sys.contexts[101]=(1,NativeFocusFlags.fullscreen);sys.activeSpaceID=99
        var windows=original
        for i in windows.indices {windows[i].on=windows[i].wid==1}
        let owner=windows.firstIndex{$0.wid==1}!;windows[owner].space=99;windows[owner].nativeFullscreen=true
        var snapshot=Snapshot(space:99,stable:true,area:area,windows:windows);snapshot.spaceType=4;sys.nativeSnapshot=snapshot
        wm.tick(socketReady:false)
        let only=SpaceState();only.tree=Node(leaf:2);let full=try XCTUnwrap(wm.layout(area,only)[2])
        XCTAssertEqual(wm.target[2],full,"Do not wait for the user to return before expanding the source peer")
        XCTAssertTrue(sink.jobs.contains{$0.wid==2 && $0.to==full})
        XCTAssertEqual(wm.sp(1).tree?.json,saved,"Retain the fullscreen return slot")
        XCTAssertEqual(sys.activeSpaceID,99)
        XCTAssertFalse(sys.calls.contains{$0.array?.first == .string("ax_focus")})
        XCTAssertFalse(eng.ch.ops.contains{$0["op"] == .string("space")})
        let count=sink.jobs.count;sys.t+=0.3;wm.tick(socketReady:false)
        XCTAssertEqual(sink.jobs.count,count,"Do not reconfigure unchanged background windows every tick")
    }
    func testBackgroundFullscreenReflowDoesNotTouchHiddenForeignOrTransitionalPeers() throws {
        for mode in ["hidden","owner","protected","zero"] {
            let (wm,sys,_,original)=try world(),sink=SnapshotHandoffTests.Recorder()
            wm.cfgSink=sink;wm.rescued=true;wm.lastSpace=1;wm.launcherAreas[1]=area
            sys.front=101;sys.contexts[101]=(1,NativeFocusFlags.fullscreen);sys.activeSpaceID=99
            var windows=original
            for i in windows.indices {windows[i].on=windows[i].wid==1}
            let owner=windows.firstIndex{$0.wid==1}!,peer=windows.firstIndex{$0.wid==2}!
            windows[owner].space=99;windows[owner].nativeFullscreen=true
            if mode=="hidden" {wm.hidden=[record(windows[peer],space:1)]}
            if mode=="owner" {sys.pidlevel[2]=(999,0)}
            if mode=="protected" {sys.protectedPIDs=[102]}
            if mode=="zero" {windows[peer].space=0}
            var snapshot=Snapshot(space:99,stable:true,area:area,windows:windows);snapshot.spaceType=4;sys.nativeSnapshot=snapshot
            wm.tick(socketReady:false);XCTAssertTrue(sink.jobs.isEmpty,mode)
        }
    }
    func testRuleOpacityNoAnimationAndSetpropAreActuallyConsumed() throws {
        let (wm,_,eng,windows)=try world()
        wm.cfg=try NativeRuntimeConfig.build(base:wm.cfg,document:JSON.parse("{\"appearance\":{\"active_opacity\":0.8,\"inactive_opacity\":0.6},\"window_rules\":[{\"match\":{\"class\":\"Fixture\"},\"opacity\":\"0.5 override 0.25\",\"no_anim\":true,\"no_follow_mouse\":true}]}"))
        wm.sp(1).focus=1
        XCTAssertEqual(wm.windowOpacity(windows[0],1),0.5)
        XCTAssertEqual(wm.windowOpacity(windows[1],1),0.15,accuracy:1e-12)
        wm.apply(area,1,windows,force:true,opening:[1])
        XCTAssertTrue(eng.ch.ops.contains { $0["op"]?.string == "warp" && $0["wid"]?.int == 1 })
        XCTAssertFalse(eng.ch.ops.contains { $0["op"]?.string == "geom" })
        XCTAssertTrue(eng.ch.ops.contains { $0["op"]?.string == "alpha" && $0["a"]?.double == 0.5 && $0["dur"]?.double == 0 })
        _=try wm.propertyCommand(["setprop","opacity","0.7"],windows[0]); XCTAssertEqual(wm.windowOpacity(windows[0],1),0.7)
        _=try wm.propertyCommand(["setprop","opacity","unset"],windows[0]); XCTAssertEqual(wm.windowOpacity(windows[0],1),0.5)
    }
    func testStaticFloatLifetimeSurvivesTitleChangeButNotPIDReuse() throws {
        let (wm,sys,_,windows)=try world()
        wm.cfg=try NativeRuntimeConfig.build(base:wm.cfg,document:JSON.parse("{\"window_rules\":[{\"match\":{\"title\":\"^Viewer$\"},\"float\":true}]}")); wm.floatRules=wm.cfg.floatRules
        var window=windows[0]; window.name="Viewer"
        XCTAssertFalse(wm.tileable(window)); window.name="Other title"; XCTAssertFalse(wm.tileable(window))
        sys.births[window.pid]="new-incarnation"; XCTAssertTrue(wm.tileable(window))
    }
    func testAppearanceCarrierPublishesConfiguredGradientCloseCloneAndGPUValues() throws {
        let path=NSTemporaryDirectory()+"hyprwm-appearance-\(getpid()).chan"
        let channel=try LiveChannel(path:path,create:true); defer { unlink(path) }
        channel.raw.pointee.version |= UInt32(CH_CAP_EFFECTS)|UInt32(CH_CAP_SHADOW)
        let cfg=try NativeRuntimeConfig.build(base:Fx.config(),document:JSON.parse("{\"appearance\":{\"rounding\":22,\"border\":{\"size\":3,\"active\":{\"colors\":[\"rgb(ff0000)\",\"rgb(0000ff)\"],\"angle\":45},\"inactive\":\"rgba(11111155)\"},\"glow\":{\"enabled\":true,\"range\":20}}}"))
        try channel.configureAppearance(cfg)
        let typed=channel.base.assumingMemoryBound(to:CChan.ch.self)
        XCTAssertEqual(typed.pointee.deco.width,3); XCTAssertEqual(typed.pointee.deco.radius,22)
        XCTAssertEqual(typed.pointee.deco.ngrad,8); XCTAssertEqual(typed.pointee.h.reserved.3,0.92.bitPattern)
        XCTAssertEqual(typed.pointee.h.cmd_head,2)
        let commands=(channel.base+MemoryLayout<ch_hdr>.stride+Int(CH_NCURVE)*MemoryLayout<ch_curve>.stride).assumingMemoryBound(to:ch_cmd.self)
        XCTAssertEqual(commands[0].op,UInt32(OP_EFFECTS)); XCTAssertEqual(commands[0].x,22)
        XCTAssertEqual(commands[0].w,20); XCTAssertEqual(commands[1].op,UInt32(OP_SHADOW))
        XCTAssertEqual(try RGBA.parse("0xff112233"),try RGBA.parse("rgba(112233ff)"))
    }
    func testUnsupportedExactShadowSendsNeutralDisableAndLegacyCarrierRemains() throws {
        let path=NSTemporaryDirectory()+"hyprwm-shadow-disable-\(getpid()).chan"
        let channel=try LiveChannel(path:path,create:true); defer { unlink(path) }
        channel.raw.pointee.version |= UInt32(CH_CAP_SHADOW)
        let cfg=try NativeRuntimeConfig.build(base:Fx.config(),document:JSON.parse("{\"appearance\":{\"shadow\":{\"color_inactive\":\"rgba(ff000044)\"}}}"))
        try channel.configureAppearance(cfg)
        let command=(channel.base+MemoryLayout<ch_hdr>.stride+Int(CH_NCURVE)*MemoryLayout<ch_curve>.stride).assumingMemoryBound(to:ch_cmd.self).pointee
        XCTAssertEqual(command.op,UInt32(OP_SHADOW)); XCTAssertEqual(command.flags,0)
        XCTAssertEqual(command.x,1); XCTAssertEqual(command.y,3)
        XCTAssertEqual(channel.base.assumingMemoryBound(to:CChan.ch.self).pointee.deco.sh_on,1)
    }
    func testMalformedRuleOrAppearanceCannotMutateExistingSnapshot() throws {
        let base=try Fx.config()
        for document in ["{\"window_rules\":[{\"match\":{\"class\":\"[\"},\"no_anim\":true}]}","{\"appearance\":{\"border\":{\"inactive\":\"not-a-color\"}}}","{\"appearance\":{\"shadow\":{\"range\":-1}}}"] {
            XCTAssertThrowsError(try NativeRuntimeConfig.build(base:base,document:JSON.parse(document)))
        }
        XCTAssertEqual(base.general["border_size"]?.double,2)
    }
    func testPlatformIdentityGuardKeepsFinderAndUserLookalikesOrdinary() {
        XCTAssertFalse(SystemUI.protected(executable:"/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",bundle:"com.apple.finder"))
        XCTAssertFalse(SystemUI.protected(executable:"/Applications/NotificationCenter.app/Contents/MacOS/NotificationCenter",bundle:"com.apple.notificationcenterui"))
        XCTAssertTrue(SystemUI.protected(executable:"/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",bundle:"com.apple.dock"))
    }
}
