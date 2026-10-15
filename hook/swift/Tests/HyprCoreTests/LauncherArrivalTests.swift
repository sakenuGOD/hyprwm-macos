@testable import HyprCore
import XCTest

final class LauncherArrivalTests:XCTestCase {
    func acknowledge(_ wm:WM,_ sys:FakeWorld,_ eng:FakeEngine,_ wid:Int) throws -> Rect {
        let transfer=try XCTUnwrap(wm.launcherTransfers[wid]),arrival=try XCTUnwrap(transfer.arrival),r=arrival.rect
        var result=CfgResult(wid:wid,owner:"Fixture",to:r,got:r,e:0,pre:transfer.frame)
        result.pid=transfer.request.pid;result.birth=transfer.request.birth;result.isCurrent={true};wm.cfgQ.append(result)
        sys.bounds[wid]=r;sys.alphaM[wid]=0
        var slot=EngWin(wid:wid,pos:(r.x,r.y),size:(r.w,r.h),curAlpha:0,a:r);slot.geo=1;eng.ch.eng=[slot]
        return r
    }
    func testAcceptedNativeMinimumKeepsFinalClipAndNeverRevealsStaleOrigin() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,_)=try f.world(f.pair())
        wm.cfgSink=SnapshotHandoffTests.Recorder()
        let goal=Rect(738,41,730,400),actual=Rect(738,41,730,508)
        let request=LauncherTransferFocus(pid:101,wid:1,birth:"birth-1",origin:1,source:2,sequence:1,deadline:sys.t+8,
            catalog:try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(2)))
        let arrival=LauncherArrival(tree:wm.sp(1).tree!.json,baseTree:wm.sp(1).tree!.json,rect:goal,presel:nil,basePresel:wm.sp(1).presel)
        func transfer()->LauncherTransfer {LauncherTransfer(request:request,frame:Rect(12,41,1446,508),wasHidden:true,nativeFrame:Rect(1670,41,1446,508),originalAlpha:0,arrival:arrival)}
        var trial=transfer()
        var slot=EngWin(wid:1,pos:(goal.x,goal.y),size:(goal.w,goal.h),curAlpha:0,a:actual);slot.geo=1
        eng.ch.eng=[slot];sys.bounds[1]=actual
        XCTAssertFalse(wm.launcherArrivalAccepted(&trial)) // A plausible minimum without configure ACK is not authority.
        var result=CfgResult(wid:1,owner:"Fixture",to:goal,got:actual,e:0,pre:Rect(12,41,1446,508))
        result.pid=101;result.birth="birth-1";result.isCurrent={true};wm.cfgQ=[result]
        XCTAssertTrue(wm.launcherArrivalAccepted(&trial))
        XCTAssertEqual(eng.ch.eng[0].visible,goal);XCTAssertEqual(eng.ch.eng[0].real,actual)
        var moved=actual;moved.x=12
        result.got=moved;wm.cfgQ=[result];sys.bounds[1]=moved;eng.ch.eng[0].ax=moved.x
        trial=transfer();XCTAssertFalse(wm.launcherArrivalAccepted(&trial)) // Old source origin is never a native-minimum exception.
        result.got=actual;result.isCurrent={false};wm.cfgQ=[result];sys.bounds[1]=actual;eng.ch.eng[0].ax=actual.x
        trial=transfer();XCTAssertFalse(wm.launcherArrivalAccepted(&trial))
        result.isCurrent={true};wm.cfgQ=[result];eng.ch.eng[0].size.1=508
        trial=transfer();XCTAssertFalse(wm.launcherArrivalAccepted(&trial)) // B must stay the exact logical allocation.
    }

    func testMovedActorIsPlacedAtFinalTileBeforeRevealAndNeverFliesFromOldSpace() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,original)=try f.world(f.pair()),sink=SnapshotHandoffTests.Recorder()
        wm.cfgSink=sink;wm.sp(1).tree=Node(leaf:2);wm.sp(2).tree=Node(leaf:1)
        sys.front=101;sys.contexts[101]=(1,0);sys.alphaM[1]=1;sys.transferCatalog=try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(2))
        let intent=LauncherIntent(sequence:1,space:1,frontPID:999,kind:1,started:sys.t);wm.launcherIntent=intent;wm.launcherAreas[1]=f.area
        var windows=original;windows[0].space=2
        XCTAssertTrue(wm.beginLauncherTransfer(intent,windows[0],2,Rect(300,300,800,600),false))
        XCTAssertEqual(eng.ch.ops.first?["op"],.string("alpha"));XCTAssertEqual(eng.ch.ops.first?["a"],.double(0))
        windows[0].space=1;windows[0].on=false;windows[0].alpha=0
        func poll(_ sample:Int,_ space:Int=2){wm.workspaceSampleSequence=sample;wm.pollLauncherTransfers(Snapshot(space:space,stable:true,area:f.area,windows:windows))}
        poll(1);poll(2)
        let arrival=try XCTUnwrap(wm.launcherTransfers[1]?.arrival)
        XCTAssertEqual(sink.jobs.count,1);XCTAssertEqual(sink.jobs.first?.to,arrival.rect)
        let warp=try XCTUnwrap(eng.ch.ops.first{$0["op"] == .string("warp") && $0["wid"] == .int(1)})
        XCTAssertEqual(warp["frm"],arrival.rect.json);XCTAssertEqual(warp["to"],arrival.rect.json)
        XCTAssertTrue(sys.transferRequests.isEmpty);XCTAssertEqual(wm.sp(2).tree?.wid,1)
        poll(3);XCTAssertFalse(wm.launcherTransfers[1]?.revealQueued==true)
        _=try acknowledge(wm,sys,eng,1);poll(4)
        XCTAssertTrue(wm.launcherTransfers[1]?.revealQueued==true);XCTAssertTrue(sys.transferRequests.isEmpty)
        windows[0].alpha=1;sys.alphaM[1]=1;eng.ch.eng[0].curAlpha=1
        poll(5);poll(6);XCTAssertEqual(sys.transferRequests.count,1)
        XCTAssertEqual(wm.sp(2).tree?.wid,1)
        sys.transferCatalog=try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(1));windows[0].on=true
        poll(7,1)
        XCTAssertNil(wm.sp(2).tree);XCTAssertTrue(wm.sp(1).tree?.contains(1)==true)
        XCTAssertEqual(wm.target[1],arrival.rect);XCTAssertNil(wm.restoreFrom[1]);XCTAssertFalse(wm.restoring.contains(1))
        XCTAssertFalse(sys.calls.contains{ $0.string?.contains("spawn") == true })
    }
    func testCancellationNeverResurrectsReusedOwnerOrDetachesSourceTree() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,original)=try f.world(f.pair())
        sys.front=101;sys.transferCatalog=try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(2));var window=original[0];window.space=2
        let intent=LauncherIntent(sequence:1,space:1,frontPID:999,kind:2,started:sys.t);wm.launcherIntent=intent;wm.sp(2).tree=Node(leaf:1)
        XCTAssertTrue(wm.beginLauncherTransfer(intent,window,2,window.rect,false));eng.ch.ops=[]
        sys.births[101]="replacement";wm.cancelLauncherTransfers()
        XCTAssertTrue(eng.ch.ops.isEmpty);XCTAssertEqual(wm.sp(2).tree?.wid,1)
    }
}
