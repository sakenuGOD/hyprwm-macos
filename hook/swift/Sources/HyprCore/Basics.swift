// Shared types: frame, ordered dictionary (Python dict preserves insertion order, which determines
// the first front window, neighbour/min ties, etc.), and Python round() rounding.
import Foundation

public struct Rect: Equatable, CustomStringConvertible {
    public var x, y, w, h: Double
    public init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    public init?(_ a: [Double]) { guard a.count >= 4 else { return nil }; self.init(a[0], a[1], a[2], a[3]) }
    public var arr: [Double] { [x, y, w, h] }
    /// max(abs(p - q) for p, q in zip(a, b))
    public func maxDiff(_ o: Rect) -> Double { zip(arr, o.arr).map { abs($0 - $1) }.max()! }
    /// Python tuple repr: (1.0, 2.0, 3.0, 4.0)
    public var description: String { "(" + arr.map(pyFloat).joined(separator: ", ") + ")" }
    public var json: JSON { .array(arr.map { .double($0) }) }
}

/// Python round(): nearest, with ties to even.
@inline(__always) public func pyRound(_ v: Double) -> Double { v.rounded(.toNearestOrEven) }

/// Insertion-ordered dictionary (like Python dict): overwriting a key preserves its position.
public struct OrderedMap<K: Hashable, V>: Sequence {
    public private(set) var keys: [K] = []
    public private(set) var dict: [K: V] = [:]
    public init() {}
    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    public subscript(k: K) -> V? {
        get { dict[k] }
        set {
            if let v = newValue {
                if dict.updateValue(v, forKey: k) == nil { keys.append(k) }
            } else if dict.removeValue(forKey: k) != nil {
                keys.removeAll { $0 == k }
            }
        }
    }
    @discardableResult public mutating func removeValue(forKey k: K) -> V? {
        let v = dict.removeValue(forKey: k)
        if v != nil { keys.removeAll { $0 == k } }
        return v
    }
    public mutating func removeAll() { keys = []; dict = [:] }
    public func contains(_ k: K) -> Bool { dict[k] != nil }
    public var values: [V] { keys.map { dict[$0]! } }
    public func makeIterator() -> AnyIterator<(K, V)> {
        var i = 0
        let ks = keys, d = dict
        return AnyIterator {
            guard i < ks.count else { return nil }
            defer { i += 1 }
            return (ks[i], d[ks[i]]!)
        }
    }
}

/// Python list string: [1, 2, 3]
public func pyList(_ a: [Int]) -> String { "[" + a.map(String.init).joined(separator: ", ") + "]" }
/// Python integer tuple string: (1, 2)
public func pyIntTuple(_ a: [Double]) -> String {
    "(" + a.map { String(Int(pyRound($0))) }.joined(separator: ", ") + (a.count == 1 ? ",)" : ")")
}
public func pyFloatTuple(_ a: [Double]) -> String { "(" + a.map(pyFloat).joined(separator: ", ") + ")" }
public func pyFloatList(_ a: [Double]) -> String { "[" + a.map(pyFloat).joined(separator: ", ") + "]" }
