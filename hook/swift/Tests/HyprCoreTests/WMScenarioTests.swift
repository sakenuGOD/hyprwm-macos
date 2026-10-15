// Daemon differential test: 160 random 60-step scenarios (sync with tabs, commands,
// new/closed windows, hide_newbies, follow_mouse, deferred actions, configure responses, watchdog,
// realign, on_activate, rescue), run through reference WM in REFERENCE_hyprwm.py with fakes.
// The Swift port with matching fakes must produce the same response, channel command batch,
// configure jobs, system calls (ax_tileable/ax_focus/ws_close/…), and state at each step.
@testable import HyprCore
import XCTest

final class FakeWorld: SysAPI {
    var t = 1000.0
    var m = (0.0, 0.0)
    var md = false
    var front: Int?
    var activeSpaceID:UInt64=0
    var tileableM: [Int: Int] = [:]
    var bounds: [Int: Rect] = [:]
    var alphaM: [Int: Double] = [:]
    var pidlevel: [Int: (Int, Int)] = [:]
    var calls: [JSON] = []
    var contexts: [Int: (Int?, Int)] = [:]
    var focusResult=0
    var deferredFocus=false
    var focusCallbacks:[(FocusRequest,(Bool)->Void)]=[]
    var births: [Int: String] = [:]
    var protectedPIDs = Set<Int>()
    var tabProperties: [Int: TabProperty] = [:]
    var propertyRead: (() -> Void)?
    var locked = false
    var overlay = false
    var launch:LauncherIntent?
    var capabilities:[Int:Int]=[:]
    var applicationPaths:[Int:String]=[:]
    var deferredClose=false
    var closeCallbacks:[(CloseResult)->Void]=[]
    var resizeContexts:[Int:NativeResizeContext]=[:]
    var pointerHint:(wid:Int,pid:Int?)?
    var nativeSnapshot:Snapshot?
    func processUID(_ pid:Int) -> Int? {Int(getuid())}
    var transferCatalog:PublicWorkspaceCatalog?
    var transferRequests:[LauncherTransferFocus]=[]
    var transferAccepted=true
    var exitedPIDs=Set<Int>()
    var windowPresenceM:[Int:Int]=[:]
    func windowPresence(_ pid:Int,_ wid:Int) -> Int {windowPresenceM[wid] ?? -1}
    func launcherCatalog() -> PublicWorkspaceCatalog? {transferCatalog}
    func requestTransferFocus(_ request:LauncherTransferFocus,completion:@escaping(Bool)->Void) {transferRequests.append(request);completion(transferAccepted)}
    func cancelTransferFocus() {}
    func processExited(_ pid:Int) -> Bool {exitedPIDs.contains(pid)}
    func pointerHit() -> (wid:Int,pid:Int?)? {pointerHint}
    func requestFocus(_ request:FocusRequest,completion:@escaping(Bool)->Void) {
        if deferredFocus {focusCallbacks.append((request,completion))}
        else {completion(axFocus(request.pid,request.wid,raise:false)==0)}
    }
    func nativeResize(_ pid:Int) -> NativeResizeContext? { resizeContexts[pid] }
    func requestClose(_ pid:Int,_ wid:Int,birth:String,completion:@escaping(CloseResult)->Void) {
        if deferredClose { closeCallbacks.append(completion) } else { completion(CloseResult(code:wsClose(pid,wid))) }
    }
    func launcherIntent(after sequence:UInt64) -> LauncherIntent? { launch.flatMap { $0.sequence > sequence ? $0 : nil } }
    func consumeLauncher(_ sequence:UInt64) { if launch?.sequence == sequence { launch=nil } }
    func clientCapability(_ pid:Int) -> Int { capabilities[pid] ?? 0 }
    func appPath(_ pid:Int) -> String? { applicationPaths[pid] }
    func sessionLocked() -> Bool { locked }
    func interactionOverlay() -> Bool { overlay }
    func tabProperty(_ wid: Int, _ pid: Int) -> TabProperty? { propertyRead?(); return tabProperties[pid] }
    func focusContext(_ pid: Int) -> (wid: Int?, flags: Int) { contexts[pid] ?? (nil, 4) }
    func processBirth(_ pid: Int) -> String? { births[pid] }
    func protectedProcess(_ pid: Int) -> Bool { protectedPIDs.contains(pid) }

    func now() -> Double { t }
    func sleep(_ s: Double) {}
    func snapshot() throws -> Snapshot {if let nativeSnapshot {return nativeSnapshot};throw CmdError("no test snapshot") }
    func winPidLevel(_ wid: Int) -> (pid: Int?, level: Int?) { pidlevel[wid].map { ($0.0, $0.1) } ?? (nil, nil) }
    func frontPid() -> Int? { front }
    func winBounds(_ wid: Int) -> Rect? { bounds[wid] }
    func winAlpha(_ wid: Int) -> Double? { alphaM[wid] }
    func moveToSpace(_ wids: [Int], _ space: Int) {
        calls.append(.array([.string("move_to_space"), .array(wids.map { .int($0) }), .int(space)]))
    }
    func activeSpace() -> UInt64 { activeSpaceID }
    func mouse() -> (Double, Double) { m }
    func mouseDown() -> Bool { md }
    func axTileable(_ pid: Int, _ wid: Int) -> Int {
        calls.append(.array([.string("ax_tileable"), .int(pid), .int(wid)]))
        return tileableM[wid] ?? -1
    }
    func axFrame(_ pid: Int, _ wid: Int, _ r: Rect) -> Int { calls.append(.string("ax_frame?")); return 0 }
    func axGetFrame(_ pid: Int, _ wid: Int) -> Rect? { nil }
    func axForget(_ wid: Int) { calls.append(.array([.string("ax_forget"), .int(wid)])) }
    func axFocus(_ pid: Int, _ wid: Int, raise: Bool) -> Int {
        calls.append(.array([.string("ax_focus"), .int(pid), .int(wid)]))
        return focusResult
    }
    func axMenuPress(_ pid: Int, _ title: String) -> Int { calls.append(.string("menu?")); return 0 }
    func wsClose(_ pid: Int, _ wid: Int) -> Int {
        calls.append(.array([.string("ws_close"), .int(pid), .int(wid)]))
        return 0
    }
    func wsQuit(_ pid: Int) -> Int {
        calls.append(.array([.string("ws_quit"), .int(pid)]))
        return 0
    }
    func spotlight() { calls.append(.string("spotlight?")) }
    func pgrep(_ name: String) -> Int? { nil }
    func spawn(_ argv: [String]) { calls.append(.string("spawn?")) }
    func background(_ f: @escaping () -> Void) { f() }
}

final class FakeChannel: ChannelAPI {
    var decorationFocused:Int?
    func decorationFocus(_ wid:Int,fullscreen:Int) {decorationFocused=wid}
    var terminalEnabled=false
    var terminalGeometrySupported:Bool {terminalEnabled}
    func geomTerminal(_ wid:Int,to:Rect,curves:(Int,Int),durations:(Double,Double),from:Rect?) -> Bool {
        guard terminalEnabled else{return false}
        geom(wid,to,curves.0,curves.1,dpos:durations.0,dsize:durations.1,frm:from,move:false,warp:false,stretch:false)
        ops[ops.count-1]=ops.last!.setting("move_end",.bool(true));return true
    }
    var nativeRequests:[Int]=[]
    var snapshotEnabled=false
    var snapshotRequests:[Int]=[]
    var snapshotSupported:Bool {snapshotEnabled}
    var engineTime:Double {10}
    var batchTime:Double=10
    var batchAfterEnqueue:Double?
    var snapshotBatchTime:Double {batchTime}
    func snapshotGeometry(_ wid:Int,to:Rect,curves:(Int,Int),durations:(Double,Double),from:Rect?) -> Bool {
        guard snapshotEnabled else{return false};snapshotRequests.append(wid);if let batchAfterEnqueue {batchTime=batchAfterEnqueue};return true
    }
    var ops: [JSON] = []
    var eng: [EngWin] = []
    var evs: [EngEvent] = []
    var widMax = 0
    var nativeTick=7
    var nativeActiveCount=1,nativeHolding=0
    var ringPending=false
    var pending: Bool { ringPending }
    var stats: EngStats {
        var s = EngStats()
        s.ticks = nativeTick; s.nactive = nativeActiveCount; s.holding=nativeHolding; s.errors = 0; s.tickUsMax = 147.25; s.tickUsLast = 3.04
        return s
    }
    func geom(_ wid: Int, _ to: Rect, _ cpos: Int, _ csize: Int, dpos: Double, dsize: Double, frm: Rect?, move: Bool,
              warp: Bool, stretch: Bool) {
        ops.append(.object([("op", .string(warp ? "warp" : "geom")), ("wid", .int(wid)), ("to", to.json),
                            ("frm", frm?.json ?? .null), ("cpos", .int(cpos)), ("csize", .int(csize)),
                            ("dpos", .double(dpos)), ("dsize", .double(dsize)), ("move", .bool(move)),
                            ("stretch", .bool(stretch))]))
    }
    func alpha(_ wid: Int, _ a: Double, _ curve: Int, _ dur: Double, frm: Double?) {
        ops.append(.object([("op", .string("alpha")), ("wid", .int(wid)), ("a", .double(a)), ("curve", .int(curve)),
                            ("dur", .double(dur)), ("frm", frm.map { .double($0) } ?? .null)]))
    }
    func geometry(_ wid:Int,to:Rect,curves:(Int,Int),durations:(Double,Double),from:Rect?,warp:Bool,stretch:Bool,native:Bool,wait:Bool,hold:Bool) {
        if native { nativeRequests.append(wid) }
        geom(wid,to,curves.0,curves.1,dpos:durations.0,dsize:durations.1,frm:from,move:true,warp:warp,stretch:stretch)
        if wait {ops[ops.count-1]=ops.last!.setting("wait",.bool(true))}
        if hold {ops[ops.count-1]=ops.last!.setting("hold",.bool(true))}
    }
    func space(_ wid: Int, _ sid: Int) { ops.append(.object([("op", .string("space")), ("wid", .int(wid)), ("space", .int(sid))])) }
    func under(_ wid: Int, _ under: Int) { ops.append(.object([("op", .string("under")), ("wid", .int(wid)), ("under", .int(under))])) }
    func forget(_ wid: Int) { ops.append(.object([("op", .string("forget")), ("wid", .int(wid))])) }
    func commit() { ops.append(.object([("op", .string("commit"))])) }
    func events() -> [EngEvent] { defer { evs = [] }; return evs }
    func wins() -> [EngWin] { eng }
}

final class FakeEngine: EngineAPI {
    let ch = FakeChannel()
    let cfg: HyprConfig
    init(cfg: HyprConfig) { self.cfg = cfg }
    var c: ChannelAPI { ch }
    func anim(_ leaf: String) -> (curve: Int, dur: Double, on: Bool) { cfg.anim(leaf) }
    func alive() -> Bool { true }
    func ensure(startup: Bool) throws {}
}

final class JobRecorder: ConfigureSink {
    var jobs: [JSON] = []
    func submit(_ js: [CfgJob]) {
        jobs += js.map { .array([.int($0.wid), .int($0.pid), .string($0.owner), $0.to.json]) }
    }
}

/// Load the generator world into the fakes.
func install(_ w: JSON, _ sys: FakeWorld, _ ch: FakeChannel) -> (Rect, Int, [WinInfo]) {
    sys.t = w["now"]!.double!
    let m = w["mouse"]!.array!
    sys.m = (m[0].double!, m[1].double!)
    sys.md = w["md"]!.truthy
    sys.front = w["front"]!.int
    sys.tileableM = Dictionary(uniqueKeysWithValues: w["tileable"]!.object!.map { (Int($0.0)!, $0.1.int!) })
    sys.bounds = Dictionary(uniqueKeysWithValues: w["bounds"]!.object!.map { (Int($0.0)!, Rect.j($0.1)!) })
    sys.alphaM = Dictionary(uniqueKeysWithValues: w["alpha"]!.object!.map { (Int($0.0)!, $0.1.double!) })
    sys.pidlevel = Dictionary(uniqueKeysWithValues: w["pidlevel"]!.object!.map {
        (Int($0.0)!, ($0.1.array![0].int!, $0.1.array![1].int!)) })
    ch.eng = w["eng"]!.array!.map { e in
        let p = e["pos"]!.array!, s = e["size"]!.array!
        return EngWin(wid: e["wid"]!.int!, pos: (p[0].double!, p[1].double!), size: (s[0].double!, s[1].double!),
                      posActive: e["posActive"]!.truthy, sizeActive: e["sizeActive"]!.truthy,
                      alphaActive: e["alphaActive"]!.truthy, settling: e["settling"]!.truthy,
                      curAlpha: e["curAlpha"]!.double!, held: e["held"]!.truthy, radius: e["radius"]!.double!,
                      a: Rect.j(e["a"])!)
    }
    ch.evs = w["events"]!.array!.map {
        let a = $0.array!
        return EngEvent(type: a[0].int!, wid: a[1].int!, t: a[2].double!, rect: Rect.j(a[3])!)
    }
    return (Rect.j(w["area"])!, w["space"]!.int!, w["wins"]!.array!.map(WinInfo.from))
}

/// state(wm) from the generator.
func stateJSON(_ wm: WM) -> JSON {
    func ints(_ a: [Int]) -> JSON { .array(a.map { .int($0) }) }
    func opt(_ v: Int?) -> JSON { v.map { .int($0) } ?? .null }
    return .object([
        ("spaces", .object(wm.spaces.map { k, s in
            (k, .object([("tree", s.tree?.json ?? .null), ("focus", opt(s.focus)), ("full", opt(s.full)),
                         ("presel", s.presel.map { .string($0) } ?? .null),
                         ("fullmode", s.fullmode.map { .string($0) } ?? .null)]))
        })),
        ("target", .object(wm.target.map { (String($0.key), $0.value.json) })),
        ("hidden", wm.stateJSON["hidden"]!),
        ("floating", ints(wm.floating.sorted())), ("restoring", ints(wm.restoring.sorted())),
        ("closing", ints(wm.closing.sorted())), ("newbies", ints(wm.newbies.keys)), ("optimistic", ints(wm.optimistic.keys)),
        ("mins", wm.minsJSON), ("own_focus", opt(wm.ownFocus.pid)), ("fwant", opt(wm.fwant)),
        ("later", .int(wm.later.count)), ("pids", .object(wm.pids.map { (String($0.key), .int($0.value)) })),
    ])
}

final class WMScenarioTests: XCTestCase {
    // The frozen Python fixtures predate the user-facing English translation.
    // Translate response prefixes only; channel jobs, calls and state stay exact.
    private func englishReferenceResponse(_ response:String)->String {
        let prefixes=[("всё видно","all visible"),("скрытых нет","no hidden windows"),
            ("нет окна: ","no window: "),("нет окна","no window"),("не знаю команду: ","unknown command: "),
            ("нечего запускать","nothing to launch"),("пусто","empty"),("закрываю ","closing "),
            ("скрыто ","hidden "),("показаны ","shown "),("фокус -> ","focus -> "),
            ("возвращено ","restored "),("завершить ","quit "),("спрятано снова ","hidden again "),
            ("уже скрыто ","already hidden ")]
        return response.components(separatedBy:"; ").map { part in
            guard let (old,new)=prefixes.first(where:{part.hasPrefix($0.0)}) else{return part}
            var translated=new+part.dropFirst(old.count)
            if old=="закрываю ",translated.hasSuffix(" мс)") {translated=String(translated.dropLast(4))+" ms)"}
            return translated
        }.joined(separator:"; ")
    }
    func testScenariosMatchPython() throws {
        let cfg = try Fx.config()
        let all = try Fx.load("wm_scenarios.json").array!
        XCTAssertGreaterThanOrEqual(all.count, 100)
        var stepsChecked = 0, cmds = Set<String>()
        hyprLogSink = { _ in }
        defer { hyprLogSink = { FileHandle.standardOutput.write(($0 + "\n").data(using: .utf8)!) } }
        for sc in all {
            let seed = sc["seed"]!.int!
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hyprwm-swift-test-\(seed)-\(getpid())")
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let sys = FakeWorld()
            sys.t = 1000
            let eng = FakeEngine(cfg: cfg)
            let rec = JobRecorder()
            let wm = WM(sys: sys, eng: eng, deco: NullDeco(), cfg: cfg, statePath: tmp.path + "/state.json",
                        minsizePath: tmp.path + "/mins.json", cfgSink: rec)
            for (i, st) in sc["steps"]!.array!.enumerated() {
                let (area, space, wins) = install(st["world"]!, sys, eng.ch)
                sys.calls = []; eng.ch.ops = []; rec.jobs = []
                let op = st["op"]!
                let kind = op["op"]!.string!
                var res: JSON = .null
                switch kind {
                case "sync":
                    let (ch, opened) = wm.sync(area, space, wins)
                    if ch { wm.apply(area, space, wins, opening: opened) }
                    res = .array([.bool(ch), .array(opened.map { .int($0) })])
                case "cmd":
                    let line = op["line"]!.string!
                    cmds.insert(line.split(separator: " ").first.map(String.init) ?? "")
                    do { res = .string(try wm.command(line, area, space, wins)) } catch { res = .string("EXC") }
                case "events":
                    let d = wm.handleEvents(eng.ch.events())
                    if d { wm.apply(area, space, wins) }
                    res = .bool(d)
                case "hide_newbies": wm.hideNewbies(space, wins)
                case "follow_mouse": wm.followMouse(space, wins)
                case "advance": wm.runDue()
                case "cfg":
                    wm.cfgQ.append(CfgResult(wid: op["wid"]!.int!, owner: op["owner"]!.string!, to: Rect.j(op["to"])!,
                                             got: Rect.j(op["got"]), e: op["e"]!.int!, pre: Rect.j(op["pre"])))
                    let ch = wm.configured()
                    if ch { wm.apply(area, space, wins) }
                    res = .bool(ch)
                case "alpha_guard": wm.alphaGuard(wins)
                case "realign":
                    let m = wm.realign(area, space, wins)
                    if m { wm.apply(area, space, wins) }
                    res = .bool(m)
                case "activate": wm.onActivate(area, space, wins, op["pid"]!.int!)
                case "rescue": res = .string(wm.rescue(area, space, wins, keepHidden: op["keep_hidden"]!.truthy))
                default: XCTFail("operation \(kind)")
                }
                let ctx = "scenario \(seed) step \(i) \(op.dumps(ensureASCII: false))"
                var want = st["res"]!
                if let response=want.string {want = .string(englishReferenceResponse(response))}
                if kind == "cmd", let s = res.string, s.hasPrefix("{"), let w = want.string {
                    res = try JSON.parse(s)                       // status: compare as JSON
                    want = try JSON.parse(w)
                }
                if let d = jsonDiff(res, want) { XCTFail("\(ctx): response \(d)"); return }
                if let d = jsonDiff(.array(eng.ch.ops), st["chan"]!) { XCTFail("\(ctx): channel \(d)"); return }
                if let d = jsonDiff(.array(rec.jobs), st["jobs"]!) { XCTFail("\(ctx): configure \(d)"); return }
                if let d = jsonDiff(.array(sys.calls), st["calls"]!) { XCTFail("\(ctx): calls \(d)"); return }
                if let d = jsonDiff(stateJSON(wm), st["state"]!) { XCTFail("\(ctx): state \(d)"); return }
                stepsChecked += 1
            }
            // state files match Python byte for byte (json.dump(indent=1) / json.dump())
            let saved = sc["saved"]!
            let gotState = try? String(contentsOfFile: tmp.path + "/state.json", encoding: .utf8)
            let gotMins = try? String(contentsOfFile: tmp.path + "/mins.json", encoding: .utf8)
            XCTAssertEqual(gotState, saved["state"]!.string, "scenario \(seed): hyprwm.state.json")
            XCTAssertEqual(gotMins, saved["mins"]!.string, "scenario \(seed): minsize_app.json")
        }
        print("steps checked: \(stepsChecked), command types: \(cmds.sorted())")
        XCTAssertGreaterThan(stepsChecked, 5000)
    }
}
