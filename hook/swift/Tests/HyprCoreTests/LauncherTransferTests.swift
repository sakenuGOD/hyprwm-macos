@testable import HyprCore
import XCTest

final class LauncherTransferTests:XCTestCase {

    func testCommittedLauncherTransferResizesBackgroundSourcePeerWithoutReturning() throws {
        for (source,destination,mode) in [(1,2,"ordinary"),(2,1,"ordinary"),(1,2,"hidden"),(1,2,"missing"),
                                          (1,2,"foreign"),(1,2,"zero"),(1,2,"owner"),(1,2,"protected"),(1,2,"area")] {
            let f=ProductionPolicyTests(),initial=Node(split:"v",ratio:0.5,a:f.pair(),b:Node(leaf:3))
            let (wm,sys,eng,original)=try f.world(initial),sink=SnapshotHandoffTests.Recorder()
            wm.cfgSink=sink;wm.rescued=true;wm.lastSpace=destination;wm.frontPid=101
            wm.sp(source).tree=f.pair();wm.sp(source).focus=1;wm.sp(destination).tree=Node(leaf:3)
            wm.launcherAreas[source]=f.area;wm.launcherAreas[destination]=f.area
            let sourceFrames=wm.layout(f.area,wm.sp(source)),destinationFrames=wm.layout(f.area,wm.sp(destination))
            var windows=original
            for i in windows.indices {
                let wid=windows[i].wid,r=(wid==3 ? destinationFrames:sourceFrames)[wid]!
                windows[i].x=r.x;windows[i].y=r.y;windows[i].w=r.w;windows[i].h=r.h
                windows[i].space=wid==3 ? destination:source;windows[i].on=wid==3
                wm.target[wid]=r;sys.bounds[wid]=r;sys.alphaM[wid]=1
            }
            let oldPeer=try XCTUnwrap(wm.target[2]),actor=windows.firstIndex{$0.wid==1}!
            let request=LauncherTransferFocus(pid:101,wid:1,birth:"birth-1",origin:destination,source:source,
                sequence:7,deadline:sys.t+8,catalog:try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(destination)))
            var arrival=try XCTUnwrap(wm.launcherArrivalPlan(windows[actor],destination,f.area))
            arrival.accepted=arrival.rect
            // Seed the authenticated terminal receipt: production tick must
            // commit this transfer and configure its source before any reentry.
            var transfer=LauncherTransfer(request:request,frame:windows[actor].rect,wasHidden:false,
                nativeFrame:windows[actor].rect,originalAlpha:1,arrival:arrival)
            transfer.samples=2;transfer.revealQueued=true;transfer.revealSamples=2;transfer.focusAccepted=true
            wm.launcherTransfers[1]=transfer
            wm.launcherIntent=LauncherIntent(sequence:7,space:destination,frontPID:103,kind:1,started:sys.t)
            windows[actor].space=destination;windows[actor].on=true
            windows[actor].x=arrival.rect.x;windows[actor].y=arrival.rect.y
            windows[actor].w=arrival.rect.w;windows[actor].h=arrival.rect.h
            wm.target[1]=arrival.rect;sys.bounds[1]=arrival.rect
            var slot=EngWin(wid:1,pos:(arrival.rect.x,arrival.rect.y),size:(arrival.rect.w,arrival.rect.h),curAlpha:1,a:arrival.rect)
            slot.geo=1;eng.ch.eng=[slot]
            sys.front=101;sys.contexts[101]=(1,0);sys.activeSpaceID=UInt64(destination)
            sys.transferCatalog=try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(destination))
            let peer=windows.firstIndex{$0.wid==2}!
            switch mode {
            case "hidden":wm.hidden=[Hidden(wid:2,pid:102,owner:"Fixture",space:source,rect:windows[peer].rect.arr,
                extra:.object([("swift_birth",.string("birth-2"))]))]
            case "missing":windows.remove(at:peer)
            case "foreign":windows[peer].space=destination
            case "zero":windows[peer].space=0
            case "owner":sys.pidlevel[2]=(999,0)
            case "protected":sys.protectedPIDs.insert(102)
            case "area":wm.launcherAreas[source]=nil
            default:break
            }
            sys.nativeSnapshot=Snapshot(space:destination,stable:true,area:f.area,windows:windows)
            wm.tick(socketReady:false)
            XCTAssertTrue(wm.launcherTransfers.isEmpty);XCTAssertNil(wm.launcherIntent)
            XCTAssertEqual(wm.sp(source).tree?.wid,2);XCTAssertTrue(wm.sp(destination).tree?.contains(1)==true)
            let full=try XCTUnwrap(wm.layout(f.area,wm.sp(source))[2])
            XCTAssertNotEqual(oldPeer,full)
            if mode != "ordinary" {
                XCTAssertFalse(sink.jobs.contains{$0.wid==2 && $0.expectedSpace==source},"Refuse unverifiable source peer: \(mode)")
                continue
            }
            XCTAssertEqual(wm.target[2],full,"Source must be resized while destination is still active")
            let job=sink.jobs.first{$0.wid==2 && $0.to==full}
            XCTAssertNotNil(job,"No source-peer native configure was submitted")
            guard let job else{continue}
            XCTAssertEqual(job.expectedSpace,source);XCTAssertTrue(job.requireOwnership);XCTAssertEqual(job.birth,"birth-2")
            XCTAssertTrue(eng.ch.ops.contains{$0["wid"] == .int(2) && $0["to"] == full.json})
            XCTAssertEqual(sys.activeSpaceID,UInt64(destination));XCTAssertEqual(wm.lastSpace,destination)
            XCTAssertFalse(sys.calls.contains{$0.array?.first == .string("ax_focus")})
            XCTAssertFalse(eng.ch.ops.contains{$0["op"] == .string("space")})
            let count=sink.jobs.filter{$0.wid==2}.count
            sys.t+=0.3;wm.tick(socketReady:false)
            XCTAssertEqual(sink.jobs.filter{$0.wid==2}.count,count,"Unchanged background peers must not be resubmitted")
        }
    }

    func testMissionControlSelectionCannotReuseEarlierLauncherToStealDestinationWindow() throws {
        for (nativeOverview,kind,alreadyObserved) in [false,true].flatMap({native in
            [1,2,3].flatMap{kind in [false,true].map{(native,kind,$0)}}
        }) {
            let f=ProductionPolicyTests(),(wm,sys,eng,original)=try f.world(f.pair())
            wm.cfgSink=SnapshotHandoffTests.Recorder();wm.rescued=true;wm.frontPid=101;wm.lastSpace=1
            wm.sp(1).tree=Node(leaf:1);wm.sp(2).tree=Node(leaf:2)
            wm.launcherAreas[1]=f.area
            sys.launch=LauncherIntent(sequence:7,space:1,frontPID:101,kind:kind,started:sys.t)
            if alreadyObserved {wm.observeLauncher(f.area,1,original)}
            // The native event may arrive before the daemon has observed it.
            sys.front=101;sys.contexts[101]=(1,0);sys.activeSpaceID=1
            sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:original)
            sys.publicOverview = !nativeOverview;wm.overviewFrozen={nativeOverview}
            wm.tick(socketReady:false)
            var entered=original
            for i in entered.indices {entered[i].space=entered[i].wid;entered[i].on=entered[i].wid==2}
            sys.publicOverview=false;wm.overviewFrozen={false}
            sys.front=102;sys.contexts[102]=(2,0);sys.activeSpaceID=2
            sys.transferCatalog=try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(2))
            sys.nativeSnapshot=Snapshot(space:2,stable:true,area:f.area,windows:entered)
            eng.ch.ops=[];sys.t+=0.1;wm.tick(socketReady:false)
            XCTAssertNil(wm.launcherIntent,"Mission Control supersedes a prior launch selection")
            XCTAssertTrue(wm.launcherTransfers.isEmpty)
            XCTAssertFalse(eng.ch.ops.contains{$0["op"] == .string("space")},"Selecting a desktop must never move its windows to the launcher's old desktop")
            XCTAssertFalse(eng.ch.ops.contains{$0["op"] == .string("alpha") && $0["wid"] == .int(2) && $0["a"] == .double(0)},"A destination window must not disappear after the desktop selection")
            XCTAssertTrue(wm.sp(2).tree?.contains(2)==true)
        }
    }
    func testSelectingOverlayAndModalFocusWaitWithoutReparkingActorOrConsumingIntent() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair())
        wm.cfgSink=SnapshotHandoffTests.Recorder();wm.sp(1).tree=Node(leaf:2)
        sys.front=101;sys.contexts[101]=(1,0);sys.transferCatalog=try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(1))
        let intent=LauncherIntent(sequence:1,space:1,frontPID:999,kind:1,started:sys.t)
        wm.launcherIntent=intent;wm.launcherAreas[1]=f.area
        XCTAssertTrue(wm.beginLauncherTransfer(intent,windows[0],1,windows[0].rect,false))
        eng.ch.ops=[]
        let snapshot=Snapshot(space:1,stable:true,area:f.area,windows:windows)
        sys.overlay=true;sys.front=999;wm.pollLauncherTransfers(snapshot)
        XCTAssertNotNil(wm.launcherTransfers[1]);XCTAssertNotNil(wm.launcherIntent);XCTAssertTrue(eng.ch.ops.isEmpty)
        sys.overlay=false;sys.front=101;sys.contexts[101]=(33,NativeFocusFlags.modal|NativeFocusFlags.child)
        wm.pollLauncherTransfers(snapshot)
        XCTAssertNotNil(wm.launcherTransfers[1]);XCTAssertNotNil(wm.launcherIntent);XCTAssertTrue(eng.ch.ops.isEmpty)
        XCTAssertTrue(sys.transferRequests.isEmpty)
        sys.contexts[101]=(1,0);wm.workspaceSampleSequence=1;wm.pollLauncherTransfers(snapshot)
        wm.workspaceSampleSequence=2;wm.pollLauncherTransfers(snapshot)
        XCTAssertNotNil(wm.launcherTransfers[1]?.arrival)
        XCTAssertTrue(sys.transferRequests.isEmpty)
    }

    func testProductionTickPreservesTransferWhenNativeMembershipBecomesVisibleBeforeFinalAck() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair())
        wm.cfgSink=SnapshotHandoffTests.Recorder()
        var moved=windows;moved[0].space=2;moved[0].on=false
        wm.sp(1).tree=Node(leaf:2);wm.sp(2).tree=Node(leaf:1)
        let peerFull=try XCTUnwrap(wm.layout(f.area,wm.sp(1))[2])
        wm.target[2]=peerFull;sys.bounds[2]=peerFull
        moved[1].x=peerFull.x;moved[1].y=peerFull.y;moved[1].w=peerFull.w;moved[1].h=peerFull.h
        wm.rescued=true;wm.frontPid=101;wm.lastSpace=2
        sys.front=101;sys.contexts[101]=(1,0);sys.activeSpaceID=2
        sys.alphaM[1]=1;sys.alphaM[2]=1
        sys.transferCatalog=try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(2))
        wm.launcherAreas[1]=f.area
        sys.launch=LauncherIntent(sequence:1,space:1,frontPID:102,kind:1,started:sys.t)
        sys.nativeSnapshot=Snapshot(space:2,stable:true,area:f.area,windows:moved)
        wm.tick(socketReady:false)
        XCTAssertNotNil(wm.launcherTransfers[1]);XCTAssertEqual(wm.launcherIntent?.sequence,1)
        XCTAssertEqual(eng.ch.ops.filter{$0["op"] == .string("space")}.count,1)
        moved[0].space=1;moved[0].on=true;moved[0].alpha=0;sys.alphaM[1]=0
        sys.activeSpaceID=1;sys.transferCatalog=try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(1))
        sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:moved)
        eng.ch.ops=[]
        sys.t+=0.02;wm.tick(socketReady:false)
        // Before this guard, activateOnCurrentSpace consumed the launcher here,
        // poll cancelled its transfer, and sync admitted an ordinary popin.
        XCTAssertNotNil(wm.launcherTransfers[1]);XCTAssertEqual(wm.launcherIntent?.sequence,1)
        XCTAssertEqual(wm.launcherStatus["disposition"],.string("awaiting-selection"))
        XCTAssertTrue(wm.sp(2).tree?.contains(1)==true)
        XCTAssertFalse(wm.sp(1).tree?.contains(1)==true)
        XCTAssertFalse(eng.ch.ops.contains{$0["wid"] == .int(1) && $0["op"] != .string("space")})
        sys.t+=0.02;wm.tick(socketReady:false)
        XCTAssertNotNil(wm.launcherTransfers[1]?.arrival);XCTAssertTrue(sys.transferRequests.isEmpty)
        XCTAssertTrue(wm.sp(2).tree?.contains(1)==true)
        sys.t+=0.02;wm.tick(socketReady:false)
        XCTAssertNotNil(wm.launcherTransfers[1]);XCTAssertNotNil(wm.launcherIntent)
        XCTAssertFalse(wm.launcherTransfers[1]?.revealQueued==true)
        _=try LauncherArrivalTests().acknowledge(wm,sys,eng,1)
        sys.t+=0.02;wm.tick(socketReady:false)
        XCTAssertTrue(wm.launcherTransfers[1]?.revealQueued==true)
        XCTAssertTrue(sys.transferRequests.isEmpty);XCTAssertTrue(wm.sp(2).tree?.contains(1)==true)
        moved[0].alpha=1;sys.alphaM[1]=1;eng.ch.eng[0].curAlpha=1
        sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:moved)
        sys.t+=0.02;wm.tick(socketReady:false)
        XCTAssertTrue(sys.transferRequests.isEmpty)
        sys.t+=0.02;wm.tick(socketReady:false)
        XCTAssertEqual(sys.transferRequests.count,1);XCTAssertNotNil(wm.launcherIntent)
        sys.t+=0.02;wm.tick(socketReady:false)
        XCTAssertTrue(wm.launcherTransfers.isEmpty);XCTAssertNil(wm.launcherIntent)
        XCTAssertNil(wm.sp(2).tree);XCTAssertTrue(wm.sp(1).tree?.contains(1)==true)
        XCTAssertEqual(wm.target[2],wm.layout(f.area,wm.sp(1))[2],"The destination peer must shrink without a click after the transfer commits")
    }
    func testReturningToSourceSpaceAppliesItsAlreadyChangedTreeWithoutMouseInput() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,original)=try f.world(f.pair())
        let sink=SnapshotHandoffTests.Recorder();wm.cfgSink=sink
        wm.sp(1).tree=Node(leaf:2);wm.sp(2).tree=Node(leaf:1)
        wm.lastSpace=2;wm.rescued=true;wm.frontPid=102
        sys.front=102;sys.contexts[102]=(2,0);sys.activeSpaceID=1
        var windows=original;windows[0].space=2;windows[0].on=false
        sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:windows)
        let full=try XCTUnwrap(wm.layout(f.area,wm.sp(1))[2])
        XCTAssertNotEqual(wm.target[2],full)
        wm.tick(socketReady:false)
        XCTAssertEqual(wm.target[2],full)
        XCTAssertTrue(eng.ch.ops.contains{$0["wid"] == .int(2) && $0["op"] == .string("geom")})
        XCTAssertTrue(sink.jobs.contains{$0.wid==2 && $0.to==full})
    }
    func testHiddenLauncherWaitsForConsumedRevealAndTwoNewNativeSamplesBeforeFocus() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair())
        wm.cfgSink=SnapshotHandoffTests.Recorder();wm.sp(1).tree=Node(leaf:2)
        sys.front=101;sys.contexts[101]=(1,0);sys.births[101]="101:40:50";sys.alphaM[1]=0
        sys.transferCatalog=try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(1))
        let hidden=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:windows[0].rect.arr,extra:.object([("swift_birth",.string("101:40:50")),("tiled",.bool(true))]))
        wm.hidden=[hidden];wm.launcherAreas[1]=f.area
        let intent=LauncherIntent(sequence:1,space:1,frontPID:999,kind:1,started:sys.t);wm.launcherIntent=intent
        var moved=windows;moved[0].on=false;moved[0].alpha=0
        XCTAssertTrue(wm.beginLauncherTransfer(intent,moved[0],1,windows[0].rect,true))
        func poll(_ sequence:Int){wm.workspaceSampleSequence=sequence;wm.pollLauncherTransfers(Snapshot(space:1,stable:true,area:f.area,windows:moved))}
        poll(1);poll(2)
        XCTAssertEqual(wm.hidden,[hidden]);XCTAssertTrue(sys.transferRequests.isEmpty)
        XCTAssertNotNil(wm.launcherTransfers[1]?.arrival)
        poll(3);XCTAssertFalse(wm.launcherTransfers[1]?.revealQueued==true)
        _=try LauncherArrivalTests().acknowledge(wm,sys,eng,1);poll(4)
        XCTAssertTrue(wm.launcherTransfers[1]?.revealQueued==true)
        moved[0].alpha=1;sys.alphaM[1]=1;eng.ch.eng[0].curAlpha=1
        eng.ch.ringPending=true;poll(5);XCTAssertTrue(sys.transferRequests.isEmpty)
        eng.ch.ringPending=false;poll(6);poll(6);XCTAssertTrue(sys.transferRequests.isEmpty)
        poll(7);XCTAssertEqual(sys.transferRequests.count,1)
        XCTAssertEqual(wm.hidden,[hidden],"hidden intent retires only after real view/key ACK")
    }
    func testLauncherOriginKeySurvivesTicksBeforeSpotlightAndConsumesOnlyNewVisibleSelection() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair())
        sys.front=101;sys.contexts[101]=(1,0);sys.contexts[102]=(2,0)
        sys.launch=LauncherIntent(sequence:1,space:1,frontPID:101,kind:1,started:sys.t)
        for _ in 0..<6 {
            wm.observeLauncher(f.area,1,windows)
            wm.activateOnCurrentSpace(f.area,1,windows,101)
            XCTAssertEqual(wm.launcherIntent?.sequence,1)
            XCTAssertEqual(wm.launcherStatus["observed_sequence"],.int(1))
            XCTAssertEqual(wm.launcherStatus["disposition"],.string("awaiting-selection"))
            XCTAssertTrue(eng.ch.ops.isEmpty)
            sys.t+=0.03
        }
        sys.overlay=true;wm.activateOnCurrentSpace(f.area,1,windows,101)
        XCTAssertNotNil(wm.launcherIntent)
        sys.overlay=false;sys.front=102
        wm.activateOnCurrentSpace(f.area,1,windows,102)
        XCTAssertNil(wm.launcherIntent);XCTAssertNil(sys.launch)
        XCTAssertEqual(wm.launcherStatus["observed"]?["front_pid"],.int(101))
        XCTAssertEqual(wm.launcherStatus["disposition"],.string("selected-visible-window"))
        XCTAssertTrue(eng.ch.ops.isEmpty)
    }
    func testRetainedOriginStillCancelsOnNativeEscapeAndExpiresWithoutMutation() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair())
        sys.front=101;sys.contexts[101]=(1,0)
        sys.launch=LauncherIntent(sequence:1,space:1,frontPID:101,kind:1,started:sys.t)
        wm.observeLauncher(f.area,1,windows);wm.activateOnCurrentSpace(f.area,1,windows,101)
        sys.launch=LauncherIntent(sequence:2,space:0,frontPID:101,kind:0,started:sys.t)
        wm.observeLauncher(f.area,1,windows)
        XCTAssertNil(wm.launcherIntent)
        XCTAssertEqual(wm.launcherStatus["observed"]?["kind"],.int(0))
        XCTAssertEqual(wm.launcherStatus["disposition"],.string("cancelled-or-invalid-origin"))
        sys.launch=LauncherIntent(sequence:3,space:1,frontPID:101,kind:1,started:sys.t)
        wm.observeLauncher(f.area,1,windows);sys.t+=15.01
        wm.observeLauncher(f.area,1,windows)
        XCTAssertNil(wm.launcherIntent);XCTAssertNil(sys.launch)
        XCTAssertEqual(wm.launcherStatus["disposition"],.string("expired"))
        XCTAssertTrue(eng.ch.ops.isEmpty)
    }
    func testOverviewInheritedParkReleaseIsAtomicAndWaitsForGeoZeroBeforePool() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair()),park=Rect(1430,43,400,500)
        sys.births[101]="101:40:50";sys.bounds[1]=park;sys.alphaM[1]=0
        wm.hidden=[Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:[14,43,400,500],extra:.object([("swift_birth",.string("101:40:50"))]))]
        wm.last=(f.area,1,windows)
        var slot=EngWin(wid:1,pos:(park.x,park.y),size:(park.w,park.h),curAlpha:0,a:park);slot.geo=1;eng.ch.eng=[slot]
        XCTAssertTrue(wm.overviewRecords().isEmpty);XCTAssertTrue(eng.ch.ops.isEmpty)
        sys.t+=0.02
        XCTAssertTrue(wm.overviewRecords().isEmpty)
        XCTAssertEqual(eng.ch.ops.map{$0["op"]?.string},["forget","alpha","commit"])
        XCTAssertEqual(eng.ch.ops[1]["a"],.double(0))
        slot.geo=0;eng.ch.eng=[slot];eng.ch.ops=[]
        XCTAssertTrue(wm.overviewRecords().isEmpty)
        sys.t+=0.02
        XCTAssertEqual(wm.overviewRecords().map(\.wid),[1]);XCTAssertTrue(eng.ch.ops.isEmpty)
        for _ in 0..<40 {sys.t+=0.025;XCTAssertEqual(wm.overviewDesiredPool()?.map(\.wid),[1])}
        sys.births[101]="101:41:0";slot.geo=1;eng.ch.eng=[slot]
        XCTAssertTrue(wm.overviewRecords().isEmpty);XCTAssertTrue(eng.ch.ops.isEmpty)
    }
    func testAllHiddenGeometryMustDrainWithActualSizeIndependentOfSavedTarget() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair())
        wm.last=(f.area,1,windows)
        for window in windows {sys.births[window.pid]="\(window.pid):40:50"}
        wm.hidden=windows.map{Hidden(wid:$0.wid,pid:$0.pid,owner:$0.owner,space:1,rect:[14,43,362,446],extra:.object([("swift_birth",.string(sys.births[$0.pid]!))]))}
        for window in windows {sys.bounds[window.wid]=Rect(1430,41,720,window.wid==1 ? 903:450);sys.alphaM[window.wid]=0}
        var slots=windows.map{window -> EngWin in let frame=sys.bounds[window.wid]!;var slot=EngWin(wid:window.wid,pos:(frame.x,frame.y),size:(frame.w,frame.h),curAlpha:0,a:frame);slot.geo=1;slot.settling=true;return slot};eng.ch.eng=slots
        XCTAssertTrue(wm.overviewRecords().isEmpty);XCTAssertTrue(eng.ch.ops.isEmpty)
        sys.t+=0.02;XCTAssertTrue(wm.overviewRecords().isEmpty)
        XCTAssertEqual(eng.ch.ops.map{$0["op"]?.string},["forget","alpha","forget","alpha","commit"])
        slots[0].geo=0;eng.ch.eng=slots;eng.ch.ops=[]
        XCTAssertTrue(wm.overviewRecords().isEmpty) // Never grant a partially cleared pool.
        slots[1].geo=0;eng.ch.eng=slots
        XCTAssertTrue(wm.overviewRecords().isEmpty)
        sys.t+=0.02
        XCTAssertEqual(wm.overviewRecords().map(\.wid),[1,2])
        sys.bounds[1]=Rect(1430,41,40000,450);XCTAssertFalse(wm.overviewRecords().contains{$0.wid==1})
    }
    func testParkingClampAfterNativeReleaseRequiresNewStableActualBounds() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair()),proposed=Rect(1670,41,720,903),accepted=Rect(1430,41,720,903)
        sys.births[101]="101:40:50";sys.bounds[1]=proposed;sys.alphaM[1]=0
        wm.hidden=[Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:[14,43,400,500],extra:.object([("swift_birth",.string("101:40:50"))]))]
        wm.last=(f.area,1,windows)
        var slot=EngWin(wid:1,pos:(proposed.x,proposed.y),size:(proposed.w,proposed.h),curAlpha:0,a:proposed);slot.geo=1;eng.ch.eng=[slot]
        XCTAssertTrue(wm.overviewRecords().isEmpty);sys.t+=0.02
        XCTAssertTrue(wm.overviewRecords().isEmpty)
        XCTAssertNil(wm.hiddenParkSamples[1])
        slot.geo=0;eng.ch.eng=[slot];eng.ch.ops=[]
        XCTAssertTrue(wm.overviewRecords().isEmpty) // Earlier retained geometry cannot authorize this read.
        sys.bounds[1]=accepted;sys.t+=0.02
        XCTAssertTrue(wm.overviewRecords().isEmpty) // A later native clamp starts a new witness pair.
        sys.t+=0.02
        let pool=wm.overviewRecords()
        XCTAssertEqual(pool.count,1);XCTAssertEqual(pool.first?.parked,accepted)
        XCTAssertTrue(eng.ch.ops.isEmpty)
    }
    func testOSFocusFallbackDoesNotRevealHiddenButSamePIDExplicitLauncherDoes() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair())
        sys.births[101]="101:40:50";sys.front=101;sys.contexts[101]=(1,0)
        let row=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:windows[0].rect.arr,extra:.object([("swift_birth",.string("101:40:50")),("tiled",.bool(true))]))
        wm.hidden=[row];wm.sp(1).tree=Node(leaf:2)
        wm.activateOnCurrentSpace(f.area,1,windows,101)
        XCTAssertEqual(wm.hidden,[row]);XCTAssertTrue(eng.ch.ops.isEmpty)
        wm.launcherIntent=LauncherIntent(sequence:1,space:1,frontPID:101,kind:3,started:sys.t)
        wm.activateOnCurrentSpace(f.area,1,windows,101)
        XCTAssertTrue(wm.hidden.isEmpty);XCTAssertTrue(wm.restoring.contains(1))
    }
    func testSameSpaceHiddenLauncherWaitsForLocalPlacementBeforeCompletion() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,original)=try f.world(f.pair())
        wm.cfgSink=SnapshotHandoffTests.Recorder();wm.sp(1).tree=Node(leaf:2)
        sys.front=101;sys.contexts[101]=(1,0);sys.activeSpaceID=1
        sys.transferCatalog=try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(1))
        let record=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:original.first{$0.wid==1}!.rect.arr,
                          extra:.object([("swift_birth",.string("birth-1")),("tiled",.bool(true))]))
        wm.hidden=[record];sys.bounds[1]=Rect(1400,40,400,500);sys.alphaM[1]=0
        var windows=original
        let index=try XCTUnwrap(windows.firstIndex{$0.wid==1});windows[index].alpha=0
        wm.launcherAreas[1]=f.area;wm.launcherIntent=LauncherIntent(sequence:7,space:1,frontPID:999,kind:1,started:sys.t)
        wm.activateOnCurrentSpace(f.area,1,windows,101)
        XCTAssertTrue(wm.launcherTransfers.isEmpty,"A local hidden window needs no cross-Space provider")
        let pending=try XCTUnwrap(wm.restorePending[1]),plan=try XCTUnwrap(pending.placement)
        XCTAssertEqual(wm.launcherIntent?.sequence,7);XCTAssertEqual(wm.hidden,[record])
        wm.cfg=try NativeRuntimeConfig.build(base:wm.cfg,document:JSON.parse("{\"runtime\":{\"pointer_focus_pause_ms\":0}}"))
        sys.pointerHint=(2,102);let other=try XCTUnwrap(windows.first{$0.wid==2});sys.m=(other.x+30,other.y+30)
        wm.followMouse(1,windows)
        XCTAssertFalse(sys.calls.contains{$0.array?.first == .string("ax_focus")},"A stale stationary pointer cannot supersede a pending launcher placement")
        wm.activateOnCurrentSpace(f.area,1,windows,101)
        XCTAssertEqual(wm.launcherIntent?.sequence,7,"Repeated activation cannot consume a pending placement")
        var result=CfgResult(wid:1,owner:"Fixture",to:plan.rect,got:plan.rect,e:0,pre:sys.bounds[1])
        result.pid=101;result.birth="birth-1";result.isCurrent={true};wm.cfgQ=[result]
        var slot=EngWin(wid:1,pos:(plan.rect.x,plan.rect.y),size:(plan.rect.w,plan.rect.h),curAlpha:0,a:plan.rect)
        slot.geo=1;eng.ch.eng=[slot];sys.bounds[1]=plan.rect
        wm.completeRestores(f.area,1,windows)
        XCTAssertTrue(wm.hidden.isEmpty);XCTAssertNil(wm.restorePending[1]);XCTAssertNil(wm.launcherIntent)
        XCTAssertEqual(wm.launcherDisposition,"restored-local-window");XCTAssertTrue(wm.sp(1).tree?.contains(1)==true)
    }
    func testLocalLauncherRestoreCancelsWithoutRevealOrConsumingNewIntent() throws {
        for invalidation in ["timeout","birth","new-intent","foreground","key"] {
            let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair())
            wm.cfgSink=SnapshotHandoffTests.Recorder();wm.sp(1).tree=Node(leaf:2)
            sys.front=101;sys.contexts[101]=(1,0);sys.activeSpaceID=1
            let record=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:windows.first{$0.wid==1}!.rect.arr,
                              extra:.object([("swift_birth",.string("birth-1")),("tiled",.bool(true))]))
            wm.hidden=[record];wm.launcherAreas[1]=f.area
            wm.launcherIntent=LauncherIntent(sequence:7,space:1,frontPID:999,kind:1,started:sys.t)
            wm.activateOnCurrentSpace(f.area,1,windows,101);XCTAssertNotNil(wm.restorePending[1]);eng.ch.ops=[]
            switch invalidation {
            case "timeout":sys.t+=2.1
            case "birth":sys.births[101]="reused"
            case "new-intent":wm.launcherIntent=LauncherIntent(sequence:8,space:1,frontPID:999,kind:1,started:sys.t)
            case "key":sys.contexts[101]=(2,0)
            default:sys.front=102;sys.contexts[102]=(2,0)
            }
            wm.completeRestores(f.area,1,windows)
            XCTAssertEqual(wm.hidden,[record],invalidation);XCTAssertNil(wm.restorePending[1],invalidation)
            XCTAssertFalse(wm.sp(1).tree?.contains(1)==true,invalidation)
            XCTAssertFalse(eng.ch.ops.contains{$0["op"] == .string("alpha") && ($0["a"]?.double ?? 0)>0},invalidation)
            XCTAssertEqual(wm.launcherIntent?.sequence,invalidation=="new-intent" ? 8:nil,invalidation)
        }
    }
    func testLaunchMovesExactWindowBeforeViewAndRequiresTwoFreshMembershipWitnessesAndFinalViewKey() throws {
        let fixture=ProductionPolicyTests(),(wm,sys,eng,windows)=try fixture.world(fixture.pair())
        wm.cfgSink=SnapshotHandoffTests.Recorder()
        var moved=windows;moved[0].space=2
        let catalogue=PublicWorkspaceTests()
        sys.transferCatalog=try PublicWorkspaceCatalog(catalogue.raw(2));sys.front=101;sys.contexts[101]=(1,0)
        wm.launcherAreas[1]=fixture.area;wm.launcherIntent=LauncherIntent(sequence:1,space:1,frontPID:101,kind:1,started:sys.t)
        wm.sp(2).tree=Node(leaf:1);wm.sp(1).tree=Node(leaf:2)
        wm.activateOnCurrentSpace(fixture.area,2,moved,101)
        XCTAssertEqual(eng.ch.ops.filter{$0["op"] == .string("space")}.map{$0["wid"]},[.int(1)])
        XCTAssertNotNil(wm.launcherIntent);XCTAssertTrue(wm.sp(2).tree!.contains(1))
        moved[0].space=1;moved[0].on=false
        let census=Snapshot(space:2,stable:true,area:fixture.area,windows:moved)
        wm.workspaceSampleSequence=1;wm.pollLauncherTransfers(census)
        wm.pollLauncherTransfers(census);XCTAssertTrue(sys.transferRequests.isEmpty)
        wm.workspaceSampleSequence=2;wm.pollLauncherTransfers(census);XCTAssertTrue(sys.transferRequests.isEmpty)
        let target=try LauncherArrivalTests().acknowledge(wm,sys,eng,1)
        wm.workspaceSampleSequence=3;wm.pollLauncherTransfers(census)
        sys.alphaM[1]=1;eng.ch.eng[0].curAlpha=1;moved[0].alpha=1
        for sequence in [4,5] {wm.workspaceSampleSequence=sequence;wm.pollLauncherTransfers(Snapshot(space:2,stable:true,area:fixture.area,windows:moved))}
        XCTAssertEqual(sys.transferRequests.count,1)
        XCTAssertTrue(wm.sp(2).tree!.contains(1));XCTAssertNotNil(wm.launcherIntent)
        sys.transferCatalog=try PublicWorkspaceCatalog(catalogue.raw(1));moved[0].on=true
        wm.workspaceSampleSequence=6;wm.pollLauncherTransfers(Snapshot(space:1,stable:true,area:fixture.area,windows:moved))
        XCTAssertNil(wm.sp(2).tree);XCTAssertNil(wm.launcherIntent);XCTAssertFalse(wm.restoring.contains(1))
        XCTAssertTrue(wm.sp(1).tree?.contains(1)==true);XCTAssertEqual(wm.target[1],target);XCTAssertNil(wm.restoreFrom[1])
    }
    func testNewLauncherOrDifferentSelectedTabCancelsWithoutSourceTreeMutation() throws {
        for replace in [false,true] {
            let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair());var moved=windows;moved[0].space=2
            sys.transferCatalog=try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(2));sys.front=101;sys.contexts[101]=(1,0)
            wm.launcherAreas[1]=f.area;wm.launcherIntent=LauncherIntent(sequence:1,space:1,frontPID:999,kind:2,started:sys.t)
            wm.sp(2).tree=Node(leaf:1);wm.activateOnCurrentSpace(f.area,2,moved,101)
            if replace {wm.launcherIntent=LauncherIntent(sequence:2,space:1,frontPID:999,kind:2,started:sys.t)} else {sys.contexts[101]=(999,0)}
            moved[0].space=1;wm.workspaceSampleSequence=1
            wm.pollLauncherTransfers(Snapshot(space:2,stable:true,area:f.area,windows:moved))
            XCTAssertTrue(wm.launcherTransfers.isEmpty);XCTAssertTrue(sys.transferRequests.isEmpty);XCTAssertTrue(wm.sp(2).tree!.contains(1))
            if replace {XCTAssertEqual(wm.launcherIntent?.sequence,2)}
        }
    }
    func testSilentSendUsesOnlyEngineAndTwoFreshMembershipACKsBeforeSourceDetach() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair())
        sys.transferCatalog=try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(1));sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:windows)
        wm.sp(1).tree=Node(split:"v",ratio:0.5,a:Node(leaf:1),b:Node(leaf:2))
        XCTAssertEqual(try wm.command("sendws 2 1",f.area,1,windows),"sendws queued 1 -> 2")
        XCTAssertEqual(eng.ch.ops.map{$0["op"]?.string},["space","commit"]);XCTAssertTrue(wm.sp(1).tree!.contains(1))
        var moved=windows;moved[0].space=2;moved[0].on=false
        let snapshot=Snapshot(space:1,stable:true,area:f.area,windows:moved)
        wm.workspaceSampleSequence=1;wm.pollSilentSpaceMoves(snapshot);wm.pollSilentSpaceMoves(snapshot)
        XCTAssertTrue(wm.sp(1).tree!.contains(1));XCTAssertEqual(wm.silentSpaceMoveStatus["last"]?["native_samples"],.int(1))
        wm.workspaceSampleSequence=2;wm.pollSilentSpaceMoves(snapshot)
        XCTAssertEqual(wm.sp(1).tree?.wid,2);XCTAssertTrue(wm.silentSpaceMoves.isEmpty)
        XCTAssertEqual(wm.silentSpaceMoveStatus["last"]?["state"],.string("acknowledged"));XCTAssertTrue(sys.transferRequests.isEmpty)
        XCTAssertEqual(eng.ch.ops.map{$0["op"]?.string},["space","commit"])
    }
    func testSilentSendRejectsHiddenAndCancelsPIDReuseWithoutGraphMutation() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair())
        sys.transferCatalog=try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(1));sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:windows)
        wm.sp(1).tree=Node(leaf:1);wm.hidden=[Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:windows[0].rect.arr)]
        XCTAssertTrue(try wm.command("sendws 2 1",f.area,1,windows).hasPrefix("sendws refused"));XCTAssertTrue(eng.ch.ops.isEmpty)
        wm.hidden=[];_=try wm.command("sendws 2 1",f.area,1,windows);sys.births[101]="101:999:0"
        wm.pollSilentSpaceMoves(sys.nativeSnapshot!);XCTAssertTrue(wm.silentSpaceMoves.isEmpty);XCTAssertEqual(wm.sp(1).tree?.wid,1)
        XCTAssertEqual(wm.silentSpaceMoveStatus["last"]?["state"],.string("cancelled"))
    }
    func testHiddenPruneNeedsProvenDepartureAndNeverWritesWindow() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,_)=try f.world(f.pair())
        let row=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:[0,0,400,500],extra:.object([("swift_birth",.string("101:40:50"))]))
        wm.hidden=[row];sys.pidlevel[1]=nil;sys.births[101]=nil
        wm.pruneDepartedHidden();XCTAssertEqual(wm.hidden,[row]) // Unknown metadata does not authorize pruning.
        sys.exitedPIDs.insert(101);wm.pruneDepartedHidden();XCTAssertTrue(wm.hidden.isEmpty);XCTAssertTrue(eng.ch.ops.isEmpty)
        wm.hidden=[row];sys.exitedPIDs=[];sys.births[101]="101:41:0"
        wm.pruneDepartedHidden();XCTAssertTrue(wm.hidden.isEmpty);XCTAssertTrue(eng.ch.ops.isEmpty)
    }
    func testAdoptedHiddenNativeAlphaDriftForcesNewSlotAndKeepsUnknownLedger() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair())
        sys.births[101]="101:40:50";sys.alphaM[1]=1
        let row=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:windows[0].rect.arr,extra:.object([("swift_birth",.string("101:40:50"))]))
        let unknown=Hidden(wid:99,pid:101,owner:"Fixture",space:1,rect:windows[0].rect.arr,extra:row.extra)
        wm.hidden=[row,unknown];sys.pidlevel[99]=nil
        eng.ch.eng=[EngWin(wid:1,pos:(100,100),size:(400,500),curAlpha:0,a:Rect(100,100,400,500))]
        _=wm.rescue(f.area,1,windows,keepHidden:true)
        let alpha=eng.ch.ops.firstIndex{$0["op"] == .string("alpha") && $0["wid"] == .int(1)}!
        XCTAssertEqual(eng.ch.ops[alpha-1]["op"],.string("forget"));XCTAssertEqual(eng.ch.ops[alpha]["a"],.double(0))
        XCTAssertEqual(wm.hidden,[row,unknown]);XCTAssertFalse(eng.ch.ops.contains{$0["wid"] == .int(99)})
    }

}
