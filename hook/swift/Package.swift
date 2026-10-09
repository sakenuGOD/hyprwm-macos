// swift-tools-version:5.9
// hyprwm-swift — порт демона hook/hyprwm.py на Swift (MASTER.md §11 П1а).
// C-код демона НЕ копируется: цели CChan/CAX/CSnap включают исходники из hook/src/ через шимы
// (#include "../../../src/…"), заголовок канала — hook/src/chan.h как есть (одна ABI на обе стороны).
import PackageDescription

let sky: [LinkerSetting] = [.unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])]

let package = Package(
    name: "hyprwm-swift",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "hyprwm-swift", targets: ["hyprwm-swift"])],
    targets: [
        // канал демон<->движок: hook/src/chanlib.c + hook/src/chan.h (без фреймворков — годится и тестам)
        .target(name: "CChan", path: "Sources/CChan"),
        // AX (configure/фокус/меню) из hook/src/axlib.c + обёртки SkyLight/CG, которые в Python были ctypes
        .target(name: "CAX", path: "Sources/CAX",
                cSettings: [.unsafeFlags(["-Wno-deprecated-declarations"])],
                linkerSettings: sky + [.linkedFramework("ApplicationServices"), .linkedFramework("CoreGraphics"),
                                       .linkedFramework("CoreFoundation")]),
        // снимок окон из hook/src/winsnap.m (ARC)
        .target(name: "CSnap", path: "Sources/CSnap",
                cSettings: [.unsafeFlags(["-fobjc-arc", "-Wno-deprecated-declarations"])],
                linkerSettings: sky + [.linkedFramework("AppKit"), .linkedFramework("ApplicationServices")]),
        // вся логика демона без обращения к системе (раскладка, конфиг, команды, sync/apply) — тестируется
        .target(name: "HyprCore", dependencies: ["CChan"], path: "Sources/HyprCore"),
        .executableTarget(name: "hyprwm-swift", dependencies: ["HyprCore", "CChan", "CAX", "CSnap"],
                          path: "Sources/hyprwm-swift",
                          linkerSettings: [.linkedFramework("AppKit")]),
        .testTarget(name: "HyprCoreTests", dependencies: ["HyprCore", "CChan"], path: "Tests/HyprCoreTests",
                    exclude: ["Fixtures"]),
    ],
    swiftLanguageVersions: [.v5]
)
