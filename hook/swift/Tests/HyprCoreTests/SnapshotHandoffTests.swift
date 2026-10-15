@testable import HyprCore
import XCTest

final class SnapshotHandoffTests:XCTestCase {
    func testCoveredOffscreenSourceKeepsLeafAfterConfigureUntilExactTerminalReceipt() throws {
        let (wm,sys,_,job)=try pending(),f=ProductionPolicyTests()
        var source=WinInfo(wid:1,pid:101,owner:"Fixture",x:job.to.x,y:job.to.y,w:job.to.w,h:job.to.h,on:false,space:1)
        source.alpha=0
        let peerFrame=wm.target[2]!
        let peer=WinInfo(wid:2,pid:102,owner:"Fixture",x:peerFrame.x,y:peerFrame.y,w:peerFrame.w,h:peerFrame.h,on:true,space:1)
        wm.observeSnapshot(event(1));wm.observeSnapshot(event(5))
        wm.snapshotConfigures[1]=nil // Readback queue may finish before the native cover releases.
        sys.tileableM[1]=0;sys.t+=0.3
        _=wm.sync(f.area,1,[source,peer])
        XCTAssertTrue(wm.sp(1).tree!.contains(1));XCTAssertTrue(wm.snapshotSourceCovered(source,space:1))
        wm.observeSnapshot(event(3,epoch:7))
        XCTAssertTrue(wm.snapshotSourceCovered(source,space:1))
        wm.observeSnapshot(event(3))
        XCTAssertFalse(wm.snapshotSourceCovered(source,space:1))
        _=wm.sync(f.area,1,[source,peer]);XCTAssertFalse(wm.sp(1).tree!.contains(1))
    }
    func testCoverLeaseNeverAdmitsHiddenOrRecycledSource() throws {
        let (wm,sys,_,job)=try pending()
        let source=WinInfo(wid:1,pid:101,owner:"Fixture",x:0,y:0,w:100,h:100,on:false,space:1)
        wm.observeSnapshot(event(1))
        wm.hidden.append(Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:job.to.arr))
        XCTAssertFalse(wm.snapshotSourceCovered(source,space:1))
        wm.hidden=[];sys.births[101]="recycled";XCTAssertFalse(wm.snapshotSourceCovered(source,space:1))
    }
    final class Recorder:ConfigureSink {
        var jobs:[CfgJob]=[]
        func submit(_ batch:[CfgJob]) {jobs+=batch}
    }
    func pending() throws -> (WM,FakeWorld,Recorder,CfgJob) {
        let f=ProductionPolicyTests(),(wm,sys,_,_)=try f.world(f.pair()),sink=Recorder()
        wm.cfgSink=sink
        let job=wm.job(101,1,wm.target[1]!)!
        wm.snapshotConfigures[1]=SnapshotConfigure(job:job,engineTime:10,started:sys.t,minimumEpoch:7)
        return (wm,sys,sink,job)
    }
    func event(_ result:Int,epoch:Int=8,time:Double=10) -> EngEvent {
        EngEvent(type:9,wid:1,t:time,rect:Rect(700,Double(result),3,Double(epoch)))
    }
    func testApplyRegistersOriginalSnapshotJobAndDefersConfigureUntilNativeReceipt() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,wins)=try f.world(f.pair()),sink=Recorder()
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:path)}
        sys.births[101]="101:40:50";sys.capabilities[101]=6;sys.applicationPaths[101]="/Applications/Fixture.app"
        let document=JSON.object([("schema",.int(1)),("generation",.string("owned")),("targets",.array([.object([("pid",.int(101)),
            ("birth",.array([.int(101),.int(Int(getuid())),.int(40),.int(50)])),("app",.string("/Applications/Fixture.app"))])]))])
        try Data(document.dumps().utf8).write(to:path)
        wm.clientPolicy=ClientPolicy(path:path.path);wm.options.snapshotFrames=true;eng.ch.snapshotEnabled=true;wm.cfgSink=sink
        eng.ch.batchTime=9.984;eng.ch.batchAfterEnqueue=10.016
        wm.sp(1).tree!.ratio=0.3
        wm.apply(f.area,1,wins,force:true)
        XCTAssertEqual(eng.ch.snapshotRequests,[1])
        XCTAssertNotNil(wm.snapshotConfigures[1]);XCTAssertEqual(wm.snapshotConfigures[1]?.job.birth,"101:40:50")
        XCTAssertEqual(wm.snapshotConfigures[1]?.job.to,wm.target[1]);XCTAssertEqual(wm.snapshotConfigures[1]?.space,1)
        XCTAssertEqual(wm.snapshotConfigures[1]?.engineTime,9.984)
        XCTAssertFalse(sink.jobs.contains{$0.wid==1})
        _=wm.handleEvents([event(1,time:9.983),event(5,time:9.983)])
        XCTAssertNil(wm.snapshotConfigures[1]?.epoch);XCTAssertFalse(sink.jobs.contains{$0.wid==1})
        _=wm.handleEvents([event(1,time:9.984),event(5,time:9.984)])
        XCTAssertEqual(sink.jobs.filter{$0.wid==1}.count,1);XCTAssertTrue(sink.jobs.first{$0.wid==1}!.verifyOnly)
    }
    func testNativeBatchClockUsesExactEngineApplyCmdProvenance() {
        XCTAssertEqual(NativeBatchClock.lowerBound(now:10,presentation:10.005,period:0.016),9.989,accuracy:0.000001)
        XCTAssertEqual(NativeBatchClock.lowerBound(now:10,presentation:10.020,period:0.016),10)
        XCTAssertEqual(NativeBatchClock.lowerBound(now:10,presentation:0,period:0),10)
    }
    func testConfiguredReceiptStartsOnlyReadbackAfterExactAcquisition() throws {
        let (wm,_,sink,_)=try pending()
        wm.observeSnapshot(event(5));XCTAssertTrue(sink.jobs.isEmpty)
        wm.observeSnapshot(event(1));wm.observeSnapshot(event(5))
        XCTAssertEqual(sink.jobs.count,1);XCTAssertTrue(sink.jobs[0].verifyOnly)
        wm.observeSnapshot(event(5));XCTAssertEqual(sink.jobs.count,1)
        wm.observeSnapshot(event(3));XCTAssertNil(wm.snapshotConfigures[1])
    }
    func testDeferredIsNotFailureAndConfigured5IsNotFallback() throws {
        let (wm,_,sink,_)=try pending()
        wm.observeSnapshot(event(2));wm.observeSnapshot(event(5))
        XCTAssertEqual(sink.jobs.count,1);XCTAssertTrue(sink.jobs[0].verifyOnly)
    }
    func testCancelledDifferentEpochStaleTimeAndRecycledOwnerCannotConfigure() throws {
        let (wm,sys,sink,_)=try pending()
        wm.observeSnapshot(event(1,time:9));wm.observeSnapshot(event(5));XCTAssertTrue(sink.jobs.isEmpty)
        wm.observeSnapshot(event(1));wm.observeSnapshot(event(5,epoch:7));XCTAssertTrue(sink.jobs.isEmpty)
        sys.births[101]="recycled"
        wm.observeSnapshot(event(5));XCTAssertTrue(sink.jobs.isEmpty)
        sys.births[101]="birth-1"
        wm.observeSnapshot(event(4));XCTAssertNil(wm.snapshotConfigures[1]);XCTAssertTrue(sink.jobs.isEmpty)
    }
    func testVerifyOnlyConfigurerNeverWritesAnAXFrame() {
        let sys=ConfigurerTests.AXSys();sys.gateFirst=false
        let result=expectation(description:"native final buffer readback")
        let configurer=Configurer(sys:sys){receipt in XCTAssertEqual(receipt.got,Rect(0,0,800,600));result.fulfill()}
        var job=CfgJob(wid:1,pid:9,owner:"Fixture",to:Rect(0,0,800,600));job.verifyOnly=true
        configurer.submit([job]);wait(for:[result],timeout:2)
        XCTAssertTrue(sys.frames.isEmpty)
    }
    func testIntegerTerminalHandoffRecoversRejectedFloatConfiguredReceiptAfterFreshCensus() throws {
        let (wm,_,sink,job)=try pending()
        wm.snapshotConfigures[1]?.space=1
        wm.observeSnapshot(event(1))
        wm.observeSnapshot(EngEvent(type:9,wid:1,t:10,rect:Rect(700,5,3,1694.8302)))
        XCTAssertTrue(sink.jobs.isEmpty)
        wm.observeSnapshot(event(3));XCTAssertTrue(sink.jobs.isEmpty)
        var snapshot=Snapshot(space:1,stable:false,area:ProductionPolicyTests().area,
            windows:[WinInfo(wid:1,pid:101,owner:"Fixture",x:job.to.x,y:job.to.y,w:job.to.w,h:job.to.h,on:true,space:1)])
        wm.verifySnapshotHandoffs(snapshot);XCTAssertTrue(sink.jobs.isEmpty)
        snapshot.stable=true;wm.verifySnapshotHandoffs(snapshot)
        XCTAssertEqual(sink.jobs.count,1);XCTAssertTrue(sink.jobs[0].verifyOnly)
        XCTAssertNil(wm.snapshotConfigures[1])
    }
    func testTerminalHandoffNeverRebindsARecycledWidInFreshCensus() throws {
        let (wm,sys,sink,job)=try pending()
        wm.observeSnapshot(event(1));wm.observeSnapshot(event(3));sys.births[101]="different-birth"
        wm.verifySnapshotHandoffs(Snapshot(space:1,stable:true,area:ProductionPolicyTests().area,
            windows:[WinInfo(wid:1,pid:101,owner:"Fixture",x:job.to.x,y:job.to.y,w:job.to.w,h:job.to.h,on:true,space:1)]))
        XCTAssertTrue(sink.jobs.isEmpty);XCTAssertNil(wm.snapshotConfigures[1])
    }
    func testCustomLongMotionDoesNotExpireItsLeaseAtTheFixedTwoSecondFallback() throws {
        let (wm,sys,_,_)=try pending();wm.snapshotConfigures[1]?.timeout=9
        sys.t+=3;XCTAssertFalse(wm.expireSnapshotJobs());XCTAssertNotNil(wm.snapshotConfigures[1])
        sys.t+=7;XCTAssertTrue(wm.expireSnapshotJobs());XCTAssertNil(wm.snapshotConfigures[1]);XCTAssertNil(wm.target[1])
    }
}
