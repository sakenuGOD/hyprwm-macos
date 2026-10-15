@testable import HyprCore
import XCTest

final class OrdinaryOverviewPolicyTests:XCTestCase {
    func testConcealedParkAllowsOnlyAppKitHorizontalOriginClampAndStillRequiresPhysicalPark() throws {
        let row=Hidden(wid:42,pid:819,owner:"Fixture",space:1,rect:[12,41,720,304],extra:.object([("swift_birth",.string("819:1792050797:225591"))]))
        let grant=try OverviewHidden(record:row,parked:Rect(1670,41,720,304),space:1,birth:[819,Int(getuid()),1792050797,225591])
        let pose=OrdinaryOverviewPose(source:grant,visible:Rect(12,41,720,304))
        let app=Rect(1430,41,720,304)
        func accepts(_ frame:Rect,_ parked:Bool=true,_ current:Bool=true,_ alpha:Double?=0) -> Bool {
            OrdinaryOverviewFrameReadback.acceptsAppKit(frame,pose:pose,parked:parked,sourceCurrent:current,alpha:alpha)
        }
        XCTAssertTrue(accepts(app)) // Real Source14 exit: original physical x1670, AppKit clamps to x1430.
        XCTAssertTrue(accepts(grant.parked))
        XCTAssertFalse(accepts(app,false));XCTAssertFalse(accepts(app,true,false))
        XCTAssertFalse(accepts(app,true,true,1));XCTAssertFalse(accepts(app,true,true,nil))
        for frame in [Rect(1430,42,720,304),Rect(1430,41,719,304),Rect(1430,41,720,303),Rect(1700,41,720,304),Rect(-40,41,720,304)] {
            XCTAssertFalse(accepts(frame))
        }
        let f=ProductionPolicyTests(),(wm,sys,eng,_)=try f.world(f.pair())
        sys.births[819]="819:1792050797:225591";sys.pidlevel[42]=(819,0);sys.alphaM[42]=0
        wm.hidden=[row];wm.overviewFrozen={true};sys.bounds[42]=app
        var slot=EngWin(wid:42,pos:(1430,41),size:(720,304),curAlpha:0,a:app);slot.geo=0;eng.ch.eng=[slot]
        XCTAssertFalse(wm.ordinaryGeometryConsumed([pose],parked:true)) // AX clamp NEVER proves physical restoration.
        sys.bounds[42]=grant.parked
        XCTAssertTrue(wm.ordinaryGeometryConsumed([pose],parked:true))
    }

    func testDepartedDockConcealsOnlyUnchangedSceneBeforeRollbackAndNeverAssumesDeath() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair())
        sys.births[101]="101:40:50";sys.alphaM[1]=1;wm.overviewFrozen={true}
        sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:windows)
        let row=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:[738,41,720,903],extra:.object([("swift_birth",.string("101:40:50"))]))
        wm.hidden=[row]
        let grant=try OverviewHidden(record:row,parked:Rect(1430,41,720,903),space:1,birth:[101,Int(getuid()),40,50])
        let pose=OrdinaryOverviewPose(source:grant,visible:Rect(738,41,720,903)),poses=[pose]
        sys.bounds[1]=pose.visible
        XCTAssertFalse(wm.ordinaryDockDeparted(pid:900,birth:"900:10:20"))
        XCTAssertFalse(wm.ordinaryRollbackConcealed(poses,dockPID:900,dockBirth:"900:10:20"));XCTAssertTrue(eng.ch.ops.isEmpty)
        sys.births[900]="900:10:20"
        XCTAssertFalse(wm.ordinaryDockDeparted(pid:900,birth:"900:10:20"))
        sys.births[900]="900:10:21"
        XCTAssertTrue(wm.ordinaryDockDeparted(pid:900,birth:"900:10:20"))
        sys.births[900]=nil;sys.exitedPIDs.insert(900)
        XCTAssertFalse(wm.ordinaryRollbackConcealed(poses,dockPID:900,dockBirth:"900:10:20"))
        XCTAssertEqual(eng.ch.ops.map{$0["op"]?.string},["forget","alpha","commit"])
        XCTAssertEqual(eng.ch.ops[1]["a"],.double(0));XCTAssertEqual(wm.hidden,[row])
        eng.ch.ops=[];eng.ch.ringPending=true
        XCTAssertFalse(wm.ordinaryRollbackConcealed(poses,dockPID:900,dockBirth:"900:10:20"));XCTAssertTrue(eng.ch.ops.isEmpty)
        eng.ch.ringPending=false;sys.alphaM[1]=0
        XCTAssertTrue(wm.ordinaryRollbackConcealed(poses,dockPID:900,dockBirth:"900:10:20"))
        sys.alphaM[1]=1;sys.bounds[1]=Rect(2,2,40,40)
        XCTAssertFalse(wm.ordinaryRollbackConcealed(poses,dockPID:900,dockBirth:"900:10:20"));XCTAssertTrue(eng.ch.ops.isEmpty)
        sys.bounds[1]=pose.visible;var elsewhere=windows;elsewhere[0].space=2
        sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:elsewhere)
        XCTAssertFalse(wm.ordinaryRollbackConcealed(poses,dockPID:900,dockBirth:"900:10:20"));XCTAssertTrue(eng.ch.ops.isEmpty)
        sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:windows);wm.hidden=[]
        XCTAssertFalse(wm.ordinaryRollbackConcealed(poses,dockPID:900,dockBirth:"900:10:20"));XCTAssertTrue(eng.ch.ops.isEmpty)
        XCTAssertTrue(wm.ordinaryRollbackConcealed([],dockPID:900,dockBirth:"900:10:20"),"no live source must not leave a dead OWN fixture busy")
    }
    func testDeadDockRollbackStillRequiresCurrentHiddenIdentityAndConsumedPark() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,_)=try f.world(f.pair())
        sys.births[101]="101:40:50";sys.alphaM[1]=0;wm.overviewFrozen={true}
        let row=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:[738,41,720,903],extra:.object([("swift_birth",.string("101:40:50"))]))
        wm.hidden=[row]
        let grant=try OverviewHidden(record:row,parked:Rect(1430,41,720,903),space:1,birth:[101,Int(getuid()),40,50])
        let pose=OrdinaryOverviewPose(source:grant,visible:Rect(738,41,720,903)),poses=[pose]
        sys.bounds[1]=pose.visible
        XCTAssertTrue(wm.ordinaryGeometryAuthority(poses,parked:true,dockCurrent:false),"dead Dock must not prevent exact hidden rollback")
        XCTAssertFalse(wm.ordinaryGeometryAuthority(poses,parked:false,dockCurrent:false),"dead Dock never authorizes presentation")
        XCTAssertTrue(wm.ordinaryGeometryStart(poses,parked:true))
        XCTAssertFalse(wm.ordinaryGeometryRelease(poses,parked:true))
        var slot=EngWin(wid:1,pos:(1430,41),size:(720,903),curAlpha:0,a:grant.parked);slot.geo=1
        eng.ch.eng=[slot];sys.bounds[1]=grant.parked
        XCTAssertTrue(wm.ordinaryGeometryRelease(poses,parked:true))
        XCTAssertFalse(wm.ordinaryGeometryConsumed(poses,parked:true))
        slot.geo=0;eng.ch.eng=[slot]
        XCTAssertTrue(wm.ordinaryGeometryConsumed(poses,parked:true));XCTAssertEqual(wm.hidden,[row])
        sys.alphaM[1]=1;XCTAssertFalse(wm.ordinaryGeometryAuthority(poses,parked:true,dockCurrent:false))
        sys.alphaM[1]=0;sys.births[101]="101:41:0"
        XCTAssertFalse(wm.ordinaryGeometryAuthority(poses,parked:true,dockCurrent:false))
        sys.births[101]="101:40:50";wm.hidden=[]
        XCTAssertFalse(wm.ordinaryGeometryAuthority(poses,parked:true,dockCurrent:false))
    }
    func testAcceptedAppKitFrameNeedsPhysicalPulseAndConsumedAlphaOnlyRelease() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,_)=try f.world(f.pair())
        sys.births[101]="101:40:50";sys.alphaM[1]=0;wm.overviewFrozen={true}
        let record=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:[738,41,720,903],extra:.object([("swift_birth",.string("101:40:50"))]))
        wm.hidden=[record]
        let grant=try OverviewHidden(record:record,parked:Rect(1430,41,720,903),space:1,birth:[101,Int(getuid()),40,50])
        let pose=OrdinaryOverviewPose(source:grant,visible:Rect(738,41,720,903)),poses=[pose]
        sys.bounds[1]=grant.parked
        XCTAssertTrue(wm.ordinaryGeometryStart(poses,parked:false))
        XCTAssertEqual(eng.ch.ops.filter{$0["op"] == .string("warp")}.last?["to"],pose.visible.json)
        XCTAssertFalse(wm.ordinaryGeometryRelease(poses,parked:false)) // AX-only acceptance is insufficient.
        var slot=EngWin(wid:1,pos:(738,41),size:(720,903),curAlpha:0,a:pose.visible);slot.geo=1
        eng.ch.eng=[slot];sys.bounds[1]=pose.visible;eng.ch.ringPending=true
        XCTAssertFalse(wm.ordinaryGeometryRelease(poses,parked:false))
        eng.ch.ringPending=false
        XCTAssertTrue(wm.ordinaryGeometryRelease(poses,parked:false))
        XCTAssertEqual(Array(eng.ch.ops.suffix(3)).map{$0["op"]},[.string("forget"),.string("alpha"),.string("commit")])
        XCTAssertEqual(eng.ch.ops[eng.ch.ops.count-2]["a"],.double(0))
        XCTAssertFalse(wm.ordinaryGeometryConsumed(poses,parked:false))
        slot.geo=0;eng.ch.eng=[slot]
        XCTAssertTrue(wm.ordinaryGeometryConsumed(poses,parked:false))
        XCTAssertEqual(wm.hidden,[record])
        XCTAssertTrue(wm.ordinaryGeometryStart(poses,parked:true))
        XCTAssertEqual(eng.ch.ops.filter{$0["op"] == .string("warp")}.last?["to"],grant.parked.json)
        sys.births[101]="101:41:0";let count=eng.ch.ops.count
        XCTAssertFalse(wm.ordinaryGeometryStart(poses,parked:true));XCTAssertEqual(eng.ch.ops.count,count)
    }
    func testOrdinaryFrameUsesSavedOriginAndActualAcceptedSizeWithoutChangingIntent() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,_)=try f.world(f.pair())
        sys.births[101]="101:40:50";sys.alphaM[1]=0
        let record=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:[738,41,362,446],extra:.object([("swift_birth",.string("101:40:50"))]))
        wm.hidden=[record]
        let grant=try OverviewHidden(record:record,parked:Rect(1430,41,720,903),space:1,birth:[101,Int(getuid()),40,50])
        let poses=wm.ordinaryOverviewPoses([grant],display:Rect(0,0,1470,956))
        XCTAssertEqual(poses?.first?.visible,Rect(738,41,720,903))
        XCTAssertEqual(wm.hidden,[record]);XCTAssertTrue(wm.restoring.isEmpty)
        XCTAssertNil(grant.json["visible_bounds"]) // Legacy wire schema is unchanged.
        XCTAssertEqual(grant.ordinaryVisibleBounds(display:Rect(0,0,500,400)),nil)
    }
    func testPreEntryRefusesMissingOrSupersededGrantAndBirthReuse() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,_)=try f.world(f.pair())
        sys.births[101]="101:40:50";sys.alphaM[1]=0
        let record=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:[738,41,720,903],extra:.object([("swift_birth",.string("101:40:50"))]))
        wm.hidden=[record]
        let grant=try OverviewHidden(record:record,parked:Rect(1430,41,720,903),space:1,birth:[101,Int(getuid()),40,50]),display=Rect(0,0,1470,956)
        XCTAssertNil(wm.ordinaryOverviewPoses([],display:display))
        XCTAssertEqual(wm.ordinaryOverviewRefusal([],display:display),"hidden-count-mismatch:1:0")
        XCTAssertNotNil(wm.ordinaryOverviewPoses([grant],display:display))
        XCTAssertNil(wm.ordinaryOverviewRefusal([grant],display:display))
        wm.hidden=[]
        XCTAssertFalse(wm.ordinaryOverviewIntentLive(grant))
        XCTAssertNil(wm.ordinaryOverviewPoses([grant],display:display))
        XCTAssertEqual(wm.ordinaryOverviewRefusal([grant],display:display),"hidden-count-mismatch:0:1")
        wm.hidden=[record];sys.births[101]="101:41:0"
        XCTAssertFalse(wm.ordinaryOverviewIntentLive(grant))
        XCTAssertNil(wm.ordinaryOverviewPoses([grant],display:display))
    }
}
