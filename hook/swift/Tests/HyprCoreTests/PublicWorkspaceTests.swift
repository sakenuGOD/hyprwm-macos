@testable import HyprCore
import XCTest

final class PublicWorkspaceTests:XCTestCase {
    func testInFlightSplitReadsWaitWithoutWeakeningStableCatalogOrACK() throws {
        let before=try PublicWorkspaceCatalog(raw(1)),display=raw(1)["displays"]!.array![0]
        let split=raw(1).setting("consistent",.bool(false)).setting("active_after",.int(2)).setting("displays",.array([display.setting("current_getter",.int(2))]))
        XCTAssertThrowsError(try PublicWorkspaceCatalog(split))
        XCTAssertNil(try PublicWorkspaceCatalog.duringTransition(split,from:before))
        XCTAssertEqual(try PublicWorkspaceCatalog.duringTransition(raw(2),from:before)?.active,2)
        for (key,value) in [("locked",JSON.bool(true)),("setter_called",.bool(true)),("generation",.array([])),("observer_identity",.null),("active_after",.int(999))] {
            XCTAssertThrowsError(try PublicWorkspaceCatalog.duringTransition(split.setting(key,value),from:before),key)
        }
        XCTAssertNil(try PublicWorkspaceCatalog.duringTransition(raw(1).setting("consistent",.bool(false)),from:before))
        XCTAssertThrowsError(try PublicWorkspaceCatalog.duringTransition(split.setting("displays",.array([display.setting("current_getter",.int(2)).setting("spaces",.array([]))])),from:before))
        var ack=try PublicWorkspaceACK(before:before,sid:1,managerIdentity:identity(101))
        for (index,time) in [0.0,0.08,0.16].enumerated(){ack.observeManager(manager(index+1),time:time);try ack.observeIndependent(PublicWorkspaceCatalog(raw(1,observer:200+index)),time:time)}
        XCTAssertTrue(ack.acknowledged);ack.resetTransitionSamples();XCTAssertFalse(ack.acknowledged)
        XCTAssertThrowsError(try ack.observeIndependent(PublicWorkspaceCatalog(raw(1,observer:200)),time:0.3))
    }
    func testSchema2KeepsLegacyAllCountWhileRequiringCompleteOrdinaryCensus() throws {
        let fixture=raw(),catalog=try PublicWorkspaceCatalog(fixture),hash=String(repeating:"a",count:64)
        let proof=JSON.object([("schema",.int(2)),("backend",.string("public-Mission-Control-AX")),("manager_identity",identity(101)),
            ("manager_runtime",.string("swift")),("manager_image_sha",.string(hash)),("manager_image",.object([("path",.string("/owned/native")),("sha256",.string(hash))])),
            ("generation",catalog.generation),("ordinary_scope",.string("native-layer0-application-windows"))] +
            ["acknowledged","independent_ack","manager_ack","manager_empty_ordinary_space_ack","shell_exclusions_complete","returned_original"].map{($0,.bool(true))})
        try PublicWorkspacePermission.validate(proof,manager:identity(101),imageHash:hash,generation:catalog.generation)
        XCTAssertThrowsError(try PublicWorkspacePermission.validate(proof.setting("shell_exclusions_complete",.bool(false)),manager:identity(101),imageHash:hash,generation:catalog.generation))
        let row=JSON.object([("wid",.int(33)),("pid",.int(100)),("birth",.array(Array(identity(100).array!.prefix(4)))),("executable",.string("/owned/100")),("layer",.int(21)),("space",.int(1)),("reason",.string("nonzero-native-layer"))])
        let descriptor=JSON.object([("schema",.int(1)),("scope",.string("native-layer0-application-windows")),("space",.int(1)),("complete",.bool(true)),("all_window_count",.int(1)),("ordinary",.array([])),("excluded",.array([row])),("titles_read",.bool(false)),("owner_labels_used",.bool(false))])
        let witness=JSON.object([("ordinary_window_count",.int(0)),("ordinary_descriptor",descriptor)])
        XCTAssertTrue(OrdinaryWorkspaceWitness.validate(witness,space:1))
        XCTAssertFalse(OrdinaryWorkspaceWitness.validate(witness.setting("ordinary_descriptor",descriptor.setting("complete",.bool(false))),space:1))
        XCTAssertFalse(OrdinaryWorkspaceWitness.validate(witness.setting("ordinary_descriptor",descriptor.setting("excluded",.array([row.setting("birth",.null)]))),space:1))
    }
    let display="11111111-1111-1111-1111-111111111111"
    func identity(_ pid:Int) -> JSON { .array([.int(pid),.int(501),.int(100),.int(pid),.string("/owned/"+String(pid))]) }
    func raw(_ active:Int=2,observer:Int=101) -> JSON {
        .object([("mode",.string("native-diagnostic")),("setter_called",.bool(false)),("locked",.bool(false)),("consistent",.bool(true)),
            ("observer_identity",identity(observer)),("generation",.array([.string("25G241"),.string("sky-uuid"),identity(100),identity(102)])),
            ("active_before",.int(active)),("active_after",.int(active)),("displays",.array([.object([("display",.string(display)),
                ("current_catalog",.int(active)),("current_getter",.int(active)),("spaces",.array([.object([("sid",.int(1)),("uuid",.string("")),("type",.int(0))]),
                    .object([("sid",.int(2)),("uuid",.string("second")),("type",.int(0))])]))])]))])
    }
    func manager(_ sequence:Int) -> JSON { .object([("sample_sequence",.int(sequence)),("space",.int(1)),("space_type",.int(0)),("stable",.bool(true)),
        ("native_current_window_count",.int(0)),("workspace_native",.array([.object([("display",.string(display)),("sid",.int(1)),("uuid",.string("")),("type",.int(0))])]))]) }
    func testExactOrdinaryRequestPreservesNativeEmptyUUIDAndSpaceOrder() throws {
        let before=try PublicWorkspaceCatalog(raw())
        XCTAssertEqual(try before.ordinal(1),1)
        XCTAssertEqual(try before.request(1)["target"]?["uuid"],.string(""))
        XCTAssertTrue(before.matchesPublicSnapshot(before.publicSnapshot))
        XCTAssertFalse(before.matchesPublicSnapshot(before.publicSnapshot.setting("active",.int(1))))
        XCTAssertThrowsError(try before.target(999))
    }
    func testPythonManagerProofDoesNotAuthorizeSwiftOrRecycledProcess() throws {
        let catalog=try PublicWorkspaceCatalog(raw()),hash=String(repeating:"a",count:64)
        let proof=JSON.object([("backend",.string("public-Mission-Control-AX")),("manager_identity",identity(101)),
            ("manager_image_sha",.string(hash)),("generation",catalog.generation)] +
            ["acknowledged","independent_ack","manager_ack","manager_empty_space_ack","returned_original"].map{($0,.bool(true))})
        try PublicWorkspacePermission.validate(proof,manager:identity(101),imageHash:hash,generation:catalog.generation)
        XCTAssertThrowsError(try PublicWorkspacePermission.validate(proof,manager:identity(999),imageHash:hash,generation:catalog.generation))
        for (key,value) in [("manager_image_sha",JSON.string(String(repeating:"b",count:64))),("manager_ack",.int(1)),("returned_original",.bool(false)),("generation",.array([]))] {
            XCTAssertThrowsError(try PublicWorkspacePermission.validate(proof.setting(key,value),manager:identity(101),imageHash:hash,generation:catalog.generation),key)
        }
    }
    func testHelperReceiptAloneCannotAcknowledgeEmptySpace() throws {
        var ack=try PublicWorkspaceACK(before:PublicWorkspaceCatalog(raw()),sid:1,managerIdentity:identity(101))
        for (index,time) in [0.0,0.08,0.16].enumerated() {
            try ack.observeIndependent(PublicWorkspaceCatalog(raw(1,observer:200+index)),time:time)
        }
        XCTAssertFalse(ack.acknowledged)
        for (index,time) in [0.0,0.08,0.16].enumerated() {ack.observeManager(manager(index+1),time:time)}
        XCTAssertTrue(ack.acknowledged)
    }
    func testDuplicateStaleAndWrongUUIDManagerSamplesNeverAuthorizeTransfer() throws {
        var ack=try PublicWorkspaceACK(before:PublicWorkspaceCatalog(raw()),sid:1,managerIdentity:identity(101))
        for index in 0..<3 {try ack.observeIndependent(PublicWorkspaceCatalog(raw(1,observer:200+index)),time:Double(index)*0.1)}
        ack.observeManager(manager(1),time:0)
        ack.observeManager(manager(1),time:0.2);ack.observeManager(manager(1),time:0.4)
        XCTAssertFalse(ack.acknowledged)
        ack.observeManager(manager(2).setting("workspace_native",.array([.object([("display",.string(display)),("sid",.int(1)),("uuid",.string("changed")),("type",.int(0))])])),time:0.5)
        ack.observeManager(manager(3),time:0.6);ack.observeManager(manager(4),time:0.7)
        XCTAssertFalse(ack.acknowledged)
    }
    func testHighFrequencyWitnessesRetainTheirContinuousStabilityStart() throws {
        for fastManager in [true,false] {
            var ack=try PublicWorkspaceACK(before:PublicWorkspaceCatalog(raw()),sid:1,managerIdentity:identity(101))
            let times=Array(0...40).map{Double($0)*0.004}
            for (index,time) in (fastManager ? times:[0,0.08,0.16]).enumerated() {
                ack.observeManager(manager(index+1),time:time)
            }
            for (index,time) in (fastManager ? [0,0.08,0.16]:times).enumerated() {
                try ack.observeIndependent(PublicWorkspaceCatalog(raw(1,observer:200+index)),time:time)
            }
            XCTAssertTrue(ack.acknowledged,"A valid fast stream must not erase its own 150ms stability span")
            ack.observeManager(manager(100).setting("stable",.bool(false)),time:0.17)
            ack.observeManager(manager(101),time:0.18)
            ack.observeManager(manager(102),time:0.19)
            XCTAssertFalse(ack.acknowledged,"An invalid observation starts a new contiguous run")
            ack.resetTransitionSamples()
            XCTAssertFalse(ack.acknowledged)
        }
    }
    func testFreshIndependentProcessesAndExactNativeSessionRequired() throws {
        var ack=try PublicWorkspaceACK(before:PublicWorkspaceCatalog(raw()),sid:1,managerIdentity:identity(101))
        XCTAssertThrowsError(try ack.observeIndependent(PublicWorkspaceCatalog(raw(1)),time:0))
        try ack.observeIndependent(PublicWorkspaceCatalog(raw(1,observer:200)),time:0)
        XCTAssertThrowsError(try ack.observeIndependent(PublicWorkspaceCatalog(raw(1,observer:200)),time:0.2))
        XCTAssertThrowsError(try ack.observeIndependent(PublicWorkspaceCatalog(raw(1,observer:201).setting("generation",.array([.string("different")]))),time:0.3))
    }
    func testUnstableMultipleDisplaysLockAndFloatSIDAreRefused() throws {
        for (key,value) in [("locked",JSON.bool(true)),("consistent",.bool(false)),("setter_called",.bool(true)),("active_after",.int(1)),("active_before",.double(2))] {
            XCTAssertThrowsError(try PublicWorkspaceCatalog(raw().setting(key,value)),key)
        }
        let displays=raw()["displays"]!.array!
        XCTAssertThrowsError(try PublicWorkspaceCatalog(raw().setting("displays",.array(displays+displays))))
    }
}
