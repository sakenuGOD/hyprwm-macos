// swift-tools-version:5.9
// hyprwm-swift: Swift daemon, menu and settings for HyprWM.
// Daemon C code is NOT copied: CChan/CAX/CSnap include hook/src/ sources via shims
// (#include "../../../src/…"); channel header hook/src/chan.h is unchanged (one ABI for both sides).
import PackageDescription

let sky: [LinkerSetting] = [.unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])]

let package = Package(
    name: "hyprwm-swift",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "hyprwm-swift", targets: ["hyprwm-swift"])],
    targets: [
        // daemon <-> engine channel: hook/src/chanlib.c + hook/src/chan.h (no frameworks; usable in tests)
        .target(name: "CChan", path: "Sources/CChan"),
        // AX (configure/focus/menu) from hook/src/axlib.c plus SkyLight/CG wrappers previously accessed via ctypes
        .target(name: "CAX", path: "Sources/CAX",
                cSettings: [.unsafeFlags(["-Wno-deprecated-declarations"])],
                linkerSettings: sky + [.linkedFramework("ApplicationServices"), .linkedFramework("CoreGraphics"),
                                       .linkedFramework("CoreFoundation"), .linkedFramework("CoreServices")]),
        // window snapshot from hook/src/winsnap.m (ARC)
        .target(name: "CSnap", path: "Sources/CSnap",
                cSettings: [.unsafeFlags(["-fobjc-arc", "-Wno-deprecated-declarations"])],
                linkerSettings: sky + [.linkedFramework("AppKit"), .linkedFramework("ApplicationServices")]),
        // all daemon logic without system access (layout, config, commands, sync/apply), testable
        .target(name: "HyprCore", dependencies: ["CChan"], path: "Sources/HyprCore"),
        .executableTarget(name: "hyprwm-swift", dependencies: ["HyprCore", "CChan", "CAX", "CSnap"],
                          path: "Sources/hyprwm-swift",
                          linkerSettings: [.linkedFramework("AppKit")]),
        .testTarget(name: "HyprCoreTests", dependencies: ["HyprCore", "CChan"], path: "Tests/HyprCoreTests",
                    exclude: ["Fixtures"]),
    ],
    swiftLanguageVersions: [.v5]
)
