import Foundation

struct OpacityAtom: Equatable {
    var value=1.0
    var overridden=false
    func apply(_ base: Double) -> Double { overridden ? value : value*base }
}
struct WindowPolicy {
    var active=OpacityAtom(), inactive=OpacityAtom(), fullscreen=OpacityAtom()
    var noAnimation=false, noPointerFocus=false
}
struct PropertyBinding {
    let pid: Int
    let birth: String
    var values: [String:JSON]
}

enum WindowProperties {
    private static let regexCache:NSCache<NSString,NSRegularExpression> = {
        let cache=NSCache<NSString,NSRegularExpression>();cache.countLimit=256;return cache
    }()
    static func regex(_ pattern:String) throws -> (NSRegularExpression,Bool) {
        let negative=pattern.hasPrefix("negative:"), body=negative ? String(pattern.dropFirst(9)) : pattern
        let key=body as NSString
        if let compiled=regexCache.object(forKey:key) { return (compiled,negative) }
        let compiled=try NSRegularExpression(pattern:"\\A(?:"+body+")\\z")
        regexCache.setObject(compiled,forKey:key);return (compiled,negative)
    }
    static func opacity(_ value: JSON) throws -> [OpacityAtom] {
        if let number=value.double {
            guard number.isFinite && (0...1).contains(number) else { throw CmdError("opacity: expected 0..1") }
            return Array(repeating:OpacityAtom(value:number),count:3)
        }
        guard let text=value.string else { throw CmdError("opacity: expected scalar or alpha/override string") }
        var tokens=text.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.first == "opacity" { tokens.removeFirst() }
        var atoms: [OpacityAtom]=[]
        for token in tokens {
            if token == "override" {
                guard !atoms.isEmpty, !atoms[atoms.count-1].overridden else { throw CmdError("opacity override must follow an alpha") }
                atoms[atoms.count-1].overridden=true
            } else {
                guard atoms.count < 3, let number=Double(token), number.isFinite, (0...1).contains(number) else { throw CmdError("opacity: expected one to three alpha values") }
                atoms.append(OpacityAtom(value:number))
            }
        }
        guard !atoms.isEmpty else { throw CmdError("opacity: expected alpha") }
        if atoms.count == 1 { return [atoms[0],atoms[0],atoms[0]] }
        if atoms.count == 2 { atoms.append(OpacityAtom()) }
        return atoms
    }
    static func validateRules(_ rules: JSON) throws -> [JSON] {
        guard let array=rules.array, array.count <= 128 else { throw CmdError("window_rules: expected at most 128 rules") }
        let allowed: Set<String>=["name","enabled","match","float","ignore","opacity","no_anim","no_follow_mouse"]
        for rule in array {
            guard let fields=rule.object, Set(fields.map(\.0)).isSubset(of:allowed), let match=rule["match"]?.object,
                  !match.isEmpty, Set(match.map(\.0)).isSubset(of:["class","title","role","subrole"]) else { throw CmdError("window_rules: invalid keys or match") }
            for (key,pattern) in match {
                guard let pattern=pattern.string, pattern.count <= 512 else { throw CmdError("window_rules.\(key): expected bounded regex") }
                do { _=try regex(pattern) } catch { throw CmdError("window_rules.\(key): invalid regex") }
            }
            for key in ["enabled","float","ignore","no_anim","no_follow_mouse"] {
                if let value=rule[key], case .bool=value {} else if rule[key] != nil { throw CmdError("window_rules.\(key): expected boolean") }
            }
            if let name=rule["name"], name.string == nil || name.string!.count > 128 { throw CmdError("window_rules.name: expected bounded string") }
            if let alpha=rule["opacity"] { _=try opacity(alpha) }
        }
        return array
    }
    static func matches(_ rule: JSON, _ window: WinInfo) -> Bool {
        if rule["enabled"]?.truthy == false { return false }
        guard let match=rule["match"]?.object, !match.isEmpty else { return false }
        for (key,value) in match {
            guard ["class","title","role","subrole"].contains(key), let expression=value.string,
                  let (regex,negative)=try? regex(expression) else { return false }
            let text: String
            switch key {
            case "class": text=window.owner
            case "title": text=window.name
            case "role": text=window.role
            default: text=window.subrole
            }
            // Unknown AX metadata cannot satisfy a negative match either.
            if (key == "role" || key == "subrole") && text.isEmpty { return false }
            if (regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) != nil) == negative { return false }
        }
        return true
    }
}

extension WM {
    func ignored(_ window: WinInfo) -> Bool {
        var ignored=false
        for rule in cfg.raw["window_rules"]?.array ?? [] where WindowProperties.matches(rule,window) {
            if let value=rule["ignore"] { ignored=value.truthy }
        }
        return ignored
    }
    func windowPolicy(_ window: WinInfo) -> WindowPolicy {
        var result=WindowPolicy()
        for rule in cfg.raw["window_rules"]?.array ?? [] where WindowProperties.matches(rule,window) {
            if let value=rule["opacity"], let atoms=try? WindowProperties.opacity(value) { result.active=atoms[0]; result.inactive=atoms[1]; result.fullscreen=atoms[2] }
            if let value=rule["no_anim"] { result.noAnimation=value.truthy }
            if let value=rule["no_follow_mouse"] { result.noPointerFocus=value.truthy }
        }
        if let explicit=propertyOverrides[window.wid] {
            if explicit.pid != window.pid || sys.processBirth(window.pid) != explicit.birth { propertyOverrides[window.wid]=nil }
            else {
                for (name,value) in explicit.values {
                    switch name {
                    case "no_anim": result.noAnimation=value.truthy
                    case "no_follow_mouse": result.noPointerFocus=value.truthy
                    case "opacity": result.active=OpacityAtom(value:value["value"]?.double ?? 1,overridden:value["overridden"]?.truthy ?? false)
                    case "opacity_inactive": result.inactive=OpacityAtom(value:value["value"]?.double ?? 1,overridden:value["overridden"]?.truthy ?? false)
                    case "opacity_fullscreen": result.fullscreen=OpacityAtom(value:value["value"]?.double ?? 1,overridden:value["overridden"]?.truthy ?? false)
                    default: break
                    }
                }
            }
        }
        return result
    }
    func propertyCommand(_ argv: [String], _ window: WinInfo) throws -> String {
        guard argv.count == 3, !sys.protectedProcess(window.pid), sys.winPidLevel(window.wid).pid == window.pid,
              let birth=sys.processBirth(window.pid) else { throw CmdError("setprop: verified window, property and value required") }
        let name=argv[1], raw=argv[2], canonical=name.hasSuffix("_override") ? String(name.dropLast(9)) : name
        let alphaKeys: Set<String>=["opacity","opacity_inactive","opacity_fullscreen"], boolKeys: Set<String>=["no_anim","no_follow_mouse"]
        guard alphaKeys.contains(canonical) || boolKeys.contains(canonical) else { throw CmdError("setprop: unsupported property") }
        var binding=propertyOverrides[window.wid] ?? PropertyBinding(pid:window.pid,birth:birth,values:[:])
        if binding.pid != window.pid || binding.birth != birth { binding=PropertyBinding(pid:window.pid,birth:birth,values:[:]) }
        if raw == "unset" { binding.values[canonical]=nil }
        else if boolKeys.contains(canonical) {
            guard ["true","false","toggle"].contains(raw) else { throw CmdError("setprop: expected true/false/toggle/unset") }
            let policy=windowPolicy(window), current=canonical == "no_anim" ? policy.noAnimation : policy.noPointerFocus
            binding.values[canonical] = .bool(raw == "toggle" ? !current : raw == "true")
        } else {
            let policy=windowPolicy(window)
            var atom=canonical == "opacity" ? policy.active : canonical == "opacity_inactive" ? policy.inactive : policy.fullscreen
            if name.hasSuffix("_override") {
                guard raw == "true" || raw == "false" else { throw CmdError("setprop: opacity override requires boolean") }; atom.overridden=raw == "true"
            } else { atom.value=try WindowProperties.opacity(.string(raw))[0].value }
            binding.values[canonical] = .object([("value",.double(atom.value)),("overridden",.bool(atom.overridden))])
        }
        propertyOverrides[window.wid]=binding
        return "property applied"
    }
}
