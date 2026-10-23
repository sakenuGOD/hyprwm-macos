@testable import HyprCore
import XCTest

final class ToolbarSelectionTests: XCTestCase {
    func testTilingOrderPublishesInactiveSpaceAndIgnoresFocusAndCensusOrder() throws {
        let f = ProductionPolicyTests(), (wm, _, _, original) = try f.world(f.pair())
        var windows = original
        windows[1].space = 2; windows[1].on = false
        wm.sp(1).tree = Node.from(.object([("wid", .int(1))]))
        wm.sp(2).tree = Node.from(.object([("wid", .int(2))]))
        // A restored inactive tree has not passed through current-Space sync.
        wm.pids[2] = nil
        let order = wm.toolbarTilingOrder(windows)
        XCTAssertEqual(order["1"]?.array?.first?["wid"]?.int, 1)
        XCTAssertEqual(order["2"]?.array?.first?["wid"]?.int, 2)
        wm.sp(1).focus = 2; wm.focusHistory = [2, 1]
        XCTAssertEqual(wm.toolbarTilingOrder(Array(windows.reversed())), order)
    }

    func testTilingOrderRejectsReusedBirthAndForeignOwner() throws {
        let f = ProductionPolicyTests(), (wm, sys, _, windows) = try f.world(f.pair())
        wm.verifiedMinima[1] = (pid: 101, birth: "prior-process", width: 100, height: 100)
        sys.pidlevel[2] = (999, 0)
        XCTAssertNil(wm.toolbarTilingOrder(windows)["1"])
    }

    func testInactiveSpaceUsesPersistedSelectionWithoutActivation() throws {
        let f = ProductionPolicyTests(), (wm, sys, _, original) = try f.world(f.pair())
        var windows = original
        sys.activeSpaceID = 1
        windows[1].space = 2; windows[1].on = false
        wm.sp(1).focus = 1; wm.sp(2).focus = 2
        wm.sp(2).toolbarSelection = ToolbarWindowSelection(wid: 2, pid: 102, birth: "birth-2", source: "wm-space-selection")
        wm.spaces["2"] = SpaceState.from(wm.sp(2).json)
        let result = wm.toolbarSelectedWindows(windows)
        XCTAssertEqual(result["2"]?["wid"]?.int, 2)
        XCTAssertEqual(result["2"]?["source"]?.string, "wm-space-selection")
        XCTAssertEqual(sys.activeSpaceID, 1)
    }

    func testNativeHistoryWinsOverSelectedTileAndHiddenHistoryIsExcluded() throws {
        let f = ProductionPolicyTests(), (wm, _, _, windows) = try f.world(f.pair())
        wm.sp(1).focus = 1
        wm.verifiedMinima[1] = (pid: 101, birth: "birth-1", width: 100, height: 100)
        wm.focusHistory = [2]; wm.nativeFocusedIdentities[2] = (102, "birth-2", 1)
        XCTAssertEqual(wm.toolbarSelectedWindows(windows)["1"]?["wid"]?.int, 2)
        XCTAssertEqual(wm.toolbarSelectedWindows(windows)["1"]?["source"]?.string, "native-focus-history")
        wm.hidden = [Hidden(wid: 2, pid: 102, owner: "Fixture", space: 1, rect: windows[1].rect.arr)]
        XCTAssertEqual(wm.toolbarSelectedWindows(windows)["1"]?["wid"]?.int, 1)
    }

    func testMissingReusedForeignMovedAndClosingWindowsAreNotProjected() throws {
        for failure in ["missing", "birth", "owner", "space", "closing"] {
            let f = ProductionPolicyTests(), (wm, sys, _, original) = try f.world(f.pair())
            var windows = original
            wm.sp(1).focus = 2; wm.focusHistory = [2]
            wm.nativeFocusedIdentities[2] = (102, "birth-2", 1)
            switch failure {
            case "missing": windows.removeAll { $0.wid == 2 }
            case "birth": sys.births[102] = "reused"
            case "owner": sys.pidlevel[2] = (999, 0)
            case "space": windows[1].space = 2
            default: wm.closing.insert(2)
            }
            XCTAssertNil(wm.toolbarSelectedWindows(windows)["1"], failure)
        }
    }

    func testCensusOrderDoesNotInventSelection() throws {
        let f = ProductionPolicyTests(), (wm, _, _, windows) = try f.world(f.pair())
        wm.sp(1).focus = nil
        XCTAssertNil(wm.toolbarSelectedWindows(windows)["1"])
    }

    func testBarePersistedWIDRequiresCurrentIdentityBoundAdmission() throws {
        let f = ProductionPolicyTests(), (wm, _, _, windows) = try f.world(f.pair())
        wm.sp(1).focus = 2
        XCTAssertNil(wm.toolbarSelectedWindows(windows)["1"])
        wm.verifiedMinima[2] = (pid: 102, birth: "old-process", width: 100, height: 100)
        XCTAssertNil(wm.toolbarSelectedWindows(windows)["1"])
        wm.verifiedMinima[2] = (pid: 102, birth: "birth-2", width: 100, height: 100)
        XCTAssertEqual(wm.toolbarSelectedWindows(windows)["1"]?["wid"]?.int, 2)
    }

    func testPersistedSelectionDoesNotAdoptReusedProcessWithoutHistory() throws {
        let f = ProductionPolicyTests(), (wm, sys, _, windows) = try f.world(f.pair())
        wm.sp(1).focus = 2
        wm.sp(1).toolbarSelection = ToolbarWindowSelection(wid: 2, pid: 102, birth: "birth-2", source: "native-focus-history")
        sys.births[102] = "reused-process"
        XCTAssertNil(wm.toolbarSelectedWindows(windows)["1"])
    }

    func testPersistedIdentityRejectsFractionalNonfiniteAndOutOfRangeNumbers() {
        let valid = ToolbarWindowSelection(wid: 2, pid: 102, birth: "birth-2", source: "native-focus-history").json
        for bad: JSON in [.double(1.5), .double(.infinity), .double(.nan), .bool(true), .int(0), .int(Int.max)] {
            XCTAssertNil(ToolbarWindowSelection.from(valid.setting("wid", bad)))
            XCTAssertNil(ToolbarWindowSelection.from(valid.setting("pid", bad)))
        }
    }
}
