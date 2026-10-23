// Swift attaches to the already installed native engine. It never installs or stops WindowServer code.
// The channel directory matches the native installer.
import CAX
import CChan
import Foundation
import HyprCore

/// Inactive channel used before a verified native engine is attached.
final class DeadChannel: ChannelAPI {
    func geom(_ wid: Int, _ to: Rect, _ cpos: Int, _ csize: Int, dpos: Double, dsize: Double, frm: Rect?, move: Bool,
              warp: Bool, stretch: Bool) {}
    func alpha(_ wid: Int, _ a: Double, _ curve: Int, _ dur: Double, frm: Double?) {}
    func under(_ wid: Int, _ under: Int) {}
    func forget(_ wid: Int) {}
    func commit() {}
    func events() -> [EngEvent] { [] }
    func wins() -> [EngWin] { [] }
    var stats: EngStats { EngStats() }
    var pending: Bool { false }
    var widMax: Int { get { 1 } set {} }
}

final class LiveEngine: EngineAPI {
    static let dir = "/tmp/hyprwm"
    static let ptr = dir + "/chan_path"   // Each installation publishes a new channel file.
    let hook: String
    var cfg: HyprConfig
    var ch: LiveChannel?
    private let dead = DeadChannel()
    private var pt: UInt32?
    var c: ChannelAPI { ch ?? dead }
    var statePath: String { hook + "/anim4.state" }

    init(hook: String, cfg: HyprConfig) {
        self.hook = hook
        self.cfg = cfg
    }

    func anim(_ leaf: String) -> (curve: Int, dur: Double, on: Bool) { cfg.anim(leaf) }

    static func wsPid() -> Int? {
        guard let native=try? VerifiedPublicWorkspace.diagnostic(),native["consistent"] == .bool(true),
              let row=native["generation"]?.array,row.count==4,
              PublicWorkspaceCatalog.identity(row[2]),let pid=OverviewBinding.integer(row[2].array?[0]) else{return nil}
        return pid
    }

    private var lastTickAt = ProcessInfo.processInfo.systemUptime
    private var attachedPID: Int?
    private var attachedBirth: (UInt64, UInt64)?
    private var attachedIdentity:JSON?
    private var curveBootstrap:(channel:LiveChannel,identity:JSON,token:LiveChannel.CurveBootstrap)?

    func commitStartupCurves() {curveBootstrap=nil}

    func rollbackStartupCurves() throws {
        guard let saved=curveBootstrap else{return}
        guard let pid=attachedPID,ch === saved.channel,
              try VerifiedPublicWorkspace.identity(pid)==saved.identity,
              try String(contentsOfFile:Self.ptr,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)==saved.channel.path else {
            throw CmdError("startup curve rollback refused: engine identity changed")
        }
        try saved.channel.rollbackCurves(saved.token)
        curveBootstrap=nil
    }

    func alive() -> Bool {
        guard let ch, ch.magicOK, ch.sizeOK, ch.raw.pointee.stop == 0,
              let pid = attachedPID, kill(pid_t(pid), 0) == 0 || errno == EPERM else { return false }
        guard let identity=attachedIdentity,(try? VerifiedPublicWorkspace.identity(pid))==identity else{return false}
        let tick = ch.ticks
        if tick != pt { pt = tick; lastTickAt = ProcessInfo.processInfo.systemUptime }
        return ProcessInfo.processInfo.systemUptime-lastTickAt < 0.5
    }

    /// Attach only. Installing or replacing code in WindowServer requires the versioned rollout workflow.
    /// An ordinary daemon start must never stop an existing core or execute the obsolete installer.
    func ensure(startup: Bool) throws {
        try attach(startup:startup,configure:true)
    }

    /// Mapping and identity checks only; no setup, appearance or mask writes.
    func attachForCanary() throws {try attach(startup:true,configure:false)}

    private func attach(startup:Bool,configure:Bool) throws {
        guard StartupQualification.fingerprint()["verified"] == .bool(true) else {
            throw CmdError("Unverified on this macOS build")
        }
        let path = try String(contentsOfFile: Self.ptr, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix(Self.dir + "/chan."), !path.contains("..") else { throw CmdError("invalid engine channel path") }
        let fields = try String(contentsOfFile: statePath, encoding: .utf8).split(whereSeparator: { $0.isWhitespace })
        guard let first = fields.first, let pid = Int(first), pid > 0,
              !startup || Self.wsPid() == pid else { throw CmdError("WindowServer identity does not match installed engine") }
        let identity=try VerifiedPublicWorkspace.identity(pid)
        guard let actor=identity.array,actor.count==5,let executable=actor[4].string,
              executable.hasPrefix("/System/Library/PrivateFrameworks/SkyLight.framework/"),executable.hasSuffix("/WindowServer"),
              OverviewBinding.integer(actor[0])==pid,OverviewBinding.integer(actor[1])==88 else {throw CmdError("exact native WindowServer path/UID/birth required")}
        if ch?.path != path { ch = try LiveChannel(path: path, create: false) }
        guard let ch, ch.magicOK, ch.sizeOK, ChannelCapabilities.abi(ch.raw.pointee.version) == 6,
              ch.raw.pointee.stop == 0 else { throw CmdError("installed engine channel is incompatible or stopped") }
        guard try VerifiedPublicWorkspace.identity(pid)==identity else{throw CmdError("WindowServer identity changed while attaching")}
        attachedIdentity=identity
        attachedPID = pid; pt = ch.ticks; lastTickAt = ProcessInfo.processInfo.systemUptime
        if startup {
            guard ch.stats.nactive == 0,ch.stats.holding==0,!ch.pending else { throw CmdError("engine is busy; wait for its animations to finish before starting Swift") }
            let adopt=configure ? (ProcessInfo.processInfo.environment["HYPRWM_ADOPT_ENGINE"] ?? "0") : "1"
            guard adopt=="0" || adopt=="1" else{throw CmdError("HYPRWM_ADOPT_ENGINE must be0or1")}
            if adopt=="1" {
                if !configure,let token=try ch.bootstrapPristineCurves(cfg) {
                    curveBootstrap=(ch,identity,token)
                }
                guard ch.curvesCompatible(cfg) else{throw CmdError("existing engine curve mapping differs; adoption refused without rewriting")}
            }else{try setup()}
        }
        // Match the native runtime defaults, including verified adoption.
        // Hosting masks keep rounded content and the ring on one contour;
        // its upward Y axis anchors that contour to the presented top edge.
        if configure {
            ch.raw.pointee.mask_only = 0
            ch.raw.pointee.mask_flip = 1
            ch.raw.pointee.use_mask = 1
        }
    }

    func replaceConfig(_ candidate: HyprConfig) throws {
        guard let ch else { throw CmdError("engine channel unavailable") }
        if ch.curvesCompatible(candidate) {
            cfg = candidate
            ch.raw.pointee.hold_max = (candidate.raw["runtime"]?["hold_max_ms"]?.double ?? 200)/1000
            ch.base.assumingMemoryBound(to:CChan.ch.self).pointee.prehide = candidate.raw["runtime"]?["prehide"]?.truthy == true ? 1 : 0
            try ch.configureAppearance(candidate)
            return
        }
        guard ch.stats.nactive == 0, !ch.pending else { throw CmdError("animations are running; reload after they finish") }
        cfg = candidate
        try setup()
    }

    /// Publish curve slots, engine timing and client-size confirmation limits.
    func setup() throws {
        guard let ch else { return }
        let h = ch.raw
        h.pointee.idle_poll = 0.004; h.pointee.phase = 0.1; h.pointee.margin = 0.002   // Poll commands every 4 ms.
        // Client frame hold duration can be overridden with HYPRWM_HOLD.
        h.pointee.hold_max = (cfg.raw["runtime"]?["hold_max_ms"]?.double ?? 200)/1000
        ch.base.assumingMemoryBound(to: CChan.ch.self).pointee.prehide = cfg.raw["runtime"]?["prehide"]?.truthy == true ? 1 : 0
        h.pointee.settle = 1.0; h.pointee.settle_px = 8.0    // Allow client minimum sizes and terminal character grids.
        let ts = cfg.timeScale
        for (i, (_, cv)) in cfg.sortedCurves().enumerated() where i < 16 {
            switch cv {
            case let .spring(mass, k, d): ch.spring(i, mass, k / (ts * ts), d / ts)   // Scale time without changing the curve shape.
            case let .bezier(p1, p2): ch.bezier(i, p1, p2)
            }
        }
        try ch.configureAppearance(cfg)
    }
}
