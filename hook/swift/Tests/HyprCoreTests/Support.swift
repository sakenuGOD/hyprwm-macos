// Shared test support: fixtures (tools/gen_fixtures.py generates them from reference Python) and JSON
// comparison with numeric tolerance.
import Foundation
@testable import HyprCore
import XCTest

enum Fx {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static func load(_ name: String) throws -> JSON {
        try JSON.parse(Data(contentsOf: dir.appendingPathComponent(name)))
    }
    static func config() throws -> HyprConfig {
        try HyprConfig.load(configDir: dir.path, rebuild: false, timeScale: 1.2)
    }
}

/// First JSON mismatch (numeric tolerance, int == float), or nil.
func jsonDiff(_ a: JSON, _ b: JSON, _ path: String = "$", tol: Double = 1e-9) -> String? {
    switch (a, b) {
    case (.int, _), (.double, _):
        guard let x = a.double, let y = b.double else { return "\(path): \(a.dumps()) != \(b.dumps())" }
        if x.isNaN && y.isNaN { return nil }
        return abs(x - y) <= tol * max(1, abs(x), abs(y)) ? nil : "\(path): \(pyFloat(x)) != \(pyFloat(y))"
    case let (.array(x), .array(y)):
        if x.count != y.count { return "\(path): length \(x.count) != \(y.count): \(a.dumps()) vs \(b.dumps())" }
        for i in x.indices { if let d = jsonDiff(x[i], y[i], "\(path)[\(i)]", tol: tol) { return d } }
        return nil
    case let (.object(x), .object(y)):
        let kx = Set(x.map(\.0)), ky = Set(y.map(\.0))
        if kx != ky { return "\(path): keys \(kx.sorted()) != \(ky.sorted())" }
        for (k, v) in x { if let d = jsonDiff(v, b[k]!, "\(path).\(k)", tol: tol) { return d } }
        return nil
    default:
        return a == b ? nil : "\(path): \(a.dumps()) != \(b.dumps())"
    }
}

extension Rect {
    static func j(_ j: JSON?) -> Rect? { j?.array.flatMap { Rect($0.compactMap(\.double)) } }
}
