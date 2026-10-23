import Foundation
import XCTest
@testable import HyprCore

final class AXWindowClassificationTests:XCTestCase {
    private func awaitValue(_ cache:AXWindowClassification,pid:Int=10,wid:Int=1,birth:String="birth",value:Int,
                            file:StaticString=#filePath,line:UInt=#line) {
        let deadline=Date().addingTimeInterval(1)
        while Date()<deadline {
            if cache.read(pid:pid,wid:wid,birth:birth,load:{value})==value{return}
            Thread.sleep(forTimeInterval:0.001)
        }
        XCTFail("No completed classification",file:file,line:line)
    }
    func testStoppedClientDoesNotBlockCallerOrOtherClient() {
        let cache=AXWindowClassification(ttl:10),entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        XCTAssertEqual(cache.read(pid:10,wid:1,birth:"birth") {entered.signal();release.wait();return 1},-1)
        XCTAssertEqual(entered.wait(timeout:.now()+1),.success)
        let start=Date()
        for _ in 0..<100 {XCTAssertEqual(cache.read(pid:10,wid:1,birth:"birth",load:{XCTFail("Duplicate pending read");return 1}),-1)}
        XCTAssertLessThan(Date().timeIntervalSince(start),0.05)
        XCTAssertEqual(cache.read(pid:20,wid:2,birth:"other",load:{0}),-1)
        awaitValue(cache,pid:20,wid:2,birth:"other",value:0)
    }
    func testNewBirthCannotUseOldClassification() {
        let cache=AXWindowClassification(ttl:10)
        awaitValue(cache,value:1)
        XCTAssertEqual(cache.read(pid:10,wid:1,birth:"replacement",load:{0}),-1)
        awaitValue(cache,birth:"replacement",value:0)
    }
    func testNewIdentityDoesNotWaitForOldBlockedRequest() {
        let cache=AXWindowClassification(ttl:10),entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        _=cache.read(pid:10,wid:1,birth:"birth") {entered.signal();release.wait();return 1}
        XCTAssertEqual(entered.wait(timeout:.now()+1),.success)
        XCTAssertEqual(cache.read(pid:20,wid:1,birth:"replacement",load:{0}),-1)
        awaitValue(cache,pid:20,wid:1,birth:"replacement",value:0)
        release.signal();Thread.sleep(forTimeInterval:0.02)
        XCTAssertEqual(cache.read(pid:20,wid:1,birth:"replacement",load:{1}),0)
    }
    func testForgetDiscardsInFlightResponse() {
        let cache=AXWindowClassification(ttl:10),entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        _=cache.read(pid:10,wid:1,birth:"birth") {entered.signal();release.wait();return 1}
        XCTAssertEqual(entered.wait(timeout:.now()+1),.success)
        cache.remove(1)
        awaitValue(cache,value:0)
        release.signal();Thread.sleep(forTimeInterval:0.02)
        XCTAssertEqual(cache.read(pid:10,wid:1,birth:"birth",load:{1}),0)
    }
    func testPendingBudgetDoesNotTurnUnknownIntoPositiveEvidence() {
        let cache=AXWindowClassification(maxPending:1,ttl:10),entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        _=cache.read(pid:10,wid:1,birth:"birth") {entered.signal();release.wait();return 1}
        XCTAssertEqual(entered.wait(timeout:.now()+1),.success)
        XCTAssertEqual(cache.read(pid:20,wid:2,birth:"other",load:{XCTFail("Exceeded pending bound");return 1}),-1)
    }
}
