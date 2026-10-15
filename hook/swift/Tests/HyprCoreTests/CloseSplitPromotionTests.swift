@testable import HyprCore
import XCTest

final class CloseSplitPromotionTests:XCTestCase {
    func testProductionExplicitHidePromotesAutomaticPairImmediatelyAndPreservesHideIntent() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(three(0.65))
        sys.births[103]="103:40:50";sys.front=103;sys.contexts[103]=(3,0)
        XCTAssertEqual(wm.hide(f.area,1,windows,3),"скрыто 3")
        XCTAssertEqual(wm.sp(1).tree?.split,"v");XCTAssertEqual(wm.sp(1).tree?.ratio,0.65)
        let rects=wm.layout(f.area,wm.sp(1)),a=try XCTUnwrap(rects[1]),b=try XCTUnwrap(rects[2])
        XCTAssertEqual(a.y,b.y);XCTAssertEqual(a.h,b.h);XCTAssertLessThan(a.x+a.w,b.x)
        XCTAssertEqual(Dwindle.leaves(wm.sp(1).tree).compactMap(\.wid),[1,2])
        XCTAssertEqual(wm.hidden.map(\.wid),[3]);XCTAssertEqual(wm.hidden.first?.extra["tiled"],.bool(true))
        XCTAssertTrue(eng.ch.ops.contains{$0["op"] == .string("alpha") && $0["wid"] == .int(3) && $0["a"] == .double(0)})
        XCTAssertEqual(sys.t,1000,"promotion occurs in the explicit hide publication, before a later census")
    }
    func testProductionExplicitHidePreservesManualAxisOrDividerRatio() throws {
        for manualAxis in [true,false] {
            let root=three(0.7);root.a?.manualSplit=manualAxis;root.a?.manualRatio = !manualAxis
            let restored=try XCTUnwrap(Node.from(root.json))
            let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(restored)
            sys.births[103]="103:40:50";sys.front=103;sys.contexts[103]=(3,0)
            XCTAssertEqual(wm.hide(f.area,1,windows,3),"скрыто 3")
            XCTAssertEqual(wm.sp(1).tree?.split,"h");XCTAssertEqual(wm.sp(1).tree?.ratio,0.7)
            XCTAssertEqual(wm.sp(1).tree?.manualSplit,manualAxis);XCTAssertEqual(wm.sp(1).tree?.manualRatio,!manualAxis)
        }
    }
    func three(_ ratio:Double=0.5)->Node {
        Node(split:"v",ratio:0.5,a:Node(split:"h",ratio:ratio,a:Node(leaf:1),b:Node(leaf:2)),b:Node(leaf:3))
    }
    func tile()->Dwindle {Dwindle(gapsIn:5,gapsOut:Gaps(top:8,right:12,bottom:12,left:12))}
    func testProductionCloseOfRightThirdPromotesPairToLandscapeColumnsImmediately() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(three())
        sys.contexts[103]=(nil,32);sys.deferredClose=true
        _=wm.closeAnim(f.area,1,windows,try XCTUnwrap(windows.first{$0.wid==3}))
        let remaining=windows.filter{$0.wid != 3}
        wm.observeCloseRequests(remaining,1)
        let result=wm.sync(f.area,1,remaining)
        XCTAssertTrue(result.0);XCTAssertTrue(result.1.isEmpty)
        XCTAssertEqual(wm.sp(1).tree?.split,"v")
        let rects=wm.layout(f.area,wm.sp(1)),a=try XCTUnwrap(rects[1]),b=try XCTUnwrap(rects[2])
        XCTAssertEqual(a.y,b.y);XCTAssertEqual(a.h,b.h);XCTAssertLessThan(a.x+a.w,b.x)
        XCTAssertEqual(sys.t,1000,"reorientation belongs to the same accepted close census")
    }
    func testAutomaticPromotionUsesNewBoxAspectAndKeepsRatioAndLeafOrder() throws {
        let t=tile(),tree=t.removeReorientingPromoted(three(0.65),3,in:Rect(0,30,1600,900))
        XCTAssertEqual(tree?.split,"v");XCTAssertEqual(tree?.ratio,0.65)
        XCTAssertEqual(Dwindle.leaves(tree).compactMap(\.wid),[1,2])
        let tall=Node(split:"h",ratio:0.5,a:Node(split:"v",ratio:0.6,a:Node(leaf:1),b:Node(leaf:2)),b:Node(leaf:3))
        let portrait=t.removeReorientingPromoted(tall,3,in:Rect(0,0,800,1400))
        XCTAssertEqual(portrait?.split,"h");XCTAssertEqual(portrait?.ratio,0.6)
    }
    func testExplicitAxisAndManualSharedDividerSurvivePromotionAndSavedState() throws {
        for manualAxis in [true,false] {
            let t=tile(),root=three(0.7),pair=root.a!
            pair.manualSplit=manualAxis;pair.manualRatio = !manualAxis
            let restored=try XCTUnwrap(Node.from(root.json))
            let result=t.removeReorientingPromoted(restored,3,in:Rect(0,0,1600,900))
            XCTAssertEqual(result?.split,"h");XCTAssertEqual(result?.ratio,0.7)
            XCTAssertEqual(result?.manualSplit,manualAxis);XCTAssertEqual(result?.manualRatio,!manualAxis)
        }
    }
    func testLegacyRemovalAndUnexpandedSiblingRemainUnchanged() {
        let legacy=Dwindle.remove(three(),3)
        XCTAssertEqual(legacy?.split,"h")
        let unchanged=Node(split:"h",ratio:0.4,a:Node(leaf:4),b:Node(leaf:5))
        let root=Node(split:"v",ratio:0.5,a:three(),b:unchanged),before=unchanged.json
        _=tile().removeReorientingPromoted(root,3,in:Rect(0,0,1600,900))
        XCTAssertEqual(unchanged.json,before)
    }
    func testPreselectionRemainsInsertionDirectionWhileToggleLocksAxis() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(Node(leaf:1)),s=wm.sp(1)
        s.focus=1;s.presel="up";s.tree=wm.insert(s,2,1,f.area)
        XCTAssertEqual(s.tree?.split,"h");XCTAssertEqual(s.tree?.manualSplit,false)
        sys.front=101;sys.contexts[101]=(1,0)
        _=try wm.command("togglesplit",f.area,1,windows)
        XCTAssertEqual(s.tree?.split,"v");XCTAssertEqual(s.tree?.manualSplit,true)
    }
}
