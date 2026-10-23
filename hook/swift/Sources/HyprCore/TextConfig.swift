import Foundation
import CoreFoundation
import Darwin

/// The editable preferences document. JSON is used only as the in-memory representation.
public enum TextConfig {
    public struct Issue: CustomStringConvertible {
        public let line: Int
        public let message: String
        public var description: String { "Line \(line): \(message)" }
    }
    public struct Result {
        public let document: JSON
        public let issues: [Issue]
        public var error: String? { issues.first?.description }
    }
    private static let lock = NSRecursiveLock()
    public static func url(configDir: String) -> URL {
        if let explicit = ProcessInfo.processInfo.environment["HYPRWM_CONFIG"], !explicit.isEmpty { return URL(fileURLWithPath: explicit) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/hyprwm/hyprwm.conf")
    }
    public static func read(configDir: String) throws -> Result {
        lock.lock(); defer { lock.unlock() }
        let file = url(configDir: configDir)
        if !FileManager.default.fileExists(atPath: file.path) {
            let base = try HyprConfig.load(configDir: configDir, rebuild: false, timeScale: 1)
            var initial = defaults(base: base)
            if let data = FileManager.default.contents(atPath: configDir + "/runtime.json"), data.count <= 262144,
               let legacy = try? JSON.parse(data), legacy.object != nil {
                initial = merge(initial, legacy)
            }
            if let data = FileManager.default.contents(atPath: configDir + "/swift-runtime.json"), let legacy = try? JSON.parse(data) {
                for key in ["menu_bar", "startup_animation"] { if let v = legacy[key] { initial = set(initial, ["runtime", key], v) } }
            }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(render(initial, configDir: configDir).utf8).write(to: file, options: .atomic)
        }
        let handle = try FileHandle(forReadingFrom:file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount:262145) ?? Data()
        guard data.count <= 262144, let text = String(data: data, encoding: .utf8) else { throw CmdError("hyprwm.conf: expected UTF-8, at most 256 KB") }
        return try parse(text, configDir: configDir)
    }
    public static func parse(_ text: String, configDir: String) throws -> Result {
        let schema = try schemaDocument(configDir)
        var result = JSON.object([]), issues: [Issue] = [], sections: [String] = []
        var origins: [String:Int] = [:]
        var rowOrigins: [String:[Int]] = [:]
        for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = offset + 1, source = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if source.isEmpty { continue }
            if source == "}" {
                if sections.isEmpty { issues.append(.init(line: line, message: "unexpected closing brace")) } else { sections.removeLast() }
                continue
            }
            if source.hasSuffix("{"), !source.contains("=") {
                let name = String(source.dropLast()).trimmingCharacters(in: .whitespaces)
                guard name.range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else { issues.append(.init(line: line, message: "invalid section name")); continue }
                sections.append(name); continue
            }
            guard let separator = source.firstIndex(of: "=") else { issues.append(.init(line: line, message: "expected key = value")); continue }
            let key = source[..<separator].trimmingCharacters(in: .whitespaces)
            let rawValue = source[source.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            let path = (sections + [key]).joined(separator: ".")
            do {
                if sections.isEmpty && (key == "bind" || key == "windowrule") {
                    let target = key == "bind" ? "hotkeys" : "window_rules"
                    let value = rawValue.hasPrefix("{") ? try parseValue(rawValue) : try readableRecord(key, rawValue, ordinal:result[target]?.array?.count ?? 0)
                    guard value.object != nil else { throw CmdError("\(key): expected object {…}") }
                    let itemSchema = schema["properties"]?[target]?["items"] ?? .object([])
                    try validate(value, schema: itemSchema, root: schema, path: key)
                    let entries = (result[target]?.array ?? []) + [value]
                    result = result.setting(target, .array(entries)); origins[target] = line; rowOrigins[target,default:[]].append(line); continue
                }
                let components = path.split(separator: ".").map(String.init)
                guard let field = fieldSchema(components, schema: schema, root: schema) else { throw CmdError("unknown setting \(path)") }
                let value = try parseValue(rawValue)
                try validate(value, schema: field, root: schema, path: path)
                result = set(result, components, value); origins[path] = line
            } catch { issues.append(.init(line: line, message: String(describing: error))) }
        }
        if !sections.isEmpty { issues.append(.init(line: max(1,text.components(separatedBy:.newlines).count), message: "section missing closing brace }")) }
        // Semantic dependencies are checked as independent groups so one bad animation
        // or rule cannot discard unrelated valid gap, focus or border edits.
        let base = try HyprConfig.load(configDir: configDir, rebuild: false, timeScale: 1)
        var accepted = JSON.object([])
        let groups = result.object ?? []
        let ordered = groups.sorted { a,b in (a.0 == "curves" ? 0 : a.0 == "animations" ? 2 : 1) < (b.0 == "curves" ? 0 : b.0 == "animations" ? 2 : 1) }
        for (name, value) in ordered {
            if name == "runtime" { accepted = accepted.setting(name,value); continue }
            if (name == "hotkeys" || name == "window_rules"),let rows=value.array {
                for (index,row) in rows.enumerated() {
                    let candidate=accepted.setting(name,.array((accepted[name]?.array ?? [])+[row]))
                    do { _ = try NativeRuntimeConfig.build(base:base,document:candidate,environment:[:]); accepted=candidate }
                    catch { issues.append(.init(line:rowOrigins[name].flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? origin(name,origins),message:String(describing:error))) }
                }
                continue
            }
            if let children = value.object {
                for (key,child) in children {
                    let current = accepted[name] ?? .object([])
                    let candidate = accepted.setting(name,current.setting(key,child))
                    do { _ = try NativeRuntimeConfig.build(base: base, document: candidate, environment: [:]); accepted = candidate }
                    catch { issues.append(.init(line: origin(name+"."+key,origins), message: String(describing: error))) }
                }
            } else {
                let candidate = accepted.setting(name,value)
                do { _ = try NativeRuntimeConfig.build(base: base, document: candidate, environment: [:]); accepted = candidate }
                catch { issues.append(.init(line: origin(name,origins), message: String(describing: error))) }
            }
        }
        return Result(document: accepted, issues: issues.sorted { $0.line < $1.line })
    }
    private static func origin(_ path: String, _ origins: [String:Int]) -> Int {
        origins[path] ?? origins.filter { $0.key.hasPrefix(path+".") }.map(\.value).min() ?? 1
    }
    public static func defaults(base: HyprConfig) -> JSON {
        let raw = base.raw, config = raw["config"] ?? .object([])
        let general = config["general"] ?? .object([]), dwindle = config["dwindle"] ?? .object([])
        var layout = JSON.object([])
        for key in ["gaps_in", "gaps_out"] { if let value = general[key] { layout = layout.setting(key,value) } }
        for key in ["default_split_ratio", "split_width_multiplier", "minimum_policy"] { if let value = dwindle[key] { layout = layout.setting(key,value) } }
        var appearance = config["decoration"] ?? .object([])
        let allowed = Set(["rounding","rounding_power","active_opacity","inactive_opacity","fullscreen_opacity","shadow","glow"])
        appearance = .object((appearance.object ?? []).filter { allowed.contains($0.0) })
        appearance = appearance.setting("border", .object([("size",general["border_size"] ?? .int(2)),("active",general["col"]?["active_border"] ?? .object([("colors",.array([.string("rgba(ffb4a4ff)")])),("angle",.int(45))])),("inactive",general["col"]?["inactive_border"] ?? .string("rgba(53434155)"))]))
        var animations = JSON.object([("enabled", config["animations"]?["enabled"] ?? .bool(true))])
        let parentEvents = Set(HyprConfig.parent.values)
        for event in Set(HyprConfig.parent.keys).subtracting(parentEvents).sorted() {
            let anim = base.animation(event)
            var item = JSON.object([("enabled",.bool(anim.enabled)),("curve",.string(anim.curve))])
            if case .spring? = base.curves()[anim.curve] { item = item.setting("time_scale",.int(1)) }
            else { item = item.setting("duration_ms",.double(anim.speed*100)) }
            if ["windowsIn","windowsOut"].contains(event) { item = item.setting("style",.string(anim.style)) }
            animations = animations.setting(event,item)
        }
        var focus = JSON.object([])
        for key in ["follow_mouse","focus_on_close"] { if let value = config["input"]?[key] { focus = focus.setting(key,value) } }
        focus = focus.setting("no_focus_fallback",general["no_focus_fallback"] ?? .bool(false))
        return .object([("version",.int(1)),("time_scale",.int(1)),("runtime",.object([("enabled",.bool(true)),("menu_bar",.bool(true)),("startup_animation",.bool(false)),("window_resize_mode",.string("native")),("overview_hidden_windows",.bool(false)),("prehide",.bool(false)),("hold_max_ms",.int(200)),("pointer_focus_pause_ms",.int(100)),("capture_sampling",.bool(false))])),("layout",layout),("appearance",appearance),("focus",focus),("drag",.object([("mode",.string("swap")),("throw_distance_pt",.int(32)),("direction_ratio",.double(1.25))])),("curves",raw["curves"] ?? .object([])),("animations",animations)])
    }
    public static func render(_ document: JSON, configDir: String) -> String {
        let schema = (try? schemaDocument(configDir)) ?? .object([])
        var lines = ["# HyprWM configuration. This file is the source of truth; saving applies changes immediately.","# Sections: name { ... }. Values: true/false, numbers, strings, arrays [ ... ].", "# bind = SUPER, H, focus, left | windowrule = float, app:^Calculator$", ""]
        for (section,value) in document.object ?? [] {
            if section == "$schema" { continue }
            if section == "hotkeys" || section == "window_rules" {
                let name = section == "hotkeys" ? "bind" : "windowrule"
                lines.append("# \(section == "hotkeys" ? "Bindings: modifiers, key, command, arguments; legacy JSON objects are also accepted." : "Rules: float/tile/ignore, app:regex, title:regex, role:regex, subrole:regex.")")
                for item in value.array ?? [] { lines.append(name+" = "+item.dumps(indent:nil)) }
                lines.append(""); continue
            }
            if let fields = value.object {
                lines.append(section+" {")
                for (key,child) in fields {
                    let path = [section,key]
                    if section == "curves" { lines.append("    # Curve: bezier points [[x,y],[x,y]], x 0...1/y -10...10; spring mass .001...100, stiffness .001...100000, damping .001...10000."); lines.append("    "+key+" = "+child.dumps(indent:nil)); continue }
                    renderField(child,path:path,prefix:"    ",schema:schema,lines:&lines)
                }
                lines.append("}"); lines.append("")
            } else { renderField(value,path:[section],prefix:"",schema:schema,lines:&lines); lines.append("") }
        }
        if document["hotkeys"] == nil { lines += ["# bind = ALT, Q, close"] }
        if document["window_rules"] == nil { lines += ["# windowrule = float, app:^Calculator$"] }
        return lines.joined(separator:"\n")+"\n"
    }
    private static func renderField(_ value: JSON, path: [String], prefix: String, schema: JSON, lines: inout [String]) {
        if let children = value.object {
            for (key,child) in children { renderField(child,path:path+[key],prefix:prefix,schema:schema,lines:&lines) }; return
        }
        let field = fieldSchema(path,schema:schema,root:schema)
        let bounds: String
        if let choices = field?["enum"]?.array { bounds = choices.map { $0.dumps(indent:nil) }.joined(separator:" | ") }
        else if let lower = field?["minimum"]?.double, let upper = field?["maximum"]?.double { bounds = "\(format(lower))…\(format(upper))" }
        else if field?["type"]?.string == "boolean" { bounds = "true | false" }
        else { bounds = field?["type"]?.string == "array" ? "array of values" : "string" }
        lines.append(prefix+"# "+description(path.joined(separator:"."))+"; "+bounds)
        let name = prefix.isEmpty ? path.joined(separator:".") : path.dropFirst().joined(separator:".")
        lines.append(prefix+name+" = "+value.dumps(indent:nil))
    }
    private static func format(_ number: Double) -> String { number == number.rounded() ? String(Int(number)) : String(number) }
    private static func description(_ path: String) -> String {
        let names = ["runtime.enabled":"Automatic tiling","time_scale":"Animation duration multiplier","layout.gaps_in":"Inner gap, pt","layout.gaps_out":"Outer gap, pt","appearance.border.size":"Border width, pt","focus.follow_mouse":"Focus follows mouse: 0 off, 1 on","runtime.window_resize_mode":"native preserves content scale; buffer scales the live surface","runtime.overview_hidden_windows":"Mission Control hidden windows, experimental"]
        return names[path] ?? path
    }
    public static func write(_ document: JSON, configDir: String, preserving text: String? = nil) throws {
        let output: String
        if let text {
            output = try replacingValues(in:text,with:document,configDir:configDir)
        } else { output = render(document,configDir:configDir) }
        try Data(output.utf8).write(to:url(configDir:configDir),options:.atomic)
    }
    // Preserve user comments and formatting for fields that did not change.
    private static func replacingValues(in text: String, with document: JSON, configDir: String) throws -> String {
        let old = try parse(text,configDir:configDir).document
        if old == document { return text }
        // Preserve free-standing comments. Serialized assignments are canonical, so a
        // reset or GUI edit never leaves an earlier duplicate assignment authoritative.
        let generated = Set(render(old,configDir:configDir).components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespaces) })
        var seen = Set<String>()
        let comments = text.components(separatedBy:.newlines).filter {
            let line = $0.trimmingCharacters(in:.whitespaces)
            return line.hasPrefix("#") && !generated.contains(line) && seen.insert(line).inserted
        }
        return (comments.isEmpty ? "" : comments.joined(separator:"\n")+"\n\n")+render(document,configDir:configDir)
    }
    private static func readableRecord(_ kind:String,_ text:String,ordinal:Int) throws -> JSON {
        let fields=csvFields(text)
        if kind == "windowrule" {
            guard let action=fields.first, !action.isEmpty else {throw CmdError("windowrule: expected action, app:regex")}
            var rule=JSON.object([]),match=JSON.object([])
            let actionParts=action.split(maxSplits:1,whereSeparator:\.isWhitespace).map(String.init)
            let verb=actionParts[0].lowercased()
            let on=actionParts.count<2 || !["0","false","off"].contains(actionParts[1].lowercased())
            switch verb {
            case "float":rule=rule.setting("float",.bool(on))
            case "tile":rule=rule.setting("float",.bool(false))
            case "ignore","no_anim","no_follow_mouse":rule=rule.setting(verb,.bool(on))
            default:throw CmdError("windowrule: unsupported action \(verb)")
            }
            for field in fields.dropFirst() {
                guard let colon=field.firstIndex(of:":") else {throw CmdError("windowrule: expected app:/title:/role:/subrole: pattern")}
                let rawKey=String(field[..<colon]).trimmingCharacters(in:.whitespaces).lowercased()
                let key=rawKey == "app" ? "class" : rawKey
                guard ["class","title","role","subrole"].contains(key) else {throw CmdError("windowrule: unknown match \(rawKey)")}
                let source=String(field[field.index(after:colon)...]).trimmingCharacters(in:.whitespaces)
                let pattern=(try? JSON.parse(source))?.string ?? source
                match=match.setting(key,.string(pattern))
            }
            guard match.object?.isEmpty == false else {throw CmdError("windowrule: at least one match is required")}
            return rule.setting("match",match)
        }
        guard fields.count>=3 else {throw CmdError("bind: expected MODIFIERS, KEY, COMMAND[, ARGUMENTS]")}
        var modifiers=0
        for part in fields[0].uppercased().split(whereSeparator:{ $0.isWhitespace || $0 == "+" || $0 == "|" }) {
            switch part {
            case "SUPER","CMD","COMMAND":modifiers |= 0x100
            case "ALT","OPTION":modifiers |= 0x800
            case "CTRL","CONTROL":modifiers |= 0x1000
            case "SHIFT":modifiers |= 0x200
            default:throw CmdError("bind: unknown modifier \(part)")
            }
        }
        guard modifiers & 0x1900 != 0 else {throw CmdError("bind: Command, Option or Control is required")}
        let key=fields[1].lowercased()
        let keycode:Int
        if key.hasPrefix("code:"),let code=Int(key.dropFirst(5)),(0...127).contains(code) {keycode=code}
        else if let code=keyCodes[key] {keycode=code}
        else {throw CmdError("bind: unknown key \(key); use code:0...127")}
        var command:[String]=[]
        for field in fields.dropFirst(2) {command += try commandWords(field)}
        guard !command.isEmpty else {throw CmdError("bind: command is required")}
        return .object([("id",.int(2048+ordinal)),("keycode",.int(keycode)),("modifiers",.int(modifiers)),("enabled",.bool(true)),("command",.array(command.map(JSON.string)))])
    }
    private static let keyCodes:[String:Int] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,"]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"return":36,"enter":36,"l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,"n":45,"m":46,".":47,"tab":48,"space":49,"`":50,"backspace":51,"escape":53,"esc":53,"left":123,"right":124,"down":125,"up":126,"f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111]
    private static func csvFields(_ text:String) -> [String] {
        var result:[String]=[],current="",quoted=false,escaped=false
        for char in text {
            if escaped {current.append(char);escaped=false;continue}
            if char == "\\" {current.append(char);escaped=true;continue}
            if char == "\"" {quoted.toggle();current.append(char);continue}
            if char == ",",!quoted {result.append(current.trimmingCharacters(in:.whitespaces));current=""}
            else {current.append(char)}
        }
        result.append(current.trimmingCharacters(in:.whitespaces));return result
    }
    private static func commandWords(_ text:String) throws -> [String] {
        var result:[String]=[],current="",quoted=false,escaped=false,started=false
        for char in text {
            if escaped {current.append(char);escaped=false;started=true;continue}
            if char == "\\" {escaped=true;started=true;continue}
            if char == "\"" {quoted.toggle();started=true;continue}
            if char.isWhitespace,!quoted {if started {result.append(current);current="";started=false}}
            else {current.append(char);started=true}
        }
        guard !quoted,!escaped else {throw CmdError("bind: unterminated quoted argument")}
        if started {result.append(current)}
        return result
    }
    private static func parseValue(_ source: String) throws -> JSON {
        guard !source.isEmpty else { throw CmdError("empty value") }
        if let value = try? JSON.parse(source) { return value }
        if ["yes","on"].contains(source.lowercased()) { return .bool(true) }
        if ["no","off"].contains(source.lowercased()) { return .bool(false) }
        return .string(source)
    }
    private static func stripComment(_ source: String) -> String {
        var quoted = false, escaped = false
        for index in source.indices {
            let char = source[index]
            if escaped { escaped = false; continue }
            if char == "\\", quoted { escaped = true; continue }
            if char == "\"" { quoted.toggle() }
            if char == "#", !quoted { return String(source[..<index]) }
        }
        return source
    }
    private static func set(_ root: JSON, _ components: [String], _ value: JSON) -> JSON {
        guard let head = components.first else { return value }
        return root.setting(head,set(root[head] ?? .object([]),Array(components.dropFirst()),value))
    }
    private static func merge(_ base: JSON, _ overlay: JSON) -> JSON {
        guard let fields = overlay.object else { return overlay }
        var result = base
        for (key,value) in fields { result = result.setting(key,value.object == nil ? value : merge(result[key] ?? .object([]),value)) }
        return result
    }
    private static func schemaDocument(_ configDir: String) throws -> JSON {
        let schema = try JSON.parse(Data(contentsOf:URL(fileURLWithPath:configDir+"/runtime.schema.json")))
        let runtime = schema["properties"]?["runtime"] ?? .object([])
        let props = (runtime["properties"] ?? .object([])).setting("enabled",.object([("type",.string("boolean"))])).setting("menu_bar",.object([("type",.string("boolean"))])).setting("startup_animation",.object([("type",.string("boolean"))]))
        var properties=(schema["properties"] ?? .object([])).setting("runtime",runtime.setting("properties",props))
        if let rules=properties["window_rules"],let item=rules["items"],let match=item["properties"]?["match"] {
            let patterns=(match["properties"] ?? .object([])).setting("role",.object([("type",.string("string")),("maxLength",.int(512))])).setting("subrole",.object([("type",.string("string")),("maxLength",.int(512))]))
            let updated=item.setting("properties",(item["properties"] ?? .object([])).setting("match",match.setting("properties",patterns)))
            properties=properties.setting("window_rules",rules.setting("items",updated))
        }
        return schema.setting("properties",properties)
    }
    private static func resolved(_ schema: JSON, root: JSON) -> JSON {
        guard let ref = schema["$ref"]?.string, ref.hasPrefix("#/") else { return schema }
        return ref.dropFirst(2).split(separator:"/").reduce(root) { $0[String($1)] ?? .object([]) }
    }
    private static func fieldSchema(_ path: [String], schema: JSON, root: JSON) -> JSON? {
        let node = resolved(schema,root:root)
        guard let key = path.first else { return node }
        if let choices = node["oneOf"]?.array {
            for child in choices { if let match = fieldSchema(path,schema:child,root:root) { return match } }; return nil
        }
        if let properties = node["properties"], let child = properties[key] { return fieldSchema(Array(path.dropFirst()),schema:child,root:root) }
        if let child = node["additionalProperties"], child.object != nil { return fieldSchema(Array(path.dropFirst()),schema:child,root:root) }
        return nil
    }
    private static func validate(_ value: JSON, schema: JSON, root: JSON, path: String) throws {
        let node = resolved(schema,root:root)
        func invalid() -> CmdError { CmdError("\(path): invalid value") }
        if let choices = node["oneOf"]?.array { guard choices.contains(where: { (try? validate(value,schema:$0,root:root,path:path)) != nil }) else { throw invalid() }; return }
        if let choices = node["enum"]?.array, !choices.contains(value) { throw invalid() }
        if let constant = node["const"], constant != value { throw invalid() }
        switch node["type"]?.string {
        case "boolean": guard case .bool = value else { throw invalid() }
        case "number", "integer":
            guard let number = value.double, number.isFinite, number >= (node["minimum"]?.double ?? -.infinity), number <= (node["maximum"]?.double ?? .infinity), node["type"]?.string != "integer" || number == number.rounded() else { throw invalid() }
        case "string":
            guard let string = value.string, string.count <= (node["maxLength"]?.int ?? Int.max), string.count >= (node["minLength"]?.int ?? 0) else { throw invalid() }
            if let pattern = node["pattern"]?.string, string.range(of:pattern,options:.regularExpression) == nil { throw invalid() }
        case "object":
            guard let fields = value.object else { throw invalid() }
            for key in node["required"]?.array?.compactMap(\.string) ?? [] where value[key] == nil { throw invalid() }
            for (key,child) in fields {
                guard let childSchema = fieldSchema([key],schema:node,root:root) else { throw CmdError("unknown setting \(path).\(key)") }
                try validate(child,schema:childSchema,root:root,path:path+"."+key)
            }
        case "array":
            guard let items = value.array, items.count >= (node["minItems"]?.int ?? 0), items.count <= (node["maxItems"]?.int ?? Int.max) else { throw invalid() }
            for (index,item) in items.enumerated() {
                let prefix = node["prefixItems"]?.array ?? []
                let child = index < prefix.count ? prefix[index] : node["items"] ?? .object([])
                try validate(item,schema:child,root:root,path:path+".\(index)")
            }
        default: break
        }
    }
}

/// Watches the directory as well as the file: editors may atomically replace its inode.
public final class ConfigFileWatcher {
    private let source: DispatchSourceFileSystemObject
    private let file: URL
    private var fileSource: DispatchSourceFileSystemObject?
    private var accepted: Data?
    private var work: DispatchWorkItem?
    private let queue = DispatchQueue(label:"hyprwm.config.watch",qos:.userInitiated)
    public init(url: URL, onChange: @escaping () -> Void) throws {
        file = url; accepted = Self.content(url)
        let fd = open(url.deletingLastPathComponent().path,O_EVTONLY)
        guard fd >= 0 else { throw CmdError("Cannot watch settings directory") }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:[.write,.rename,.delete,.attrib],queue:queue)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in self?.observe(onChange) }
        armFile(onChange)
        source.resume()
    }
    private static func content(_ url:URL) -> Data? {
        guard let handle=try? FileHandle(forReadingFrom:url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount:262145)
    }
    private func armFile(_ callback: @escaping () -> Void) {
        fileSource?.cancel()
        let fd = open(file.path,O_EVTONLY)
        guard fd >= 0 else { fileSource=nil; return }
        let next=DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:[.write,.rename,.delete,.attrib],queue:queue)
        next.setCancelHandler { close(fd) }
        next.setEventHandler { [weak self] in self?.observe(callback) }
        fileSource=next; next.resume()
    }
    private func observe(_ callback: @escaping () -> Void) {
        work?.cancel()
        let next=DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.armFile(callback)
            guard let data=Self.content(self.file),data != self.accepted else { return }
            self.accepted=data; callback()
        }
        work=next;queue.asyncAfter(deadline:.now()+0.065,execute:next)
    }
    deinit { source.cancel(); fileSource?.cancel(); work?.cancel() }
}
