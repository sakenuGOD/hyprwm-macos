import Foundation
import CoreFoundation
import Darwin
import HyprCore

/// Publishes chord overrides for the native watcher without rebuilding Lua actions.
/// Calls are serialized; the first observed document remains the reset baseline.
enum NativeHotkeys {
    private static let lock = NSLock()
    private static var baseline: Data?
    private static var accepted: Data?
    private static var baselineRows: [[String: Any]]?
    private static var boundPath: String?
    private static let limit = 262_144

    private static func fail(_ message: String) -> NSError {
        NSError(domain: "HyprWM.NativeHotkeys", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func ownedData(_ file: String) throws -> (Data, stat) {
        let fd = Darwin.open(file, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw fail("Cannot read owned hotkey document: \(file)") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o022) == 0, info.st_size >= 0, info.st_size <= limit else {
            Darwin.close(fd); throw fail("Unsafe or oversized hotkey document")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw fail("Oversized hotkey document") }
        return (data, info)
    }
    static func apply(configDir: String, bindingsPath: String = "/tmp/hyprkeys.json") throws {
        let path = bindingsPath
        lock.lock(); defer { lock.unlock() }
        let parsed = try TextConfig.read(configDir: configDir).document
        let runtime = Data(parsed.dumps(ensureASCII: false).utf8)
        guard let document = try JSONSerialization.jsonObject(with: runtime) as? [String: Any] else { throw fail("Invalid hotkey document") }
        let overrides: [[String: Any]]
        if let value = document["hotkeys"] {
            guard let rows = value as? [[String: Any]], rows.count <= 256 else { throw fail("Invalid hotkey override list") }
            overrides = rows
        } else { overrides = [] }
        // A fresh startup without overrides preserves the complete existing file byte-for-byte.
        if overrides.isEmpty && baseline == nil { return }
        if let bound = boundPath, bound != path { throw fail("Hotkey publisher baseline path changed") }
        let (current, info) = try ownedData(path)
        if baseline == nil {
            guard let rows = try JSONSerialization.jsonObject(with: current) as? [[String: Any]], rows.count <= 4096 else {
                throw fail("Invalid native hotkey baseline")
            }
            baseline = current; accepted = current; baselineRows = rows; boundPath = path
        }
        guard current == accepted, let original = baseline, var rows = baselineRows else {
            throw fail("Hotkey metadata changed externally; refusing to overwrite it")
        }
        var edited = Set<Int>()
        for item in overrides {
            guard Set(item.keys).isSubset(of: ["id", "command", "keycode", "modifiers", "enabled"]),
                  let id = integer(item["id"]), id >= 0, id <= 4095 else { throw fail("Invalid hotkey identity") }
            let index: Int
            if let raw = item["command"] {
                guard let command = raw as? [String], !command.isEmpty, command.count <= 32,
                      command.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 512 }) else { throw fail("Invalid hotkey command identity") }
                let matches = rows.indices.filter { rows[$0]["cmd"] as? [String] == command }
                if let exact=matches.first(where: { $0 == id && !edited.contains($0) }) ?? matches.first(where: { !edited.contains($0) }) {
                    index=exact
                } else {
                    guard rows.count < 4096,integer(item["keycode"]) != nil,integer(item["modifiers"]) != nil else {throw fail("New binding requires keycode and modifiers")}
                    index=rows.count
                    rows.append(["cmd":command,"keycode":0,"mods":0x100,"enabled":true,"repeat":false,"desc":command.joined(separator:" ")])
                }
            } else { index = id }
            guard rows.indices.contains(index), edited.insert(index).inserted,
                  rows[index]["event"] as? String != "wheel" else { throw fail("Stale, repeated or wheel hotkey override") }
            if item["keycode"] != nil {
                guard let key = integer(item["keycode"]), (0...127).contains(key) else { throw fail("Invalid hotkey keycode") }
                rows[index]["keycode"] = key
            }
            if item["modifiers"] != nil {
                guard let mods = integer(item["modifiers"]), mods >= 0, mods & ~0x1b00 == 0, mods & 0x1900 != 0 else {
                    throw fail("Hotkey requires a supported Command/Option/Control chord")
                }
                rows[index]["mods"] = mods
            }
            if item["enabled"] != nil {
                guard let enabled = boolean(item["enabled"]) else { throw fail("Invalid hotkey enabled value") }
                rows[index]["enabled"] = enabled
            }
        }
        var chords = Set<String>()
        for row in rows where row["event"] as? String != "wheel" && boolean(row["enabled"]) != false {
            guard let key = integer(row["keycode"]), (0...127).contains(key),
                  let mods = integer(row["mods"]), mods >= 0, mods & ~0x1b00 == 0,
                  chords.insert("\(key):\(mods)").inserted else { throw fail("Duplicate or invalid enabled hotkey chord") }
        }
        let candidate = overrides.isEmpty ? original : try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        if candidate == current { return }
        guard candidate.count <= limit else { throw fail("Oversized updated hotkey document") }
        let temporary = path + ".native-" + UUID().uuidString
        let fd = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, info.st_mode & 0o777)
        guard fd >= 0 else { throw fail("Cannot create exclusive hotkey update") }
        defer { Darwin.unlink(temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: candidate); try handle.synchronize(); try handle.close()
        let (fresh, freshInfo) = try ownedData(path)
        guard fresh == current, freshInfo.st_dev == info.st_dev, freshInfo.st_ino == info.st_ino,
              Darwin.rename(temporary, path) == 0 else { throw fail("Hotkey document changed before atomic publication") }
        accepted = candidate
    }
}
