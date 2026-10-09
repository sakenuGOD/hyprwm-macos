// JSON с сохранением порядка ключей и различием int/float — чтобы файлы состояния
// (hyprwm.state.json, minsize_app.json) и ответ status были в том же виде, что пишет Python
// (json.dump(indent=1) / json.dumps(ensure_ascii=False)), а Python-демон читал их без отличий.
import Foundation

public enum JSON: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    public static func == (l: JSON, r: JSON) -> Bool {
        switch (l, r) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.int(a), .double(b)), let (.double(b), .int(a)): return Double(a) == b   // как в Python: 1 == 1.0
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            guard a.count == b.count else { return false }
            let db = Dictionary(b, uniquingKeysWith: { x, _ in x })
            return a.allSatisfy { db[$0.0] == $0.1 }
        default: return false
        }
    }

    // ── доступ ──────────────────────────────────────────────────────────
    public subscript(key: String) -> JSON? {
        if case let .object(kv) = self { return kv.first(where: { $0.0 == key })?.1 }
        return nil
    }
    public var double: Double? {
        switch self { case let .int(i): return Double(i); case let .double(d): return d; default: return nil }
    }
    public var int: Int? {
        switch self { case let .int(i): return i; case let .double(d): return Int(d); default: return nil }
    }
    public var string: String? { if case let .string(s) = self { return s }; return nil }
    public var array: [JSON]? { if case let .array(a) = self { return a }; return nil }
    public var object: [(String, JSON)]? { if case let .object(o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }
    /// Истинность по правилам Python (bool(x)).
    public var truthy: Bool {
        switch self {
        case .null: return false
        case let .bool(b): return b
        case let .int(i): return i != 0
        case let .double(d): return d != 0
        case let .string(s): return !s.isEmpty
        case let .array(a): return !a.isEmpty
        case let .object(o): return !o.isEmpty
        }
    }

    // ── разбор ──────────────────────────────────────────────────────────
    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func parse(_ s: String) throws -> JSON { try parse(Array(s.utf8)) }
    public static func parse(_ data: Data) throws -> JSON { try parse([UInt8](data)) }

    public static func parse(_ b: [UInt8]) throws -> JSON {
        var p = Parser(b: b)
        p.ws()
        let v = try p.value()
        p.ws()
        if p.i != b.count { throw ParseError(description: "лишние символы на позиции \(p.i)") }
        return v
    }

    private struct Parser {
        let b: [UInt8]
        var i = 0
        mutating func ws() { while i < b.count, [0x20, 0x09, 0x0a, 0x0d].contains(b[i]) { i += 1 } }
        func err(_ m: String) -> ParseError { ParseError(description: "JSON: \(m) на позиции \(i)") }
        mutating func lit(_ s: String, _ v: JSON) throws -> JSON {
            let u = Array(s.utf8)
            guard i + u.count <= b.count, Array(b[i..<i + u.count]) == u else { throw err("ожидалось \(s)") }
            i += u.count
            return v
        }
        mutating func value() throws -> JSON {
            guard i < b.count else { throw err("конец данных") }
            switch b[i] {
            case UInt8(ascii: "{"):
                i += 1; ws()
                var kv: [(String, JSON)] = []
                if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(kv) }
                while true {
                    ws()
                    guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw err("ожидался ключ") }
                    let k = try str()
                    ws()
                    guard i < b.count, b[i] == UInt8(ascii: ":") else { throw err("ожидалось :") }
                    i += 1; ws()
                    let v = try value()
                    if let j = kv.firstIndex(where: { $0.0 == k }) { kv[j].1 = v } else { kv.append((k, v)) }
                    ws()
                    guard i < b.count else { throw err("конец объекта") }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "}") { i += 1; return .object(kv) }
                    throw err("ожидалось , или }")
                }
            case UInt8(ascii: "["):
                i += 1; ws()
                var a: [JSON] = []
                if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                while true {
                    ws()
                    a.append(try value())
                    ws()
                    guard i < b.count else { throw err("конец массива") }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                    throw err("ожидалось , или ]")
                }
            case UInt8(ascii: "\""): return .string(try str())
            case UInt8(ascii: "t"): return try lit("true", .bool(true))
            case UInt8(ascii: "f"): return try lit("false", .bool(false))
            case UInt8(ascii: "n"): return try lit("null", .null)
            case UInt8(ascii: "N"): return try lit("NaN", .double(.nan))
            case UInt8(ascii: "I"): return try lit("Infinity", .double(.infinity))
            default: return try num()
            }
        }
        mutating func num() throws -> JSON {
            let s = i
            var isFloat = false
            if i < b.count, b[i] == UInt8(ascii: "-") {
                i += 1
                if i < b.count, b[i] == UInt8(ascii: "I") { _ = try lit("Infinity", .null); return .double(-.infinity) }
            }
            while i < b.count {
                let c = b[i]
                if c >= 0x30 && c <= 0x39 { i += 1; continue }
                if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") ||
                    c == UInt8(ascii: "+") || c == UInt8(ascii: "-") { isFloat = true; i += 1; continue }
                break
            }
            let t = String(decoding: b[s..<i], as: UTF8.self)
            if !isFloat, let v = Int(t) { return .int(v) }
            if let d = Double(t) { return .double(d) }
            throw err("неверное число \(t)")
        }
        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= b.count, let v = UInt32(String(decoding: b[i..<i + 4], as: UTF8.self), radix: 16)
            else { throw err("неверный \\u") }
            i += 4
            return v
        }
        mutating func str() throws -> String {
            i += 1
            var out = [UInt8]()
            while true {
                guard i < b.count else { throw err("незакрытая строка") }
                let c = b[i]
                if c == UInt8(ascii: "\"") { i += 1; break }
                if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
                i += 1
                guard i < b.count else { throw err("обрыв escape") }
                let e = b[i]; i += 1
                switch e {
                case UInt8(ascii: "n"): out.append(0x0a)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0d)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0c)
                case UInt8(ascii: "u"):
                    var cp = try hex4()
                    if cp >= 0xd800 && cp < 0xdc00, i + 6 <= b.count, b[i] == UInt8(ascii: "\\"),
                       b[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let lo = try hex4()
                        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00)
                    }
                    out.append(contentsOf: Array(String(Character(Unicode.Scalar(cp) ?? "\u{fffd}")).utf8))
                default: out.append(e)   // \" \\ \/
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }

    // ── вывод (как json.dumps в Python) ─────────────────────────────────
    /// indent == nil — в одну строку с разделителями ", " и ": "; indent == n — как json.dump(indent=n).
    public func dumps(indent: Int? = nil, ensureASCII: Bool = true) -> String {
        var o = ""
        write(&o, indent: indent, level: 0, ascii: ensureASCII)
        return o
    }

    private func write(_ o: inout String, indent: Int?, level: Int, ascii: Bool) {
        switch self {
        case .null: o += "null"
        case let .bool(b): o += b ? "true" : "false"
        case let .int(i): o += String(i)
        case let .double(d): o += pyFloat(d)
        case let .string(s): o += JSON.quote(s, ascii: ascii)
        case let .array(a):
            if a.isEmpty { o += "[]"; return }
            o += "["
            for (k, v) in a.enumerated() {
                if k > 0 { o += indent == nil ? ", " : "," }
                if let n = indent { o += "\n" + String(repeating: " ", count: n * (level + 1)) }
                v.write(&o, indent: indent, level: level + 1, ascii: ascii)
            }
            if let n = indent { o += "\n" + String(repeating: " ", count: n * level) }
            o += "]"
        case let .object(kv):
            if kv.isEmpty { o += "{}"; return }
            o += "{"
            for (k, (key, v)) in kv.enumerated() {
                if k > 0 { o += indent == nil ? ", " : "," }
                if let n = indent { o += "\n" + String(repeating: " ", count: n * (level + 1)) }
                o += JSON.quote(key, ascii: ascii) + ": "
                v.write(&o, indent: indent, level: level + 1, ascii: ascii)
            }
            if let n = indent { o += "\n" + String(repeating: " ", count: n * level) }
            o += "}"
        }
    }

    static func quote(_ s: String, ascii: Bool) -> String {
        var o = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            case "\u{08}": o += "\\b"
            case "\u{0c}": o += "\\f"
            default:
                if u.value < 0x20 || (ascii && u.value > 0x7e) {
                    if u.value > 0xffff {
                        let v = u.value - 0x10000
                        o += String(format: "\\u%04x\\u%04x", 0xd800 + (v >> 10), 0xdc00 + (v & 0x3ff))
                    } else {
                        o += String(format: "\\u%04x", u.value)
                    }
                } else {
                    o.unicodeScalars.append(u)
                }
            }
        }
        return o + "\""
    }
}

/// repr(float) в Python: кратчайшее представление, целые — с «.0».
public func pyFloat(_ d: Double) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
    var s = "\(d)"
    if let e = s.firstIndex(of: "e") {                     // Swift: 1e-05 / 1e+16 — как Python
        let mant = s[..<e], ex = s[s.index(after: e)...]
        var exs = String(ex)
        let sign = exs.hasPrefix("-") ? "-" : "+"
        if exs.hasPrefix("-") || exs.hasPrefix("+") { exs.removeFirst() }
        if exs.count < 2 { exs = "0" + exs }
        var m = String(mant)
        if m.hasSuffix(".0") { m.removeLast(2) }
        s = m + "e" + sign + exs
    }
    return s
}

/// str(x) для числа так, как его напечатал бы Python (int — без точки).
public func pyNum(_ j: JSON) -> String {
    switch j {
    case let .int(i): return String(i)
    case let .double(d): return pyFloat(d)
    default: return j.dumps()
    }
}
