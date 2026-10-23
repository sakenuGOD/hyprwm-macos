@testable import HyprCore
import XCTest

final class OverviewOwnershipTests:XCTestCase {
    final class Sink:ConfigureSink {
        var cancelled:[Int]=[],jobs:[CfgJob]=[]
        var idle=true
        func cancel(_ wid:Int){cancelled.append(wid)}
        func submit(_ jobs:[CfgJob]){self.jobs+=jobs}
    }
    func testEntryReleasesVisibleMotionOncePreservesOpaqueHiddenGrantAndExitRetiles() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,wins)=try f.world(f.pair()),sink=Sink()
        wm.cfgSink=sink;sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:wins)
        for w in wins {sys.alphaM[w.wid]=1}
        let hidden=Hidden(wid:2,pid:102,owner:"Fixture",space:1,rect:wins[1].rect.arr)
        wm.hidden=[hidden];wm.overviewGrantedWindows={Set([2])}
        let goal=wm.target[1]!,job=wm.job(101,1,goal)!
        _=wm.prepareLiveBuffer(job,actual:Rect(12,41,1200,870),space:1,duration:0.4)
        var active=true;wm.overviewFrozen={active}
        wm.updateOverviewOwnership(active:true)
        XCTAssertEqual(sink.cancelled,[1]);XCTAssertNil(wm.liveBufferShrinks[1]);XCTAssertNil(wm.target[1])
        XCTAssertEqual(eng.ch.ops.filter{$0["op"] == .string("forget")}.map{$0["wid"]},[.int(1)])
        XCTAssertEqual(eng.ch.ops.filter{$0["op"] == .string("commit")}.count,1)
        XCTAssertEqual(wm.hidden,[hidden]);XCTAssertNotNil(wm.target[2])
        wm.apply(f.area,1,wins,force:true);wm.configure([job]);wm.updateOverviewOwnership(active:true)
        XCTAssertTrue(sink.jobs.isEmpty);XCTAssertEqual(sink.cancelled,[1])
        active=false;wm.updateOverviewOwnership(active:false)
        XCTAssertTrue(wm.overviewRetilePending)
        wm.apply(f.area,1,wins.filter{$0.wid==1},force:true)
        XCTAssertEqual(wm.target[1],goal)
        XCTAssertTrue(eng.ch.ops.contains{$0["op"] == .string("geom") && $0["wid"] == .int(1)})
    }
    func testUnknownOwnerAndGrantedVisibleLookingSourcesAreNeverForgotten() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,wins)=try f.world(f.pair())
        sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:wins)
        for w in wins {sys.alphaM[w.wid]=1}
        sys.pidlevel[1]=(999,0);wm.overviewGrantedWindows={Set([2])}
        wm.updateOverviewOwnership(active:true)
        XCTAssertTrue(eng.ch.ops.isEmpty);XCTAssertFalse(wm.overviewRetilePending)
        XCTAssertEqual(wm.target.count,2)
    }
    func testPreEntryAckRequiresConsumedNativeSlotsIdleWorkerAndUnchangedBirth() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,wins)=try f.world(f.pair()),sink=Sink()
        wm.cfgSink=sink;sys.nativeSnapshot=Snapshot(space:1,stable:true,area:f.area,windows:wins)
        for w in wins{sys.alphaM[w.wid]=1}
        wm.overviewFrozen={true};wm.updateOverviewOwnership(active:true)
        eng.ch.nativeActiveCount=0;eng.ch.ringPending=true
        XCTAssertFalse(wm.overviewOwnershipConsumed)
        eng.ch.ringPending=false
        var slot=EngWin(wid:1,pos:(0,0),size:(10,10),a:wins[0].rect);slot.geo=1
        eng.ch.eng=[slot];XCTAssertFalse(wm.overviewOwnershipConsumed)
        slot.geo=0;slot.settling=true;eng.ch.eng=[slot];XCTAssertFalse(wm.overviewOwnershipConsumed)
        slot.settling=false;eng.ch.eng=[slot];sink.idle=false;XCTAssertFalse(wm.overviewOwnershipConsumed)
        sink.idle=true;XCTAssertTrue(wm.overviewOwnershipConsumed)
        sys.births[101]="recycled";XCTAssertFalse(wm.overviewOwnershipConsumed)
    }
}
