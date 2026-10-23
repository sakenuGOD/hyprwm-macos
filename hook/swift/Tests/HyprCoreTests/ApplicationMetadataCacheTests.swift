@testable import HyprCore
import XCTest

final class ApplicationMetadataCacheTests:XCTestCase {
    let old=ApplicationMetadata(executable:"/Applications/Old.app/Contents/MacOS/Old",bundlePath:"/Applications/Old.app",bundleIdentifier:"old")
    func testPIDReuseCannotInheritOldRoleOrApplicationPath() {
        let cache=ApplicationMetadataCache();cache.store(pid:42,birth:"42:1:2",value:old)
        XCTAssertEqual(cache.read(pid:42,birth:"42:1:2")?.bundleIdentifier,"old")
        XCTAssertNil(cache.read(pid:42,birth:"42:1:3"));XCTAssertEqual(cache.count,0)
        let system=ApplicationMetadata(executable:"/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",bundlePath:nil,bundleIdentifier:"com.apple.dock")
        cache.store(pid:42,birth:"42:1:3",value:system)
        XCTAssertEqual(cache.read(pid:42,birth:"42:1:3")?.executable,system.executable)
        cache.remove(42);XCTAssertNil(cache.read(pid:42,birth:"42:1:3"))
    }
    func testCapacityRemainsBoundedWhileFrequentlyUsedApplicationSurvives() {
        let cache=ApplicationMetadataCache(limit:2)
        cache.store(pid:1,birth:"one",value:old);cache.store(pid:2,birth:"two",value:old)
        XCTAssertNotNil(cache.read(pid:1,birth:"one"))
        cache.store(pid:3,birth:"three",value:old)
        XCTAssertEqual(cache.count,2);XCTAssertNil(cache.read(pid:2,birth:"two"));XCTAssertNotNil(cache.read(pid:1,birth:"one"))
        for pid in 4...1000 {cache.store(pid:pid,birth:String(pid),value:old)}
        XCTAssertEqual(cache.count,2)
    }
}
