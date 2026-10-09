// Дифференциальный тест демона: 160 случайных сценариев по 60 шагов (sync с вкладками, команды,
// новые/закрытые окна, hide_newbies, follow_mouse, отложенные действия, ответы configure, страж,
// realign, on_activate, rescue), прогнанных эталонным классом WM из REFERENCE_hyprwm.py с подделками.
// Swift-порт с такими же подделками должен на каждом шаге дать: тот же ответ, ту же пачку команд в канал,
// те же задания configure, те же системные вызовы (ax_tileable/ax_focus/ws_close/…) и то же состояние.
@testable import HyprCore
import XCTest

final class FakeWorld: SysAPI {
    var t = 1000.0
    var m = (0.0, 0.0)
    var md = false
    var front: Int?
    var tileableM: [Int: Int] = [:]
    var bounds: [Int: Rect] = [:]
    var alphaM: [Int: Double] = [:]
    var pidlevel: [Int: (Int, Int)] = [:]
    var calls: [JSON] = []

    func now() -> Double { t }
    func sleep(_ s: Double) {}
    func snapshot() throws -> Snapshot { throw CmdError("нет снимка в тесте") }
    func winPidLevel(_ wid: Int) -> (pid: Int?, level: Int?) { pidlevel[wid].map { ($0.0, $0.1) } ?? (nil, nil) }
    func frontPid() -> Int? { front }
    func winBounds(_ wid: Int) -> Rect? { bounds[wid] }
    func winAlpha(_ wid: Int) -> Double? { alphaM[wid] }
    func moveToSpace(_ wids: [Int], _ space: Int) {
        calls.append(.array([.string("move_to_space"), .array(wids.map { .int($0) }), .int(space)]))
    }
    func activeSpace() -> UInt64 { 0 }
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
        return 0
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
    var ops: [JSON] = []
    var eng: [EngWin] = []
    var evs: [EngEvent] = []
    var widMax = 0
    var pending: Bool { false }
    var stats: EngStats {
        var s = EngStats()
        s.ticks = 7; s.nactive = 1; s.errors = 0; s.tickUsMax = 147.25; s.tickUsLast = 3.04
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

/// Мир, как его описал генератор, — в подделки.
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

/// state(wm) из генератора.
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
                default: XCTFail("операция \(kind)")
                }
                let ctx = "сценарий \(seed) шаг \(i) \(op.dumps(ensureASCII: false))"
                var want = st["res"]!
                if kind == "cmd", let s = res.string, s.hasPrefix("{"), let w = want.string {
                    res = try JSON.parse(s)                       // status: сравнить как JSON
                    want = try JSON.parse(w)
                }
                if let d = jsonDiff(res, want) { XCTFail("\(ctx): ответ \(d)"); return }
                if let d = jsonDiff(.array(eng.ch.ops), st["chan"]!) { XCTFail("\(ctx): канал \(d)"); return }
                if let d = jsonDiff(.array(rec.jobs), st["jobs"]!) { XCTFail("\(ctx): configure \(d)"); return }
                if let d = jsonDiff(.array(sys.calls), st["calls"]!) { XCTFail("\(ctx): вызовы \(d)"); return }
                if let d = jsonDiff(stateJSON(wm), st["state"]!) { XCTFail("\(ctx): состояние \(d)"); return }
                stepsChecked += 1
            }
            // файлы состояния — байт в байт как у Python (json.dump(indent=1) / json.dump())
            let saved = sc["saved"]!
            let gotState = try? String(contentsOfFile: tmp.path + "/state.json", encoding: .utf8)
            let gotMins = try? String(contentsOfFile: tmp.path + "/mins.json", encoding: .utf8)
            XCTAssertEqual(gotState, saved["state"]!.string, "сценарий \(seed): hyprwm.state.json")
            XCTAssertEqual(gotMins, saved["mins"]!.string, "сценарий \(seed): minsize_app.json")
        }
        print("сверено шагов: \(stepsChecked), видов команд: \(cmds.sorted())")
        XCTAssertGreaterThan(stepsChecked, 5000)
    }
}
