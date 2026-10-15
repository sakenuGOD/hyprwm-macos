@testable import HyprCore
import XCTest

final class TextConfigRobustnessTests: XCTestCase {
    private func directory() throws -> URL {
        let config = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("config")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:config.appendingPathComponent("runtime.schema.json"),to:directory.appendingPathComponent("runtime.schema.json"))
        try Data(Fx.config().raw.dumps().utf8).write(to:directory.appendingPathComponent("hypr_cfg.json"))
        return directory
    }
    func testBadLineDoesNotDiscardValidGapAndAppearanceEdits() throws {
        let directory=try directory();defer{try? FileManager.default.removeItem(at:directory)}
        let parsed=try TextConfig.parse("layout.gaps_in = 7\nappearance.border.size = 3\nlayout.gaps_out = -1\nfocus.follow_mouse = 0\n",configDir:directory.path)
        XCTAssertEqual(parsed.issues.map(\.line),[3])
        XCTAssertEqual(parsed.document["layout"]?["gaps_in"],.int(7))
        XCTAssertNil(parsed.document["layout"]?["gaps_out"])
        XCTAssertEqual(parsed.document["appearance"]?["border"]?["size"],.int(3))
        XCTAssertEqual(parsed.document["focus"]?["follow_mouse"],.int(0))
    }
    func testInvalidCurveDoesNotDiscardValidSiblingCurveAndItsAnimation() throws {
        let directory=try directory();defer{try? FileManager.default.removeItem(at:directory)}
        let text = """
        curves._bad = {"type":"bezier","points":[[0.2,0.4],[0.5,1]]}
        curves.custom = {"type":"bezier","points":[[0.2,0.4],[0.5,1]]}
        animations.windowsMove.curve = "custom"
        """
        let parsed=try TextConfig.parse(text,configDir:directory.path)
        XCTAssertEqual(parsed.issues.map(\.line),[1])
        XCTAssertNil(parsed.document["curves"]?["_bad"])
        XCTAssertEqual(parsed.document["curves"]?["custom"]?["type"],.string("bezier"))
        XCTAssertEqual(parsed.document["animations"]?["windowsMove"]?["curve"],.string("custom"))
    }
    func testWatcherSurvivesRepeatedAtomicInodeReplacement() throws {
        let directory=try directory();defer{try? FileManager.default.removeItem(at:directory)}
        let file=directory.appendingPathComponent("hyprwm.conf")
        try Data("layout.gaps_in = 3\n".utf8).write(to:file,options:.atomic)
        let first=expectation(description:"first atomic save"),second=expectation(description:"second atomic save")
        let lock=NSLock();var callbacks=0
        let watcher=try ConfigFileWatcher(url:file) {
            lock.lock();callbacks+=1;let count=callbacks;lock.unlock()
            if count==1 { first.fulfill() }
            if count==2 { second.fulfill() }
        }
        try Data("layout.gaps_in = 5\n".utf8).write(to:file,options:.atomic)
        wait(for:[first],timeout:3)
        try Data("layout.gaps_in = 7\n".utf8).write(to:file,options:.atomic)
        wait(for:[second],timeout:3)
        withExtendedLifetime(watcher) {}
    }
}
