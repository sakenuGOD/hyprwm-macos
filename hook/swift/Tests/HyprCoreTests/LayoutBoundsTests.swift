@testable import HyprCore
import XCTest

final class LayoutBoundsTests:XCTestCase {
    func testExtremeRatioCannotGrowSmallTileAcrossItsSiblingOrOutsideScreen() throws {
        for axis in ["v","h"] {for ratio in [0.02,0.98] {
            let f=ProductionPolicyTests(),tree=Node(split:axis,ratio:ratio,a:Node(leaf:1),b:Node(leaf:2))
            tree.manualRatio=true
            let (wm,_,_,_)=try f.world(tree);wm.tile.minimumPolicy="ratio"
            let rects=wm.layout(f.area,wm.sp(1)),a=try XCTUnwrap(rects[1]),b=try XCTUnwrap(rects[2])
            for r in [a,b] {
                XCTAssertGreaterThanOrEqual(r.x,f.area.x);XCTAssertGreaterThanOrEqual(r.y,f.area.y)
                XCTAssertLessThanOrEqual(r.x+r.w,f.area.x+f.area.w);XCTAssertLessThanOrEqual(r.y+r.h,f.area.y+f.area.h)
            }
            if axis=="v" {XCTAssertLessThanOrEqual(a.x+a.w,b.x)}
            else {XCTAssertLessThanOrEqual(a.y+a.h,b.y)}
        }}
    }
    func testAXConfirmedWindowMinimumConstrainsCrowdedRatioWithoutUsingStaleOwnerCache() throws {
        let f=ProductionPolicyTests()
        let left=Node(split:"h",ratio:0.5,a:Node(leaf:1),b:Node(split:"v",ratio:0.5,a:Node(leaf:2),b:Node(leaf:3)))
        let (wm,sys,_,_)=try f.world(Node(split:"v",ratio:0.5,a:left,b:Node(leaf:4)))
        wm.tile.minimumPolicy="ratio"
        wm.mins["Fixture"]=[.double(1400),.double(900)]
        let target=try XCTUnwrap(wm.layout(f.area,wm.sp(1))[3]);wm.target[3]=target
        var result=CfgResult(wid:3,owner:"Fixture",to:target,
                             got:Rect(target.x,target.y,459,target.h),e:0,
                             pre:Rect(target.x,target.y,720,600))
        result.pid=103;result.birth="birth-3";result.isCurrent={true};wm.cfgQ=[result]
        XCTAssertTrue(wm.configured(),"A newly verified hard minimum must reflow even if an old owner cache is larger")
        let rects=wm.layout(f.area,wm.sp(1))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(rects[3]).w,459)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(rects[2]).w,200)
        XCTAssertLessThan(try XCTUnwrap(rects[4]).w,1400,"An unrelated window must not inherit the cached or verified minimum")
        for a in rects.values {
            XCTAssertGreaterThanOrEqual(a.x,f.area.x);XCTAssertGreaterThanOrEqual(a.y,f.area.y)
            XCTAssertLessThanOrEqual(a.x+a.w,f.area.x+f.area.w);XCTAssertLessThanOrEqual(a.y+a.h,f.area.y+f.area.h)
            for b in rects.values where a != b {
                XCTAssertTrue(a.x+a.w<=b.x || b.x+b.w<=a.x || a.y+a.h<=b.y || b.y+b.h<=a.y)
            }
        }
        sys.births[103]="replacement-process"
        XCTAssertLessThan(try XCTUnwrap(wm.layout(f.area,wm.sp(1))[3]).w,459,
                          "A recycled window identity must not inherit a previous AX floor")
    }
    func testCrowdedRatioLayoutKeepsTargetsDisjointWhenClientsMustBeClipped() throws {
        let f=ProductionPolicyTests()
        let tree=Node(split:"h",ratio:0.5,a:Node(split:"h",ratio:0.5,a:Node(leaf:1),b:Node(leaf:2)),b:Node(leaf:3))
        let (wm,_,_,_)=try f.world(tree);wm.tile.minimumPolicy="ratio"
        let area=Rect(0,30,500,300),rects=wm.layout(area,wm.sp(1))
        let rows=rects.values.sorted{$0.y<$1.y}
        XCTAssertEqual(rows.count,3)
        for (a,b) in zip(rows,rows.dropFirst()) {XCTAssertLessThanOrEqual(a.y+a.h,b.y)}
        for r in rows {XCTAssertGreaterThan(r.h,0);XCTAssertLessThanOrEqual(r.y+r.h,area.y+area.h)}
    }
}
