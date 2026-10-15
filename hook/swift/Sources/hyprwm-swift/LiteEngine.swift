import AppKit
import QuartzCore
import HyprCore

final class LiteEngine: EngineAPI {
    let channel: LiteChannel
    var cfg: HyprConfig
    var c: ChannelAPI { channel }
    init(sys: LiteSys, config: HyprConfig) throws { cfg = config; channel = try LiteChannel(sys: sys, config: config) }
    func anim(_ leaf: String) -> (curve: Int, dur: Double, on: Bool) { cfg.anim(leaf) }
    func alive() -> Bool { true }
    func ensure(startup: Bool) throws {}
    func replaceConfig(_ config: HyprConfig) throws {
        let appearance = try Appearance(config)
        cfg = config; channel.config = config; channel.borders.appearance = appearance
        channel.refreshBorders()
    }
}

/// ChannelAPI keeps the existing layout/focus/rules/IPC policy shared with Engine
/// mode. Client geometry belongs entirely to this adapter while a proxy exists.
final class LiteChannel: ChannelAPI {
    struct Geometry {
        var to: Rect, from: Rect?
        var curve: Int, duration: Double
        var instant: Bool
    }
    struct Command {
        var geometry: Geometry?
        var alpha: Double?, alphaDuration = 0.0
    }
    final class Slot {
        let wid: Int, pid: Int, birth: String
        var target: Rect, actual: Rect, presented: Rect
        var version = 0, busy = false, capturing = false, landing = false
        var forgetVersion: Int?
        var proxy: LiteProxy?
        var alpha = 1.0
        var lastSample: (time: Double, frame: Rect)?
        var velocity: [Double] = []
        var started = 0.0, duration = 0.0
        var cached: CGImage?, capturedAt = 0.0
        init(window: WinInfo, birth: String) {
            wid = window.wid; pid = window.pid; self.birth = birth
            target = window.rect; actual = window.rect; presented = window.rect
        }
    }
    let sys: LiteSys, captures = LiteCaptures(), borders: LiteBorders
    var config: HyprConfig
    private var slots: [Int: Slot] = [:]
    private var commands: [Int: Command] = [:]
    private var queue: [EngEvent] = []
    private var departures: [(LiteProxy, Double)] = []
    private var census: [Int: Rect] = [:]
    private var focused = 0, fullscreen = 0
    private var counters = EngStats()
    private var capturePending = Set<Int>()
    private var shuttingDown = false
    private(set) var proxyMotions = 0, directPlacements = 0, captureFailures = 0
    var widMax = 1
    init(sys: LiteSys, config: HyprConfig) throws {
        self.sys = sys; self.config = config; borders = try LiteBorders(config: config)
        sys.beforeClose = { [weak self] wid, completion in
            guard let self, let slot = self.slots[wid] else { completion(true); return }
            var finished = false
            func finish(_ ready: Bool = true) { guard !finished else { return }; finished = true; completion(ready) }
            if slot.busy {
                // A close can open a modal save sheet. Put its real parent back
                // on screen before pressing Close so the sheet cannot be parked.
                let current = slot.proxy?.presented ?? slot.target
                self.place(slot, frame: current, logical: current, completion: { finish($0) })
                return
            }
            guard slot.cached == nil else { finish(); return }
            self.captures.image(wid, pid: slot.pid, frame: slot.presented) { image in slot.cached = image; finish() }
            // ScreenCaptureKit failure/denial must never make a close command hang.
            DispatchQueue.main.asyncAfter(deadline: .now()+0.2) { finish() }
        }
    }
    var engineTime: Double { sys.now() }
    var stats: EngStats {
        var value = counters; value.nactive = slots.values.filter { $0.busy }.count + departures.count
        value.holding = slots.values.filter { $0.capturing || $0.landing }.count; return value
    }
    var pending: Bool { !commands.isEmpty }
    func geom(_ wid: Int, _ to: Rect, _ cpos: Int, _ csize: Int, dpos: Double, dsize: Double, frm: Rect?, move: Bool, warp: Bool, stretch: Bool) {
        guard !shuttingDown else { return }
        var command = commands[wid] ?? Command()
        command.geometry = Geometry(to: to, from: frm, curve: cpos, duration: max(dpos, dsize), instant: warp || max(dpos, dsize) <= 0)
        commands[wid] = command
    }
    func alpha(_ wid: Int, _ alpha: Double, _ curve: Int, _ duration: Double, frm: Double?) {
        guard !shuttingDown else { return }
        var command = commands[wid] ?? Command(); command.alpha = min(1, max(0, alpha)); command.alphaDuration = duration
        commands[wid] = command
    }
    func under(_ wid: Int, _ under: Int) {}
    func space(_ wid: Int, _ sid: Int) { sys.moveToSpace([wid], sid) }
    func decorationFocus(_ wid: Int, fullscreen: Int) {
        guard focused != wid || self.fullscreen != fullscreen else { return }
        focused = wid; self.fullscreen = fullscreen; refreshBorders()
    }
    func forget(_ wid: Int) {
        if let slot = slots[wid], slot.busy, slot.proxy != nil {
            // Pause can request forget before its queued AX frame is accepted.
            // Bind the release to this configure, never to a future retarget.
            slot.forgetVersion = slot.version + (commands[wid]?.geometry == nil ? 0 : 1)
            return
        }
        commands[wid] = nil
        if let slot = slots.removeValue(forKey: wid) {
            slot.version += 1; slot.proxy?.close()
            sys.presentation[wid] = nil
        }
        borders.drop(wid)
        if !sys.concealed.contains(wid) { sys.membership[wid] = nil }
    }
    func events() -> [EngEvent] { let events = queue; queue.removeAll(keepingCapacity: true); return events }
    func wins() -> [EngWin] {
        slots.values.map { slot in
            var window = EngWin(wid: slot.wid, pos: (slot.presented.x, slot.presented.y), size: (slot.presented.w, slot.presented.h),
                posActive: slot.busy, sizeActive: slot.busy, curAlpha: slot.alpha,
                held: slot.capturing || slot.landing, radius: borders.appearance.radius, a: slot.actual)
            window.geo = 1; return window
        }
    }
    func busy(_ wid: Int) -> Bool { slots[wid]?.busy == true }
    func actual(_ wid: Int) -> Rect? { slots[wid]?.actual }
    func destination(_ wid: Int) -> Rect? { slots[wid]?.target }
    // The proxy owns one final client handoff. This generic channel contract
    // keeps shared policy from replaying a compatibility warp after its ACK.
    var terminalGeometrySupported: Bool { true }
    func geomTerminal(_ wid: Int, to: Rect, curves: (Int, Int), durations: (Double, Double), from: Rect?) -> Bool {
        geom(wid, to, curves.0, curves.1, dpos: durations.0, dsize: durations.1, frm: from, move: true, warp: false, stretch: false)
        return true
    }
    func receiptCheck(_ wid: Int) -> () -> Bool {
        guard let slot = slots[wid] else { return { false } }
        let version = slot.version
        return { [weak self, weak slot] in
            guard let self, let slot else { return false }
            return self.slots[wid] === slot && slot.version == version
        }
    }
    func commit() {
        let batch = commands; commands.removeAll(keepingCapacity: true)
        for (wid, command) in batch {
            guard let window = sys.window(wid), !sys.protectedProcess(window.pid), let birth = sys.processBirth(window.pid) else { continue }
            let fresh = slots[wid] == nil
            // Opacity refresh alone never grants workspace ownership.
            if fresh, command.geometry == nil, (command.alpha ?? 1) > 0.001 { continue }
            if let old = slots[wid], old.pid != window.pid || old.birth != birth { forget(wid) }
            let slot = slots[wid] ?? Slot(window: window, birth: birth); slots[wid] = slot
            guard sys.track(wid) else { slots[wid] = nil; continue }
            if let alpha = command.alpha { slot.alpha = alpha <= 0.001 ? 0 : 1 }
            if slot.alpha <= 0.001 {
                sys.concealed.insert(wid); borders.hide(wid)
                let frame = sys.park(command.geometry?.to ?? slot.target)
                place(slot, frame: frame, logical: command.geometry?.to ?? slot.target, concealed: true)
                continue
            }
            let wasConcealed = sys.concealed.remove(wid) != nil
            guard var geometry = command.geometry else {
                if wasConcealed { place(slot, frame: slot.target, logical: slot.target) }
                continue
            }
            let opening = fresh && geometry.curve == 16 && geometry.from == geometry.to && config.anim("windowsIn").on
            if opening {
                let scale = config.animation("windowsIn").style == "fade" ? 1 : (config.popin("windowsIn") ?? 0.86)
                geometry.from = Rect(geometry.to.x+geometry.to.w*(1-scale)/2, geometry.to.y+geometry.to.h*(1-scale)/2, geometry.to.w*scale, geometry.to.h*scale)
                geometry.duration = config.anim("windowsIn").dur; geometry.curve = config.anim("windowsIn").curve; geometry.instant = false
            }
            if geometry.instant || geometry.duration < 0.015 || !captures.permitted || sys.mouseDown() {
                directPlacements += 1; place(slot, frame: geometry.to, logical: geometry.to)
            } else { animate(slot, geometry: geometry, opening: opening) }
        }
    }
    private func current(_ slot: Slot, _ version: Int) -> Bool {
        !shuttingDown && slots[slot.wid] === slot && slot.version == version && sys.processBirth(slot.pid) == slot.birth
    }
    private func place(_ slot: Slot, frame: Rect, logical: Rect, concealed: Bool = false, completion: ((Bool) -> Void)? = nil) {
        slot.version += 1; let version = slot.version
        slot.target = logical; slot.busy = true; slot.landing = true; slot.capturing = false
        sys.ax.setFrameAsync(slot.pid, slot.wid, frame) { [weak self, weak slot] result, accepted in
            guard let self, let slot, self.current(slot, version) else { completion?(false); return }
            if result != 0 { self.counters.errors += 1 }
            guard let actual = accepted ?? self.sys.winBounds(slot.wid) else {
                slot.proxy?.freeze(); slot.busy = false; slot.landing = false
                self.counters.errors += 1; completion?(false); return
            }
            slot.actual = actual
            if slot.proxy != nil, slot.actual.maxDiff(frame) > 8 {
                // Keep a visible frozen proxy and the recovery record when AX
                // refuses the landing. Never reveal a still-parked real body.
                slot.proxy?.freeze(); slot.busy = false; slot.landing = false
                self.counters.errors += 1; completion?(false); return
            }
            slot.presented = concealed ? logical : slot.actual
            slot.busy = false; slot.landing = false
            slot.proxy?.close(); slot.proxy = nil
            self.sys.presentation[slot.wid] = nil
            self.queue.append(EngEvent(type: Ev.settled, wid: slot.wid, t: self.sys.now(), rect: slot.presented))
            self.updateBorder(slot)
            completion?(result == 0)
            if slot.forgetVersion == version { self.forget(slot.wid) }
        }
    }
    private func animate(_ slot: Slot, geometry: Geometry, opening: Bool) {
        slot.version += 1; let version = slot.version
        let oldProxy = slot.proxy
        let start = oldProxy?.presented ?? geometry.from ?? slot.presented
        let velocity = oldProxy == nil ? [] : slot.velocity
        let curves = config.sortedCurves(), curve = curves.indices.contains(geometry.curve) ? curves[geometry.curve].1 : nil
        let frames = LiteMotion.frames(from: start, to: geometry.to, velocity: velocity, duration: geometry.duration, curve: curve, timeScale: config.timeScale)
        slot.target = geometry.to; slot.busy = true; slot.capturing = true; slot.landing = false
        borders.hide(slot.wid)
        func captured(_ image: CGImage?) {
            guard self.current(slot, version), slot.capturing else { return }
            guard let image else {
                self.captureFailures += 1; self.directPlacements += 1
                self.place(slot, frame: geometry.to, logical: geometry.to); return
            }
            slot.cached = image; slot.capturedAt = self.sys.now()
            let proxy = LiteProxy(image: image, from: start, to: geometry.to, motionFrames: frames, appearance: self.borders.appearance, focused: self.focused == slot.wid, relativeTo: slot.wid)
            if opening { proxy.window.orderOut(nil) }
            slot.proxy = proxy; oldProxy?.close()
            self.sys.presentation[slot.wid] = start
            // Resize the parked real client first; the proxy remains the only body
            // on screen until its exact final AX placement is acknowledged.
            let park = self.sys.park(geometry.to)
            self.sys.ax.setFrameAsync(slot.pid, slot.wid, park) { [weak self] result, accepted in
                guard let self, self.current(slot, version) else { return }
                if result != 0 {
                    self.counters.errors += 1; self.place(slot, frame: geometry.to, logical: geometry.to); return
                }
                if let accepted { slot.actual = accepted }
                slot.capturing = false
                slot.started = CACurrentMediaTime()+0.008; slot.duration = geometry.duration
                proxy.animate(frames: frames, duration: geometry.duration, started: slot.started, fromAlpha: opening ? 0 : 1)
                proxy.window.order(.above, relativeTo: slot.wid)
                slot.presented = start; self.sys.presentation[slot.wid] = start
                self.proxyMotions += 1
            }
        }
        if let image = oldProxy?.image { captured(image) }
        else {
            captures.image(slot.wid, pid: slot.pid, frame: slot.presented, completion: captured)
            DispatchQueue.main.asyncAfter(deadline: .now()+0.22) { [weak self, weak slot] in
                guard let self, let slot, self.current(slot, version), slot.capturing, slot.proxy == nil else { return }
                captured(nil)
            }
        }
    }
    func advance() {
        let began = sys.now(); counters.ticks += 1
        for slot in Array(slots.values) where slot.busy && !slot.capturing && !slot.landing {
            guard let proxy = slot.proxy else { continue }
            let time = CACurrentMediaTime(), frame = proxy.presented
            if let previous = slot.lastSample, time > previous.time {
                slot.velocity = zip(previous.frame.arr, frame.arr).map { ($1-$0)/(time-previous.time) }
            }
            slot.lastSample = (time, frame); slot.presented = frame; sys.presentation[slot.wid] = frame
            guard time >= slot.started+slot.duration else { continue }
            slot.presented = slot.target; sys.presentation[slot.wid] = slot.target
            slot.landing = true; let version = slot.version
            sys.ax.setFrameAsync(slot.pid, slot.wid, slot.target) { [weak self, weak slot] result, accepted in
                guard let self, let slot, self.current(slot, version) else { return }
                if result != 0 { self.counters.errors += 1 }
                guard let actual = accepted ?? self.sys.winBounds(slot.wid) else {
                    slot.proxy?.freeze(); slot.busy = false; slot.landing = false
                    self.counters.errors += 1; return
                }
                slot.actual = actual
                if slot.actual.maxDiff(slot.target) > 8 {
                    slot.proxy?.freeze(); slot.busy = false; slot.landing = false
                    self.counters.errors += 1
                    return // Keep the visible proxy and exact recovery authority.
                }
                // Keep the exact target image for two display intervals so the
                // application's newly sized backing surface can become visible.
                DispatchQueue.main.asyncAfter(deadline: .now()+0.034) { [weak self, weak slot] in
                    guard let self, let slot, self.current(slot, version) else { return }
                    slot.busy = false; slot.landing = false; slot.presented = slot.actual
                    slot.proxy?.close(); slot.proxy = nil; slot.lastSample = nil; slot.velocity = []
                    self.sys.presentation[slot.wid] = nil
                    self.queue.append(EngEvent(type: Ev.settled, wid: slot.wid, t: self.sys.now(), rect: slot.actual))
                    self.updateBorder(slot)
                    if slot.forgetVersion == version { self.forget(slot.wid) }
                }
            }
        }
        let now = CACurrentMediaTime()
        departures.removeAll { proxy, deadline in if now >= deadline { proxy.close(); return true }; return false }
        let elapsed = (sys.now()-began)*1_000_000
        counters.tickUsLast = elapsed; counters.tickUsMax = max(counters.tickUsMax, elapsed)
    }
    func observe(_ snapshot: Snapshot) {
        let live = Dictionary(snapshot.windows.filter { $0.layer == 0 }.map { ($0.wid, $0.rect) }, uniquingKeysWith: { first, _ in first })
        for (wid, frame) in live where census[wid] == nil || census[wid]!.maxDiff(frame) > 1 && slots[wid]?.busy != true {
            queue.append(EngEvent(type: census[wid] == nil ? Ev.new : Ev.moved, wid: wid, t: sys.now(), rect: frame))
        }
        for wid in census.keys where live[wid] == nil {
            if let slot = slots[wid] {
                closeDeparture(slot)
                slots[wid] = nil; sys.presentation[wid] = nil; sys.membership[wid] = nil; sys.concealed.remove(wid)
                sys.recovery.remove(wid)
            }
            queue.append(EngEvent(type: Ev.gone, wid: wid, t: sys.now(), rect: census[wid]!))
        }
        census = live
        refreshBorders()
        // A bounded in-memory image cache makes an external Cmd+W animatable.
        for slot in slots.values.filter({ !capturePending.contains($0.wid) && !$0.busy && $0.alpha > 0 && sys.membership[$0.wid] == sys.workspace && sys.now()-$0.capturedAt > 0.75 && capturePending.count < 2 })
            .sorted(by: { $0.capturedAt < $1.capturedAt }).prefix(1) {
            guard capturePending.insert(slot.wid).inserted else { continue }
            slot.capturedAt = sys.now()
            let capturedID = slot.wid
            captures.image(capturedID, pid: slot.pid, frame: slot.presented) { [weak self, weak slot] image in
                guard let self else { return }; self.capturePending.remove(capturedID)
                if let slot, let image, self.slots[slot.wid] === slot, !slot.busy { slot.cached = image }
            }
        }
    }
    private func closeDeparture(_ slot: Slot) {
        let image = slot.proxy?.image ?? slot.cached, from = slot.proxy?.presented ?? slot.presented
        slot.version += 1; slot.proxy?.close(); borders.drop(slot.wid)
        guard let image, config.anim("windowsOut").on else { return }
        let animation = config.anim("windowsOut"), scale = config.popin("windowsOut") ?? 0.92
        let to = Rect(from.x+from.w*(1-scale)/2, from.y+from.h*(1-scale)/2, from.w*scale, from.h*scale)
        let curves = config.sortedCurves(), curve = curves.indices.contains(animation.curve) ? curves[animation.curve].1 : nil
        let duration = min(animation.dur, config.anim("fadeOut").dur)
        let frames = LiteMotion.frames(from: from, to: to, velocity: [], duration: duration, curve: curve, timeScale: config.timeScale)
        let proxy = LiteProxy(image: image, from: from, to: to, motionFrames: frames, appearance: borders.appearance, focused: focused == slot.wid, relativeTo: 0)
        let start = CACurrentMediaTime()
        proxy.animate(frames: frames, duration: duration, started: start, toAlpha: 0)
        departures.append((proxy, start+duration)); proxyMotions += 1
    }
    private func updateBorder(_ slot: Slot) {
        let visible = !slot.busy && slot.alpha > 0 && sys.membership[slot.wid] == sys.workspace && !sys.concealed.contains(slot.wid) && (fullscreen == 0 || fullscreen == slot.wid)
        borders.update(slot.wid, frame: sys.winBounds(slot.wid) ?? slot.presented, focused: focused == slot.wid, visible: visible,
                       duration: config.anim("border").on ? config.anim("border").dur : 0)
    }
    func refreshBorders() {
        for slot in slots.values {
            slot.proxy?.focus(focused == slot.wid, appearance: borders.appearance, config: config)
            updateBorder(slot)
        }
    }
    func shutdown() {
        shuttingDown = true; commands.removeAll()
        cancelMotions()
    }
    func prepareRecovery() {
        commands.removeAll()
        for slot in slots.values {
            slot.version += 1; slot.busy = false; slot.capturing = false; slot.landing = false
            if let proxy = slot.proxy { proxy.freeze(); slot.presented = proxy.presented; sys.presentation[slot.wid] = slot.presented }
        }
        for (proxy, _) in departures { proxy.close() }; departures.removeAll(); borders.close()
    }
    func recovered(_ wid: Int) {
        if let slot = slots.removeValue(forKey: wid) { slot.version += 1; slot.proxy?.close() }
        sys.presentation[wid] = nil; borders.drop(wid)
    }
    func cancelMotions() {
        commands.removeAll()
        for slot in slots.values { slot.version += 1; slot.proxy?.close() }
        for (proxy, _) in departures { proxy.close() }; departures.removeAll(); borders.close()
        sys.presentation.removeAll()
        slots.removeAll()
    }
    var capabilityStatus: JSON {
        .object([("capture", .string(captures.permitted ? "public-screencapturekit" : "permission-missing")),
                 ("animation", .string(captures.permitted ? "captured-proxy" : "direct-ax-fallback")),
                 ("private_ax_id_bridge", .bool(sys.ax.privateIDBridgeAvailable)), ("private_ax_id_sip", .string("documented SIP-on by AeroSpace; not locally verified")),
                 ("engine_channel_used", .bool(false)), ("virtual_workspaces", .bool(true)),
                 ("proxy_motions", .int(proxyMotions)), ("direct_placements", .int(directPlacements)),
                 ("capture_failures", .int(captureFailures)), ("client_opacity", .string("opaque; public API does not set foreign alpha"))])
    }
}

/// Core configure receipts wait for this adapter's final AX frame. They never
/// race the proxy by issuing another physical configure behind its back.
final class LiteConfigureSink: ConfigureSink {
    private let channel: LiteChannel
    private var jobs: [Int: CfgJob] = [:]
    private var tickets: [Int: UInt64] = [:], nextTicket: UInt64 = 0
    private var previous: [Int: Rect] = [:]
    let completed: (CfgResult) -> Void
    init(channel: LiteChannel, completed: @escaping (CfgResult) -> Void) { self.channel = channel; self.completed = completed }
    var idle: Bool { jobs.isEmpty }
    func busy(_ wid: Int) -> Bool { jobs[wid] != nil || channel.busy(wid) }
    func cancel(_ wid: Int) { jobs[wid] = nil; tickets[wid] = nil; previous[wid] = nil }
    func cancelAll() { jobs.removeAll(); tickets.removeAll(); previous.removeAll() }
    func submit(_ batch: [CfgJob]) {
        for job in batch {
            nextTicket &+= 1; tickets[job.wid] = nextTicket
            previous[job.wid] = channel.actual(job.wid); jobs[job.wid] = job
        }
    }
    func drain() {
        for (wid, job) in jobs where !channel.busy(wid) {
            jobs[wid] = nil
            let ticket = tickets[wid], currentSlot = channel.receiptCheck(wid)
            var result = CfgResult(wid: wid, owner: job.owner, to: job.to, got: channel.actual(wid), e: channel.actual(wid) == nil ? -1 : 0, pre: previous.removeValue(forKey: wid))
            result.pid = job.pid; result.birth = job.birth
            result.isCurrent = { [weak self] in
                guard let self, let ticket else { return false }
                return self.tickets[wid] == ticket && currentSlot() && self.channel.destination(wid) == job.to
            }
            completed(result)
        }
    }
}
