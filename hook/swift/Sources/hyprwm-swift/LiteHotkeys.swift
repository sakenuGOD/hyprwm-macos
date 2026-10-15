import Carbon
import Foundation
import HyprCore

/// RegisterEventHotKey is public and requires neither injection nor Input
/// Monitoring. Text config overrides use the existing Carbon modifier schema.
final class LiteHotkeys {
    struct Binding {
        var key: UInt32, modifiers: UInt32, command: String, enabled = true
    }
    private var registrations: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var commands: [UInt32: String] = [:]
    private(set) var metadata: JSON = .array([])
    private let action: (String) -> Void
    private let signature: OSType = 0x48594c54 // HYLT
    private(set) var conflicts = 0
    init(configDir: String, action: @escaping (String) -> Void) throws {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<LiteHotkeys>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == owner.signature, let command = owner.commands[identifier.id] else { return OSStatus(eventNotHandledErr) }
            owner.action(command); return noErr
        }, 1, &event, context, &handler)
        guard result == noErr else { throw CmdError("public hotkey event handler unavailable (\(result))") }
        try reload(configDir: configDir)
    }
    deinit { close() }
    static var defaults: [Binding] {
        let option: UInt32 = 0x0800, shift: UInt32 = 0x0200, control: UInt32 = 0x1000
        var rows = [Binding(key: 35, modifiers: option|control, command: "panic-toggle"),
                    Binding(key: 13, modifiers: option, command: "hide"),
                    Binding(key: 13, modifiers: option|shift, command: "unhide"),
                    Binding(key: 3, modifiers: option, command: "fullscreen"),
                    Binding(key: 3, modifiers: option|control, command: "float"),
                    Binding(key: 36, modifiers: option|control, command: "togglesplit"),
                    Binding(key: 36, modifiers: option|shift, command: "fullscreen 1"),
                    Binding(key: 12, modifiers: option, command: "close"),
                    Binding(key: 11, modifiers: option|shift, command: "balance"),
                    Binding(key: 17, modifiers: option|control|shift, command: "retile")]
        for (key, direction) in [(123, "left"), (124, "right"), (125, "down"), (126, "up")] {
            rows.append(Binding(key: UInt32(key), modifiers: option|control, command: "focus \(direction)"))
            rows.append(Binding(key: UInt32(key), modifiers: option|control|shift, command: "move \(direction)"))
        }
        for (index, key) in [18, 19, 20, 21, 23, 22, 26, 28, 25, 29].enumerated() {
            rows.append(Binding(key: UInt32(key), modifiers: option, command: "workspace \(index+1)"))
            rows.append(Binding(key: UInt32(key), modifiers: option|control, command: "moveworkspace \(index+1) follow"))
        }
        return rows
    }
    private static func render(_ argv: [String]) -> String {
        argv.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: " ")
    }
    func reload(configDir: String) throws {
        var rows = Self.defaults
        var baseline = Self.defaults
        let document = try TextConfig.read(configDir: configDir).document
        for override in document["hotkeys"]?.array ?? [] {
            guard let id = override["id"]?.int, id >= 0, id <= 4095 else { throw CmdError("Lite hotkeys: bounded binding ID required") }
            let command = override["command"]?.array?.compactMap(\.string)
            let index: Int
            if let command, let match = rows.firstIndex(where: { (try? CommandArguments.parse($0.command)) == command }) { index = match }
            else if rows.indices.contains(id), command == nil { index = id }
            else {
                guard let command, !command.isEmpty, let key = override["keycode"]?.int, let modifiers = override["modifiers"]?.int else { throw CmdError("Lite hotkeys: a new binding needs command, keycode and modifiers") }
                guard (0...127).contains(key), modifiers >= 0, modifiers & ~0x1b00 == 0 else { throw CmdError("Lite hotkeys: invalid new chord") }
                index = rows.count; rows.append(Binding(key: UInt32(key), modifiers: UInt32(modifiers), command: Self.render(command)))
                baseline.append(rows[index])
            }
            if let key = override["keycode"]?.int { guard (0...127).contains(key) else { throw CmdError("Lite hotkeys: keycode 0..127 required") }; rows[index].key = UInt32(key) }
            if let modifiers = override["modifiers"]?.int {
                guard modifiers >= 0, modifiers & ~0x1b00 == 0, modifiers & 0x1900 != 0 else { throw CmdError("Lite hotkeys: Command/Option/Control chord required") }
                rows[index].modifiers = UInt32(modifiers)
            }
            if let enabled = override["enabled"] { rows[index].enabled = enabled.truthy }
        }
        var chords = Set<String>()
        for row in rows where row.enabled {
            guard chords.insert("\(row.key):\(row.modifiers)").inserted else { throw CmdError("Lite hotkeys: duplicate enabled chord") }
        }
        metadata = .array(baseline.map { row in
            .object([("cmd", .array(((try? CommandArguments.parse(row.command)) ?? []).map(JSON.string))),
                     ("keycode", .int(Int(row.key))), ("mods", .int(Int(row.modifiers))),
                     ("enabled", .bool(row.enabled)), ("desc", .string(row.command))])
        })
        for registration in registrations { UnregisterEventHotKey(registration) }; registrations.removeAll(); commands.removeAll(); conflicts = 0
        for (index, row) in rows.enumerated() where row.enabled {
            let id = UInt32(index+1); var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(row.key, row.modifiers, EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { registrations.append(reference); commands[id] = row.command }
            else { conflicts += 1 }
        }
        if conflicts > 0 { log("Lite hotkeys: \(conflicts) chords are already owned by another application; available bindings remain active") }
    }
    func close() {
        for registration in registrations { UnregisterEventHotKey(registration) }; registrations.removeAll(); commands.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}
