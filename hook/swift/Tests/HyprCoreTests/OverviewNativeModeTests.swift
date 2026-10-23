@testable import HyprCore
import XCTest

final class OverviewNativeModeTests:XCTestCase {
    func testKnownNativeModeFreezesWithoutBindingAndExitUnknownRelease() {
        XCTAssertTrue(OverviewNativeMode.active(1))
        XCTAssertTrue(OverviewNativeMode.active(2))
        XCTAssertFalse(OverviewNativeMode.active(0))
        XCTAssertFalse(OverviewNativeMode.active(UInt64.max))
    }
    func testAuthenticatedActiveSurvivesRawZeroBetweenReadsAndExpiresMissingEvidence() {
        var fence=OverviewActivityFence()
        let active=JSON.object([("controller_observed",.bool(true)),("mode",.int(1)),("raw_mode",.int(1)),("overview_active",.bool(true))])
        fence.observe(active,time:10)
        for time in [10.025,10.05,10.1,10.15,10.29] {XCTAssertTrue(fence.active(raw:0,time:time))}
        XCTAssertFalse(fence.active(raw:0,time:10.301))
        fence.observe(active,time:10.15);XCTAssertTrue(fence.active(raw:0,time:10.4))
        let exited=active.setting("mode",.int(0)).setting("raw_mode",.int(0)).setting("overview_active",.bool(false))
        fence.observe(exited,time:10.41);XCTAssertFalse(fence.active(raw:0,time:10.411))
        fence.observe(active.setting("controller_observed",.bool(false)),time:10.42)
        XCTAssertFalse(fence.active(raw:0,time:10.43));XCTAssertTrue(fence.active(raw:1,time:100))
        fence.observe(active.setting("mode",.int(0)).setting("raw_mode",.int(0)),time:20)
        XCTAssertTrue(fence.active(raw:0,time:20.025)) // Authenticated native pending-entry scope.
        fence.reset();XCTAssertFalse(fence.active(raw:0,time:20.05))
    }

}
