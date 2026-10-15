import Foundation
import CoreFoundation
import Darwin

/// The editable preferences document. JSON is used only as the in-memory representation.
public enum TextConfig {
    public struct Issue: CustomStringConvertible {
        public let line: Int
        public let message: String
        public var description: String { "Строка \(line): \(message)" }
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
        let data = try Data(contentsOf: file)
        guard data.count <= 262144, let text = String(data: data, encoding: .utf8) else { throw CmdError("hyprwm.conf: ожидается UTF-8, не больше 256 КБ") }
        return try parse(text, configDir: configDir)
    }
    public static func parse(_ text: String, configDir: String) throws -> Result {
        let schema = try schemaDocument(configDir)
        var result = JSON.object([]), issues: [Issue] = [], sections: [String] = []
        var origins: [String:Int] = [:]
        for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = offset + 1, source = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if source.isEmpty { continue }
            if source == "}" {
                if sections.isEmpty { issues.append(.init(line: line, message: "лишняя закрывающая скобка")) } else { sections.removeLast() }
                continue
            }
            if source.hasSuffix("{"), !source.contains("=") {
                let name = String(source.dropLast()).trimmingCharacters(in: .whitespaces)
                guard name.range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else { issues.append(.init(line: line, message: "неверное имя раздела")); continue }
                sections.append(name); continue
            }
            guard let separator = source.firstIndex(of: "=") else { issues.append(.init(line: line, message: "ожидается key = value")); continue }
            let key = source[..<separator].trimmingCharacters(in: .whitespaces)
            let rawValue = source[source.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            let path = (sections + [key]).joined(separator: ".")
            do {
                if sections.isEmpty && (key == "bind" || key == "windowrule") {
                    let value = try parseValue(rawValue)
                    let target = key == "bind" ? "hotkeys" : "window_rules"
                    guard value.object != nil else { throw CmdError("\(key): ожидается объект {…}") }
                    let itemSchema = schema["properties"]?[target]?["items"] ?? .object([])
                    try validate(value, schema: itemSchema, root: schema, path: key)
                    let entries = (result[target]?.array ?? []) + [value]
                    result = result.setting(target, .array(entries)); origins[target] = line; continue
                }
                let components = path.split(separator: ".").map(String.init)
                guard let field = fieldSchema(components, schema: schema, root: schema) else { throw CmdError("неизвестный параметр \(path)") }
                let value = try parseValue(rawValue)
                try validate(value, schema: field, root: schema, path: path)
                result = set(result, components, value); origins[path] = line
            } catch { issues.append(.init(line: line, message: String(describing: error))) }
        }
        if !sections.isEmpty { issues.append(.init(line: max(1,text.components(separatedBy:.newlines).count), message: "раздел не закрыт скобкой }")) }
        // Semantic dependencies are checked as independent groups so one bad animation
        // or rule cannot discard unrelated valid gap, focus or border edits.
        let base = try HyprConfig.load(configDir: configDir, rebuild: false, timeScale: 1)
        var accepted = JSON.object([])
        let groups = result.object ?? []
        let ordered = groups.sorted { a,b in (a.0 == "curves" ? 0 : a.0 == "animations" ? 2 : 1) < (b.0 == "curves" ? 0 : b.0 == "animations" ? 2 : 1) }
        for (name, value) in ordered {
            if name == "runtime" { accepted = accepted.setting(name,value); continue }
            if let children = value.object, name != "curves" {
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
        return .object([("version",.int(1)),("time_scale",.int(1)),("runtime",.object([("enabled",.bool(true)),("menu_bar",.bool(true)),("startup_animation",.bool(false)),("window_resize_mode",.string("native")),("overview_hidden_windows",.bool(false)),("prehide",.bool(false)),("hold_max_ms",.int(200)),("pointer_focus_pause_ms",.int(0)),("capture_sampling",.bool(false))])),("layout",layout),("appearance",appearance),("focus",focus),("drag",.object([("mode",.string("swap")),("throw_distance_pt",.int(32)),("direction_ratio",.double(1.25))])),("curves",raw["curves"] ?? .object([])),("animations",animations)])
    }
    public static func render(_ document: JSON, configDir: String) -> String {
        let schema = (try? schemaDocument(configDir)) ?? .object([])
        var lines = ["# HyprWM — единственный файл настроек. Изменения применяются после сохранения.","# Разделы: name { … }. Значения: true/false, числа, строки, массивы [ … ].", "# bind и windowrule повторяются; значение — объект с параметрами действия/правила.", ""]
        for (section,value) in document.object ?? [] {
            if section == "$schema" { continue }
            if section == "hotkeys" || section == "window_rules" {
                let name = section == "hotkeys" ? "bind" : "windowrule"
                lines.append("# \(section == "hotkeys" ? "Горячие клавиши: id, keycode 0…127, modifiers (Carbon), command [аргументы]." : "Правила: match.class/title — регулярное выражение; float/ignore/no_anim/no_follow_mouse — true/false.")")
                for item in value.array ?? [] { lines.append(name+" = "+item.dumps(indent:nil)) }
                lines.append(""); continue
            }
            if let fields = value.object {
                lines.append(section+" {")
                for (key,child) in fields {
                    let path = [section,key]
                    if section == "curves" { lines.append("    # Кривая: bezier с points [[x,y],[x,y]] или spring с mass/stiffness/damping."); lines.append("    "+key+" = "+child.dumps(indent:nil)); continue }
                    renderField(child,path:path,prefix:"    ",schema:schema,lines:&lines)
                }
                lines.append("}"); lines.append("")
            } else { renderField(value,path:[section],prefix:"",schema:schema,lines:&lines); lines.append("") }
        }
        if document["hotkeys"] == nil { lines += ["# bind = {\"id\":0,\"keycode\":12,\"modifiers\":2048,\"enabled\":true,\"command\":[\"close\"]}"] }
        if document["window_rules"] == nil { lines += ["# windowrule = {\"match\":{\"class\":\"^Calculator$\"},\"float\":true}"] }
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
        else { bounds = field?["type"]?.string == "array" ? "массив значений" : "строка" }
        lines.append(prefix+"# "+description(path.joined(separator:"."))+"; "+bounds)
        let name = prefix.isEmpty ? path.joined(separator:".") : path.dropFirst().joined(separator:".")
        lines.append(prefix+name+" = "+value.dumps(indent:nil))
    }
    private static func format(_ number: Double) -> String { number == number.rounded() ? String(Int(number)) : String(number) }
    private static func description(_ path: String) -> String {
        let names = ["runtime.enabled":"Автоматический тайлинг","time_scale":"Множитель длительности анимаций","layout.gaps_in":"Отступ между окнами, pt","layout.gaps_out":"Отступ от края экрана, pt","appearance.border.size":"Толщина рамки, pt","focus.follow_mouse":"Фокус за мышью: 0 выключен, 1 включён","runtime.window_resize_mode":"native — края без растяжения, buffer — масштабирование содержимого","runtime.overview_hidden_windows":"Mission Control: экспериментальная функция"]
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
    private static func parseValue(_ source: String) throws -> JSON {
        guard !source.isEmpty else { throw CmdError("пустое значение") }
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
        return schema.setting("properties",(schema["properties"] ?? .object([])).setting("runtime",runtime.setting("properties",props)))
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
        func invalid() -> CmdError { CmdError("\(path): недопустимое значение") }
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
                guard let childSchema = fieldSchema([key],schema:node,root:root) else { throw CmdError("неизвестный параметр \(path).\(key)") }
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
        file = url; accepted = try? Data(contentsOf:url)
        let fd = open(url.deletingLastPathComponent().path,O_EVTONLY)
        guard fd >= 0 else { throw CmdError("Не удалось наблюдать папку настроек") }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:[.write,.rename,.delete,.attrib],queue:queue)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in self?.observe(onChange) }
        armFile(onChange)
        source.resume()
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
            guard let data=try? Data(contentsOf:self.file),data != self.accepted else { return }
            self.accepted=data; callback()
        }
        work=next;queue.asyncAfter(deadline:.now()+0.065,execute:next)
    }
    deinit { source.cancel(); fileSource?.cancel(); work?.cancel() }
}
