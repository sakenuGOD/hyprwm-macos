@testable import HyprCore
import XCTest

final class OverviewRetirementTests:XCTestCase {
    let nonce=String(repeating:"a",count:32),intent=String(repeating:"b",count:64)
    func snapshot()->JSON {
        let commit:JSON = .object([("nonce",.string(nonce)),("pool_generation",.int(91)),
            ("hidden_intent",.string(intent)),("inverse_park_observed",.bool(false))])
        return .object([("nonce",.string(nonce)),("controller_observed",.bool(true)),
            ("mode",.int(0)),("raw_mode",.int(0)),("overview_active",.bool(false)),
            ("pool_generation",.int(91)),("commits",.array([commit]))])
    }
    func testWithdrawnIntentCanRetireStuckNativePoolWithoutForgingSelectionACK() {
        let capturedPattern=snapshot()
        XCTAssertTrue(OverviewProtocol.hasCurrentPoolCommits(capturedPattern))
        XCTAssertTrue(OverviewRetirement.permitted(capturedPattern,nonce:nonce,liveIntents:[]))
    }
    func testCurrentOrUnknownLedgerAndActiveOverviewNeverRetire() {
        let s=snapshot()
        XCTAssertFalse(OverviewRetirement.permitted(s,nonce:nonce,liveIntents:nil))
        XCTAssertFalse(OverviewRetirement.permitted(s,nonce:nonce,liveIntents:[intent]))
        XCTAssertFalse(OverviewRetirement.permitted(s.setting("mode",.int(1)),nonce:nonce,liveIntents:[]))
        XCTAssertFalse(OverviewRetirement.permitted(s.setting("raw_mode",.int(2)),nonce:nonce,liveIntents:[]))
        XCTAssertFalse(OverviewRetirement.permitted(s.setting("nonce",.string("wrong")),nonce:nonce,liveIntents:[]))
    }
}
