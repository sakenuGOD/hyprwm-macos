@testable import HyprCore
import Foundation
import XCTest

/// Source3 Dock replies from Root OWN13, with session nonce/image UUID redacted.
/// Handler codes and typed envelopes are captured native output, not generated fixtures.
/// No sockets, GUI or runtime writes.
final class OverviewNativeResultTests:XCTestCase {
    func fixture(_ operation:String) throws -> JSON {
        let directory=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        var captured=try JSON.parse(Data(contentsOf:directory.appendingPathComponent("overview10-source3-\(operation).json")))
        if var generation=captured["generation"]?.array {
            generation[1] = .int(Int(getuid()));captured=captured.setting("generation",.array(generation))
            if let info=captured["service_info"],let endpoint=info["endpoint"]?.string {
                captured=captured.setting("service_info",info.setting("generation",.array(generation)).setting("endpoint",.string(endpoint.replacingOccurrences(of:"-501-",with:"-\(getuid())-"))))
            }
        }
        return captured
    }
    func testActualNativeReadAndMutationRepliesPassAuthenticatedOperationContract() throws {
        let hello=try fixture("hello"),info=hello["service_info"]!,generation=hello["generation"]!
        let binding=try OverviewBinding(.object([("schema",.int(1)),("actor",.object([("pid",generation.array![0]),("birth",generation),("path",.string("/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"))])),("nonce",hello["nonce"]!),
            ("endpoint",info["endpoint"]!),("image",.object([("path",info["image_path"]!),("uuid",info["image_uuid"]!)]))]))
        for operation in ["snapshot","configure","disable"] {
            let native=try fixture(operation)
            let validated=try binding.response(native,sequence:native["request_seq"]!.int!,operation:operation)
            XCTAssertTrue(OverviewProtocol.succeeded(validated,operation:operation))
            XCTAssertFalse(OverviewProtocol.succeeded(validated,operation:operation=="snapshot" ? "configure":"snapshot"))
            XCTAssertThrowsError(try binding.response(native.setting("main_evaluated",.bool(false)),sequence:native["request_seq"]!.int!,operation:operation))
            XCTAssertFalse(OverviewProtocol.succeeded(native.setting("pending",.bool(true)),operation:operation))
            XCTAssertFalse(OverviewProtocol.succeeded(native.setting("result",native["result"]!.setting("code",.double(native["result"]!["code"]!.double!))),operation:operation))
            XCTAssertThrowsError(try binding.response(native.setting("request_seq",.int(1)),sequence:native["request_seq"]!.int!,operation:operation))
        }
    }
    func testAcceptedNativeGrantSurvivesTransientEmptyDesiredPoolAndPendingRecovery() throws {
        let intent=try fixture("configure-intent"),reply=try fixture("configure")
        let granted=try intent["payload"]!["windows"]!.array!.map {row -> OverviewHidden in
            let window=row["window"]!,bounds=row["parked_bounds"]!.array!.map{$0.double!}
            let record=Hidden(wid:window["wid"]!.int!,pid:window["pid"]!.int!,owner:"OwnedFixture",space:row["spaces"]!.array![0].int!,rect:bounds)
            return try OverviewHidden(record:record,parked:Rect(bounds)!,space:row["spaces"]!.array![0].int!,birth:window["birth"]!.array!.map{$0.int!})
        }
        var pool=OverviewConfiguredPool();pool.pendingRecords=granted
        try pool.confirm(reply);XCTAssertEqual(pool.records,granted)
        let transientDesired:[OverviewHidden]=[]
        pool.pendingRecords=transientDesired
        XCTAssertEqual(pool.records.map(\.wid),[51901,51902,51903]) // Exit's first park samples cannot erase native commit authority.
        XCTAssertThrowsError(try pool.confirm(reply.setting("result",reply["result"]!.setting("code",.int(0)))))
        XCTAssertEqual(pool.records,granted)
        pool.pendingRecords=granted;try pool.confirm(reply) // Exact retained configure completion has identical authority semantics.
        XCTAssertNil(pool.pendingRecords);XCTAssertEqual(pool.records,granted)
        // An accepted empty retirement configure must publish the same empty scope as its payload.
        pool.pendingRecords=[]
        XCTAssertEqual(pool.records,granted) // Pending retirement is not yet authority.
        try pool.confirm(reply)
        XCTAssertTrue(pool.records.isEmpty);XCTAssertNil(pool.pendingRecords)
        pool.reset();XCTAssertTrue(pool.records.isEmpty)
    }

    func testNullNativeSnapshotBootstrapsOnlyEmptyInactiveUnconfiguredScope() throws {
        let original=try fixture("snapshot")
        let null=original.setting("result",original["result"]!.setting("snapshot",.null))
        XCTAssertTrue(OverviewProtocol.requiresEmptyBootstrap(null,hasConfiguredScope:false,rawMode:0,locked:false,pending:false))
        XCTAssertFalse(OverviewProtocol.requiresEmptyBootstrap(original,hasConfiguredScope:false,rawMode:0,locked:false,pending:false))
        for (configured,raw,locked,pending) in [(true,UInt64(0),false,false),(false,UInt64(1),false,false),(false,UInt64.max,false,false),(false,UInt64(0),true,false),(false,UInt64(0),false,true)] {
            XCTAssertFalse(OverviewProtocol.requiresEmptyBootstrap(null,hasConfiguredScope:configured,rawMode:raw,locked:locked,pending:pending))
        }
        XCTAssertFalse(OverviewProtocol.requiresEmptyBootstrap(null.setting("main_evaluated",.bool(false)),hasConfiguredScope:false,rawMode:0,locked:false,pending:false))
    }

    func testOlderRetainedCommitCannotBlockReplacementOrAuthorizeRestore() throws {
        let hello=try fixture("hello"),info=hello["service_info"]!,generation=hello["generation"]!
        let binding=try OverviewBinding(.object([("schema",.int(1)),("actor",.object([("pid",generation.array![0]),("birth",generation),("path",.string("/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"))])),("nonce",hello["nonce"]!),
            ("endpoint",info["endpoint"]!),("image",.object([("path",info["image_path"]!),("uuid",info["image_uuid"]!)]))]))
        let source=try OverviewHidden(record:Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:[12,41,720,903]),parked:Rect(1430,41,720,903),space:1,birth:[101,Int(getuid()),40,50])
        let commit=JSON.object([("nonce",.string(binding.nonce)),("pool_generation",.int(7)),("setup_observed",.bool(true)),("end_order_observed",.bool(true)),("root_cancel_requested",.bool(false)),("inverse_park_observed",.bool(true)),
            ("commit_token",.string(String(repeating:"b",count:32))),("wid",.int(source.wid)),("pid",.int(source.pid)),("birth",.array(source.birth.map(JSON.int))),("hidden_intent",.string(source.intent)),("epoch",.int(1))])
        let snapshot=JSON.object([("controller_observed",.bool(true)),("mode",.int(0)),("raw_mode",.int(0)),("overview_active",.bool(false)),("pool_generation",.int(8)),("commits",.array([commit]))])
        XCTAssertFalse(OverviewProtocol.hasCurrentPoolCommits(snapshot))
        XCTAssertTrue(try OverviewProtocol.selections(snapshot:snapshot,binding:binding,hidden:[source]).isEmpty)
        XCTAssertEqual(snapshot["commits"],.array([commit])) // Retention is unchanged; no forged ACK or deletion.
        let current=snapshot.setting("pool_generation",.int(7))
        XCTAssertTrue(OverviewProtocol.hasCurrentPoolCommits(current))
        XCTAssertEqual(try OverviewProtocol.selections(snapshot:current,binding:binding,hidden:[source]).map(\.wid),[1])
        XCTAssertTrue(OverviewProtocol.hasCurrentPoolCommits(snapshot.setting("commits",.array([commit.setting("pool_generation",.double(7))]))))
        XCTAssertTrue(OverviewProtocol.hasCurrentPoolCommits(snapshot.setting("pool_generation",.int(6))))
    }

    func testCanceledNativeFlightRetiresOnlyExactUnstartedAuthenticatedRequest() throws {
        let hello=try fixture("hello"),info=hello["service_info"]!,generation=hello["generation"]!
        let binding=try OverviewBinding(.object([("schema",.int(1)),("actor",.object([("pid",generation.array![0]),("birth",generation),("path",.string("/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"))])),("nonce",hello["nonce"]!),
            ("endpoint",info["endpoint"]!),("image",.object([("path",info["image_path"]!),("uuid",info["image_uuid"]!)]))]))
        // Exact os10FlightResponse(state=2) transport envelope; no main handler or mutation ran.
        let canceled=JSON.object([("schema",.int(1)),("nonce",hello["nonce"]!),("generation",generation),
            ("request_seq",.int(42)),("operation",.string("configure")),("completed",.bool(false)),
            ("pending",.bool(false)),("main_evaluated",.bool(false)),("canceled",.bool(true))])
        func retires(_ reply:JSON,_ seq:Int=42,_ op:String="configure") -> Bool {
            OverviewProtocol.canceledBeforeMain(reply,binding:binding,sequence:seq,operation:op)
        }
        XCTAssertTrue(retires(canceled))
        XCTAssertFalse(OverviewProtocol.succeeded(canceled,operation:"configure")) // Cancellation is never a successful configure ACK.
        for changed in [canceled.setting("canceled",.bool(false)),canceled.setting("canceled",.null),
            canceled.setting("pending",.bool(true)),canceled.setting("main_evaluated",.bool(true)),
            canceled.setting("completed",.bool(true)),canceled.setting("refused",.bool(true)),
            canceled.setting("nonce",.string(String(repeating:"f",count:32))),
            canceled.setting("generation",.array([.int(99)])),canceled.setting("result",.object([]))] {
            XCTAssertFalse(retires(changed))
        }
        XCTAssertFalse(retires(canceled,43));XCTAssertFalse(retires(canceled,42,"snapshot"))
        let started=canceled.setting("canceled",.bool(false)).setting("pending",.bool(true)).setting("main_evaluated",.bool(true))
        XCTAssertFalse(retires(started))
        XCTAssertNoThrow(try binding.request("configure",sequence:43,payload:.object([]))) // Retry is a new request, never a replay of canceled seq42.
    }

    func testActualSource14CanceledSnapshotAllowsOnlyFreshRequestRecovery() throws {
        let path=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/overview14-canceled-before-main.json")
        let captured=try JSON.parse(Data(contentsOf:path))
        var document=captured["binding"]!,generation=captured["reply"]!["generation"]!.array!
        generation[1] = .int(Int(getuid()))
        let actor=document["actor"]!.setting("birth",.array(generation))
        document=document.setting("actor",actor).setting("endpoint",.string(document["endpoint"]!.string!.replacingOccurrences(of:"-501-",with:"-\(getuid())-")))
        let binding=try OverviewBinding(document)
        let canceled=captured["reply"]!.setting("generation",.array(generation))
        XCTAssertEqual(canceled["canceled"],.int(1))
        XCTAssertTrue(OverviewProtocol.canceledBeforeMain(canceled,binding:binding,sequence:12088,operation:"snapshot"))
        XCTAssertFalse(OverviewProtocol.succeeded(canceled,operation:"snapshot"))
        for value:JSON in [.int(0),.int(2),.int(-1),.double(1),.string("1"),.string("true"),.null] {
            XCTAssertFalse(OverviewProtocol.canceledBeforeMain(canceled.setting("canceled",value),binding:binding,sequence:12088,operation:"snapshot"))
        }
        let later=captured["later_snapshot"]!.setting("generation",.array(generation))
        XCTAssertTrue(OverviewProtocol.succeeded(try binding.response(later,sequence:12089,operation:"snapshot"),operation:"snapshot"))
        XCTAssertFalse(OverviewProtocol.canceledBeforeMain(later,binding:binding,sequence:12088,operation:"snapshot"))
    }

    func testEmptyPoolAcknowledgmentRequiresAcceptedEmptyConfigureAndIdleAuthenticatedScope() throws {
        var pool=OverviewConfiguredPool()
        func allowed(_ enabled:Bool=false,_ attested:Bool=true,_ pending:Bool=false,_ configured:Bool=true,_ desired:[OverviewHidden]=[]) -> Bool {
            pool.canAcknowledgeEmpty(hiddenWindowsEnabled:enabled,attested:attested,pending:pending,configured:configured,desired:desired)
        }
        XCTAssertFalse(allowed(false,true,false,false)) // Empty local startup state is not a native configure receipt.
        pool.pendingRecords=[];XCTAssertFalse(allowed())
        try pool.confirm(fixture("configure"));XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(true));XCTAssertFalse(allowed(false,false));XCTAssertFalse(allowed(false,true,true))
        let row=Hidden(wid:1,pid:101,owner:"Fixture",space:1,rect:[12,41,720,304])
        let source=try OverviewHidden(record:row,parked:Rect(1430,41,720,304),space:1,birth:[101,Int(getuid()),40,50])
        XCTAssertFalse(allowed(false,true,false,true,[source]))
        pool.pendingRecords=[source];XCTAssertFalse(allowed())
        try pool.confirm(fixture("configure"));XCTAssertFalse(allowed())
        pool.pendingRecords=[];XCTAssertFalse(allowed())
        try pool.confirm(fixture("configure"));XCTAssertTrue(allowed())
    }

}
