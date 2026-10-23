@testable import HyprCore
import XCTest

final class ExplicitWorkspaceCommandTests:XCTestCase {
    func testFirstClickQueuesWhileLegacyProviderIsStillPreparing() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,wins)=try f.world(f.pair())
        sys.transferCatalog=try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(1));sys.activeSpaceID=1
        wm.workspaceFocus={_,_ in false}
        var queued:[String]=[];wm.workspaceCommandSubmit={selector,source in XCTAssertEqual(source,1);queued.append(selector);return true}
        XCTAssertTrue(try wm.command("workspace 2",f.area,1,wins).contains("queued"))
        XCTAssertEqual(queued,["2"]);XCTAssertEqual(wm.workspaceHistoryCurrent,1)
    }
    func testActiveExplicitNumberIsIdempotentDespiteBackAndForthSetting() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,wins)=try f.world(f.pair())
        sys.transferCatalog=try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(1));sys.activeSpaceID=1
        wm.observeWorkspaceHistory(2);wm.observeWorkspaceHistory(1)
        var calls=0;wm.workspaceFocus={_,_ in calls+=1;return true};wm.workspaceCommandSubmit={_,_ in calls+=1;return true}
        XCTAssertTrue(try wm.command("workspace 1",f.area,1,wins).contains("already active"));XCTAssertEqual(calls,0)
    }
    func testNewAlwaysQueuesANewRequestFromTheCurrentOrdinarySource() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,wins)=try f.world(f.pair())
        var sources:[Int]=[];wm.workspaceCommandSubmit={selector,source in XCTAssertEqual(selector,"new");sources.append(source);return true}
        for source in [1,2] {
            sys.transferCatalog=try PublicWorkspaceCatalog(PublicWorkspaceTests().raw(source));sys.activeSpaceID=UInt64(source)
            XCTAssertTrue(try wm.command("workspace new",f.area,source,wins).contains("queued"))
        }
        XCTAssertEqual(sources,[1,2])
    }
    func testCreationReadbackRequiresExactlyOneUniqueOrdinaryAppend() throws {
        let f=PublicWorkspaceTests(),raw=f.raw(1),before=try PublicWorkspaceCatalog(raw)
        let old=raw["displays"]!.array![0],rows=old["spaces"]!.array!,added=JSON.object([("sid",.int(99)),("uuid",.string("created")),("type",.int(0))])
        func changed(_ spaces:[JSON],_ active:Int=1) throws -> PublicWorkspaceCatalog {
            try PublicWorkspaceCatalog(raw.setting("active_before",.int(active)).setting("active_after",.int(active)).setting("displays",.array([old.setting("current_catalog",.int(active)).setting("current_getter",.int(active)).setting("spaces",.array(spaces))])))
        }
        XCTAssertEqual(try before.appendedOrdinary(changed(rows+[added])).sid,99)
        XCTAssertThrowsError(try before.appendedOrdinary(changed(rows)))
        XCTAssertThrowsError(try before.appendedOrdinary(changed([rows[1],rows[0],added])))
        XCTAssertThrowsError(try before.appendedOrdinary(changed(rows+[added.setting("type",.int(4))])))
        XCTAssertThrowsError(try before.appendedOrdinary(changed(rows+[added],2)))
        XCTAssertThrowsError(try before.appendedOrdinary(changed(rows+[added.setting("uuid",.string("second"))])))
    }
}
