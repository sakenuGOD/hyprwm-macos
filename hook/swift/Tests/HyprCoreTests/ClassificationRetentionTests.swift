@testable import HyprCore
import XCTest

final class ClassificationRetentionTests: XCTestCase {
    let policy = ProductionPolicyTests()

    func testColdClassificationKeepsExistingTreeAndTargetsUntilAnswer() throws {
        for answer in [0, 1] {
            let (wm, sys, eng, wins) = try policy.world(policy.pair())
            let before = wm.sp(1).tree!.json, targets = wm.target
            wm.sp(1).focus = 1
            sys.front = 101; sys.contexts[101] = (1, 0)
            sys.tileableM[1] = -1
            eng.ch.ops = []
            for _ in 0..<4 {
                let (changed, opened) = wm.sync(policy.area, 1, wins)
                XCTAssertFalse(changed)
                XCTAssertTrue(opened.isEmpty)
                XCTAssertEqual(wm.sp(1).tree?.json, before)
                XCTAssertEqual(wm.target, targets)
                XCTAssertEqual(wm.sp(1).focus, 1)
                sys.t += 0.3
            }
            XCTAssertFalse(wm.tileable(wins.first { $0.wid == 1 }!), "Pending retention is not eligibility for focus or admission")
            XCTAssertFalse(eng.ch.ops.contains { $0["op"] == .string("geom") })
            sys.tileableM[1] = answer
            let (changed, opened) = wm.sync(policy.area, 1, wins)
            XCTAssertEqual(changed, answer == 0)
            XCTAssertTrue(opened.isEmpty)
            XCTAssertEqual(wm.sp(1).tree?.contains(1), answer == 1)
        }
    }

    func testPreviouslyEligibleWindowSurvivesLongUnknownBackoff() throws {
        let (wm,sys,eng,wins)=try policy.world(policy.pair())
        wm.sp(1).focus=1
        _=wm.sync(policy.area,1,wins)
        let before=wm.sp(1).tree?.json,targets=wm.target
        sys.tileableM[1] = -1
        eng.ch.ops=[]
        var churn:[Int]=[]
        for step in 0..<240 {
            sys.t+=0.0167
            let (changed,opened)=wm.sync(policy.area,1,wins)
            if changed || !opened.isEmpty || wm.sp(1).tree?.json != before || wm.target != targets {churn.append(step)}
        }
        XCTAssertTrue(churn.isEmpty,"Unknown/backoff must not remove an identity-valid existing tile; first churn step: \(String(describing:churn.first))")
        XCTAssertEqual(wm.sp(1).focus,1)
        XCTAssertFalse(eng.ch.ops.contains{$0["op"] == .string("geom")})
    }

    func testRestoredTreeWithoutRuntimeMetadataSurvivesColdCache() throws {
        let (wm, sys, _, wins) = try policy.world(policy.pair())
        wm.pids = [:]; wm.target = [:]; wm.owner = [:]
        sys.tileableM[1] = -1; sys.tileableM[2] = -1
        let before = wm.sp(1).tree!.json
        let (changed, opened) = wm.sync(policy.area, 1, wins)
        XCTAssertFalse(changed)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(wm.sp(1).tree?.json, before)
    }

    func testUnknownNewWindowWaitsForPositiveClassification() throws {
        let (wm, sys, _, wins) = try policy.world(Node(leaf: 2))
        let fresh = WinInfo(wid: 1, pid: 101, owner: "Fixture", x: 50, y: 70, w: 600, h: 400, on: true, space: 1)
        sys.pidlevel[1] = (101, 0); sys.births[101] = "birth-1"
        sys.tileableM[1] = -1
        XCTAssertFalse(wm.sync(policy.area, 1, wins + [fresh]).0)
        XCTAssertFalse(wm.sp(1).tree?.contains(1) == true)
        sys.t += 0.3; sys.tileableM[1] = 1
        XCTAssertEqual(wm.sync(policy.area, 1, wins + [fresh]).1, [1])
    }

    func testConfirmedNegativeAndExplicitFloatDoNotUseRetention() throws {
        for floated in [false, true] {
            let (wm, sys, _, wins) = try policy.world(policy.pair())
            sys.tileableM[1] = floated ? -1 : 0
            if floated { wm.floating.insert(1) }
            XCTAssertTrue(wm.sync(policy.area, 1, wins).0)
            XCTAssertFalse(wm.sp(1).tree?.contains(1) == true)
        }
    }

    func testConfirmedRejectionDoesNotGainRetentionDuringUnknownRefresh() throws {
        let (wm,sys,_,wins)=try policy.world(policy.pair())
        sys.tileableM[1]=0
        XCTAssertEqual(wm.wmInfo(101,1)?.type,"other")
        sys.tileableM[1] = -1;sys.t+=0.3
        XCTAssertTrue(wm.sync(policy.area,1,wins).0)
        XCTAssertFalse(wm.sp(1).tree?.contains(1)==true)
        XCTAssertFalse(wm.tileable(wins.first{$0.wid==1}!))
    }

    func testMissingWindowStillLeavesAfterNativeCensusGrace() throws {
        let (wm, sys, _, wins) = try policy.world(policy.pair())
        sys.tileableM[1] = -1
        _ = wm.sync(policy.area, 1, wins)
        let remaining = wins.filter { $0.wid != 1 }
        _ = wm.sync(policy.area, 1, remaining)
        sys.t += 0.1
        _ = wm.sync(policy.area, 1, remaining)
        XCTAssertFalse(wm.sp(1).tree?.contains(1) == true)
        XCTAssertNil(wm.target[1])
    }

    func testRecycledProcessBirthCannotInheritCachedEligibilityOrRetention() throws {
        for wasClassified in [false, true] {
            let (wm, sys, _, wins) = try policy.world(policy.pair())
            sys.tileableM[1] = wasClassified ? 1 : -1
            _ = wm.sync(policy.area, 1, wins)
            sys.births[101] = "replacement-birth"
            sys.tileableM[1] = -1
            sys.t += 0.01
            _ = wm.sync(policy.area, 1, wins)
            XCTAssertFalse(wm.sp(1).tree?.contains(1) == true)
            XCTAssertFalse(wm.tileable(wins.first { $0.wid == 1 }!))
        }
    }

    func testUnknownDifferentOwnerCannotKeepOldWindowID() throws {
        let (wm, sys, _, wins) = try policy.world(policy.pair())
        _ = wm.sync(policy.area, 1, wins)
        var replacement = wins
        let index = replacement.firstIndex { $0.wid == 1 }!
        replacement[index].pid = 201
        sys.pidlevel[1] = (201, 0); sys.births[201] = "replacement"
        sys.tileableM[1] = -1
        sys.t += 0.3
        _ = wm.sync(policy.area, 1, replacement)
        XCTAssertFalse(wm.sp(1).tree?.contains(1) == true)
    }

    func testUnknownWithoutNativeOwnerOrBirthCannotKeepRestoredLeaf() throws {
        for missingBirth in [false, true] {
            let (wm, sys, _, wins) = try policy.world(policy.pair())
            sys.tileableM[1] = -1
            if missingBirth { sys.births[101] = nil } else { sys.pidlevel[1] = nil }
            _ = wm.sync(policy.area, 1, wins)
            XCTAssertFalse(wm.sp(1).tree?.contains(1) == true)
        }
    }
}
