@testable import HyprCore
import XCTest

final class LiveBufferMotionTests:XCTestCase {
    func testRetargetReplacesOutstandingGrowDespiteStaleMatchingNativeFrame() throws {
        final class Delayed:ConfigureSink {
            var jobs:[CfgJob]=[],cancelled=false
            func busy(_ wid:Int)->Bool {wid==1 && !cancelled}
            func cancel(_ wid:Int) {if wid==1 {cancelled=true}}
            func submit(_ batch:[CfgJob]) {jobs+=batch}
        }
        for retainedMotion in [false,true] {
            let f=ProductionPolicyTests(),(wm,_,eng,windows)=try f.world(f.pair()),sink=Delayed()
            wm.cfgSink=sink;eng.ch.terminalEnabled=true
            let half=wm.target[1]!,full=Rect(half.x,half.y,1176,half.h)
            wm.target[1]=full
            if retainedMotion {_=wm.prepareLiveBuffer(wm.job(101,1,full)!,actual:half,space:1,duration:0.4)}
            eng.ch.eng=[EngWin(wid:1,pos:(half.x,half.y),size:(half.w,half.h),a:half)]
            // The old AX grow may still complete after this stale server sample.
            wm.apply(f.area,1,windows)
            let replacements=sink.jobs.filter{$0.wid==1}
            XCTAssertEqual(replacements.count,1,"A cancelled grow still needs its final size replaced")
            XCTAssertEqual(replacements.first?.to,half)
            XCTAssertEqual(replacements.first?.sizeOnly,true,"The engine owns the terminal position")
            XCTAssertEqual(replacements.first?.forceWrite,true,"A matching stale read cannot certify cancellation")
        }
    }
    func testBothHalfDirectionsSendOneFinalSizeBeforeVisualMotionAndNeverLateAXFrame() throws {
        for terminal in [false,true] {for right in [false,true] {
            let f=ProductionPolicyTests(),tree=right ? Node(split:"v",ratio:0.5,a:Node(leaf:2),b:Node(leaf:1)):f.pair()
            let (wm,sys,eng,original)=try f.world(tree),sink=SnapshotHandoffTests.Recorder()
            wm.cfgSink=sink;eng.ch.terminalEnabled=terminal;wm.options.snapshotFrames=false;wm.options.nativeFrames=false
            var windows=original
            let goal=wm.target[1]!,full=Rect(12,goal.y,1176,goal.h)
            let index=windows.firstIndex{$0.wid==1}!;windows[index].x=full.x;windows[index].y=full.y;windows[index].w=full.w;windows[index].h=full.h;sys.bounds[1]=full
            var slot=EngWin(wid:1,pos:(full.x,full.y),size:(full.w,full.h),a:full);slot.geo=1;eng.ch.eng=[slot]
            wm.apply(f.area,1,windows,force:true)
            let motion=eng.ch.ops.first{$0["op"] == .string("geom") && $0["wid"] == .int(1)}!
            XCTAssertEqual(motion["stretch"],.bool(false));XCTAssertEqual(motion["move"],.bool(false))
            XCTAssertEqual(motion["move_end"],terminal ? .bool(true):nil)
            XCTAssertTrue(eng.ch.snapshotRequests.isEmpty);XCTAssertTrue(eng.ch.nativeRequests.isEmpty)
            XCTAssertEqual(sink.jobs.filter{$0.wid==1}.map(\.to),[goal]);XCTAssertTrue(sink.jobs[0].sizeOnly)
            // Logical resize is submitted while B is still full.
            slot.aw=goal.w;slot.ah=goal.h
            slot.pos=(goal.x,goal.y);slot.size=(goal.w,goal.h);slot.settling=true;slot.geo=terminal ? 4:1;eng.ch.eng=[slot]
            eng.ch.nativeTick=8;wm.pollLiveBufferShrinks();eng.ch.nativeTick=9;wm.pollLiveBufferShrinks()
            XCTAssertEqual(sink.jobs.filter{$0.wid==1}.count,1)
            let warps=eng.ch.ops.filter{$0["op"] == .string("warp") && $0["wid"] == .int(1)}
            XCTAssertEqual(warps.count,right && !terminal ? 1:0)
            if right && terminal {
                XCTAssertNotNil(wm.liveBufferShrinks[1])
                slot.ax=goal.x;slot.ay=goal.y;eng.ch.eng=[slot];wm.pollLiveBufferShrinks()
            }
            XCTAssertNil(wm.liveBufferShrinks[1])
        }}
    }
    func testMixedAxesUseExactFinalSizeAtBeginningWithoutGrowingIntermediateBuffer() throws {
        let f=ProductionPolicyTests(),(wm,_,_,_)=try f.world(Node(leaf:1))
        let actual=Rect(12,41,800,900),goal=Rect(12,41,1000,400),job=wm.job(101,1,goal)!
        let early=wm.prepareLiveBuffer(job,actual:actual,space:1,duration:0.4)
        XCTAssertEqual(early?.to,goal);XCTAssertEqual(early?.sizeOnly,false)
        XCTAssertTrue(wm.liveBufferShrinks[1]?.requiresFinalSize == true)
    }
    func testRecycledOrSupersededActorCannotReceiveCompatibilityTerminalWarp() throws {
        for recycled in [false,true] {
            let f=ProductionPolicyTests(),(wm,sys,eng,_)=try f.world(Node(leaf:1)),sink=SnapshotHandoffTests.Recorder()
            wm.cfgSink=sink;let goal=Rect(605,41,600,400),job=wm.job(101,1,goal)!
            wm.target[1]=goal;_=wm.prepareLiveBuffer(job,actual:Rect(12,41,1200,900),space:1,duration:0.4)
            if recycled {sys.births[101]="recycled"} else {wm.target[1]=Rect(12,41,900,600)}
            var slot=EngWin(wid:1,pos:(goal.x,goal.y),size:(goal.w,goal.h),a:goal);slot.geo=1;eng.ch.eng=[slot]
            wm.pollLiveBufferShrinks();XCTAssertTrue(sink.jobs.isEmpty);XCTAssertTrue(eng.ch.ops.isEmpty);XCTAssertNil(wm.liveBufferShrinks[1])
        }
    }
    func testPureTranslationNeverResizesAndGrowthUsesOnlyFinalLogicalSize() throws {
        let f=ProductionPolicyTests(),(wm,_,_,_)=try f.world(Node(leaf:1))
        let move=wm.job(101,1,Rect(605,38,583,850))!
        XCTAssertNil(wm.prepareLiveBuffer(move,actual:Rect(12,38,583,850),space:1,duration:0.4))
        XCTAssertEqual(wm.liveBufferShrinks[1]?.job.to,move.to)
        let grow=wm.job(101,1,Rect(12,38,1176,850))!
        let early=wm.prepareLiveBuffer(grow,actual:Rect(605,38,583,850),space:1,duration:0.4)
        XCTAssertEqual(early?.to,grow.to);XCTAssertEqual(early?.sizeOnly,false)
    }
    func testGrowingRightParentKeepsOriginalVisualFrameAndWaitsForAcceptedFinalSize() throws {
        let f=ProductionPolicyTests(),(wm,_,eng,original)=try f.world(Node(leaf:1)),sink=SnapshotHandoffTests.Recorder()
        wm.cfgSink=sink;eng.ch.terminalEnabled=true
        let goal=wm.target[1]!,right=Rect(605,goal.y,583,goal.h)
        var parent=original[0];parent.x=right.x;parent.w=right.w
        var slot=EngWin(wid:1,pos:(right.x,right.y),size:(right.w,right.h),a:right);slot.geo=1;eng.ch.eng=[slot]
        wm.apply(f.area,1,[parent],force:true)
        XCTAssertEqual(sink.jobs.count,1);XCTAssertFalse(sink.jobs[0].sizeOnly);XCTAssertEqual(sink.jobs[0].to,goal)
        let motion=eng.ch.ops.first{$0["wid"] == .int(1) && $0["op"] == .string("geom")}!
        XCTAssertEqual(motion["frm"],right.json);XCTAssertEqual(motion["move"],.bool(true),"Growth must park the physical origin in the engine batch before AX changes it");XCTAssertNil(motion["move_end"])
        slot.pos=(goal.x,goal.y);slot.size=(goal.w,goal.h);slot.ax=goal.x;slot.ay=goal.y;slot.geo=1;eng.ch.eng=[slot]
        wm.pollLiveBufferShrinks();XCTAssertNotNil(wm.liveBufferShrinks[1]) // Origin alone cannot certify a clamped growth.
        slot.aw=goal.w;slot.ah=goal.h;eng.ch.eng=[slot];wm.pollLiveBufferShrinks()
        XCTAssertNil(wm.liveBufferShrinks[1]);XCTAssertEqual(sink.jobs.count,1)
    }
}
