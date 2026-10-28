// Daemon/system boundaries. All WM logic interacts with the world through these protocols:
// live implementations are in hyprwm-swift (SkyLight/AX/channel); test fakes never touch WS.
import Foundation

/// Window from a snapshot (winsnap.m: CGWindowList plus window space).
public struct WinInfo: Equatable {
    public var wid: Int, pid: Int
    public var owner: String, name: String
    /// AX metadata, empty until verified by the live adapter.
    public var role = "", subrole = ""
    public var x, y, w, h: Double
    public var on: Bool
    public var space: Int
    public var layer = 0
    public var alpha = 1.0
    public var nativeFullscreen = false
    public init(wid: Int, pid: Int, owner: String, name: String = "", x: Double, y: Double, w: Double, h: Double,
                on: Bool, space: Int) {
        self.wid = wid; self.pid = pid; self.owner = owner; self.name = name
        self.x = x; self.y = y; self.w = w; self.h = h; self.on = on; self.space = space
    }
    public var rect: Rect { Rect(x, y, w, h) }

    public static func from(_ j: JSON) -> WinInfo {
        var window = WinInfo(wid: j["wid"]?.int ?? 0, pid: j["pid"]?.int ?? 0, owner: j["owner"]?.string ?? "",
                name: j["name"]?.string ?? "", x: j["x"]?.double ?? 0, y: j["y"]?.double ?? 0,
                w: j["w"]?.double ?? 0, h: j["h"]?.double ?? 0, on: (j["on"] ?? .null).truthy,
                space: j["space"]?.int ?? 0)
        window.role = j["role"]?.string ?? ""
        window.subrole = j["subrole"]?.string ?? ""
        window.layer = j["layer"]?.int ?? 0
        window.alpha = j["alpha"]?.double ?? 1
        window.nativeFullscreen = j["native_fullscreen"]?.truthy ?? false
        return window
    }
}

public struct Snapshot {
    public var space: Int
    public var locked = false
    public var spaceType = 0
    public var stable: Bool
    public var area: Rect                // screen visible frame (excluding menu bar and Dock)
    public var windows: [WinInfo]        // front to back, on-screen windows first
    public var nativeMetadata:JSON?
    public init(space: Int, stable: Bool, area: Rect, windows: [WinInfo]) {
        self.space = space; self.stable = stable; self.area = area; self.windows = windows
    }
    /// JSON from ws_snapshot().
    public static func parse(_ j: JSON) -> Snapshot {
        let v = j["visible"] ?? .object([])
        var snapshot = Snapshot(space: j["space"]?.int ?? 0, stable: (j["stable"] ?? .null).truthy,
                        area: Rect(v["x"]?.double ?? 0, v["y"]?.double ?? 0, v["w"]?.double ?? 0, v["h"]?.double ?? 0),
                        windows: (j["windows"]?.array ?? []).map(WinInfo.from))
        snapshot.locked = j["locked"]?.truthy ?? false
        snapshot.spaceType = j["space_type"]?.int ?? 0
        snapshot.nativeMetadata=j
        return snapshot
    }
}

/// Engine window slot (struct ch_win): fields read by the daemon.
public struct EngWin {
    public var wid: Int
    public var pos: (Double, Double), size: (Double, Double)
    public var posActive: Bool, sizeActive: Bool, alphaActive: Bool
    public var geo=0
    public var settling: Bool
    public var curAlpha: Double
    public var held: Bool
    public var radius: Double
    public var ax, ay, aw, ah: Double
    public init(wid: Int, pos: (Double, Double), size: (Double, Double), posActive: Bool = false,
                sizeActive: Bool = false, alphaActive: Bool = false, settling: Bool = false, curAlpha: Double = 1,
                held: Bool = false, radius: Double = 0, a: Rect) {
        self.wid = wid; self.pos = pos; self.size = size; self.posActive = posActive; self.sizeActive = sizeActive
        self.alphaActive = alphaActive; self.settling = settling; self.curAlpha = curAlpha; self.held = held
        self.radius = radius; ax = a.x; ay = a.y; aw = a.w; ah = a.h
    }
    public var moving: Bool { posActive || sizeActive || settling }
    public var visible: Rect { Rect(pos.0, pos.1, size.0, size.1) }   // visible frame B
    public var real: Rect { Rect(ax, ay, aw, ah) }                      // actual frame A
}

public struct EngEvent {
    public var type: Int, wid: Int, t: Double
    public var rect: Rect
    public init(type: Int, wid: Int, t: Double, rect: Rect) { self.type = type; self.wid = wid; self.t = t; self.rect = rect }
}

/// Event/flag numbers from chan.h (EV_*). Duplicated here only as Int for protocols;
/// ChannelABITests checks the live channel against chan.h.
public enum Ev { public static let gone = 1, settled = 2, done = 3, new = 4, moved = 5 }

/// Channel header counters for status.
public struct EngStats {
    public var ticks = 0, nactive = 0, errors = 0, ticksLate = 0, teSkips = 0, holding = 0
    public var tickUsMax = 0.0, tickUsLast = 0.0
    public init() {}
}

/// Daemon -> engine channel (chan.py Chan).
public protocol ChannelAPI: AnyObject {
    var acceptedCloseSupported:Bool {get}
    func acceptedClose(_ command:AcceptedCloseCommand) -> Bool
    func acceptedClosePublication(_ releases:[AcceptedCloseCommand],geometry:[Int])->Bool
    var viewportSupported:Bool {get}
    func viewport(_ wid:Int,nonce:UInt64,offset:(Double,Double),box:Rect,enabled:Bool) -> Bool
    var ordinaryPrepareSupported:Bool {get}
    func ordinaryPrepare(_ wid:Int,nonce:UInt64,to:Rect,prepare:Bool) -> Bool
    var birthSupported:Bool {get}
    /// True means enqueued, not that the native lease has accepted the command.
    func birth(_ command:BirthCommand) -> Bool
    var terminalGeometrySupported:Bool {get}
    func geomTerminal(_ wid:Int,to:Rect,curves:(Int,Int),durations:(Double,Double),from:Rect?) -> Bool
    func geom(_ wid: Int, _ to: Rect, _ cpos: Int, _ csize: Int, dpos: Double, dsize: Double, frm: Rect?,
              move: Bool, warp: Bool, stretch: Bool)
    func alpha(_ wid: Int, _ a: Double, _ curve: Int, _ dur: Double, frm: Double?)
    func geometry(_ wid: Int, to: Rect, curves: (Int,Int), durations: (Double,Double), from: Rect?, warp: Bool, stretch: Bool, native: Bool, wait: Bool, hold: Bool)
    func configureNative(_ wid: Int, _ frame: Rect)
    /// Separate SCFG transport; legacy native geometry never gains F_STREAM.
    func streamGeometry(_ wid:Int,to:Rect,curves:(Int,Int),durations:(Double,Double),from:Rect?,hold:Bool) -> Bool
    func configureStreamProbe(_ wid:Int,_ frame:Rect) -> Bool
    func streamMotionHorizon(curve:Int,duration:Double,from:Rect,to:Rect,minimum:(Double,Double),hold:Bool) -> Double?
    func snapshotGeometry(_ wid:Int,to:Rect,curves:(Int,Int),durations:(Double,Double),from:Rect?) -> Bool
    var snapshotSupported:Bool { get }
    var engineTime:Double { get }
    var snapshotBatchTime:Double { get }
    func decorationFocus(_ wid: Int, fullscreen: Int)
    func space(_ wid: Int, _ sid: Int)
    func under(_ wid: Int, _ under: Int)
    func forget(_ wid: Int)
    func commit()
    func events() -> [EngEvent]
    func wins() -> [EngWin]
    var stats: EngStats { get }
    /// cmd_tail != cmd_head: the engine has not consumed the published batch yet
    var pending: Bool { get }
    var widMax: Int { get set }
}

public extension ChannelAPI {
    var acceptedCloseSupported:Bool {false}
    func acceptedClose(_ command:AcceptedCloseCommand) -> Bool {false}
    func acceptedClosePublication(_ releases:[AcceptedCloseCommand],geometry:[Int])->Bool {false}
    var viewportSupported:Bool {false}
    func viewport(_ wid:Int,nonce:UInt64,offset:(Double,Double),box:Rect,enabled:Bool) -> Bool {false}
    var ordinaryPrepareSupported:Bool {false}
    func ordinaryPrepare(_ wid:Int,nonce:UInt64,to:Rect,prepare:Bool) -> Bool {false}
    var birthSupported:Bool {false}
    func birth(_ command:BirthCommand) -> Bool {false}
    var terminalGeometrySupported:Bool {false}
    func geomTerminal(_ wid:Int,to:Rect,curves:(Int,Int),durations:(Double,Double),from:Rect?) -> Bool {false}
    var snapshotSupported:Bool { false }
    var engineTime:Double { 0 }
    var snapshotBatchTime:Double { engineTime }
    func snapshotGeometry(_ wid:Int,to:Rect,curves:(Int,Int),durations:(Double,Double),from:Rect?) -> Bool { false }
    func geometry(_ wid: Int,to: Rect,curves: (Int,Int),durations: (Double,Double),from: Rect?,warp: Bool,stretch: Bool,native: Bool,wait: Bool,hold: Bool) {
        geom(wid,to,curves.0,curves.1,dpos:durations.0,dsize:durations.1,frm:from,move:true,warp:warp,stretch:stretch)
    }
    func configureNative(_ wid: Int, _ frame: Rect) {}
    func streamGeometry(_ wid:Int,to:Rect,curves:(Int,Int),durations:(Double,Double),from:Rect?,hold:Bool) -> Bool {false}
    func configureStreamProbe(_ wid:Int,_ frame:Rect) -> Bool {false}
    func streamMotionHorizon(curve:Int,duration:Double,from:Rect,to:Rect,minimum:(Double,Double),hold:Bool) -> Double? {nil}
    func decorationFocus(_ wid: Int, fullscreen: Int) {}
    func space(_ wid: Int, _ sid: Int) {}
    func geom(_ wid: Int, _ to: Rect, _ cpos: Int, _ csize: Int, dpos: Double = 0, dsize: Double = 0,
              frm: Rect? = nil, move: Bool = true, warp: Bool = false, stretch: Bool = false) {
        geom(wid, to, cpos, csize, dpos: dpos, dsize: dsize, frm: frm, move: move, warp: warp, stretch: stretch)
    }
    func alpha(_ wid: Int, _ a: Double, _ curve: Int, _ dur: Double = 0) { alpha(wid, a, curve, dur, frm: nil) }
}

/// Engine wrapper (engine.py Engine).
public protocol EngineAPI: AnyObject {
    var c: ChannelAPI { get }
    func anim(_ leaf: String) -> (curve: Int, dur: Double, on: Bool)
    func alive() -> Bool
    func ensure(startup: Bool) throws
}

public extension EngineAPI {
    /// wid -> actual server window frame (without our transform).
    func real() -> [Int: Rect] {
        var d: [Int: Rect] = [:]
        for w in c.wins() { d[w.wid] = w.real }   // dict comprehension: last value wins
        return d
    }
}

/// Backdrops (deco.py).
public protocol DecoAPI: AnyObject {
    func ensure(_ wid: Int, _ owner: String, _ radius: Double)
    func place(_ wid: Int, _ rect: Rect) -> Int?
    func sample(_ wid: Int)
    func drop(_ wid: Int)
}

public final class NullDeco: DecoAPI {
    public init() {}
    public func ensure(_ wid: Int, _ owner: String, _ radius: Double) {}
    public func place(_ wid: Int, _ rect: Rect) -> Int? { nil }
    public func sample(_ wid: Int) {}
    public func drop(_ wid: Int) {}
}

/// Everything the daemon asks of the system (SkyLight, AX, CoreGraphics, processes), plus the clock.
public protocol SysAPI: AnyObject {
    func now() -> Double
    func sleep(_ s: Double)
    func snapshot() throws -> Snapshot
    func winPidLevel(_ wid: Int) -> (pid: Int?, level: Int?)
    func frontPid() -> Int?
    func winBounds(_ wid: Int) -> Rect?
    func winAlpha(_ wid: Int) -> Double?
    func moveToSpace(_ wids: [Int], _ space: Int)
    func activeSpace() -> UInt64
    func windowOnSpace(_ pid:Int,_ wid:Int,_ space:Int) -> Bool
    func mouse() -> (Double, Double)
    func mouseDown() -> Bool
    // AX (axlib.c)
    func axTileable(_ pid: Int, _ wid: Int) -> Int
    func axPrimaryWindow(_ pid:Int,_ wid:Int) -> Bool
    func axFrame(_ pid: Int, _ wid: Int, _ r: Rect) -> Int
    func axSize(_ pid:Int,_ wid:Int,_ width:Double,_ height:Double) -> Int
    func axGetFrame(_ pid: Int, _ wid: Int) -> Rect?
    func axForget(_ wid: Int)
    func axFocus(_ pid: Int, _ wid: Int, raise: Bool) -> Int
    func preserveAppFloats(_ tile:WinInfo,space:Int,windows:[WinInfo])
    func preserveFloatingWindows(_ windows:[WinInfo],space:Int)
    func axMenuPress(_ pid: Int, _ title: String) -> Int
    // winsnap.m
    func wsClose(_ pid: Int, _ wid: Int) -> Int
    func requestClose(_ pid:Int,_ wid:Int,birth:String,completion:@escaping(CloseResult)->Void)
    var closeBusy:Bool { get }
    func wsQuit(_ pid: Int) -> Int
    // exec
    func spotlight()
    func pgrep(_ name: String) -> Int?
    func spawn(_ argv: [String])
    func background(_ f: @escaping () -> Void)
    func focusContext(_ pid: Int) -> (wid: Int?, flags: Int)
    func requestFocus(_ request:FocusRequest,completion:@escaping(Bool)->Void)
    func cancelFocus()
    func setFocusCover(_ value:FocusCoverStamp?,wid:Int)
    var focusBusy:Bool {get}
    func pointerHit() -> (wid:Int,pid:Int?)?
    func protectedProcess(_ pid: Int) -> Bool
    func appPath(_ pid: Int) -> String?
    func clientCapability(_ pid: Int) -> Int
    func clientMinimum(_ pid:Int,_ wid:Int) -> (Double,Double)?
    func streamLease(_ pid:Int,_ wid:Int,_ space:Int,minimumTTL:Double) -> ConfigureStreamLease?
    func streamProbeLease(_ pid:Int,_ wid:Int,_ space:Int,epoch:Int) -> ConfigureStreamLease?
    func nativeResize(_ pid: Int) -> NativeResizeContext?
    func interactionOverlay() -> Bool
    func overviewTransitionActive() -> Bool
    func sessionLocked() -> Bool
    func processBirth(_ pid: Int) -> String?
    func tabProperty(_ wid: Int, _ pid: Int) -> TabProperty?
    func tabPropertiesChanged(_ pids: Set<Int>) -> Bool
    func launcherIntent(after sequence:UInt64) -> LauncherIntent?
    func launcherAvailable() -> Int
    func cacheLauncher(space:Int,frontPID:Int,windows:[WinInfo])
    func consumeLauncher(_ sequence:UInt64)
    func launcherCatalog() -> PublicWorkspaceCatalog?
    func requestTransferFocus(_ request:LauncherTransferFocus,completion:@escaping(Bool)->Void)
    func cancelTransferFocus()
    var transferFocusBusy:Bool {get}
    func processUID(_ pid:Int) -> Int?
    func processExited(_ pid:Int) -> Bool
    func windowPresence(_ pid:Int,_ wid:Int) -> Int
    func windowOrderedIn(_ pid:Int,_ wid:Int) -> Bool?
    func invalidateWindowPresence(_ wid:Int)
}

public extension SysAPI {
    func axPrimaryWindow(_ pid:Int,_ wid:Int) -> Bool {axTileable(pid,wid)==1}
    func windowOnSpace(_ pid:Int,_ wid:Int,_ space:Int) -> Bool {false}
    func preserveAppFloats(_ tile:WinInfo,space:Int,windows:[WinInfo]) {}
    func preserveFloatingWindows(_ windows:[WinInfo],space:Int) {}
    func windowPresence(_ pid:Int,_ wid:Int) -> Int {-1}
    func windowOrderedIn(_ pid:Int,_ wid:Int) -> Bool? {nil}
    func invalidateWindowPresence(_ wid:Int) {}
    func axSize(_ pid:Int,_ wid:Int,_ width:Double,_ height:Double) -> Int {-1}
    func requestFocus(_ request:FocusRequest,completion:@escaping(Bool)->Void) {completion(axFocus(request.pid,request.wid,raise:false)==0)}
    func cancelFocus() {}
    func setFocusCover(_ value:FocusCoverStamp?,wid:Int) {}
    var focusBusy:Bool {false}
    func pointerHit() -> (wid:Int,pid:Int?)? {nil}
    func requestClose(_ pid:Int,_ wid:Int,birth:String,completion:@escaping(CloseResult)->Void) { completion(CloseResult(code:wsClose(pid,wid))) }
    var closeBusy:Bool { false }
    func focusContext(_ pid: Int) -> (wid: Int?, flags: Int) { (nil, 4) }
    func protectedProcess(_ pid: Int) -> Bool { false }
    func appPath(_ pid: Int) -> String? { nil }
    func clientCapability(_ pid: Int) -> Int { 0 }
    func clientMinimum(_ pid:Int,_ wid:Int) -> (Double,Double)? { nil }
    func streamLease(_ pid:Int,_ wid:Int,_ space:Int,minimumTTL:Double) -> ConfigureStreamLease? {nil}
    func streamProbeLease(_ pid:Int,_ wid:Int,_ space:Int,epoch:Int) -> ConfigureStreamLease? {nil}
    func nativeResize(_ pid: Int) -> NativeResizeContext? { nil }
    func interactionOverlay() -> Bool { false }
    func overviewTransitionActive() -> Bool { false }
    func sessionLocked() -> Bool { false }
    func processBirth(_ pid: Int) -> String? { nil }
    func tabProperty(_ wid: Int, _ pid: Int) -> TabProperty? { nil }
    func tabPropertiesChanged(_ pids: Set<Int>) -> Bool { false }
    func launcherIntent(after sequence:UInt64) -> LauncherIntent? { nil }
    func launcherAvailable() -> Int { 0 }
    func cacheLauncher(space:Int,frontPID:Int,windows:[WinInfo]) {}
    func consumeLauncher(_ sequence:UInt64) {}
    func launcherCatalog() -> PublicWorkspaceCatalog? {nil}
    func requestTransferFocus(_ request:LauncherTransferFocus,completion:@escaping(Bool)->Void) {completion(false)}
    func cancelTransferFocus() {}
    var transferFocusBusy:Bool {false}
    func processUID(_ pid:Int) -> Int? {nil}
    func processExited(_ pid:Int) -> Bool {false}
}

/// Configure job destination (live: Configurer with a queue per app; tests: recording).
public protocol ConfigureSink: AnyObject {
    func submit(_ jobs: [CfgJob])
    func cancelAll()
    func cancel(_ wid: Int)
    var idle:Bool { get }
    func busy(_ wid:Int) -> Bool
}
public extension ConfigureSink { func cancelAll() {}
    func cancel(_ wid: Int) {}
    var idle:Bool { true }
    func busy(_ wid:Int) -> Bool { false }
}

public struct CfgJob: Equatable {
    public var wid: Int, pid: Int
    public var owner: String
    public var to: Rect
    public var seq = 0
    public var birth: String?
    public var requireOwnership = false
    public var expectedSpace:Int?
    /// C5 already posted its one final native configure; this job ONLY reads ACK.
    public var verifyOnly = false
    /// One logical configure at motion start. Physical origin belongs to the
    /// native terminal handoff, never to a delayed AX position setter.
    public var sizeOnly = false
    /// Replace an outstanding native write even when a stale read already
    /// matches this target. Cancellation cannot undo an AX setter in flight.
    public var forceWrite = false
    public init(wid: Int, pid: Int, owner: String, to: Rect) { self.wid = wid; self.pid = pid; self.owner = owner; self.to = to }
}

/// Configure response (the frame the window actually accepted).
public struct CfgResult {
    public var wid: Int
    public var owner: String
    public var to: Rect
    public var got: Rect?
    public var e: Int
    public var pre: Rect?
    public var pid:Int?, birth:String?
    public var isCurrent:(()->Bool)?
    public init(wid: Int, owner: String, to: Rect, got: Rect?, e: Int, pre: Rect?) {
        self.wid = wid; self.owner = owner; self.to = to; self.got = got; self.e = e; self.pre = pre
    }
}

public var hyprLogSink: (String) -> Void = { line in
    FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
}

/// Like log() in hyprwm.py: "HH:MM:SS.mmm message".
private let logTimeFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

public func log(_ parts: Any...) {
    let t = Date().timeIntervalSince1970
    let f = logTimeFormat
    let ms = Int((t.truncatingRemainder(dividingBy: 1)) * 1000)
    hyprLogSink(f.string(from: Date(timeIntervalSince1970: t)) + String(format: ".%03d ", ms) +
                parts.map { "\($0)" }.joined(separator: " "))
}
