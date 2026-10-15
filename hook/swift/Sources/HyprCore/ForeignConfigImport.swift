import Foundation

/// Conservative, non-executing migration of foreign preferences into HyprWM.
public enum ForeignConfigImport {
    public struct Issue: CustomStringConvertible {
        public let line: Int
        public let message: String
        public var description: String { "Line \(line): \(message)" }
    }
    public struct Result {
        public let format: String
        public let document: JSON
        public let issues: [Issue]
        public let mappedCount: Int
        public let backupURL: URL?
    }
    private static let limit = 262_144

    /// Preview by default. Applying merges supported settings and backs up the old file.
    public static func importFile(_ file: URL, configDir: String, apply: Bool = false) throws -> Result {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= limit else {
            throw CmdError("Import requires a regular configuration file no larger than 256 KB")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit, let text = String(data: data, encoding: .utf8) else {
            throw CmdError("Import requires UTF-8 text no larger than 256 KB")
        }
        let parsed = try preview(text, filename: file.lastPathComponent, configDir: configDir)
        guard apply else { return parsed }
        guard parsed.mappedCount > 0 else { throw CmdError("No supported settings were found; the existing configuration was preserved") }
        let current = try TextConfig.read(configDir: configDir).document
        let destination = TextConfig.url(configDir: configDir)
        let backup = destination.appendingPathExtension("backup-" + UUID().uuidString)
        try FileManager.default.copyItem(at: destination, to: backup)
        let merged = merge(current, parsed.document)
        try TextConfig.write(merged, configDir: configDir)
        return Result(format: parsed.format, document: merged, issues: parsed.issues,
                      mappedCount: parsed.mappedCount, backupURL: backup)
    }

    public static func preview(_ text: String, filename: String, configDir: String) throws -> Result {
        guard text.utf8.count <= limit else { throw CmdError("Import exceeds 256 KB") }
        let lower = filename.lowercased()
        let format: String
        if lower.contains("aerospace") || text.contains("[mode.main.binding]") { format = "AeroSpace" }
        else if lower.contains("skhd") { format = "skhd" }
        else if lower.contains("yabai") || text.contains("yabai -m") { format = "yabai" }
        else if lower.contains("hyprland") || text.contains("windowrulev2") || text.contains("general {") { format = "Hyprland" }
        else if lower.contains("amethyst") { format = "Amethyst" }
        else if lower.contains("rectangle") { format = "Rectangle" }
        else if lower.contains("sway") || lower.contains("i3") || text.contains("bindsym ") { format = "i3/sway" }
        else { throw CmdError("Unrecognized configuration format; use a recognized source filename") }
        var parser = Parser(format: format)
        for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
            parser.line = offset + 1
            guard raw.utf8.count <= 4096 else { parser.issue("Line exceeds 4096 bytes"); continue }
            parser.consume(raw)
        }
        parser.finishRule()
        // Validate every generated assignment independently; an invalid setting must not
        // discard an unrelated valid preference from the same source file.
        var accepted = JSON.object([])
        for item in parser.items {
            let native: String
            if item.path == "hotkeys" { native = "bind = " + item.value.dumps(indent: nil) }
            else if item.path == "window_rules" { native = "windowrule = " + item.value.dumps(indent: nil) }
            else { native = item.path + " = " + item.value.dumps(indent: nil) }
            let validation = try TextConfig.parse(native, configDir: configDir)
            if validation.issues.isEmpty {
                accepted = merge(accepted, validation.document)
            } else {
                parser.issues.append(Issue(line: item.line, message: "Value is outside HyprWM's supported range or shape: " + item.path))
            }
        }
        return Result(format: format, document: accepted, issues: parser.issues.sorted { $0.line < $1.line },
                      mappedCount: parser.items.count - parser.items.filter { item in
                          !parser.issues.filter { $0.line == item.line && $0.message.hasPrefix("Value is outside") }.isEmpty
                      }.count, backupURL: nil)
    }

    private static func merge(_ original: JSON, _ patch: JSON) -> JSON {
        guard let fields = patch.object else { return patch }
        var result = original
        for (key, value) in fields {
            if ["hotkeys", "window_rules"].contains(key), let additions = value.array {
                var items = result[key]?.array ?? []
                for item in additions {
                    if key == "hotkeys", let command = item["command"], let index = items.firstIndex(where: { $0["command"] == command }) {
                        items[index] = item
                    } else if !items.contains(item) { items.append(item) }
                }
                result = result.setting(key, .array(items))
            } else if value.object != nil {
                result = result.setting(key, merge(result[key] ?? .object([]), value))
            } else { result = result.setting(key, value) }
        }
        return result
    }

    private struct Item { let path: String; let value: JSON; let line: Int }
    private struct Parser {
        let format: String
        var line = 0
        var section = ""
        var items: [Item] = []
        var issues: [Issue] = []
        var variables: [String: String] = [:]
        var rule: [(Int, String, String)] = []
        mutating func issue(_ message: String) { issues.append(Issue(line: line, message: message)) }
        mutating func add(_ path: String, _ value: JSON) { items.append(Item(path: path, value: value, line: line)) }
        mutating func consume(_ raw: String) {
            let text = uncomment(raw).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.hasPrefix("#!") else { return }
            switch format {
            case "AeroSpace": aerospace(text)
            case "Hyprland": hyprland(text)
            case "yabai": yabai(text)
            case "skhd": skhd(text)
            case "i3/sway": i3(text)
            case "Amethyst": amethyst(text)
            default: issue("Rectangle preferences are not yet supported: " + text)
            }
        }
        mutating func number(_ path: String, _ raw: String, scale: Double = 1) {
            guard let value = Double(unquote(raw)), value.isFinite else { issue("Expected a finite scalar: " + raw); return }
            add(path, .double(value * scale))
        }
        mutating func aerospace(_ text: String) {
            if text.hasPrefix("[") {
                finishRule()
                section = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                return
            }
            guard let (key, value) = assignment(text) else { issue("Unsupported TOML statement: " + text); return }
            if section == "on-window-detected" { rule.append((line, key, value)); return }
            if section == "gaps" {
                let paths = ["inner.horizontal":"layout.gaps_in", "inner.vertical":"layout.gaps_in",
                             "outer.left":"layout.gaps_out.left", "outer.right":"layout.gaps_out.right",
                             "outer.top":"layout.gaps_out.top", "outer.bottom":"layout.gaps_out.bottom"]
                if let path = paths[key] {
                    if path == "layout.gaps_in", let previous = items.last(where: { $0.path == path }),
                       let incoming = Double(value), previous.value.double != incoming {
                        issue("HyprWM has one inner gap; horizontal and vertical gaps differ")
                    } else { number(path, value) }
                } else { issue("Unsupported gap or per-monitor override: " + key) }
            } else if section == "mode.main.binding" {
                binding(unquote(key), action: unquote(value), source: "aerospace")
            } else { issue("Unsupported AeroSpace setting: " + (section.isEmpty ? key : section + "." + key)) }
        }
        mutating func finishRule() {
            guard !rule.isEmpty else { return }
            let entries = rule; rule.removeAll()
            var match: [(String, JSON)] = [], action: Bool?, invalid = false
            for (origin, key, raw) in entries {
                let value = unquote(raw)
                if key == "if.app-name-regex" { match.append(("class", .string(value))) }
                else if key == "if.window-title-regex" { match.append(("title", .string(value))) }
                else if key == "run", value == "layout floating" { action = true }
                else if key == "run", value == "layout tiling" { action = false }
                else {
                    issues.append(Issue(line: origin, message: "Unsupported AeroSpace window condition or action: " + key))
                    invalid = true
                }
            }
            if !invalid, !match.isEmpty, let action {
                items.append(Item(path: "window_rules", value: .object([("match", .object(match)), ("float", .bool(action))]), line: entries[0].0))
            } else if !invalid { issues.append(Issue(line: entries[0].0, message: "Window rule requires a supported condition and float/tile action")) }
        }
        mutating func hyprland(_ text: String) {
            if text == "}" { section = ""; return }
            if text.hasSuffix("{") { section = text.dropLast().trimmingCharacters(in: .whitespaces); return }
            guard let (key, raw) = assignment(text) else { issue("Unsupported Hyprland statement: " + text); return }
            if key.hasPrefix("$") { variables[key] = unquote(raw); return }
            let value = expand(raw)
            let paths = ["general.gaps_in":"layout.gaps_in", "general.gaps_out":"layout.gaps_out",
                         "general.border_size":"appearance.border.size", "decoration.rounding":"appearance.rounding",
                         "decoration.active_opacity":"appearance.active_opacity", "decoration.inactive_opacity":"appearance.inactive_opacity",
                         "dwindle.default_split_ratio":"layout.default_split_ratio", "dwindle.split_width_multiplier":"layout.split_width_multiplier",
                         "input.follow_mouse":"focus.follow_mouse"]
            if let path = paths[section + "." + key] { number(path, value); return }
            if key == "bind" || key == "bindd" {
                let fields = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                let index = key == "bindd" ? 3 : 2
                guard fields.count > index else { issue("Incomplete key binding"); return }
                let chord = fields[0].replacingOccurrences(of: " ", with: "-") + "-" + fields[1]
                binding(chord, action: fields[index...].joined(separator: " "), source: "hyprland"); return
            }
            if key == "windowrule" || key == "windowrulev2" {
                let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let mode = parts.first, ["float", "tile"].contains(mode), parts.count > 1 else { issue("Unsupported window rule action: " + value); return }
                var match: [(String, JSON)] = []
                for field in parts.dropFirst() {
                    guard let colon = field.firstIndex(of: ":"), ["class", "title"].contains(String(field[..<colon])) else {
                        issue("Unsupported window condition: " + field); return
                    }
                    match.append((String(field[..<colon]), .string(String(field[field.index(after: colon)...]))))
                }
                add("window_rules", .object([("match", .object(match)), ("float", .bool(mode == "float"))])); return
            }
            issue("Unsupported Hyprland setting: " + (section.isEmpty ? key : section + "." + key))
        }
        mutating func yabai(_ text: String) {
            guard let words = tokens(text), let marker = words.firstIndex(of: "-m"), marker + 2 < words.count else { issue("Unsupported shell statement (never executed): " + text); return }
            let values = Array(words[(marker + 1)...])
            if values[0] == "config", values.count == 3 {
                let paths = ["window_gap":"layout.gaps_in", "top_padding":"layout.gaps_out.top", "bottom_padding":"layout.gaps_out.bottom",
                             "left_padding":"layout.gaps_out.left", "right_padding":"layout.gaps_out.right", "window_border_width":"appearance.border.size"]
                if let path = paths[values[1]] { number(path, values[2]); return }
                if values[1] == "focus_follows_mouse", ["autofocus", "off"].contains(values[2]) { add("focus.follow_mouse", .int(values[2] == "off" ? 0 : 1)); return }
            }
            if values[0] == "rule", values[1] == "--add" {
                var match: [(String, JSON)] = [], floating: Bool?
                for field in values.dropFirst(2) {
                    guard let (key, value) = assignment(field) else { issue("Unsupported yabai rule: " + field); return }
                    if ["app", "title"].contains(key) { match.append((key == "app" ? "class" : "title", .string(value))) }
                    else if key == "manage", ["on", "off"].contains(value) { floating = value == "off" }
                    else { issue("Unsupported yabai rule condition or action: " + key); return }
                }
                if let floating, !match.isEmpty { add("window_rules", .object([("match", .object(match)), ("float", .bool(floating))])); return }
            }
            issue("Unsupported yabai command: " + text)
        }
        mutating func skhd(_ text: String) {
            guard let separator = text.firstIndex(of: ":") else { issue("Unsupported skhd statement: " + text); return }
            let chord = text[..<separator].replacingOccurrences(of: " ", with: "")
            let command = text[text.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            binding(chord, action: command, source: "yabai")
        }
        mutating func i3(_ text: String) {
            if text.hasPrefix("set ") {
                let words = text.split(maxSplits: 2, whereSeparator: { $0.isWhitespace }).map(String.init)
                if words.count == 3, words[1].range(of: "^\\$[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil {
                    variables[words[1]] = words[2]; return
                }
            }
            if text.hasPrefix("gaps "), let words = tokens(text), words.count == 3, ["inner", "outer"].contains(words[1]) {
                number(words[1] == "inner" ? "layout.gaps_in" : "layout.gaps_out", words[2]); return
            }
            if text.hasPrefix("bindsym "), let words = tokens(expand(text)), words.count >= 3 {
                binding(expand(words[1]).replacingOccurrences(of: "+", with: "-"), action: words.dropFirst(2).joined(separator: " "), source: "i3"); return
            }
            if text.hasPrefix("focus_follows_mouse "), let value = text.split(separator: " ").last, ["yes", "no"].contains(value) {
                add("focus.follow_mouse", .int(value == "yes" ? 1 : 0)); return
            }
            issue("Unsupported i3/sway statement: " + text)
        }
        mutating func amethyst(_ text: String) {
            guard let separator = text.firstIndex(of: ":") else { issue("Unsupported Amethyst YAML statement: " + text); return }
            let key = text[..<separator].trimmingCharacters(in: .whitespaces)
            let value = text[text.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            let paths = ["window-margin-size":"layout.gaps_in", "screen-padding-left":"layout.gaps_out.left",
                         "screen-padding-right":"layout.gaps_out.right", "screen-padding-top":"layout.gaps_out.top", "screen-padding-bottom":"layout.gaps_out.bottom"]
            if let path = paths[key] { number(path, value) }
            else if key == "mouse-follows-focus" { issue("Mouse-following focus differs from focus-following mouse") }
            else { issue("Unsupported Amethyst setting: " + key) }
        }
        func expand(_ text: String) -> String {
            variables.keys.sorted { $0.count > $1.count }.reduce(text) { $0.replacingOccurrences(of: $1, with: variables[$1]!) }
        }
        mutating func binding(_ chord: String, action: String, source: String) {
            guard let (key, modifiers) = keyChord(chord), let command = mapAction(action, source: source) else {
                issue("Unsupported shortcut or action: " + chord + " = " + action); return
            }
            guard items.filter({ $0.path == "hotkeys" }).count < 256 else { issue("HyprWM supports at most 256 imported shortcuts"); return }
            let repeated = items.contains { item in
                item.path == "hotkeys" && ((item.value["keycode"]?.int == key && item.value["modifiers"]?.int == modifiers)
                    || item.value["command"] == .array(command.map(JSON.string)))
            }
            guard !repeated else { issue("Repeated shortcut or action cannot be represented by one native binding: " + chord); return }
            add("hotkeys", .object([("id", .int(items.filter { $0.path == "hotkeys" }.count)), ("keycode", .int(key)),
                                    ("modifiers", .int(modifiers)), ("enabled", .bool(true)), ("command", .array(command.map(JSON.string)))]))
        }
    }

    private static func mapAction(_ raw: String, source: String) -> [String]? {
        guard let words = tokens(raw), !words.isEmpty else { return nil }
        var a = words
        if source == "yabai" {
            guard a.count >= 4, URL(fileURLWithPath: a[0]).lastPathComponent == "yabai", a[1] == "-m", a[2] == "window" else { return nil }
            a = Array(a.dropFirst(3))
            let directions = ["west":"left", "east":"right", "north":"up", "south":"down"]
            if a.count == 2, let direction = directions[a[1]], ["--focus", "--swap", "--warp"].contains(a[0]) {
                return [a[0] == "--focus" ? "focus" : "move", direction]
            }
            if a == ["--toggle", "float"] { return ["float"] }
            if a == ["--toggle", "zoom-fullscreen"] { return ["fullscreen"] }
            if a == ["--close"] { return ["close"] }
            return nil
        }
        if source == "hyprland" {
            let directions = ["l":"left", "r":"right", "u":"up", "d":"down"]
            if a.count == 2, let direction = directions[a[1]], ["movefocus", "movewindow", "swapwindow"].contains(a[0]) {
                return [a[0] == "movefocus" ? "focus" : "move", direction]
            }
            if a == ["togglefloating"] { return ["float"] }
            if a == ["killactive"] { return ["close"] }
            if a == ["fullscreen"] || a == ["fullscreen", "0"] { return ["fullscreen"] }
            if a == ["togglesplit"] { return ["togglesplit"] }
            return nil
        }
        if a.count == 2, ["focus", "move"].contains(a[0]), ["left", "right", "up", "down"].contains(a[1]) { return a }
        if source == "aerospace" {
            if a == ["close"] { return ["close"] }
            if a == ["fullscreen"] { return ["fullscreen"] }
            if a == ["balance-sizes"] { return ["balance"] }
            if a == ["layout", "floating", "tiling"] || a == ["layout", "tiling", "floating"] { return ["float"] }
        }
        if source == "i3" {
            if a == ["kill"] { return ["close"] }
            if a == ["floating", "toggle"] { return ["float"] }
            if a == ["fullscreen", "toggle"] { return ["fullscreen"] }
            if a == ["split", "toggle"] { return ["togglesplit"] }
        }
        return nil
    }
    private static func keyChord(_ raw: String) -> (Int, Int)? {
        let pieces = raw.lowercased().split(whereSeparator: { $0 == "-" || $0 == "+" || $0.isWhitespace }).map(String.init)
        guard let last = pieces.last else { return nil }
        let keys: [String: Int] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
            "1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,"return":36,"enter":36,"l":37,"j":38,"k":40,"n":45,"m":46,
            "tab":48,"space":49,"grave":50,"delete":51,"escape":53,"left":123,"right":124,"down":125,"up":126]
        guard let key = keys[last] else { return nil }
        var modifiers = 0
        for part in pieces.dropLast() {
            switch part {
            case "cmd", "super", "mod4", "win": modifiers |= 0x100
            case "alt", "option", "mod1": modifiers |= 0x800
            case "ctrl", "control": modifiers |= 0x1000
            case "shift": modifiers |= 0x200
            default: return nil
            }
        }
        guard modifiers & 0x1900 != 0 else { return nil }
        return (key, modifiers)
    }
    private static func assignment(_ text: String) -> (String, String)? {
        guard let index = text.firstIndex(of: "=") else { return nil }
        return (String(text[..<index]).trimmingCharacters(in: .whitespaces), String(text[text.index(after: index)...]).trimmingCharacters(in: .whitespaces))
    }
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        if first == "\"", let decoded = try? JSON.parse(value).string { return decoded }
        return String(value.dropFirst().dropLast())
    }
    private static func uncomment(_ text: String) -> String {
        var quote: Character?, escaped = false
        for index in text.indices {
            let char = text[index]
            if escaped { escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if char == "\"" || char == "'" { if quote == char { quote = nil } else if quote == nil { quote = char }; continue }
            if char == "#", quote == nil { return String(text[..<index]) }
        }
        return text
    }
    /// Deliberately rejects shell operators, interpolation, and compound statements.
    private static func tokens(_ text: String) -> [String]? {
        var result: [String] = [], token = "", quote: Character?, escaped = false
        for char in text {
            if escaped { token.append(char); escaped = false; continue }
            if char == "\\", quote != "'" { escaped = true; continue }
            if char == "\"" || char == "'" {
                if quote == char { quote = nil } else if quote == nil { quote = char } else { token.append(char) }
            } else if quote == nil, ";|&`$<>".contains(char) { return nil }
            else if char.isWhitespace, quote == nil {
                if !token.isEmpty { result.append(token); token = "" }
            } else { token.append(char) }
        }
        guard quote == nil, !escaped else { return nil }
        if !token.isEmpty { result.append(token) }
        return result
    }
}
