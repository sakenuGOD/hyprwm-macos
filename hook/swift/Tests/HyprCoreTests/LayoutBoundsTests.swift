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
