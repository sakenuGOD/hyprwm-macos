// User Hyprland config: port of hook/config/hyprcfg.py (reading) plus curve IDs/durations
// from hook/engine.py (setup/anim). The Lua shim remains external: like Python, a stale cache
// (a dotfile .lua newer than hypr_cfg.json) triggers `lua hypr_shim.lua HOME CACHE`.
import Foundation

public struct AnimSetting: Equatable {
    public var enabled: Bool
    public var speed: Double
    public var kind: String      // "spring" | "bezier"
    public var curve: String
    public var style: String
    public var node: String
}

public enum Curve: Equatable {
    case bezier(p1: (Double, Double), p2: (Double, Double))
    case spring(mass: Double, stiffness: Double, damping: Double)
    public static func == (l: Curve, r: Curve) -> Bool {
        switch (l, r) {
        case let (.bezier(a1, a2), .bezier(b1, b2)): return a1 == b1 && a2 == b2
        case let (.spring(a, b, c), .spring(x, y, z)): return a == x && b == y && c == z
        default: return false
        }
    }
}

public final class HyprConfig {
    public static let parent: [String: String] = [
        "windows": "global", "windowsIn": "windows", "windowsOut": "windows", "windowsMove": "windows",
        "layers": "global", "layersIn": "layers", "layersOut": "layers",
        "fade": "global", "fadeIn": "fade", "fadeOut": "fade", "fadeSwitch": "fade", "fadeShadow": "fade",
        "fadeGlow": "fade", "fadeDim": "fade", "fadeDpms": "fade",
        "fadeLayers": "fade", "fadeLayersIn": "fadeLayers", "fadeLayersOut": "fadeLayers",
        "fadePopups": "fade", "fadePopupsIn": "fadePopups", "fadePopupsOut": "fadePopups",
        "border": "global", "borderangle": "global", "shadowangle": "global", "glowangle": "global",
        "zoomFactor": "global", "monitorAdded": "global",
        "workspaces": "global", "workspacesIn": "workspaces", "workspacesOut": "workspaces",
        "specialWorkspace": "workspaces", "specialWorkspaceIn": "specialWorkspace",
        "specialWorkspaceOut": "specialWorkspace",
    ]
    // hyprutils/Hyprland defaults (AnimationTree.cpp): global = (1, 8, "default"); *angle disabled
    static let defaults: [String: JSON] = [
        "global": .object([("enabled", .bool(true)), ("speed", .int(8)), ("bezier", .string("default"))]),
        "borderangle": .object([("enabled", .bool(false)), ("speed", .int(1)), ("bezier", .string("default"))]),
        "shadowangle": .object([("enabled", .bool(false)), ("speed", .int(1)), ("bezier", .string("default"))]),
        "glowangle": .object([("enabled", .bool(false)), ("speed", .int(1)), ("bezier", .string("default"))]),
    ]
    /// Leaves to which TIME_SCALE applies (engine.py GEOM_LEAVES).
    public static let geomLeaves: Set<String> = ["windows", "windowsIn", "windowsOut", "windowsMove", "workspaces",
                                                 "workspacesIn", "workspacesOut", "specialWorkspace",
                                                 "specialWorkspaceIn", "specialWorkspaceOut"]

    public let raw: JSON
    public let timeScale: Double
    public private(set) var curveIDs: [String: Int] = [:]   // curve name -> channel ID (engine.setup)

    public init(json: JSON, timeScale: Double = 1.2) throws {
        raw = json
        self.timeScale = timeScale
        guard json["load_ok"]?.truthy == true else {
            throw NSError(domain: "hyprcfg", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Hyprland config failed to load: \(json["load_error"].map { $0.dumps() } ?? "None")"])
        }
        for (i, (name, _)) in sortedCurves().enumerated() where i < 16 { curveIDs[name] = i }
    }

    /// Load config/defaults unless HYPR_HOME selects another home directory.
    /// Rebuild the cache through the Lua shim when a source .lua file is newer.
    /// Set rebuild=false to read only, for tests and dry runs.
    public static func load(configDir: String, rebuild: Bool = true, timeScale: Double = 1.2) throws -> HyprConfig {
        let cache = configDir + "/hypr_cfg.json"
        let implicit = configDir + "/defaults"
        let home = ProcessInfo.processInfo.environment["HYPR_HOME"] ?? implicit
        let fm = FileManager.default
        if rebuild {
            let cacheT = (try? fm.attributesOfItem(atPath: cache)[.modificationDate] as? Date)?.timeIntervalSince1970
            if cacheT == nil || cacheT! < newestLua(home + "/.config/hypr") {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = ["lua", configDir + "/hypr_shim.lua", home, cache]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    throw NSError(domain: "hyprcfg", code: 2, userInfo: [NSLocalizedDescriptionKey:
                        "lua hypr_shim.lua exited with code \(p.terminationStatus)"])
                }
            }
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: cache))
        return try HyprConfig(json: JSON.parse(data), timeScale: timeScale)
    }

    static func newestLua(_ dir: String) -> Double {
        var t = 0.0
        guard let en = FileManager.default.enumerator(atPath: dir) else { return 0 }
        for case let f as String in en where f.hasSuffix(".lua") {
            if let d = try? FileManager.default.attributesOfItem(atPath: dir + "/" + f)[.modificationDate] as? Date {
                t = max(t, d.timeIntervalSince1970)
            }
        }
        return t
    }

    var config: JSON { raw["config"] ?? .object([]) }
    public var general: JSON { config["general"] ?? .object([]) }
    public var dwindleCfg: JSON { config["dwindle"] ?? .object([]) }

    /// hyprcfg.gaps(): (gaps_in, gaps_out{top,right,bottom,left})
    public func gaps() -> (Double, Gaps) {
        let g = general
        var gi = g["gaps_in"] ?? .int(5)
        let go = g["gaps_out"] ?? .int(20)
        if case .object = gi { gi = gi["top"] ?? .int(5) }
        func side(_ k: String) -> Double {
            if let d = go.double { return d }
            return go[k]?.double ?? 20
        }
        return (gi.double ?? 5, Gaps(top: side("top"), right: side("right"), bottom: side("bottom"), left: side("left")))
    }

    public func makeDwindle() -> Dwindle {
        let (gi, go) = gaps()
        let tile = Dwindle(gapsIn: gi, gapsOut: go,
                       splitWidthMult: dwindleCfg["split_width_multiplier"]?.double ?? 1.0,
                       defaultRatio: (dwindleCfg["default_split_ratio"]?.double ?? 1.0) / 2.0)
        tile.minimumPolicy = dwindleCfg["minimum_policy"]?.string ?? "native"
        return tile
    }

    /// hyprcfg.animation(leaf): an explicitly configured node overrides everything; an unspecified leaf takes
    /// values from its nearest configured ancestor.
    public func animation(_ leaf: String) -> AnimSetting {
        var anims: [String: JSON] = [:]
        for a in raw["animations"]?.array ?? [] {
            anims[a["leaf"]?.string ?? "None"] = a        // dict comprehension: last value wins
        }
        var node: String? = leaf
        var found: JSON?
        while let n = node {
            var a: JSON? = anims[n]
            if let x = a, !x.truthy { a = nil }
            if a == nil, HyprConfig.parent[n] == nil || HyprConfig.defaults[n] != nil { a = HyprConfig.defaults[n] }
            if let x = a, x.truthy { found = x; node = n; break }
            node = HyprConfig.parent[n]
        }
        let a: JSON
        let nodeName: String
        if let f = found, let n = node { a = f; nodeName = n } else { a = HyprConfig.defaults["global"]!; nodeName = "global" }
        let kind: String, curve: String
        if let s = a["spring"] { kind = "spring"; curve = s.string ?? s.dumps() } else {
            kind = "bezier"; curve = a["bezier"]?.string ?? "default"
        }
        return AnimSetting(enabled: (a["enabled"] ?? .bool(true)).truthy, speed: a["speed"]?.double ?? 8,
                           kind: kind, curve: curve, style: a["style"]?.string ?? "", node: nodeName)
    }

    /// hyprcfg.curves(): all curves, including the built-in default.
    public func curves() -> [String: Curve] {
        var out: [String: Curve] = ["default": .bezier(p1: (0, 0.75), p2: (0.15, 1.0))]
        for (name, c) in raw["curves"]?.object ?? [] {
            if c["type"]?.string == "spring" {
                out[name] = .spring(mass: c["mass"]?.double ?? 1, stiffness: c["stiffness"]?.double ?? 250,
                                    damping: (c["damping"] ?? c["dampening"])?.double ?? 25)
            } else {
                let pts = c["points"]?.array ?? [.array([.int(0), .int(0)]), .array([.int(1), .int(1)])]
                if pts.count >= 2 {
                    let p = pts.map { ($0.array?[0].double ?? 0, $0.array?[1].double ?? 0) }
                    out[name] = .bezier(p1: p[0], p2: p[1])
                } else {
                    out[name] = .bezier(p1: (0, 0), p2: (1, 1))
                }
            }
        }
        return out
    }

    /// sorted(curves().items()): sort names by code point, as Python does.
    public func sortedCurves() -> [(String, Curve)] {
        let selected = raw["runtime_curve_names"]?.array.map { Set($0.compactMap(\.string)) }
        return curves().filter { selected == nil || selected!.contains($0.key) }.sorted { Array($0.key.unicodeScalars.map(\.value)).lexicographicallyPrecedes($1.key.unicodeScalars.map(\.value)) }
            .map { ($0.key, $0.value) }
    }

    /// engine.anim(leaf): (curve ID, Bezier duration in seconds, enabled). TIME_SCALE affects geometry only.
    public func anim(_ leaf: String) -> (curve: Int, dur: Double, on: Bool) {
        let a = animation(leaf)
        let s = HyprConfig.geomLeaves.contains(leaf) ? timeScale : 1.0
        return (curveIDs[a.curve] ?? curveIDs["default"] ?? 0, a.speed * 0.1 * s, a.enabled && (config["animations"]?["enabled"]?.truthy ?? true))
    }

    /// popin N% from the leaf style (re.search(r"popin\s+(\d+)", style)) -> N/100 or nil.
    public func popin(_ leaf: String) -> Double? {
        let style = animation(leaf).style
        guard let re = try? NSRegularExpression(pattern: "popin\\s+(\\d+)"),
              let m = re.firstMatch(in: style, range: NSRange(style.startIndex..., in: style)),
              let r = Range(m.range(at: 1), in: style), let v = Double(style[r]) else { return nil }
        return v / 100
    }

    /// Rules containing float (WM.float_rules).
    public var floatRules: [JSON] {
        (raw["window_rules"]?.array ?? []).filter { ($0["float"] ?? .null).truthy }
    }
}
