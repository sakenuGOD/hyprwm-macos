@testable import HyprCore
import XCTest

final class WorkspaceCommandTests:XCTestCase {
    func testDispatcherRefusesUnverifiedProviderAndRoutesNativeSIDWithoutOptimisticHistory() throws {
        let f=ProductionPolicyTests(),(wm,sys,eng,windows)=try f.world(f.pair()),catalog=PublicWorkspaceTests()
        sys.transferCatalog=try PublicWorkspaceCatalog(catalog.raw(1))
        XCTAssertTrue(try wm.command("workspace 2",f.area,1,windows).contains("unverified/unavailable"))
        XCTAssertTrue(eng.ch.ops.isEmpty)
        var calls:[(Int,Bool)]=[]
        wm.workspaceFocus={sid,preflight in calls.append((sid,preflight));return true}
        XCTAssertTrue(try wm.command("ws 2",f.area,1,windows).contains("native2; acknowledgement pending"))
        XCTAssertEqual(calls.map(\.0),[2,2]);XCTAssertEqual(calls.map(\.1),[true,false])
        XCTAssertEqual(wm.workspaceHistoryCurrent,1);XCTAssertNil(wm.workspaceHistoryPrevious)
        wm.observeWorkspaceHistory(2);sys.transferCatalog=try PublicWorkspaceCatalog(catalog.raw(2));calls=[]
        XCTAssertTrue(try wm.command("workspace previous",f.area,2,windows).contains("native1; acknowledgement pending"))
        XCTAssertEqual(calls.map(\.0),[1,1]);XCTAssertTrue(eng.ch.ops.isEmpty)
    }
    func testFreshNativeChangeAfterPreflightRefusesCommitAndStrictSelectors() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair()),catalog=PublicWorkspaceTests()
        sys.transferCatalog=try PublicWorkspaceCatalog(catalog.raw(1))
        var commits=0
        wm.workspaceFocus={_,preflight in
            if preflight {sys.transferCatalog=try? PublicWorkspaceCatalog(catalog.raw(2))} else {commits+=1};return true
        }
        XCTAssertTrue(try wm.command("workspace 2",f.area,1,windows).contains("changed at focus commit"));XCTAssertEqual(commits,0)
        sys.transferCatalog=try PublicWorkspaceCatalog(catalog.raw(1))
        for command in ["workspace +2","workspace 02","workspace 0","workspace 11","wsstep 2","workspace 2 extra"] {
            XCTAssertTrue(try wm.command(command,f.area,1,windows).hasPrefix("workspace unavailable:"),command)
        }
    }
    func testStepAndBackAndForthUseObservedOrdinaryHistory() throws {
        let f=ProductionPolicyTests(),(wm,sys,_,windows)=try f.world(f.pair()),catalog=PublicWorkspaceTests()
        sys.transferCatalog=try PublicWorkspaceCatalog(catalog.raw(1));wm.observeWorkspaceHistory(2);wm.observeWorkspaceHistory(1)
        var targets:[Int]=[];wm.workspaceFocus={sid,preflight in if !preflight {targets.append(sid)};return true}
        _=try wm.command("workspace 1",f.area,1,windows);_ = try wm.command("wsstep 1",f.area,1,windows)
        XCTAssertEqual(targets,[2,2])
        XCTAssertTrue(try wm.command("wsstep -1",f.area,1,windows).contains("workspace5 does not exist"))
    }
}
