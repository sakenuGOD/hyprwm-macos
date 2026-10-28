import CAX
import CChan
import Foundation
import HyprCore

/// Host readiness without an engine mapping, configuration publication, AX mutation, or permission prompt.
func diagnose(hook: String, controlPath: String) -> JSON {
    let system = LiveSys()
    let trusted = ax_trusted() != 0
    var fields: [(String, JSON)] = [
        ("mode", .string("native-read-only")), ("runtime", .string("swift")),
        ("pid", .int(Int(getpid()))), ("accessibility_trusted", .bool(trusted)),
        ("control_alive", .bool(CommandServer.isAlive(controlPath))),
        ("automatic_engine_installation", .bool(false)),
        ("startup_canary_performed", .bool(false))
    ]
    do {
        let location=try EngineStateLocation.resolve(hook:hook)
        let tokens=try location.read().split(whereSeparator:{$0.isWhitespace})
        guard let first=tokens.first,let pid=Int(first),pid>1 else {throw CmdError("Invalid native engine state file")}
        let identity=try VerifiedPublicWorkspace.identity(pid)
        let actor=identity.array,executable=actor?.count==5 ? actor?[4].string:nil
        let matches=actor?.count==5 && OverviewBinding.integer(actor?[0])==pid &&
            OverviewBinding.integer(actor?[1])==88 && executable?.hasPrefix("/System/Library/PrivateFrameworks/SkyLight.framework/")==true &&
            executable?.hasSuffix("/WindowServer")==true && LiveEngine.wsPid()==pid
        fields.append(("engine_state",.object([("path",.string(location.path)),("source",.string(location.source)),
            ("pid",.int(pid)),("identity_matches",.bool(matches))])))
    } catch {fields.append(("engine_state_error",.string(String(describing:error))))}
    do {
        let snapshot = try system.snapshot()
        fields.append(("snapshot", .object([("stable", .bool(snapshot.stable)), ("space", .int(snapshot.space)),
                                            ("space_type", .int(snapshot.spaceType)), ("locked", .bool(snapshot.locked)),
                                            ("window_count", .int(snapshot.windows.count)), ("area", snapshot.area.json)])))
    } catch { fields.append(("snapshot_error", .string(String(describing: error)))) }
    do {
        let path = try String(contentsOfFile: LiveEngine.ptr, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix(LiveEngine.dir + "/chan."), !path.contains("..") else { throw CmdError("invalid engine channel pointer") }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 32) ?? Data()
        guard data.count == 32 else { throw CmdError("short native channel header") }
        func unsigned(_ offset: Int, _ count: Int) -> UInt64 {
            data[offset..<offset+count].enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset*8)) }
        }
        let magic = unsigned(0,8), version = unsigned(8,4), size = unsigned(12,4)
        let compatible = magic == CH_MAGIC && ChannelCapabilities.abi(UInt32(version)) == 6 && size == ch_abi()
        fields.append(("channel", .object([("compatible", .bool(compatible)), ("abi", .int(Int(ChannelCapabilities.abi(UInt32(version))))),
                                           ("size", .int(Int(size))), ("expected_size", .int(Int(ch_abi()))),
                                           ("capabilities", .string(String(format: "0x%08llx", version & UInt64(ChannelCapabilities.mask)))),
                                           ("commands_pending", .bool(unsigned(16,4) != unsigned(20,4)))])))
    } catch { fields.append(("channel_error", .string(String(describing: error)))) }
    if let reply = try? ControlClient(path: controlPath).request("status"), let status = try? JSON.parse(reply) {
        fields.append(("daemon", .object([("enabled", status["enabled"] ?? .null),
                                          ("space", status["space"] ?? .null),
                                          ("engine", status["engine"] ?? .null)])))
    }
    return .object(fields)
}
