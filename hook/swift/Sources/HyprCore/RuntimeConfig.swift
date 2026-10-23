import Foundation

extension JSON {
    public func setting(_ key: String, _ value: JSON) -> JSON {
        var fields = object ?? []
        if let index = fields.firstIndex(where: { $0.0 == key }) { fields[index].1 = value }
        else { fields.append((key, value)) }
        return .object(fields)
    }
}

/// Reads the shared text configuration directly in Swift.
public enum NativeRuntimeConfig {
    public static func load(base: HyprConfig, configDir: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> HyprConfig {
        let parsed = try TextConfig.read(configDir: configDir)
        if let warning=parsed.error { FileHandle.standardError.write(Data(("hyprwm.conf: "+warning+"\n").utf8)) }
        return try build(base: base, document: parsed.document, environment: environment)
    }
    public static func build(base: HyprConfig, document: JSON, environment: [String: String] = [:]) throws -> HyprConfig {
        guard let root = document.object else { throw CmdError("runtime.json: expected object") }
        let supported: Set<String> = ["$schema", "version", "time_scale", "runtime", "curves", "animations", "layout", "appearance", "focus", "drag", "window_rules", "hotkeys"]
        guard Set(root.map(\.0)).isSubset(of: supported) else { throw CmdError("runtime.json: unknown top-level key") }
        func validateUnique(_ value: JSON) throws {
            if let fields = value.object {
                guard Set(fields.map(\.0)).count == fields.count else { throw CmdError("runtime.json: duplicate key") }
                for (_, child) in fields { try validateUnique(child) }
            }
            for child in value.array ?? [] { try validateUnique(child) }
        }
        try validateUnique(document)
        if let schema=document["$schema"], schema.string == nil { throw CmdError("$schema: expected string metadata") }
        if let hotkeys=document["hotkeys"] {
            guard let rows=hotkeys.array, rows.count <= 256 else { throw CmdError("hotkeys: expected bounded array") }
            var identities=Set<Int>()
            for row in rows {
                guard let fields=row.object, Set(fields.map(\.0)).isSubset(of:["id","keycode","modifiers","enabled","command"]),
                      let id=OverviewBinding.integer(row["id"]), id >= 0, id <= 4095, identities.insert(id).inserted else { throw CmdError("hotkeys: unique bounded integer id required") }
                if let key=row["keycode"], let code=OverviewBinding.integer(key), (0...127).contains(code) {} else if row["keycode"] != nil { throw CmdError("hotkeys.keycode: expected 0..127") }
                if let value=row["modifiers"], let mask=OverviewBinding.integer(value), mask >= 0, mask&(~0x1b00) == 0, mask&0x1900 != 0 {} else if row["modifiers"] != nil { throw CmdError("hotkeys.modifiers: expected Command/Option/Control Carbon chord") }
                if let enabled=row["enabled"], case .bool=enabled {} else if row["enabled"] != nil { throw CmdError("hotkeys.enabled: expected boolean") }
                if let command=row["command"] {
                    guard let arguments=command.array, (1...32).contains(arguments.count), arguments.allSatisfy({ $0.string.map { !$0.contains("\0") && $0.count <= 512 } == true }) else { throw CmdError("hotkeys.command: expected bounded argv identity") }
                }
            }
        }
        for key in ["runtime", "curves", "appearance", "focus", "drag"] {
            if let value = document[key], value.object == nil { throw CmdError("\(key): expected object") }
        }
        if let version = document["version"], version != .int(1) { throw CmdError("version: expected 1") }
        func number(_ value: JSON?, _ name: String, _ range: ClosedRange<Double>, _ fallback: Double) throws -> Double {
            guard let value else { return fallback }
            guard let n = value.double, n.isFinite, range.contains(n) else { throw CmdError("\(name): expected finite number \(range)") }
            return n
        }
        func bool(_ value: JSON?, _ name: String, _ fallback: Bool) throws -> Bool {
            guard let value else { return fallback }
            guard case let .bool(b) = value else { throw CmdError("\(name): expected boolean") }; return b
        }
        let runtime = document["runtime"] ?? .object([])
        _ = try bool(runtime["overview_hidden_windows"], "runtime.overview_hidden_windows", false)
        _ = try bool(runtime["prehide"], "runtime.prehide", false)
        _ = try bool(runtime["capture_sampling"], "runtime.capture_sampling", false)
        _ = try number(runtime["hold_max_ms"], "runtime.hold_max_ms", 0...2000, 200)
        _ = try number(runtime["pointer_focus_pause_ms"], "runtime.pointer_focus_pause_ms", 0...2000, 0)
        _ = try WindowResizeMode.resolve(runtime: runtime)
        var effectiveRuntime = runtime
        if let hold = environment["HYPRWM_HOLD"] {
            guard let seconds = Double(hold), seconds.isFinite, (-1.0...2).contains(seconds) else { throw CmdError("HYPRWM_HOLD: expected -1..2 seconds") }
            effectiveRuntime = effectiveRuntime.setting("hold_max_ms", .double(seconds*1000))
        }
        if let prehide = environment["HYPRWM_PREHIDE"] {
            guard prehide == "0" || prehide == "1" else { throw CmdError("HYPRWM_PREHIDE: expected 0 or 1") }
            effectiveRuntime = effectiveRuntime.setting("prehide", .bool(prehide == "1"))
        }
        var scale = try number(document["time_scale"], "time_scale", 0.1...4, 1)
        if let explicit = environment["HYPRWM_TIME_SCALE"] {
            guard let n = Double(explicit), n.isFinite, (0.1...4).contains(n) else { throw CmdError("HYPRWM_TIME_SCALE: expected 0.1..4") }
            scale = n
        }
        var raw = base.raw
        var config = raw["config"] ?? .object([])
        var general = config["general"] ?? .object([])
        var dwindle = config["dwindle"] ?? .object([])
        let layout = document["layout"] ?? .object([])
        if layout.object == nil { throw CmdError("layout: expected object") }
        if let value = layout["gaps_in"] { general = general.setting("gaps_in", .double(try number(value, "gaps_in", 0...100, 5))) }
        if let value = layout["gaps_out"] {
            if let fields = value.object {
                var gaps = general["gaps_out"] ?? .int(20)
                if gaps.object == nil { gaps = .object(["top", "right", "bottom", "left"].map { ($0, gaps) }) }
                for (side, n) in fields {
                    guard ["top", "right", "bottom", "left"].contains(side) else { throw CmdError("unknown gap side: \(side)") }
                    gaps = gaps.setting(side, .double(try number(n, "gaps_out.\(side)", 0...200, 20)))
                }
                general = general.setting("gaps_out", gaps)
            } else { general = general.setting("gaps_out", .double(try number(value, "gaps_out", 0...200, 20))) }
        }
        for (key, range) in [("default_split_ratio", 0.1...1.9), ("split_width_multiplier", 0.1...10)] {
            if let value = layout[key] { dwindle = dwindle.setting(key, .double(try number(value, key, range, 1))) }
        }
        if let policy = layout["minimum_policy"] {
            guard let value = policy.string, ["native", "ratio"].contains(value) else { throw CmdError("minimum_policy: expected native or ratio") }
            dwindle = dwindle.setting("minimum_policy", policy)
        }
        let focus = document["focus"] ?? .object([])
        if let follow = focus["follow_mouse"] {
            guard follow == .int(0) || follow == .int(1) else { throw CmdError("focus.follow_mouse: expected 0 or 1") }
            config = config.setting("input", (config["input"] ?? .object([])).setting("follow_mouse", follow))
        }
        if let mode=focus["focus_on_close"] {
            guard let value=OverviewBinding.integer(mode), (0...2).contains(value) else { throw CmdError("focus.focus_on_close: expected 0..2") }
            config=config.setting("input",(config["input"] ?? .object([])).setting("focus_on_close",mode))
        }
        if let value=focus["no_focus_fallback"] { general=general.setting("no_focus_fallback",.bool(try bool(value,"focus.no_focus_fallback",false))) }
        let appearance = document["appearance"] ?? .object([])
        var decoration = config["decoration"] ?? .object([])
        for (key, range) in [("rounding", 0.0...100), ("active_opacity", 0.0...1), ("inactive_opacity", 0.0...1), ("fullscreen_opacity", 0.0...1)] {
            if let value = appearance[key] { decoration = decoration.setting(key, .double(try number(value, key, range, 1))) }
        }
        if let rounding = appearance["rounding_power"] { decoration = decoration.setting("rounding_power", .double(try number(rounding, "rounding_power", 1...10, 2))) }
        if let glow = appearance["glow"] {
            guard glow.object != nil else { throw CmdError("glow: expected object") }
            var merged = decoration["glow"] ?? .object([])
            for (key, value) in glow.object! { merged = merged.setting(key, value) }
            decoration = decoration.setting("glow", merged)
        }
        if let shadow = appearance["shadow"] {
            guard shadow.object != nil else { throw CmdError("appearance.shadow: expected object") }
            var merged = decoration["shadow"] ?? .object([])
            for (key, value) in shadow.object! { merged = merged.setting(key, value) }
            decoration = decoration.setting("shadow", merged)
        }
        if let border = appearance["border"] {
            if let width = border["size"] { general = general.setting("border_size", .double(try number(width, "border.size", 0...20, 2))) }
            var colors = general["col"] ?? .object([])
            if let active = border["active"] { colors = colors.setting("active_border", active) }
            if let inactive = border["inactive"] { colors = colors.setting("inactive_border", inactive) }
            general = general.setting("col", colors)
        }
        config = config.setting("general", general).setting("dwindle", dwindle).setting("decoration", decoration)
        var curves = raw["curves"] ?? .object([])
        for (name, value) in document["curves"]?.object ?? [] {
            guard name.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil,
                  let kind = value["type"]?.string else { throw CmdError("invalid curve \(name)") }
            if kind == "spring" {
                _ = try number(value["mass"], name + ".mass", 0.001...100, 1)
                _ = try number(value["stiffness"], name + ".stiffness", 0.001...100000, 250)
                _ = try number(value["damping"] ?? value["dampening"], name + ".damping", 0.001...10000, 25)
            } else if kind == "bezier" {
                guard let pts = value["points"]?.array, pts.count == 2 else { throw CmdError("\(name): expected two control points") }
                for p in pts {
                    guard let pair = p.array, pair.count == 2 else { throw CmdError("\(name): expected [x,y]") }
                    _ = try number(pair[0], name + ".x", 0...1, 0)
                    _ = try number(pair[1], name + ".y", -10...10, 0)
                }
            } else { throw CmdError("unknown curve kind: \(kind)") }
            curves = curves.setting(name, value)
        }
        let overridden = document["animations"] ?? .object([])
        guard overridden.object != nil else { throw CmdError("animations: expected object") }
        let master = try bool(overridden["enabled"], "animations.enabled", true)
        config = config.setting("animations", (config["animations"] ?? .object([])).setting("enabled", .bool(master)))
        var records: [JSON] = [], used = Set<String>(), variants: [String: String] = [:]
        var curveMap = try HyprConfig(json: raw.setting("curves", curves), timeScale: 1).curves()
        let events = Set(HyprConfig.parent.keys).union(["global"])
        for (name, _) in overridden.object! where name != "enabled" {
            guard events.contains(name) else { throw CmdError("unknown animation event: \(name)") }
        }
        for event in events.sorted() {
            var nodes: [String] = [], node: String? = event
            while let current = node { nodes.append(current); node = HyprConfig.parent[current] }
            var override = JSON.object([])
            for name in nodes.reversed() {
                if let entry = overridden[name] {
                    guard entry.object != nil else { throw CmdError("animations.\(name): expected object") }
                    for (key, value) in entry.object! { override = override.setting(key, value) }
                }
            }
            let original = base.animation(event)
            var name = override["curve"]?.string ?? original.curve
            guard let curve = curveMap[name] else { throw CmdError("\(event): unknown curve \(name)") }
            let eventScale = try number(override["time_scale"], event + ".time_scale", 0.1...4, HyprConfig.geomLeaves.contains(event) ? scale : 1)
            let speed = try number(override["duration_ms"], event + ".duration_ms", 0...10000, original.speed*100)/100*eventScale
            var kind = "bezier"
            if case let .spring(mass, stiffness, damping) = curve {
                kind = "spring"
                if override["duration_ms"] != nil { throw CmdError("\(event): spring uses time_scale, not duration_ms") }
                if eventScale != 1 {
                    let key = name + ":" + String(eventScale)
                    if let known = variants[key] { name = known } else {
                        let variant = "_swift_runtime_\(variants.count)"
                        variants[key] = variant; name = variant
                        let entry = JSON.object([("type", .string("spring")), ("mass", .double(mass)),
                                                 ("stiffness", .double(stiffness/(eventScale*eventScale))),
                                                 ("damping", .double(damping/eventScale))])
                        curves = curves.setting(name, entry); curveMap[name] = .spring(mass: mass, stiffness: stiffness/(eventScale*eventScale), damping: damping/eventScale)
                    }
                }
            }
            let on = try bool(override["enabled"], event + ".enabled", original.enabled)
            let style = override["style"]?.string ?? original.style
            if override["style"] != nil && event != "windowsIn" && event != "windowsOut" && event != "windows" && event != "global" {
                throw CmdError("\(event): native Swift renderer does not support custom styles for this event")
            }
            records.append(.object([("leaf", .string(event)), ("enabled", .bool(on)), ("speed", .double(speed)),
                                    (kind, .string(name)), ("style", .string(style))])); used.insert(name)
        }
        guard used.count <= 16 else { throw CmdError("configuration needs more than 16 active native curves") }
        if let rules = document["window_rules"] {
            let validated = try WindowProperties.validateRules(rules)
            raw = raw.setting("window_rules", .array((raw["window_rules"]?.array ?? []) + validated))
        }
        raw = raw.setting("config", config).setting("curves", curves).setting("animations", .array(records))
                 .setting("runtime", effectiveRuntime)
                 .setting("runtime_curve_names", .array(used.sorted().map(JSON.string)))
        let result = try HyprConfig(json: raw, timeScale: 1)
        _ = try Appearance(result)
        return result
    }
}
