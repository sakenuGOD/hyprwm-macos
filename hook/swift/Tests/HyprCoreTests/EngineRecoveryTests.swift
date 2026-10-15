@testable import HyprCore
import XCTest

final class EngineRecoveryTests:XCTestCase {
    let f = ProductionPolicyTests()
    var owned: [URL] = []
    override func tearDown() { for path in owned { try? FileManager.default.removeItem(at: path) } }
    func fixture() throws -> (WM,FakeWorld,FakeEngine,SnapshotHandoffTests.Recorder,Hidden) {
        let (_,sys,eng,_) = try f.world(f.pair()), sink = SnapshotHandoffTests.Recorder()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories:true);owned.append(directory)
        let wm = WM(sys:sys,eng:eng,deco:NullDeco(),cfg:try Fx.config(),
                    statePath:directory.appendingPathComponent("state.json").path,
                    minsizePath:directory.appendingPathComponent("mins.json").path)
        wm.options = .standard;wm.cfgSink = sink; wm.enabled = false; eng.ch.nativeActiveCount = 0
        sys.births[101] = "101:40:50"; sys.alphaM[1] = 0
        let row = Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:sys.bounds[1]!.arr,
                         extra:.object([("swift_birth",.string("101:40:50"))]))
        wm.hidden = [row]; eng.ch.ops = []
        return (wm,sys,eng,sink,row)
    }
    func ack(_ wm:WM,_ job:CfgJob,frame:Rect? = nil,current:Bool = true) {
        var r = CfgResult(wid:job.wid,owner:job.owner,to:job.to,got:frame ?? job.to,e:0,pre:nil)
        r.pid = job.pid; r.birth = job.birth; r.isCurrent = {current}; wm.cfgQ.append(r)
    }
    func step(_ wm:WM,_ sys:FakeWorld) {sys.t += 0.02;wm.pollEngineRecovery()}
    func testRestoreAllWorksPausedAndRetainsLedgerUntilNativeAndForgetACK() throws {
        let (wm,sys,eng,sink,row) = try fixture()
        XCTAssertThrowsError(try wm.command("restore-all",f.area,1,[]))
        XCTAssertEqual(wm.hidden,[row]); XCTAssertFalse(wm.enabled)
        XCTAssertEqual(sink.jobs.count,1); XCTAssertTrue(sink.jobs[0].requireOwnership)
        ack(wm,sink.jobs[0]); step(wm,sys)
        sys.alphaM[1] = 1; eng.ch.ringPending = true; step(wm,sys)
        XCTAssertEqual(wm.hidden,[row]); XCTAssertFalse(eng.ch.ops.contains{$0["op"] == .string("forget")})
        eng.ch.ringPending = false; step(wm,sys); step(wm,sys)
        XCTAssertTrue(eng.ch.ops.contains{$0["op"] == .string("forget")}); XCTAssertEqual(wm.hidden,[row])
        eng.ch.ringPending = true; step(wm,sys); XCTAssertEqual(wm.hidden,[row])
        eng.ch.ringPending = false; step(wm,sys); step(wm,sys)
        XCTAssertTrue(wm.hidden.isEmpty); XCTAssertFalse(wm.engineRecoveryActive); XCTAssertFalse(wm.enabled)
        XCTAssertEqual(try wm.command("restore-all",f.area,1,[]),"restored all windows")
    }
    func testOldConfigureOrUnchangedParkNeverRetiresRow() throws {
        let (wm,sys,_,sink,row) = try fixture();wm.requestEngineRecovery();step(wm,sys)
        ack(wm,sink.jobs[0],current:false);sys.alphaM[1] = 1
        for _ in 0..<4 {step(wm,sys)}
        XCTAssertEqual(wm.hidden,[row]);XCTAssertNil(wm.engineRecoveryWork[1]?.accepted)
        wm.cfgQ = [];ack(wm,sink.jobs[0],frame:Rect(1600,30,400,400))
        for _ in 0..<4 {step(wm,sys)}
        XCTAssertEqual(wm.hidden,[row]);XCTAssertNil(wm.engineRecoveryWork[1]?.accepted)
    }
    func testReusedIdentityAndUnknownIdentityReceiveNoRecoveryCommands() throws {
        for birth in ["101:99:99",nil] as [String?] {
            let (wm,sys,eng,sink,row) = try fixture();sys.births[101] = birth
            wm.requestEngineRecovery();step(wm,sys)
            XCTAssertEqual(wm.hidden,[row]);XCTAssertTrue(eng.ch.ops.isEmpty);XCTAssertTrue(sink.jobs.isEmpty)
            sys.t += 9;step(wm,sys);XCTAssertEqual(wm.hidden,[row]);XCTAssertTrue(eng.ch.ops.isEmpty)
        }
    }
    func testCrashRecoveryPumpsBeforePausedTickReturnAndBlocksResume() throws {
        let (wm,_,_,sink,row) = try fixture();wm.startupRecoveryPending = true
        wm.tick(socketReady:false)
        XCTAssertEqual(wm.hidden,[row]);XCTAssertEqual(sink.jobs.count,1)
        XCTAssertThrowsError(try wm.command("resume",f.area,1,[]))
        XCTAssertFalse(wm.enabled);XCTAssertTrue(wm.engineRecoveryActive)
    }
    func testHandoverIsOneUseExactLedgerAndRequiresPreviousOwnerDeparture() throws {
        let (wm,sys,eng,_,row) = try fixture();let pid = Int(getpid());sys.births[pid] = "owner-birth"
        XCTAssertTrue(wm.prepareHandover().hasPrefix("handover ready:"))
        XCTAssertNotNil(wm.stateJSON["handover"])
        XCTAssertThrowsError(try wm.prepareStartupRecovery()) // previous owner still alive
        sys.births[pid] = nil
        XCTAssertThrowsError(try wm.prepareStartupRecovery()) // unknown is not departed
        sys.exitedPIDs.insert(pid);try wm.prepareStartupRecovery()
        wm.startupRecoveryPending = true;eng.ch.ops = [];wm.pollEngineRecovery()
        XCTAssertEqual(wm.hidden,[row]);XCTAssertNil(wm.hiddenHandover)
        XCTAssertFalse(wm.engineRecoveryActive);XCTAssertTrue(eng.ch.ops.isEmpty)
    }
    func testFailedHandoverPersistenceNeverReportsReady() throws {
        let (wm,sys,_,_,_) = try fixture();sys.births[Int(getpid())] = "owner-birth";wm.saveEnabled = false
        XCTAssertTrue(wm.prepareHandover().hasPrefix("handover refused:"));XCTAssertNil(wm.hiddenHandover)
    }
    func testChangedHandoverLedgerRefusesAndResumeDisarmsMarker() throws {
        let (wm,sys,_,_,_) = try fixture();let pid = Int(getpid());sys.births[pid] = "owner-birth"
        _ = wm.prepareHandover();sys.exitedPIDs.insert(pid);wm.hidden[0].rect[0] += 10
        XCTAssertThrowsError(try wm.prepareStartupRecovery())
        wm.setEnabled(true);XCTAssertNil(wm.hiddenHandover)
    }
    func testRecoveryNeverSubmitsMoreThanTwoUnacknowledgedAXJobs() throws {
        let (wm,sys,_,sink,row) = try fixture()
        for wid in 2...12 {
            let pid = 100+wid;sys.pidlevel[wid] = (pid,0);sys.births[pid] = "\(pid):40:50"
            wm.hidden.append(Hidden(wid:wid,pid:pid,owner:row.owner,space:1,rect:row.rect,
                extra:.object([("swift_birth",.string("\(pid):40:50"))])))
        }
        wm.requestEngineRecovery();for _ in 0..<5 {step(wm,sys)}
        XCTAssertEqual(sink.jobs.count,2);XCTAssertEqual(wm.hidden.count,12)
    }
    func testHideRefusesBeforeNativeMutationWhenJournalCannotBeSaved() throws {
        let (wm,sys,eng,_,row) = try fixture();wm.hidden = [];wm.sp(1).tree = f.pair()
        try FileManager.default.createDirectory(atPath:wm.statePath,withIntermediateDirectories:false)
        let tree = wm.sp(1).tree!.json, r = Rect(row.rect)!
        let window = WinInfo(wid:1,pid:101,owner:"Fixture",x:r.x,y:r.y,w:r.w,h:r.h,on:true,space:1)
        XCTAssertEqual(wm.hide(f.area,1,[window],1),"hide refused: hidden ledger was not saved")
        XCTAssertEqual(wm.sp(1).tree!.json,tree);XCTAssertTrue(wm.hidden.isEmpty);XCTAssertTrue(eng.ch.ops.isEmpty)
        XCTAssertEqual(sys.alphaM[1],0) // fake native truth was never changed by the refusal
    }
    func testHideJournalExistsBeforeFirstAlphaZeroPublication() throws {
        let (wm,_,eng,_,row) = try fixture();wm.hidden = [];wm.sp(1).tree = f.pair()
        var witnessed = false
        eng.ch.beforeAlpha = { wid,alpha in
            guard wid == 1 && alpha == 0 else { return }
            let data = try? Data(contentsOf:URL(fileURLWithPath:wm.statePath))
            let state = data.flatMap { try? JSON.parse($0) }
            XCTAssertEqual(state?["hidden"]?.array?.first?["wid"],.int(1));witnessed = true
        }
        let r = Rect(row.rect)!, window = WinInfo(wid:1,pid:101,owner:"Fixture",x:r.x,y:r.y,w:r.w,h:r.h,on:true,space:1)
        XCTAssertEqual(wm.hide(f.area,1,[window],1),"hidden 1");XCTAssertTrue(witnessed)
    }

    func testActiveAndExpiredRecoveryCannotArmHandover() throws {
        let (wm,sys,_,sink,_) = try fixture();sys.births[Int(getpid())] = "owner-birth"
        wm.requestEngineRecovery();step(wm,sys);ack(wm,sink.jobs[0]);step(wm,sys)
        XCTAssertEqual(wm.prepareHandover(),"handover pending: Engine recovery is active")
        XCTAssertNil(wm.hiddenHandover)
        sys.t += 9
        XCTAssertEqual(wm.prepareHandover(),"handover pending: Engine recovery is active")
        XCTAssertNil(wm.hiddenHandover)
    }

    func testExplicitRecoveryOverridesActiveStartupResumeIntent() throws {
        let (wm,sys,_,sink,_) = try fixture();wm.requestEngineRecovery(resumeAfter:true)
        XCTAssertTrue(wm.engineRecoveryResume);wm.requestEngineRecovery();XCTAssertFalse(wm.engineRecoveryResume)
        step(wm,sys);ack(wm,sink.jobs[0]);step(wm,sys);sys.alphaM[1] = 1
        for _ in 0..<4 {step(wm,sys)}
        XCTAssertTrue(wm.hidden.isEmpty);XCTAssertFalse(wm.enabled);XCTAssertFalse(wm.engineRecoveryActive)
    }

    func testExplicitPauseRevokesActiveStartupResumeIntent() throws {
        let (wm,sys,_,sink,_) = try fixture();wm.requestEngineRecovery(resumeAfter:true)
        XCTAssertTrue(wm.engineRecoveryResume);_ = try wm.command("pause",f.area,1,[])
        XCTAssertFalse(wm.engineRecoveryResume);step(wm,sys);ack(wm,sink.jobs[0]);step(wm,sys);sys.alphaM[1] = 1
        for _ in 0..<4 {step(wm,sys)}
        XCTAssertTrue(wm.hidden.isEmpty);XCTAssertFalse(wm.enabled)
    }

    func testStartupPendingCannotRearmConsumedHandoverBeforeFirstTick() throws {
        let (wm,sys,_,_,row) = try fixture();let pid = Int(getpid());sys.births[pid] = "old-birth"
        XCTAssertTrue(wm.prepareHandover().hasPrefix("handover ready:"));let marker = wm.hiddenHandover
        sys.births[pid] = nil;sys.exitedPIDs.insert(pid);try wm.prepareStartupRecovery();wm.startupRecoveryPending = true
        XCTAssertEqual(wm.prepareHandover(),"handover pending: Engine recovery is active")
        XCTAssertEqual(wm.hiddenHandover,marker);wm.pollEngineRecovery()
        XCTAssertNil(wm.hiddenHandover);XCTAssertEqual(wm.hidden,[row]);XCTAssertFalse(wm.engineRecoveryActive)
    }

    final class PauseRecorder:ConfigureSink {
        var jobs:[CfgJob]=[],pending=Set<Int>(),globalCancels=0,cancelled:[Int]=[]
        func submit(_ batch:[CfgJob]){jobs+=batch;pending.formUnion(batch.map(\.wid))}
        func cancelAll(){globalCancels+=1;pending.removeAll()}
        func cancel(_ wid:Int){cancelled.append(wid);pending.remove(wid)}
        var idle:Bool{pending.isEmpty};func busy(_ wid:Int)->Bool{pending.contains(wid)}
    }
    func visiblePauseFixture()throws->(WM,FakeWorld,FakeEngine,PauseRecorder,Rect){
        let (wm,sys,eng,_,row)=try fixture(),sink=PauseRecorder(),actual=Rect(row.rect)!
        let presented=Rect(actual.x+70,actual.y+40,actual.w-20,actual.h-10)
        wm.hidden=[];wm.enabled=true;wm.cfgSink=sink;wm.target[1]=actual;wm.pids[1]=101;wm.owner[1]="Fixture"
        var slot=EngWin(wid:1,pos:(presented.x,presented.y),size:(presented.w,presented.h),curAlpha:1,a:actual);slot.geo=1;eng.ch.eng=[slot]
        sys.alphaM[1]=1;return(wm,sys,eng,sink,presented)
    }
    func testVisibleMidMotionWithoutHiddenRowsCannotCompleteBeforePauseLanding()throws{
        let(wm,sys,eng,sink,presented)=try visiblePauseFixture()
        XCTAssertThrowsError(try wm.engineRestoreAll());XCTAssertEqual(sink.globalCancels,1)
        XCTAssertEqual(sink.pending,[1]);XCTAssertEqual(sink.jobs.first?.to,presented);XCTAssertTrue(wm.hidden.isEmpty);XCTAssertFalse(wm.shutdownDrained)
        let before=try JSON.parse(wm.command("status",f.area,1,[]))
        XCTAssertEqual(before["visibility"]?["restore_pending"],.array([.int(1)]));XCTAssertEqual(before["visibility"]?["engine_recovery_active"],.bool(true))
        sink.pending.remove(1);sys.bounds[1]=presented;ack(wm,sink.jobs[0]);step(wm,sys)
        XCTAssertTrue(wm.engineRecoveryActive);XCTAssertTrue(wm.cfgQ.isEmpty)
        eng.ch.ringPending=true;step(wm,sys);XCTAssertTrue(wm.engineRecoveryActive)
        eng.ch.ringPending=false;step(wm,sys);step(wm,sys)
        XCTAssertFalse(wm.engineRecoveryActive);XCTAssertFalse(wm.enabled);XCTAssertTrue(wm.shutdownDrained)
        let after=try JSON.parse(wm.command("status",f.area,1,[]));XCTAssertEqual(after["visibility"]?["restore_pending"],.array([]));XCTAssertEqual(after["visibility"]?["engine_recovery_active"],.bool(false))
    }
    func testAlreadyPausedLandingJobsSurviveRestoreAllAndLateACKDrains()throws{
        let(wm,sys,_,sink,presented)=try visiblePauseFixture();wm.setEnabled(false)
        XCTAssertEqual(sink.globalCancels,1);XCTAssertEqual(sink.pending,[1])
        XCTAssertThrowsError(try wm.engineRestoreAll());XCTAssertEqual(sink.globalCancels,1);XCTAssertEqual(sink.pending,[1])
        sink.pending.remove(1);sys.bounds[1]=presented
        for _ in 0..<3{step(wm,sys)}
        XCTAssertFalse(wm.engineRecoveryActive)
        ack(wm,sink.jobs[0]);XCTAssertFalse(wm.cfgQ.isEmpty);wm.tick(socketReady:false);XCTAssertTrue(wm.cfgQ.isEmpty)
    }
    func testFailedVisiblePauseACKNeverTimeoutForgetsDuringRecovery()throws{
        let(wm,sys,eng,sink,_)=try visiblePauseFixture();wm.requestEngineRecovery();sink.pending.remove(1)
        sys.t+=1.1
        let done=expectation(description:"existing pause callback polled")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.05){done.fulfill()};wait(for:[done],timeout:0.3)
        XCTAssertFalse(eng.ch.ops.contains{$0["op"] == .string("forget")})
        XCTAssertThrowsError(try wm.engineRestoreAll());XCTAssertTrue(wm.engineRecoveryActive)
    }

    func testOrdinaryPauseClearsConsumedWitnessWithoutMovingManuallyPlacedWindow()throws{
        let(wm,sys,eng,sink,presented)=try visiblePauseFixture();wm.setEnabled(false)
        XCTAssertEqual(wm.pauseLandingWitnesses.count,1);sink.pending.remove(1);sys.bounds[1]=presented;eng.ch.eng=[]
        let manual=Rect(presented.x+20,presented.y+20,presented.w,presented.h);sys.bounds[1]=manual
        let before=eng.ch.ops;wm.tick(socketReady:false)
        XCTAssertTrue(wm.pauseLandingWitnesses.isEmpty);XCTAssertEqual(eng.ch.ops,before);XCTAssertEqual(sys.bounds[1],manual)
        XCTAssertTrue(wm.shutdownDrained)
    }

}
