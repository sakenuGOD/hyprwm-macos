@testable import HyprCore
import XCTest

final class OpeningPresentationTests:XCTestCase {
    func testAlreadyPresentedWindowNeverDisappearsOrFliesFromItsInitialFrame() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,original)=try f.world(f.pair())
        let sink=SnapshotHandoffTests.Recorder();wm.cfgSink=sink;eng.ch.terminalEnabled=true
        var wins=original
        let index=wins.firstIndex{$0.wid==2}!,initial=Rect(100,150,800,650)
        wins[index].x=initial.x;wins[index].y=initial.y;wins[index].w=initial.w;wins[index].h=initial.h
        sys.bounds[2]=initial;sys.alphaM[2]=1
        wm.target[2]=nil
        wm.apply(f.area,1,wins,opening:[2])
        let opacity=eng.ch.ops.filter{$0["op"] == .string("alpha") && $0["wid"] == .int(2)}
        XCTAssertFalse(opacity.contains{$0["a"] == .double(0) || $0["frm"] == .double(0)},"An already shown window must not blink off before tiling")
        let motion=try XCTUnwrap(eng.ch.ops.first{$0["op"] == .string("warp") && $0["wid"] == .int(2)})
        XCTAssertEqual(motion["frm"],wm.target[2]?.json)
        XCTAssertEqual(motion["move"],.bool(true))
        XCTAssertEqual(motion["stretch"],.bool(false))
        XCTAssertEqual(motion["dpos"],.double(0))
        XCTAssertEqual(sink.jobs.filter{$0.wid==2}.count,1)
        XCTAssertTrue(eng.ch.snapshotRequests.isEmpty)
    }

    func testConcealedOpeningWaitsForFinalSizeAndStartsFadeInSameBatch() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,original)=try f.world(f.pair())
        let sink=SnapshotHandoffTests.Recorder();wm.cfgSink=sink
        var wins=original;let index=wins.firstIndex{$0.wid==2}!
        wins[index].alpha=0;sys.alphaM[2]=0;wm.target[2]=nil
        wm.apply(f.area,1,wins,opening:[2])
        let motion=try XCTUnwrap(eng.ch.ops.first{$0["op"] == .string("geom") && $0["wid"] == .int(2)})
        XCTAssertEqual(motion["wait"],.bool(true))
        XCTAssertEqual(motion["hold"],.bool(true))
        XCTAssertEqual(eng.ch.ops.filter{$0["op"] == .string("commit")}.count,1)
        XCTAssertEqual(sink.jobs.filter{$0.wid==2}.count,1)
    }
}
