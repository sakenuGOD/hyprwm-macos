@testable import HyprCore
import CChan
import XCTest

final class MigrationProtocolTests:XCTestCase {
    func binding() throws -> OverviewBinding {
        let nonce=String(repeating:"a",count:32)
        return try OverviewBinding(.object([("schema",.int(1)),("actor",.object([("pid",.int(100)),("birth",.array([.int(100),.int(Int(getuid())),.int(20),.int(30)])),("path",.string("/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"))])),("nonce",.string(nonce)),("endpoint",.string("/private/tmp/re-tools-overview10-\(getuid())-\(nonce)/control.sock")),("image",.object([("path",.string("/tmp/source10.dylib")),("uuid",.string(String(repeating:"b",count:32)))]))]))
    }
    func overview() throws -> (OverviewBinding,OverviewHidden,JSON) {
        let hidden=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:[0,0,400,500],extra:.object([("hidden_intent",.string(String(repeating:"c",count:64)))]))
        let source=try OverviewHidden(record:hidden,parked:Rect(1500,0,400,500),space:1,birth:[101,Int(getuid()),40,50])
        let bound=try binding()
        let commit=JSON.object([("commit_token",.string(String(repeating:"d",count:32))),("wid",.int(1)),("pid",.int(101)),("birth",.array(source.birth.map(JSON.int))),("hidden_intent",.string(source.intent)),("epoch",.int(1)),("nonce",.string(bound.nonce)),("pool_generation",.int(9)),("setup_observed",.bool(true)),("end_order_observed",.bool(true)),("root_cancel_requested",.bool(false)),("inverse_park_observed",.bool(true))])
        return (bound,source,.object([("controller_observed",.bool(true)),("mode",.int(0)),("raw_mode",.int(0)),("overview_active",.bool(false)),("pool_generation",.int(9)),("records",.array([])),("commits",.array([commit]))]))
    }
    func testNativeHotkeyArgvAndTextPreserveLiteralArguments() throws {
        XCTAssertEqual(try CommandArguments.parse("[\"exec\",\"/Applications/My Terminal.app\",\"$(id)\",\"\"]"),["exec","/Applications/My Terminal.app","$(id)",""])
        XCTAssertEqual(try CommandArguments.parse("exec '/Applications/My Terminal.app' \"a b\" c\\ d ''"),["exec","/Applications/My Terminal.app","a b","c d",""])
        XCTAssertThrowsError(try CommandArguments.parse("[\"exec\",1]"));XCTAssertThrowsError(try CommandArguments.parse("exec 'unfinished"))
        let fixture=ProductionPolicyTests(), (wm,sys,_,windows)=try fixture.world(fixture.pair())
        sys.locked=true
        XCTAssertEqual(try JSON.parse(wm.command("[\"status\"]",fixture.area,1,windows))["runtime"],.string("swift"))
        sys.locked=false;XCTAssertThrowsError(try wm.command("close 999999999999999999999999",fixture.area,1,windows))
        XCTAssertThrowsError(try wm.command("unhide 999999999999999999999999",fixture.area,1,windows))
    }
    func testOverviewRestoreRequiresAllNativeHandoffLatches() throws {
        let (bound,hidden,snapshot)=try overview()
        XCTAssertEqual(try OverviewProtocol.selections(snapshot:snapshot,binding:bound,hidden:[hidden]).count,1)
        // Authority may be retired and records gone; persistent flat commit remains exact.
        for (key,value) in [("setup_observed",JSON.bool(false)),("end_order_observed",.bool(false)),("inverse_park_observed",.bool(false)),("root_cancel_requested",.bool(true)),("hidden_intent",.string(String(repeating:"e",count:64))),("wid",.double(1)),("pool_generation",.int(8))] {
            let bad=snapshot.setting("commits",.array([snapshot["commits"]!.array![0].setting(key,value)]))
            XCTAssertTrue(try OverviewProtocol.selections(snapshot:bad,binding:bound,hidden:[hidden]).isEmpty,key)
        }
        XCTAssertTrue(try OverviewProtocol.selections(snapshot:snapshot.setting("controller_observed",.bool(false)),binding:bound,hidden:[hidden]).isEmpty)
        XCTAssertTrue(try OverviewProtocol.selections(snapshot:snapshot.setting("mode",.int(2)),binding:bound,hidden:[hidden]).isEmpty)
    }
    func testOverviewNonceAndTypedBirthNeverAliasAnotherHiddenWindow() throws {
        let (bound,hidden,snapshot)=try overview(), commit=snapshot["commits"]!.array![0]
        for bad in [commit.setting("nonce",.string(String(repeating:"e",count:32))),commit.setting("birth",.array([.int(101),.int(Int(getuid())),.int(40),.int(51)]))] {
            XCTAssertTrue(try OverviewProtocol.selections(snapshot:snapshot.setting("commits",.array([bad])),binding:bound,hidden:[hidden]).isEmpty)
        }
        let duplicate=snapshot.setting("commits",.array([commit,commit]))
        XCTAssertEqual(try OverviewProtocol.selections(snapshot:duplicate,binding:bound,hidden:[hidden]).count,1)
        XCTAssertThrowsError(try bound.request("configure",sequence:0,payload:.object([])))
        XCTAssertThrowsError(try bound.request("arbitrary",sequence:1,payload:.object([])))
    }
    func testIgnoreIsIndependentOfFloatAndDoesNotAdmitIgnoredTile() throws {
        let fixture=ProductionPolicyTests(), (wm,_,eng,windows)=try fixture.world(fixture.pair())
        wm.cfg=try NativeRuntimeConfig.build(base:wm.cfg,document:JSON.parse("{\"$schema\":\"runtime.schema.json\",\"window_rules\":[{\"match\":{\"title\":\"Secret\"},\"ignore\":true}]}"))
        var ignored=windows[0];ignored.name="Secret"
        XCTAssertFalse(wm.tileable(ignored));XCTAssertFalse(wm.floating.contains(1));XCTAssertTrue(wm.tileable(windows[1]))
        _=wm.sync(fixture.area,1,[ignored,windows[1]]);XCTAssertFalse(wm.sp(1).tree!.contains(1))
        wm.apply(fixture.area,1,[ignored,windows[1]],force:true)
        XCTAssertFalse(eng.ch.ops.contains { $0["op"]?.string == "geom" && $0["wid"] == .int(1) })
    }
    func testHotkeysValidationMatchesNativeCarbonChordContract() throws {
        let base=try Fx.config()
        _=try NativeRuntimeConfig.build(base:base,document:JSON.parse("{\"hotkeys\":[{\"id\":4095,\"keycode\":127,\"modifiers\":256,\"enabled\":false}],\"focus\":{\"focus_on_close\":2,\"no_focus_fallback\":true}}"))
        for value in [0,0x200,0x400,0x1f00] {
            XCTAssertThrowsError(try NativeRuntimeConfig.build(base:base,document:JSON.parse("{\"hotkeys\":[{\"id\":1,\"modifiers\":\(value)}]}")))
        }
    }
    func testLauncherOriginSurvivesAutoswitchButRequiresVerifiedViewProvider() throws {
        let fixture=ProductionPolicyTests(), (wm,sys,eng,windows)=try fixture.world(fixture.pair())
        wm.launcherAreas[1]=fixture.area;sys.front=windows[0].pid
        sys.launch=LauncherIntent(sequence:1,space:1,frontPID:999,kind:1,started:sys.now())
        var moved=windows; moved[0].space=2
        wm.observeLauncher(fixture.area,2,moved);sys.contexts[101]=(1,0)
        wm.sp(1).tree=Node(leaf:2);wm.sp(2).tree=Node(leaf:1)
        wm.onActivate(fixture.area,2,moved,101);XCTAssertTrue(eng.ch.ops.isEmpty)
        var calls:[(Int,Bool)]=[]
        wm.workspaceFocus={ sid,preflight in calls.append((sid,preflight));return true }
        wm.onActivate(fixture.area,2,moved,101)
        XCTAssertEqual(eng.ch.ops.first?["space"],.int(1));XCTAssertEqual(calls.map(\.0),[1,1]);XCTAssertEqual(calls.map(\.1),[true,false])
        wm.completeActivationMoves(fixture.area,2,moved)
        XCTAssertNotNil(wm.activationMoves[1]);XCTAssertTrue(wm.sp(2).tree!.contains(1))
        moved[0].space=1;wm.completeActivationMoves(fixture.area,1,moved)
        XCTAssertNil(wm.sp(2).tree);XCTAssertTrue(wm.restoring.contains(1));XCTAssertNil(wm.launcherIntent)
    }
    func testLauncherExplicitSpaceChangeAndAgeInvalidateOrigin() throws {
        let fixture=ProductionPolicyTests(), (wm,sys,_,windows)=try fixture.world(fixture.pair())
        wm.launcherAreas[1]=fixture.area
        sys.launch=LauncherIntent(sequence:1,space:1,frontPID:999,kind:1,started:sys.now())
        wm.observeLauncher(fixture.area,2,windows);XCTAssertEqual(wm.launcherIntent?.space,1)
        sys.launch=LauncherIntent(sequence:2,space:0,frontPID:999,kind:0,started:sys.now())
        wm.observeLauncher(fixture.area,2,windows);XCTAssertNil(wm.launcherIntent)
        sys.launch=LauncherIntent(sequence:3,space:1,frontPID:999,kind:2,started:sys.now()-4)
        wm.observeLauncher(fixture.area,2,windows);XCTAssertNil(wm.launcherIntent)
    }
    func testFarEdgeResizeCompensatesInnerCutWithoutMovingOppositeNeighbor() throws {
        let fixture=ProductionPolicyTests(), tree=Node(split:"v",ratio:0.5,a:fixture.pair(),b:Node(leaf:3))
        let (wm,sys,_,windows)=try fixture.world(tree), before=wm.layout(fixture.area,wm.sp(1)),actor=before[2]!
        sys.m=(actor.x+actor.w,actor.y+100);wm.beginInteraction(fixture.area,1,windows)
        sys.bounds[2]=Rect(actor.x,actor.y,actor.w+60,actor.h)
        XCTAssertTrue(wm.updateSharedResize(fixture.area,1,windows))
        let after=wm.layout(fixture.area,wm.sp(1))
        XCTAssertEqual(after[1],before[1]);XCTAssertEqual(after[2],sys.bounds[2]);XCTAssertTrue(wm.sp(1).tree!.a.manualRatio)
        XCTAssertEqual(after[3]!.x,before[3]!.x+60)
    }
    func testNativeFramesRequireExactExistingClientBirthAndCapability() throws {
        let fixture=ProductionPolicyTests(), (wm,sys,eng,windows)=try fixture.world(fixture.pair())
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:path) }
        let targets=windows.map { window -> JSON in
            sys.births[window.pid]="\(window.pid):40:50";sys.capabilities[window.pid]=6;sys.applicationPaths[window.pid]="/Applications/Fixture.app"
            return .object([("pid",.int(window.pid)),("birth",.array([.int(window.pid),.int(Int(getuid())),.int(40),.int(50)])),("app",.string("/Applications/Fixture.app"))])
        }
        try Data(JSON.object([("schema",.int(1)),("generation",.string("owned")),("targets",.array(targets))]).dumps().utf8).write(to:path)
        wm.clientPolicy=ClientPolicy(path:path.path);wm.options.nativeFrames=true
        let recorder=SnapshotHandoffTests.Recorder();wm.cfgSink=recorder
        wm.target.removeAll() // Exercise a new configure, not an unchanged settled target.
        wm.apply(fixture.area,1,windows,force:true);XCTAssertEqual(Set(eng.ch.nativeRequests),[1,2])
        XCTAssertTrue(recorder.jobs.isEmpty);eng.ch.nativeRequests=[]
        sys.births[101]="101:40:51";sys.capabilities[102]=5
        var changed=windows;changed[1].w+=20
        wm.apply(fixture.area,1,changed,force:true);XCTAssertTrue(eng.ch.nativeRequests.isEmpty)
        XCTAssertEqual(recorder.jobs.map(\.wid),[2])
        XCTAssertTrue(recorder.jobs.allSatisfy(\.sizeOnly)) // One early logical size; rejected native policy never streams frames.
    }
    func testCloseFocusPolicyWaitsForUnmapAndPreservesSheetOwnership() throws {
        let fixture=ProductionPolicyTests()
        for mode in [1,2] {
            let tree=Node(split:"v",ratio:0.5,a:Node(leaf:1),b:fixture.pair("h"))
            tree.b.a.wid=2;tree.b.b.wid=3
            let (wm,sys,_,windows)=try fixture.world(tree)
            wm.cfg=try NativeRuntimeConfig.build(base:wm.cfg,document:JSON.parse("{\"focus\":{\"focus_on_close\":\(mode)}}"))
            wm.sp(1).focus=1;wm.focusHistory=[3,2];sys.front=101;sys.contexts[101]=(1,0)
            let third=windows.first { $0.wid == 3 }!;sys.m=(third.x+20,third.y+20)
            _=wm.sync(fixture.area,1,windows.filter { $0.wid != 1 })
            XCTAssertEqual(wm.sp(1).focus,1);XCTAssertFalse(sys.calls.contains { $0.array?.first?.string == "ax_focus" })
            sys.t+=0.081;_=wm.sync(fixture.area,1,windows.filter { $0.wid != 1 })
            XCTAssertEqual(wm.sp(1).focus,mode == 1 ? 3 : 2)
            XCTAssertTrue(sys.calls.contains { $0.array?.first?.string == "ax_focus" })
            let calls=sys.calls.count;sys.contexts[101]=(nil,2)
            wm.focusAfterClose(fixture.area,1,windows,nil);XCTAssertEqual(sys.calls.count,calls)
        }
    }
    func testUnchangedOldFrameCannotBecomeAnApplicationMinimum() throws {
        let fixture=ProductionPolicyTests(),(wm,sys,_,windows)=try fixture.world(fixture.pair()),window=windows[0]
        let goal=wm.target[1]!,old=Rect(goal.x,goal.y,1446,903)
        var result=CfgResult(wid:1,owner:window.owner,to:goal,got:old,e:0,pre:old)
        result.pid=101;result.birth="birth-1";result.isCurrent={true};sys.births[101]="birth-1"
        wm.cfgQ=[result]
        XCTAssertFalse(wm.configured(),"An ignored resize must not convert the previous full-screen width into a minimum")
        XCTAssertNil(wm.mins[window.owner])
    }
    func testQueuedConfigureResultMustStillBelongToCurrentRequestAndProcess() throws {
        let fixture=ProductionPolicyTests(),(wm,sys,_,windows)=try fixture.world(fixture.pair()),window=windows[0]
        let target=wm.target[1]!
        var result=CfgResult(wid:1,owner:"Fixture",to:target,got:Rect(target.x,target.y,target.w+100,target.h),e:0,pre:nil)
        result.pid=101;result.birth="birth-1";result.isCurrent={true}
        sys.births[101]="reused";wm.cfgQ=[result]
        XCTAssertFalse(wm.configured());XCTAssertNil(wm.mins[window.owner])
        sys.births[101]="birth-1";result.isCurrent={false};wm.cfgQ=[result]
        XCTAssertFalse(wm.configured());XCTAssertNil(wm.mins[window.owner])
        result.isCurrent={true};wm.cfgQ=[result];XCTAssertTrue(wm.configured())
        XCTAssertEqual(wm.mins[window.owner]?.first?.double,target.w+100)
    }
    func testPointerPauseActuallyWaitsAfterMotionAndCanFocusWhileStationary() throws {
        let fixture=ProductionPolicyTests(),(wm,sys,_,windows)=try fixture.world(fixture.pair())
        wm.cfg=try NativeRuntimeConfig.build(base:wm.cfg,document:JSON.parse("{\"runtime\":{\"pointer_focus_pause_ms\":100}}"))
        sys.front=101;sys.contexts[101]=(1,0);sys.m=(windows[1].x+20,windows[1].y+20)
        wm.followMouse(1,windows);XCTAssertFalse(sys.calls.contains { $0.array?.first?.string == "ax_focus" })
        sys.t+=0.099;wm.followMouse(1,windows);XCTAssertFalse(sys.calls.contains { $0.array?.first?.string == "ax_focus" })
        sys.t+=0.002;wm.followMouse(1,windows);XCTAssertTrue(sys.calls.contains { $0.array?.first?.string == "ax_focus" })
    }
    func testAtomicSnapshotPairHasOneFinalConfigureAndNeverNativeOrStretch() throws {
        let path=NSTemporaryDirectory()+"hyprwm-snapshot-pair-\(UUID().uuidString).chan"
        let channel=try LiveChannel(path:path,create:true);defer { unlink(path) }
        let to=Rect(100,30,600,400),from=Rect(0,30,1200,870)
        XCTAssertFalse(channel.snapshotSupported)
        XCTAssertFalse(channel.snapshotGeometry(1,to:to,curves:(0,0),durations:(0.3,0.3),from:from))
        channel.raw.pointee.version |= UInt32(CH_CAP_SNAPSHOT)
        XCTAssertFalse(channel.snapshotSupported);XCTAssertFalse(channel.snapshotGeometry(1,to:to,curves:(0,0),durations:(0.3,0.3),from:from))
        channel.raw.pointee.version |= UInt32(CH_CAP_SNAPSHOT_COVER)
        XCTAssertEqual(ChannelCapabilities.abi(channel.raw.pointee.version|UInt32(CH_CAP_EFFECTS)|UInt32(CH_CAP_SHADOW)),6)
        XCTAssertTrue(channel.snapshotGeometry(1,to:to,curves:(0,0),durations:(0.3,0.3),from:from))
        XCTAssertEqual(channel.raw.pointee.cmd_head,0);channel.commit();XCTAssertEqual(channel.raw.pointee.cmd_head,2)
        let commands=(channel.base+MemoryLayout<ch_hdr>.stride+Int(CH_NCURVE)*MemoryLayout<ch_curve>.stride).assumingMemoryBound(to:ch_cmd.self)
        XCTAssertEqual(commands[0].op,UInt32(OP_GEOM));XCTAssertEqual(commands[0].flags,UInt32(F_FROM|F_MOVE|F_SNAPSHOT))
        XCTAssertEqual(commands[0].w,to.w);XCTAssertEqual(commands[0].fw,from.w)
        XCTAssertEqual(commands[1].op,UInt32(OP_CFG));XCTAssertEqual(commands[1].wid,1);XCTAssertEqual(commands[1].w,to.w)
    }
    func testExhaustedSnapshotPairCannotPublishAnOrphanFinalConfigure() throws {
        let path=NSTemporaryDirectory()+"hyprwm-snapshot-full-\(UUID().uuidString).chan"
        let channel=try LiveChannel(path:path,create:true);defer { unlink(path) }
        channel.raw.pointee.version |= UInt32(CH_CAP_SNAPSHOT)|UInt32(CH_CAP_SNAPSHOT_COVER)
        for _ in 0..<Int(CH_NCMD)-1 { channel.alpha(1,1,16,0) }
        XCTAssertFalse(channel.snapshotGeometry(1,to:Rect(0,0,400,500),curves:(0,0),durations:(0.3,0.3),from:nil))
        XCTAssertEqual(channel.raw.pointee.cmd_head,0);channel.commit();XCTAssertEqual(channel.raw.pointee.cmd_head,UInt32(CH_NCMD-1))
        let commands=(channel.base+MemoryLayout<ch_hdr>.stride+Int(CH_NCURVE)*MemoryLayout<ch_curve>.stride).assumingMemoryBound(to:ch_cmd.self)
        XCTAssertEqual(commands[Int(CH_NCMD)-1].op,0)
    }
    func testFullMatchAndNegativeRulesDoNotIgnoreSubstringLookalikes() throws {
        let fixture=ProductionPolicyTests(),(wm,_,_,windows)=try fixture.world(fixture.pair())
        wm.cfg=try NativeRuntimeConfig.build(base:wm.cfg,document:JSON.parse("{\"window_rules\":[{\"match\":{\"class\":\"Fixture\"},\"ignore\":true,\"float\":true},{\"match\":{\"class\":\"Fixture\",\"title\":\"negative:Secret\"},\"ignore\":false,\"float\":false}]}"))
        var exact=windows[0];exact.name="Secret";XCTAssertTrue(wm.ignored(exact));XCTAssertNotNil(wm.ruleFloat(exact))
        exact.name="SecretPreview";XCTAssertFalse(wm.ignored(exact));XCTAssertNil(wm.ruleFloat(exact))
        exact.owner="FixturePreview";exact.name="Secret";XCTAssertFalse(wm.ignored(exact));XCTAssertNil(wm.ruleFloat(exact))
        let alternative=JSON.object([("match",.object([("class",.string("F|Fixture"))]))])
        XCTAssertTrue(WindowProperties.matches(alternative,windows[0]))
        XCTAssertThrowsError(try NativeRuntimeConfig.build(base:wm.cfg,document:JSON.parse("{\"window_rules\":[{\"match\":{\"class\":\"negative:[\"},\"ignore\":true}]}")))
    }
    func testAsynchronousCloseNeverRemovesParentOnPressACKOrSaveSheet() throws {
        let fixture=ProductionPolicyTests(),(wm,sys,eng,windows)=try fixture.world(fixture.pair()),original=wm.sp(1).tree!.json
        sys.deferredClose=true
        XCTAssertTrue(wm.closeAnim(fixture.area,1,windows,windows[0]).contains("queued"))
        XCTAssertEqual(wm.closeRequests.count,1);XCTAssertEqual(wm.sp(1).tree!.json,original);XCTAssertTrue(eng.ch.ops.isEmpty)
        // Other commands remain available while the exact AX request is outstanding.
        XCTAssertEqual(try JSON.parse(wm.command("status",fixture.area,1,windows))["close"]?["pending"],.array([.int(1)]))
        sys.t+=0.1;sys.closeCallbacks.removeFirst()(CloseResult(code:0,lookupMS:2,buttonMS:3,pressMS:95))
        XCTAssertEqual(wm.sp(1).tree!.json,original);XCTAssertEqual(wm.closeMetrics["press_ms"],.double(95))
        sys.contexts[101]=(1,2);wm.observeCloseRequests(windows,1)
        XCTAssertTrue(wm.closeRequests.isEmpty);XCTAssertEqual(wm.closeMetrics["deferred_to_dialog"],.bool(true))
        _=wm.sync(fixture.area,1,windows);XCTAssertEqual(wm.sp(1).tree!.json,original)
    }
    func testCloseUnmapRecognitionDoesNotWaitForNativeWindowDisposal() throws {
        let fixture=ProductionPolicyTests(),(wm,sys,_,windows)=try fixture.world(fixture.pair())
        sys.deferredClose=true;_=wm.closeAnim(fixture.area,1,windows,windows[0]);sys.t+=0.02
        var orderedOut=windows;orderedOut[0].on=false
        wm.observeCloseRequests(orderedOut,1);_=wm.sync(fixture.area,1,orderedOut)
        XCTAssertTrue(wm.closeRequests.isEmpty);XCTAssertEqual(wm.closeMetrics["native_departure"],.bool(true))
        XCTAssertFalse(wm.sp(1).tree!.contains(1));XCTAssertEqual(sys.winPidLevel(1).pid,101)
        sys.closeCallbacks.removeFirst()(CloseResult(code:0,lookupMS:2,buttonMS:3,pressMS:15))
        XCTAssertEqual(wm.closeMetrics["press_ms"],.double(15));XCTAssertNotNil(wm.closeMetrics["unmap_ms"])
    }
}
