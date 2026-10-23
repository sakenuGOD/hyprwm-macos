@testable import HyprCore
import XCTest

final class TabIdentityTests: XCTestCase {
    func packet(pid: Int = 101, publication: Int = 1, generation: Int = 1, selected: Int = 3,
                launch: String = "fixture-launch", complete: Bool = true, revision: Int = 4, settled: Int = 4) -> JSON {
        let members = [1,3].map { JSON.object([("object", .int($0)), ("wid", .int($0))]) }
        let windows = [1,3].map { wid in JSON.object([
            ("object", .int(wid)), ("wid", .int(wid)), ("group", .int(5)),
            ("group_known", .bool(true)), ("group_kvo", .bool(true)), ("hidden_tab", .bool(wid != selected))]) }
        return .object([
            ("schema", .int(1)), ("transport", .string("ws-connection-v1")), ("pid", .int(pid)),
            ("launch", .string(launch)), ("generation", .int(generation)), ("publication", .int(publication)),
            ("seq", .int(publication)), ("revision", .int(revision)), ("settled_revision", .int(settled)),
            ("installed", .bool(true)), ("complete", .bool(complete)), ("reconcile_pending", .bool(false)),
            ("gap", .bool(false)), ("dropped_events", .int(0)), ("windows", .array(windows)),
            ("groups", .array([.object([("group", .int(5)), ("members", .array(members)),
                ("selected", .int(selected)), ("selected_wid", .int(selected)),
                ("membership_kvo", .bool(true)), ("selection_kvo", .bool(true))])])), ("events", .array([]))])
    }
    func data(_ packet: JSON) -> Data { Data(packet.dumps().utf8) }
    func install(_ packet: JSON, _ world: FakeWorld, connection: Int = 100) {
        world.tabProperties[101] = TabProperty(connection: connection, data: data(packet))
    }
    func world() -> (FakeWorld, [WinInfo]) {
        let sys = FakeWorld(); sys.births[101] = "birth-A"; sys.pidlevel[1] = (101,0); sys.pidlevel[3] = (101,0)
        let window = WinInfo(wid: 1, pid: 101, owner: "Fixture", x: 0, y: 30, w: 580, h: 850, on: true, space: 1)
        return (sys, [window])
    }
    func testSettledProtocolProducesExactSelectedMembership() throws {
        let (sys, windows) = world(), reader = TabIdentityReader()
        install(packet(), sys)
        let facts = reader.read(windows, sys)
        XCTAssertEqual(facts[1]?.selected, 3); XCTAssertEqual(facts[3]?.members, [1,3])
        XCTAssertEqual(facts[1]?.birth, "birth-A")
        XCTAssertEqual(reader.read(windows, sys), facts, "a freshly reread identical property is valid")
    }
    func testPendingRevokedAndForgedCompleteSnapshotsNeverConferMembership() throws {
        let reader = TabIdentityReader(), (sys, windows) = world()
        install(packet(complete: false), sys); XCTAssertTrue(reader.read(windows, sys).isEmpty)
        install(packet(publication: 2, revision: 5, settled: 4), sys); XCTAssertTrue(reader.read(windows, sys).isEmpty)
        install(packet(publication: 3).setting("installed", .bool(false)), sys); XCTAssertTrue(reader.read(windows, sys).isEmpty)
        let bad = packet().setting("groups", .array([]))
        XCTAssertThrowsError(try TabSnapshot.parse(data(bad)))
        let wrongSelection = packet().setting("groups", .array([packet()["groups"]!.array![0].setting("selected_wid", .int(999))]))
        XCTAssertThrowsError(try TabSnapshot.parse(data(wrongSelection)))
        XCTAssertThrowsError(try TabSnapshot.parse(Data(repeating: 32, count: 65537)))
    }
    func testReplayLaunchReplacementAndRevisionRegressionFailClosed() throws {
        let reader = TabIdentityReader(), (sys, windows) = world()
        install(packet(publication: 10), sys); XCTAssertFalse(reader.read(windows, sys).isEmpty)
        install(packet(publication: 9), sys); XCTAssertTrue(reader.read(windows, sys).isEmpty)
        install(packet(publication: 11, launch: "unverified-new-launch"), sys); XCTAssertTrue(reader.read(windows, sys).isEmpty)
        install(packet(publication: 11, revision: 3, settled: 3), sys); XCTAssertTrue(reader.read(windows, sys).isEmpty)
        install(packet(publication: 11, generation: 2, revision: 1, settled: 1), sys); XCTAssertFalse(reader.read(windows, sys).isEmpty)
        install(packet(publication: 12, generation: 1), sys); XCTAssertTrue(reader.read(windows, sys).isEmpty)
    }
    func testProcessBirthReadBracketRejectsChangedOwner() throws {
        let reader = TabIdentityReader(), (sys, windows) = world()
        install(packet(), sys)
        sys.propertyRead = { sys.births[101] = "birth-replaced" }
        XCTAssertTrue(reader.read(windows, sys).isEmpty)
        XCTAssertTrue(reader.stores.isEmpty)
    }
    func testConnectionReplacementRequiresFreshBaselineAndPIDMatches() throws {
        let reader = TabIdentityReader(), (sys, windows) = world()
        install(packet(), sys); XCTAssertFalse(reader.read(windows, sys).isEmpty)
        install(packet(pid: 999), sys, connection: 200); XCTAssertTrue(reader.read(windows, sys).isEmpty)
        install(packet(launch: "fresh-connection"), sys, connection: 200)
        XCTAssertFalse(reader.read(windows, sys).isEmpty)
    }
    func testOrderOverlapReplacesOnlySelectedLeafWithoutOpeningAnimation() throws {
        let test = ProductionPolicyTests(), (wm, sys, eng, windows) = try test.world(test.pair())
        let retained = wm.target[1]!
        var new = windows[0]; new.wid = 3; new.x += 80; new.w = 800
        sys.tileableM[3] = 1; sys.pidlevel[3] = (101,0)
        install(packet(), sys)
        let (changed, opened) = wm.sync(test.area, 1, windows+[new])
        XCTAssertFalse(changed); XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(Dwindle.leaves(wm.sp(1).tree).compactMap(\.wid), [3,2])
        XCTAssertEqual(wm.target[3], retained)
        let geometry = eng.ch.ops.filter { ["geom", "warp"].contains($0["op"]?.string ?? "") }
        XCTAssertEqual(geometry.count, 1)
        XCTAssertEqual(geometry[0]["op"]?.string, "warp")
        XCTAssertEqual(geometry[0]["wid"]?.int, 3)
        XCTAssertEqual(Rect.j(geometry[0]["to"]), retained)
        XCTAssertFalse(geometry.contains { $0["wid"]?.int == 2 })
        // AppKit selects the original while both native windows are still order-on.
        install(packet(publication: 2, selected: 1), sys)
        let result = wm.sync(test.area, 1, windows+[new])
        XCTAssertFalse(result.0); XCTAssertTrue(result.1.isEmpty)
        XCTAssertEqual(Dwindle.leaves(wm.sp(1).tree).compactMap(\.wid), [1,2])
    }
}
