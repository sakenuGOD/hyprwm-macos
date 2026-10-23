import Foundation

/// Native daemon policy. Frozen Oct 9 differential fixtures exercise legacy behavior.
public enum WindowResizeMode: String {
    case native, buffer
    static func resolve(runtime: JSON?) throws -> WindowResizeMode {
        var mode: WindowResizeMode = .native
        if let value = runtime?["window_resize_mode"] {
            guard let name = value.string, let parsed = WindowResizeMode(rawValue: name) else {
                throw CmdError("runtime.window_resize_mode: expected native or buffer")
            }
            mode = parsed
        }
        return mode
    }
}

public struct RuntimeOptions {
    public var production = false
    public var tilingEnabled = true
    public var menuBar = true
    public var startupAnimation = true
    public var throwDistance = 32.0
    public var directionRatio = 1.25
    public var transferOnActivation = true
    public var sharedResize = true
    public var dragMode = "swap"
    public var overviewHiddenWindows = false
    public var nativeFrames = false
    public var snapshotFrames = false
    public init() {}
    public static var standard: RuntimeOptions { var value = RuntimeOptions(); value.production = true; return value }
    public static func load(configDir: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> RuntimeOptions {
        var result = standard
        if let value=environment["HYPRWM_SNAPSHOT_FRAMES"] {
            guard value == "0" || value == "1" else { throw CmdError("HYPRWM_SNAPSHOT_FRAMES: expected 0 or 1") }
            result.snapshotFrames=value == "1"
        }
        let document = try TextConfig.read(configDir: configDir).document
        let runtime = document["runtime"]
        if case let .bool(value)? = runtime?["enabled"] { result.tilingEnabled = value }
        if case let .bool(value)? = runtime?["menu_bar"] { result.menuBar = value }
        if case let .bool(value)? = runtime?["startup_animation"] { result.startupAnimation = value }
        let drag = document["drag"]
        if let mode = drag?["mode"]?.string { result.dragMode = mode }
        if let distance = drag?["throw_distance_pt"]?.double { result.throwDistance = distance }
        if let ratio = drag?["direction_ratio"]?.double { result.directionRatio = ratio }
        if let value=runtime?["overview_hidden_windows"] {
            guard case let .bool(enabled)=value else {throw CmdError("runtime.overview_hidden_windows: expected boolean")}
            result.overviewHiddenWindows=enabled
        }
        _ = try WindowResizeMode.resolve(runtime: runtime)
        // Debug-only per-frame application configure; independent of live buffer projection.
        if let value = environment["HYPRWM_NATIVE_FRAMES"] {
            guard value == "0" || value == "1" else { throw CmdError("HYPRWM_NATIVE_FRAMES: expected 0 or 1") }
            result.nativeFrames = value == "1"
        }
        if let value=environment["HYPRWM_MENU_BAR"] {
            guard value == "0" || value == "1" else { throw CmdError("HYPRWM_MENU_BAR: expected 0 or 1") }
            result.menuBar=value == "1"
        }
        return result
    }
}
