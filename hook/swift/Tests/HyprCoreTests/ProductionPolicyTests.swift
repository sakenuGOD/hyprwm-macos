@testable import HyprCore
import XCTest

final class ProductionPolicyTests: XCTestCase {
    let area = Rect(0, 30, 1200, 870)
    func world(_ tree: Node) throws -> (WM, FakeWorld, FakeEngine, [WinInfo]) {
        let cfg = try Fx.config(), sys = FakeWorld(), eng = FakeEngine(cfg: try Fx.config())
        let wm = WM(sys: sys, eng: eng, deco: NullDeco(), cfg: cfg, statePath: "/not-written", minsizePath: "/not-written")
        wm.saveEnabled = false; wm.options = .standard; wm.sp(1).tree = tree
        let rects = wm.layout(area, wm.sp(1))
        let wins = rects.map { wid, r -> WinInfo in
            sys.tileableM[wid] = 1; sys.pidlevel[wid] = (100+wid, 0); sys.bounds[wid] = r; sys.births[100+wid] = "birth-\(wid)"
            wm.target[wid] = r; wm.pids[wid] = 100+wid; wm.owner[wid] = "Fixture"
            return WinInfo(wid: wid, pid: 100+wid, owner: "Fixture", x: r.x, y: r.y, w: r.w, h: r.h, on: true, space: 1)
        }
        return (wm, sys, eng, wins)
    }
    func pair(_ split: String = "v") -> Node { Node(split: split, ratio: 0.5, a: Node(leaf: 1), b: Node(leaf: 2)) }

    func testAcceptedNativeFrameWinsOverUnchangedServerFrameAndEpochCannotReplay() throws {
        let (wm,sys,_,wins)=try world(pair()),start=sys.bounds[1]!
        let native=NativeResizeContext(pid:101,birth:"birth-1",wid:1,epoch:7,sequence:2,phase:1,
            frame:start,point:(start.x+start.w-1,start.y+100))
        wm.beginInteraction(area,1,wins,native:native)
        XCTAssertEqual(wm.dragSession?.nativeEpoch,7)
        sys.resizeContexts[101]=NativeResizeContext(pid:101,birth:"birth-1",wid:1,epoch:7,sequence:4,phase:2,
            frame:start,point:native.point,acceptedFrame:Rect(start.x,start.y,start.w+80,start.h),acceptedTime:sys.t,sample:2)
        XCTAssertTrue(wm.updateSharedResize(area,1,wins))
        XCTAssertEqual(wm.layout(area,wm.sp(1))[1]?.w,start.w+80)
        let tree=wm.sp(1).tree!.json
        // A newer accepted frame must NOT fall back to an unrelated server sample.
        sys.bounds[1]=Rect(start.x,start.y,start.w+160,start.h)
        sys.resizeContexts[101]=NativeResizeContext(pid:101,birth:"birth-1",wid:1,epoch:8,sequence:6,phase:2,
            frame:start,point:native.point,acceptedFrame:sys.bounds[1],acceptedTime:sys.t,sample:3)
        XCTAssertFalse(wm.updateSharedResize(area,1,wins))
        XCTAssertEqual(wm.sp(1).tree!.json,tree)
    }

    func testFinalAcceptedFrameIsAdoptedWhenMouseUpPollArrivesLater() throws {
        let (wm,sys,_,wins)=try world(pair()),start=sys.bounds[1]!
        let native=NativeResizeContext(pid:101,birth:"birth-1",wid:1,epoch:7,sequence:2,phase:1,
            frame:start,point:(start.x+start.w-1,start.y+100))
        wm.beginInteraction(area,1,wins,native:native)
        sys.resizeContexts[101]=NativeResizeContext(pid:101,birth:"birth-1",wid:1,epoch:7,sequence:4,phase:2,
            frame:start,point:native.point,acceptedFrame:Rect(start.x,start.y,start.w+50,start.h),acceptedTime:sys.t,sample:2)
        XCTAssertTrue(wm.updateSharedResize(area,1,wins))
        sys.resizeContexts[101]=NativeResizeContext(pid:101,birth:"birth-1",wid:1,epoch:7,sequence:6,phase:3,
            frame:start,point:native.point,acceptedFrame:Rect(start.x,start.y,start.w+80,start.h),acceptedTime:sys.t,sample:3)
        sys.t += 0.1
        XCTAssertTrue(wm.endInteraction(area,1,wins))
        XCTAssertEqual(wm.layout(area,wm.sp(1))[1]?.w,start.w+80)
        XCTAssertNil(wm.dragSession)
    }

    func testFirstObservedAcceptedFrameCanBeTerminal() throws {
        let (wm,sys,_,wins)=try world(pair()),start=sys.bounds[1]!
        let native=NativeResizeContext(pid:101,birth:"birth-1",wid:1,epoch:7,sequence:2,phase:1,
            frame:start,point:(start.x+start.w-1,start.y+100))
        wm.beginInteraction(area,1,wins,native:native)
        sys.resizeContexts[101]=NativeResizeContext(pid:101,birth:"birth-1",wid:1,epoch:7,sequence:4,phase:3,
            frame:start,point:native.point,acceptedFrame:Rect(start.x,start.y,start.w+80,start.h),acceptedTime:sys.t,sample:2)
        XCTAssertTrue(wm.endInteraction(area,1,wins))
        XCTAssertEqual(wm.layout(area,wm.sp(1))[1]?.w,start.w+80)
    }

    func testGentleHorizontalThrowKeepsTreeAndDoesNotMoveUp() throws {
        for (actor, delta) in [(1, 38.0), (2, -38.0)] {
            let (wm, sys, _, wins) = try world(pair())
            let start = sys.bounds[actor]!
            sys.m = (start.x+50, start.y+10); wm.beginInteraction(area, 1, wins)
            sys.bounds[actor] = Rect(start.x+delta, start.y-8, start.w, start.h)
            XCTAssertTrue(wm.endInteraction(area, 1, wins))
            XCTAssertEqual(wm.sp(1).tree?.split, "v")
            XCTAssertEqual(Dwindle.leaves(wm.sp(1).tree).compactMap(\.wid), [2, 1])
        }
    }
    func testResizeUpdatesWholeSiblingSubtreeAndAcceptedActorIsNotConfigured() throws {
        let right = Node(split: "h", ratio: 0.5, a: Node(leaf: 2), b: Node(leaf: 3))
        let (wm, sys, eng, wins) = try world(Node(split: "v", ratio: 0.5, a: Node(leaf: 1), b: right))
        let start = sys.bounds[1]!
        // Previously learned minimum must not silently move the divider away from the accepted native frame.
        wm.mins["Fixture"] = [.double(900), .double(100)]
        sys.m = (start.x+start.w, start.y+100)
        wm.beginInteraction(area, 1, wins)
        sys.bounds[1] = Rect(start.x, start.y, start.w+80, start.h)
        XCTAssertTrue(wm.updateSharedResize(area, 1, wins))
        XCTAssertTrue(wm.sp(1).tree!.manualRatio)
        let geometry = eng.ch.ops.filter { $0["op"]?.string == "geom" }
        XCTAssertEqual(Set(geometry.compactMap { $0["wid"]?.int }), [2,3])
        let actorMirror=eng.ch.ops.first{$0["wid"] == .int(1) && $0["op"] == .string("warp")}!
        XCTAssertEqual(actorMirror["move"],.bool(false))
        XCTAssertEqual(actorMirror["stretch"],.bool(false))
        XCTAssertEqual(actorMirror["to"],sys.bounds[1]!.json)
        XCTAssertFalse(eng.ch.nativeRequests.contains(1))
        XCTAssertEqual(wm.layout(area, wm.sp(1))[2]!.x, start.x+start.w+80+2*wm.tile.gapsIn)
        XCTAssertTrue(wm.sp(1).tree!.json["manual_ratio"]!.truthy)
        XCTAssertTrue(Node.from(wm.sp(1).tree!.json)!.manualRatio)
    }
    func testVerticalSharedResizeAndReversePreserveDivider() throws {
        let (wm, sys, _, wins) = try world(pair("h"))
        let start = sys.bounds[1]!
        sys.m = (start.x+100, start.y+start.h); wm.beginInteraction(area, 1, wins)
        sys.bounds[1] = Rect(start.x, start.y, start.w, start.h+70)
        XCTAssertTrue(wm.updateSharedResize(area, 1, wins))
        sys.bounds[1] = Rect(start.x, start.y, start.w, start.h+20)
        XCTAssertTrue(wm.updateSharedResize(area, 1, wins))
        XCTAssertEqual(wm.layout(area, wm.sp(1))[1]!.h, start.h+20)
    }
    func testResizeOwnershipChangeAbortsWithoutPeerCommands() throws {
        let (wm, sys, eng, wins) = try world(pair())
        let start = sys.bounds[1]!
        sys.m = (start.x+start.w, start.y+100); wm.beginInteraction(area, 1, wins)
        sys.pidlevel[1] = (999, 0)
        sys.bounds[1] = Rect(start.x, start.y, start.w+50, start.h)
        XCTAssertFalse(wm.updateSharedResize(area, 1, wins)); XCTAssertTrue(eng.ch.ops.isEmpty)
    }
    func testCrossSpaceTransferRequiresNativeACKAndNeverLaunchesFallback() throws {
        let (wm, sys, eng, windows) = try world(pair())
        let foreign = windows[0]
        wm.sp(1).tree = Node(leaf: 2); wm.sp(2).tree = Node(leaf: 1)
        var wins = windows; wins[0].space = 2; wins[0].on = false
        sys.contexts[foreign.pid] = (foreign.wid, 0)
        wm.launcherIntent=LauncherIntent(sequence:1,space:1,frontPID:999,kind:1,started:sys.t)
        wm.onActivate(area, 1, wins, foreign.pid)
        XCTAssertEqual(eng.ch.ops.first?["op"]?.string, "space")
        XCTAssertTrue(wm.sp(2).tree!.contains(foreign.wid))
        wm.completeActivationMoves(area, 1, wins)
        XCTAssertTrue(wm.sp(2).tree!.contains(foreign.wid))
        wins[0].space = 1; wins[0].on = true
        wm.completeActivationMoves(area, 1, wins)
        XCTAssertNil(wm.sp(2).tree)
        XCTAssertTrue(wm.restoring.contains(foreign.wid))
        XCTAssertFalse(sys.calls.contains(.string("spawn?")))
    }
    func testTransferPIDReuseFailsClosed() throws {
        let (wm, sys, _, windows) = try world(pair())
        let foreign = windows[0]; wm.sp(2).tree = Node(leaf: foreign.wid)
        var wins = windows; wins[0].space = 2
        sys.contexts[foreign.pid] = (foreign.wid, 0)
        wm.launcherIntent=LauncherIntent(sequence:1,space:1,frontPID:999,kind:1,started:sys.t)
        wm.onActivate(area, 1, wins, foreign.pid)
        sys.births[foreign.pid] = "different-process"
        wins[0].space = 1
        wm.completeActivationMoves(area, 1, wins)
        XCTAssertTrue(wm.sp(2).tree!.contains(foreign.wid)); XCTAssertFalse(wm.restoring.contains(foreign.wid))
    }
    func testDialogAndSystemShellCannotAuthorizeTransfer() throws {
        for flags in [1, 2, 4, 8, 16] {
            let (wm, sys, eng, windows) = try world(pair())
            var wins = windows; wins[0].space = 2
            sys.contexts[wins[0].pid] = (wins[0].wid, flags)
            wm.onActivate(area, 1, wins, wins[0].pid)
            XCTAssertTrue(eng.ch.ops.isEmpty)
        }
    }
    func testCoincidentNewTabDoesNotRelayoutBeforeNativeReplacement() throws {
        let (wm, sys, eng, windows) = try world(pair())
        var candidate = windows[0]; candidate.wid = 3; sys.tileableM[3] = 1
        let before = wm.sp(1).tree!.json
        let (changed, opened) = wm.sync(area, 1, windows+[candidate])
        XCTAssertFalse(changed); XCTAssertTrue(opened.isEmpty); XCTAssertEqual(wm.sp(1).tree!.json, before)
        var next = windows; next[0].on = false
        let (changed2, opened2) = wm.sync(area, 1, next+[candidate])
        XCTAssertFalse(changed2); XCTAssertTrue(opened2.isEmpty)
        XCTAssertTrue(wm.sp(1).tree!.contains(3)); XCTAssertFalse(wm.sp(1).tree!.contains(1))
        XCTAssertFalse(eng.ch.ops.contains { $0["op"]?.string == "geom" })
    }
    func testUnrelatedNewWindowIsAdmittedAfterBoundedOverlapGrace() throws {
        let (wm, sys, _, windows) = try world(pair())
        var candidate = windows[0]; candidate.wid = 3; sys.tileableM[3] = 1
        _ = wm.sync(area, 1, windows+[candidate]); sys.t += 0.1
        let (changed, opened) = wm.sync(area, 1, windows+[candidate])
        XCTAssertTrue(changed); XCTAssertEqual(opened, [3])
    }
    func testPauseLeavesControlAvailableAndResumeDoesNotLaunchApplications() throws {
        let (wm, sys, eng, wins) = try world(pair())
        XCTAssertEqual(try wm.command("pause", area, 1, wins), "paused")
        let count = eng.ch.ops.count
        wm.apply(area, 1, wins, force: true)
        XCTAssertEqual(eng.ch.ops.count, count)
        XCTAssertEqual(try wm.command("retile", area, 1, wins), "paused: use resume")
        XCTAssertEqual(try wm.command("resume", area, 1, wins), "enabled")
        XCTAssertFalse(sys.calls.contains(.string("spawn?")))
    }
    func testHiddenMetadataRoundtripAndPIDReuseDoNotRevealWindow() throws {
        let (wm, sys, eng, wins) = try world(pair())
        let data = try JSON.parse("{\"wid\":1,\"pid\":101,\"owner\":\"Fixture\",\"space\":1,\"rect\":[12,38,583,850],\"swift_birth\":\"birth-1\",\"native_visibility_pending\":false,\"tiled\":true}")
        let record = Hidden.from(data)
        XCTAssertEqual(record.json, data)
        wm.hidden.append(record)
        sys.births[101] = "reused"
        _ = wm.unhide(area, 1, wins, everything: true)
        XCTAssertEqual(wm.hidden.count, 1)
        XCTAssertFalse(eng.ch.ops.contains { $0["op"]?.string == "alpha" || $0["op"]?.string == "geom" })
    }
    func testRuntimeConfigurationScalesEachCurveOnceAndRejectsMalformedCandidate() throws {
        let base = try Fx.config()
        let document = try JSON.parse("{\"version\":1,\"time_scale\":2,\"animations\":{\"windowsMove\":{\"curve\":\"drift\"}},\"layout\":{\"gaps_in\":3,\"minimum_policy\":\"ratio\"}}")
        let cfg = try NativeRuntimeConfig.build(base: base, document: document)
        let name = cfg.animation("windowsMove").curve
        guard case let .spring(_, k, d) = cfg.curves()[name]! else { return XCTFail("spring") }
        XCTAssertEqual(k, 210/4); XCTAssertEqual(d, 24/2)
        XCTAssertEqual(cfg.timeScale, 1); XCTAssertEqual(cfg.makeDwindle().gapsIn, 3)
        XCTAssertEqual(cfg.makeDwindle().minimumPolicy, "ratio")
        XCTAssertThrowsError(try NativeRuntimeConfig.build(base: base, document: JSON.parse("{\"time_scale\":0}")))
        XCTAssertThrowsError(try NativeRuntimeConfig.build(base: base, document: JSON.parse("{\"curves\":{\"broken\":{\"type\":\"bezier\",\"points\":[[],[]]}}}")))
        XCTAssertEqual(base.makeDwindle().gapsIn, 5)
    }
}

final class ProductionSocketTests: XCTestCase {
    func testIncompleteClientCannotBlockAnotherClient() throws {
        let test = SocketTests()
        let path = NSTemporaryDirectory()+"hyprwm-partial-\(getpid()).ctl"
        let server = try CommandServer(path: path)
        defer { unlink(path) }
        let partial = test.client(path, "sta")
        defer { close(partial) }
        let ready = test.client(path, "status\n")
        var seen: [String] = []
        let started = ProcessInfo.processInfo.systemUptime
        server.drain { seen.append($0); return "ok" }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-started, 0.05)
        XCTAssertEqual(seen, ["status"])
        XCTAssertEqual(test.reply(ready), "ok\n")
        _ = "tus\n".withCString { write(partial, $0, strlen($0)) }
        server.drain { seen.append($0); return "ok" }
        XCTAssertEqual(seen, ["status", "status"])
    }
    func testRegularFileAtControlPathIsNeverRemoved() throws {
        let path = NSTemporaryDirectory()+"hyprwm-file-\(getpid()).ctl"
        try "keep".write(toFile: path, atomically: true, encoding: .utf8)
        defer { unlink(path) }
        XCTAssertThrowsError(try CommandServer(path: path))
        XCTAssertEqual(try String(contentsOfFile: path), "keep")
    }
}
