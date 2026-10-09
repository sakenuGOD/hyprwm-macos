// Демон тайлинга — порт класса WM из hook/hyprwm.py (снимок-эталон: hook/swift/REFERENCE_hyprwm.py).
//
// Кто что делает (как в Python):
// - демон: дерево dwindle на каждый рабочий стол macOS, события (открытие/закрытие окна, бинды) ->
//   целевые рамки -> ОДНА пачка команд движку (все окна события стартуют в одном кадре, как в Hyprland);
// - движок (src/anim4.c внутри WS) ведёт видимую рамку и альфу по кривым Hyprland;
// - приложению конечный размер сообщается один раз (configure через AX), без его анимации.
//
// Отличие устройства от Python (целевая архитектура fable_plan §2.1–2.2):
// - один владелец состояния окна — этот объект, и он живёт только на главной очереди. Потоков, которые
//   трогают состояние, нет: ответы configure приходят на главную очередь событием (cfgQ), а не через
//   общий queue.Queue из чужого потока;
// - configure — последовательная очередь на приложение, «последняя цель побеждает» (Configurer);
// - команды сокета обрабатываются сразу по событию готовности сокета (DispatchSource), а такт 16 мс —
//   таймер (не select с опросом).
// Методы ниже повторяют Python строка в строку; где поведение сознательно отличается — помечено «ОТЛИЧИЕ».
import Foundation

public let TOL = 6.0               // допуск размера, pt (Terminal округляет до сетки символов)
public let RESIZABLE = 1 << 3      // NSWindowStyleMaskResizable
public let DIRS: [String: String] = ["l": "left", "r": "right", "u": "up", "d": "down",
                                     "left": "left", "right": "right", "up": "up", "down": "down"]

/// Состояние рабочего стола: {tree, focus, full, presel[, fullmode]} — ссылочное, как dict в Python.
public final class SpaceState {
    public var tree: Node?
    public var focus: Int?
    public var full: Int?
    public var presel: String?
    public var fullmode: String?
    var hasFullmode = false
    public init() {}

    static func from(_ j: JSON) -> SpaceState {
        let s = SpaceState()
        s.tree = Node.from(j["tree"])
        s.focus = j["focus"]?.int
        s.full = j["full"]?.int
        s.presel = j["presel"]?.string
        if let fm = j["fullmode"] { s.hasFullmode = true; s.fullmode = fm.string }
        return s
    }
    var json: JSON {
        var kv: [(String, JSON)] = [("tree", tree?.json ?? .null), ("focus", focus.map { .int($0) } ?? .null),
                                   ("full", full.map { .int($0) } ?? .null), ("presel", presel.map { .string($0) } ?? .null)]
        if hasFullmode { kv.append(("fullmode", fullmode.map { .string($0) } ?? .null)) }
        return .object(kv)
    }
}

/// Скрытое окно (special:hidden): {wid, pid, owner, space, rect}.
public struct Hidden: Equatable {
    public var wid: Int
    public var pid: Int?
    public var owner: String
    public var space: Int?
    public var rect: [Double]
    static func from(_ j: JSON) -> Hidden {
        Hidden(wid: j["wid"]?.int ?? 0, pid: j["pid"]?.int, owner: j["owner"]?.string ?? "",
               space: j["space"]?.int, rect: j["rect"]?.array?.compactMap(\.double) ?? [])
    }
    var json: JSON {
        .object([("wid", .int(wid)), ("pid", pid.map { .int($0) } ?? .null), ("owner", .string(owner)),
                 ("space", space.map { .int($0) } ?? .null), ("rect", .array(rect.map { .double($0) }))])
    }
}

public struct WinTypeInfo {
    public var type: String       // "primary" | "other"
    public var style: Int
    public var t: Double
    public var n: Int
}

public struct CmdError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

public enum HiddenPick {
    case wids([Int])
    case filter((Hidden) -> Bool)
}

public final class WM {
    public let sys: SysAPI
    public let eng: EngineAPI
    public let deco: DecoAPI
    public let cfg: HyprConfig
    public let tile: Dwindle
    public var cfgSink: ConfigureSink?
    public var server: CommandServer?
    public let statePath: String, minsizePath: String
    public var saveEnabled = true

    public var spaces = OrderedMap<String, SpaceState>()   // space -> {tree, focus, full, presel}
    public var floating = Set<Int>()
    // owner -> [w, h]; числа хранятся как JSON (int/float), чтобы minsize_app.json был байт-в-байт как у Python
    public var mins = OrderedMap<String, [JSON]>()
    public var owner: [Int: String] = [:]                  // wid -> имя приложения
    public var cfgQ: [CfgResult] = []                      // ответы configure (кладёт главная очередь)
    public var info: [Int: [Int: WinTypeInfo]] = [:]       // pid -> wid -> {type, style}
    public var miss: [Int: (Int, Double)] = [:]            // wid -> (попыток, когда)
    public var target: [Int: Rect] = [:]                   // wid -> последняя цель, отданная движку
    public var pids: [Int: Int] = [:]                      // wid -> pid (для узнавания вкладок)
    public var goneT: [Int: Double] = [:]                  // wid -> когда движок сообщил, что окна нет
    public var newbies = OrderedMap<Int, Double>()         // wid -> когда движок увидел новое окно
    public var optimistic = OrderedMap<Int, Double>()      // wid -> когда спрятано заранее
    public var hidden: [Hidden] = []                       // скрытые (special:hidden)
    public var restoring = Set<Int>()                      // возвращаемые из скрытых: drift + fadeIn
    public var later: [(Double, () -> Void)] = []          // [(когда, функция)]
    public var closing = Set<Int>()
    public var frontPid: Int?                              // переднее приложение
    public var ownFocus: (pid: Int?, t: Double) = (nil, 0) // активацию сделали мы сами (follow_mouse)
    public var dimSince: [Int: Double] = [:]               // wid -> когда замечено «α<1 без причины»
    public var movedT: [Int: [Double]] = [:]               // wid -> [когда] возвращали в плитку по EV_MOVED
    public let floatRules: [JSON]
    public var snaps = 0
    // getattr(self, "_…") из Python
    public var mp: (Double, Double)?
    public var fwant: Int?
    var ft = 0.0
    var sampled = 0.0
    var errorsSeen = 0
    // состояние главного цикла (локальные переменные run() в Python)
    var lastSpace: Int?
    var lastEng: Double
    var wasDown = false
    var rescued = false
    var lastGuard = 0.0
    public var last: (area: Rect, space: Int, wins: [WinInfo])?
    var lastSnap = 0.0
    var lastSp: UInt64?
    private var regexCache: [String: NSRegularExpression?] = [:]

    public init(sys: SysAPI, eng: EngineAPI, deco: DecoAPI, cfg: HyprConfig, statePath: String, minsizePath: String,
                cfgSink: ConfigureSink? = nil) {
        self.sys = sys; self.eng = eng; self.deco = deco; self.cfg = cfg
        self.tile = cfg.makeDwindle()
        self.statePath = statePath; self.minsizePath = minsizePath; self.cfgSink = cfgSink
        lastEng = sys.now()
        if let d = FileManager.default.contents(atPath: statePath), let st = try? JSON.parse(d) {
            for (k, v) in st["spaces"]?.object ?? [] { spaces[k] = SpaceState.from(v) }
            floating = Set((st["floating"]?.array ?? []).compactMap(\.int))
            for hj in st["hidden"]?.array ?? [] {                  // без дублей (старый баг: прятали уже скрытое)
                let h = Hidden.from(hj)
                if hidden.allSatisfy({ $0.wid != h.wid }) { hidden.append(h) }
            }
        }
        if let d = FileManager.default.contents(atPath: minsizePath), let m = try? JSON.parse(d) {
            for (k, v) in m.object ?? [] { mins[k] = v.array ?? [.int(0), .int(0)] }
        }
        floatRules = cfg.floatRules
        let (gi, go) = cfg.gaps()
        let wm = cfg.animation("windowsMove"), wi = cfg.animation("windowsIn")
        log("конфиг: зазоры", pyFloat(gi), "{'top': \(pyFloat(go.top)), 'right': \(pyFloat(go.right)), 'bottom': \(pyFloat(go.bottom)), 'left': \(pyFloat(go.left))}",
            "windowsMove", "\(wm.kind) \(wm.curve) \(pyFloat(wm.speed))", "windowsIn", "\(wi.kind) \(wi.curve) \(pyFloat(wi.speed)) '\(wi.style)'",
            "правил float:", floatRules.count)
    }

    // ── состояние ────────────────────────────────────────────────────────
    public var stateJSON: JSON {
        .object([("spaces", .object(spaces.map { ($0.0, $0.1.json) })),
                 ("floating", .array(floating.sorted().map { .int($0) })),
                 ("hidden", .array(hidden.map(\.json)))])
    }
    public var minsJSON: JSON { .object(mins.map { ($0.0, .array($0.1)) }) }

    public func save() {
        guard saveEnabled else { return }
        // ОТЛИЧИЕ: запись через временный файл + rename (Python писал поверх — при падении посреди
        // записи файл мог остаться обрезанным). Формат тот же: json.dump(indent=1) / json.dump().
        writeAtomic(statePath, stateJSON.dumps(indent: 1))
        writeAtomic(minsizePath, minsJSON.dumps())
    }

    private func writeAtomic(_ path: String, _ s: String) {
        let tmp = path + ".tmp.\(getpid())"
        do {
            try s.write(toFile: tmp, atomically: false, encoding: .utf8)
            if rename(tmp, path) != 0 { throw CmdError("rename: \(String(cString: strerror(errno)))") }
        } catch {
            log("не записать \(path): \(error)")
        }
    }

    @discardableResult
    public func sp(_ space: Int) -> SpaceState { sp(String(space)) }
    public func sp(_ key: String) -> SpaceState {
        if let s = spaces[key] { return s }
        let s = SpaceState()
        spaces[key] = s
        return s
    }

    // ── какие окна тайлить ───────────────────────────────────────────────
    /// Тайлить ли окно: обычное окно с изменяемым размером (спрашиваем приложение напрямую, ~1 мс).
    /// Окна, которых приложение ещё не показало, переспрашиваются с паузой (backoff).
    public func wmInfo(_ pid: Int, _ wid: Int) -> WinTypeInfo? {
        let now = sys.now()
        let i = info[pid]?[wid]
        // положительный ответ — навсегда; отрицательный — переспросить: только что созданное окно
        // бывает ещё не AXStandardWindow / без settable размера (S5.2); первые ~3 с раз в 0.25 с
        if let i, i.type == "primary" || i.n >= 12 || now - i.t < 0.25 { return i }
        let (n, t) = miss[wid] ?? (0, 0)
        // окна ещё нет у приложения: первую секунду — каждый такт, потом с паузой (P26)
        if now - t < (n < 60 ? 0.0 : min(0.05 * pow(2.0, Double(n - 60)), 1.0)) { return nil }
        let r = sys.axTileable(pid, wid)
        if r < 0 {
            miss[wid] = (n + 1, now)
            return i
        }
        miss[wid] = nil
        let ni = WinTypeInfo(type: r == 1 ? "primary" : "other", style: r == 1 ? RESIZABLE : 0, t: now, n: (i?.n ?? 0) + 1)
        info[pid, default: [:]][wid] = ni
        return ni
    }

    private func regex(_ p: String) -> NSRegularExpression? {
        if let r = regexCache[p] { return r }
        let r = try? NSRegularExpression(pattern: p)
        regexCache[p] = r
        return r
    }

    private func search(_ p: String, _ s: String) -> Bool? {
        guard let re = regex(p) else { return nil }        // re.error -> правило пропускается
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    public func ruleFloat(_ w: WinInfo) -> String? {
        for r in floatRules {
            let m = r["match"] ?? .object([])
            var skip = false
            if let t = m["title"] {
                guard let ok = search(t.string ?? "", w.name) else { continue }
                if !ok { skip = true }
            }
            if !skip, let c = m["class"] {
                guard let ok = search(c.string ?? "", w.owner) else { continue }
                if !ok { skip = true }
            }
            if skip { continue }
            if (m.object ?? []).contains(where: { $0.0 != "title" && $0.0 != "class" }) { continue }
            return r["name"]?.string ?? "rule"
        }
        return nil
    }

    public func tileable(_ w: WinInfo) -> Bool {
        if floating.contains(w.wid) { return false }
        guard let i = wmInfo(w.pid, w.wid), i.type == "primary", i.style & RESIZABLE != 0 else { return false }
        return ruleFloat(w) == nil
    }

    // ── раскладка ────────────────────────────────────────────────────────
    public func layout(_ area: Rect, _ s: SpaceState) -> OrderedMap<Int, Rect> {
        // минимумы известны ДО раскладки (по приложению) — окно сразу получает место, в которое влезает
        tile.mins = [:]
        for n in Dwindle.leaves(s.tree) {
            if let o = owner[n.wid!], let m = mins[o], m.count >= 2 { tile.mins[n.wid!] = (m[0].double ?? 0, m[1].double ?? 0) }
        }
        var rects = OrderedMap<Int, Rect>()
        for (wid, b) in tile.boxes(s.tree, area) { rects[wid] = tile.withGaps(b, area) }
        if let f = s.full, rects.contains(f) {
            let go = tile.gapsOut
            if s.fullmode == "fullscreen" {                       // весь экран без зазоров
                rects[f] = area
            } else {                                              // maximized: рабочая область минус gaps_out
                rects[f] = Rect(area.x + go.left, area.y + go.top, area.w - go.left - go.right, area.h - go.top - go.bottom)
            }
        }
        var out = OrderedMap<Int, Rect>()
        for (wid, r) in rects { out[wid] = Rect(pyRound(r.x), pyRound(r.y), pyRound(r.w), pyRound(r.h)) }
        return out
    }

    /// Цели всех окон стола -> одна пачка движку (общий t0) + конечные размеры приложениям.
    public func apply(_ area: Rect, _ space: Int, _ wins: [WinInfo], force: Bool = false, opening: [Int] = []) {
        let s = sp(space)
        let rects = layout(area, s)
        var cur: [Int: WinInfo] = [:]
        for w in wins { cur[w.wid] = w }
        let real = eng.real()
        let c = eng.c
        let (mvC, _, mvOn) = eng.anim("windowsMove")
        let (inC, _, inOn) = eng.anim("windowsIn")
        let (fiC, fiD, fiOn) = eng.anim("fadeIn")
        let pop = cfg.popin("windowsIn")
        var posted: [Int] = [], jobs: [CfgJob] = []
        if !opening.isEmpty && inOn {                            // новое окно — сразу невидимо, до размера и popin
            for wid in opening where !restoring.contains(wid) {   // возвращаемое уже невидимо и пойдёт drift+fadeIn
                c.alpha(wid, 0.0, 0, 0.0, frm: 0.0)
            }
            c.commit()
        }
        var engW: [Int: EngWin] = [:]
        for w in c.wins() { engW[w.wid] = w }
        var vis: [Int: Rect] = [:]
        for w in wins {                                           // видимая рамка: у покоящегося окна = реальная
            if let ew = engW[w.wid], ew.moving { vis[w.wid] = ew.visible } else { vis[w.wid] = real[w.wid] ?? w.rect }
        }
        for (wid, to) in rects {
            guard let cw = cur[wid] else { continue }
            if !force && target[wid] == to { continue }
            if opening.contains(wid) && inOn && !restoring.contains(wid) {
                var frm: Rect?
                if let pop, pop != 0 {                            // popin: от pop% цели, масштаб от центра
                    let sw = max(5.0, to.w * pop), sh = max(5.0, to.h * pop)
                    frm = Rect(to.x + (to.w - sw) / 2, to.y + (to.h - sh) / 2, sw, sh)
                }
                c.geom(wid, to, inC, inC, frm: frm, move: true, stretch: true)   // popin тянет содержимое
                if fiOn { c.alpha(wid, 1.0, fiC, fiD, frm: 0.0) }
            } else {
                // стартовая ВИДИМАЯ рамка явно: приложение может встать в цель раньше, чем движок
                // заберёт команду (AX быстрее тика) — тогда движок взял бы уже новую рамку = телепорт
                var frm: Rect?
                let ew = engW[wid]
                if ew == nil || !ew!.moving { frm = vis[wid] }
                deco.ensure(wid, cw.owner, ew?.radius ?? 0)
                if let u = deco.place(wid, to), u != 0 { c.under(wid, u) }
                c.geom(wid, to, mvC, mvC, frm: frm, move: true, warp: !mvOn)
                if restoring.contains(wid) {
                    restoring.remove(wid)
                    c.alpha(wid, 1.0, fiC, fiOn ? fiD : 0.0)
                }
            }
            target[wid] = to
            posted.append(wid)
            // Приложению — конечный размер сразу и один раз по обеим осям (как xdg configure в Hyprland);
            // позицию ставит движок сразу.
            let a = real[wid] ?? cw.rect
            if opening.contains(wid) || a.maxDiff(to) > 1 {
                if let j = job(cw.pid, wid, to) { jobs.append(j) }  // конечный размер сразу и один раз (Hyprland)
            }
        }
        if !posted.isEmpty {
            c.commit()
            let t = sys.now()                                     // движок принимает пачку в ближайшем тике
            while c.pending && sys.now() - t < 0.05 { sys.sleep(0.001) }
        }
        if !jobs.isEmpty { configure(jobs) }
        if !posted.isEmpty { log(String(format: "событие: %d окон в движок, configure %d", posted.count, jobs.count)) }
        if !posted.isEmpty || force { save() }
    }

    public func job(_ pid: Int, _ wid: Int, _ r: Rect) -> CfgJob? {
        guard wmInfo(pid, wid) != nil else { return nil }
        return CfgJob(wid: wid, pid: pid, owner: owner[wid] ?? "", to: r)
    }

    /// Конечный размер приложениям — сразу после того, как движок принял пачку (очередь на приложение).
    public func configure(_ jobs: [CfgJob]) { cfgSink?.submit(jobs) }

    /// Ответы configure: окно стабильно стоит больше цели — это его минимум; запомнить по приложению.
    /// -> true, если раскладку надо пересчитать (ретаргет в этом же цикле).
    public func configured() -> Bool {
        var changed = false
        while !cfgQ.isEmpty {
            let r = cfgQ.removeFirst()
            if r.e != 0 {
                log("configure окна \(r.wid): ошибка \(r.e)")
                continue
            }
            guard let got = r.got, target[r.wid] == r.to else { continue }
            // Минимум: окно стабильно (поток дождался тишины) и по оси осталось больше цели (S2).
            let m = mins[r.owner] ?? [.int(0), .int(0)]
            let (mw, mh) = (m[0], m[1])
            // max(mw, got) Python: при равенстве остаётся mw (и его тип int/float)
            let nw: JSON = got.w > r.to.w + TOL && got.w > (mw.double ?? 0) ? .double(got.w) : mw
            let nh: JSON = got.h > r.to.h + TOL && got.h > (mh.double ?? 0) ? .double(got.h) : mh
            if nw.double != mw.double || nh.double != mh.double {
                mins[r.owner] = [nw, nh]
                log("минимум \(r.owner): [\(pyNum(nw)), \(pyNum(nh))] (окно \(r.wid): \(r.pre.map { pyIntTuple([$0.w, $0.h]) } ?? "None") -> \(pyIntTuple([got.w, got.h])), цель \(pyFloatTuple([r.to.w, r.to.h])))")
                changed = true
            } else if abs(got.w - r.to.w) > TOL || abs(got.h - r.to.h) > TOL {
                log("окно \(r.owner) \(r.wid) стоит \(pyIntTuple([got.w, got.h])) вместо \(pyFloatTuple([r.to.w, r.to.h])) — держу в плитке")
            }
        }
        return changed
    }

    /// Дерево стола <- его видимые окна. -> (изменилось ли, новые окна).
    public func sync(_ area: Rect, _ space: Int, _ wins: [WinInfo]) -> (Bool, [Int]) {
        let s = sp(space)
        let hid = Set(hidden.map(\.wid))
        let live = wins.filter { $0.space == space && $0.on && !hid.contains($0.wid) && !closing.contains($0.wid) && tileable($0) }
        let ids = live.map(\.wid)
        let idSet = Set(ids)
        var have = Set(Dwindle.leaves(s.tree).map { $0.wid! })
        var changed = false, opened: [Int] = []
        // Вкладки (Ghostty, Finder, Safari): у macOS это отдельные окна одной группы, видна одна.
        // Ушло окно X и в этот же момент появилось окно того же приложения на его месте —
        // это переключение вкладки: новое окно занимает лист X, раскладка не меняется.
        // ОТЛИЧИЕ: в Python порядок gone — порядок хеш-множества (не задан); здесь — по возрастанию wid.
        var gone = have.subtracting(idSet).sorted()
        let alive = Set(wins.map(\.wid))
        // ушедшие «на задний план» (вкладку заслонила другая) или закрытые (Cmd+W вкладки — показалась соседняя)
        let offscreen = Set(gone.filter { x in !hid.contains(x) && (!alive.contains(x) || wins.contains { $0.wid == x && !$0.on }) })
        for w in live {
            if have.contains(w.wid) { continue }
            var twin = gone.first { x in pids[x] == w.pid && target[x] != nil && target[x]!.maxDiff(w.rect) <= TOL }
            if twin == nil {
                // рамка новой вкладки в первые кадры бывает ещё не рамкой группы; признак надёжнее: окно того
                // же приложения в этот же момент ушло с экрана, но живо (не закрыто) — его заслонила вкладка
                twin = gone.first { x in pids[x] == w.pid && offscreen.contains(x) }
            }
            guard let tw = twin else { continue }
            for n in Dwindle.leaves(s.tree) where n.wid == tw { n.wid = w.wid }
            gone.removeAll { $0 == tw }
            have.remove(tw); have.insert(w.wid)
            // ОТЛИЧИЕ: в Python self.target.pop(twin) без умолчания — KeyError (падение демона), если у старой
            // вкладки цели уже нет (её снял EV_GONE/EV_MOVED/unhide). Здесь просто не переносим цель.
            if let t = target.removeValue(forKey: tw) { target[w.wid] = t }
            if s.focus == tw { s.focus = w.wid }
            if s.full == tw { s.full = w.wid }
            // Вкладка у macOS появляется мгновенно — без анимации. Её могли спрятать до popin
            // (hide_newbies): вернуть альфу. Старой вкладке — освободить слот движка.
            let c = eng.c
            c.alpha(w.wid, 1.0, 0, 0.0)
            c.forget(tw)
            c.commit()
            newbies[w.wid] = nil
            optimistic[w.wid] = nil
            dimSince[w.wid] = nil
            deco.drop(tw)
            deco.ensure(w.wid, w.owner, 0)
            log("вкладка \(w.owner): \(tw) -> \(w.wid) (место в раскладке то же)")
        }
        for w in live { pids[w.wid] = w.pid }
        for wid in have.subtracting(idSet).sorted() {
            let g = goneT.removeValue(forKey: wid)
            log("окно \(wid) ушло из раскладки" + (g.map { String(format: " (через %.0f мс после движка)", (sys.now() - $0) * 1000) } ?? " (движок не сообщал)"))
            s.tree = Dwindle.remove(s.tree, wid)
            target[wid] = nil
            if s.full == wid { s.full = nil }
            changed = true
        }
        have.formIntersection(idSet)
        // активное окно (Hyprland делит именно его) — самое переднее тайловое окно стола
        s.focus = ids.first { have.contains($0) } ?? (s.focus.map { have.contains($0) } == true ? s.focus : nil)
        for w in live {
            if have.contains(w.wid) { continue }
            let tgt = s.focus.map { have.contains($0) } == true ? s.focus : nil
            s.tree = insert(s, w.wid, tgt, area)
            have.insert(w.wid)
            s.focus = w.wid
            opened.append(w.wid)
            log("новое окно \(w.owner) (\(w.wid)) -> в раскладку")
            deco.ensure(w.wid, w.owner, 0)
            changed = true
        }
        return (changed, opened)
    }

    /// dwindle-вставка: preselect задаёт сторону; без него — сторона по курсору (force_split 0)
    /// или по точке point (перенос направлением: focal за краем окна).
    public func insert(_ s: SpaceState, _ wid: Int, _ target: Int?, _ area: Rect, point: (Double, Double)? = nil) -> Node {
        let pre = s.presel
        let bx = target != nil ? tile.boxes(s.tree, area) : OrderedMap<Int, Rect>()
        let tree = tile.insert(s.tree, wid, target, area)
        let par = target != nil ? Dwindle.findParent(tree, wid) : nil
        if let par, par.b.wid == wid {
            var first = false
            if let pre, !pre.isEmpty {
                par.split = (pre == "left" || pre == "right") ? "v" : "h"
                first = pre == "left" || pre == "up"
                s.presel = nil
            } else if let t = target, let b = bx[t] {
                let (mx, my) = point ?? sys.mouse()
                first = par.split == "v" ? mx < b.x + b.w / 2 : my < b.y + b.h / 2
            }
            if first { swap(&par.a, &par.b) }
        }
        return tree
    }

    // ── команды (бинды) ──────────────────────────────────────────────────
    static func isDigits(_ s: String) -> Bool { !s.isEmpty && s.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 } }

    /// Python float(): ValueError -> исключение (команда «падает», ответа нет — как в Python).
    static func pyFloatParse(_ s: String) throws -> Double {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")
        let low = t.lowercased()
        if ["inf", "+inf", "infinity", "+infinity"].contains(low) { return .infinity }
        if ["-inf", "-infinity"].contains(low) { return -.infinity }
        if ["nan", "+nan", "-nan"].contains(low) { return .nan }
        guard let v = Double(t), !t.isEmpty else { throw CmdError("ValueError: could not convert string to float: '\(s)'") }
        return v
    }

    public func command(_ line: String, _ area: Rect, _ space: Int, _ wins: [WinInfo]) throws -> String {
        let a = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let cmd = a.first else { return "пусто" }
        let s = sp(space)
        let rects = layout(area, s)
        let cur = wins.first { rects.contains($0.wid) && $0.on }?.wid      // переднее разложенное
        if cmd == "status" { return statusJSON(space, s, cur, rects).dumps(ensureASCII: false) }
        if (cmd == "focus" || cmd == "move") && a.count > 1 {
            let d = DIRS[a[1]]
            var tgt: Int?
            if let cur, cur != 0, let d { tgt = Dwindle.neighbour(rects, cur, d) }
            guard let tgt else { return "нет окна: \(a[1])" }
            if cmd == "focus" {
                guard let pid = wins.first(where: { $0.wid == tgt })?.pid else { throw CmdError("StopIteration") }
                ownFocus = (pid, sys.now())
                let r = sys.axFocus(pid, tgt, raise: false)        // именно окно; z тайловых не меняем (Hyprland)
                return "фокус -> \(tgt) (\(r))"
            }
            moveDir(s, area, cur!, d!, rects)
        } else if cmd == "togglesplit" {
            if let par = Dwindle.findParent(s.tree, cur) { par.split = par.split == "v" ? "h" : "v" }
        } else if cmd == "preselect" {
            s.presel = a.count > 1 ? DIRS[a[1]] : nil
            return "preselect \(s.presel ?? "None")"
        } else if cmd == "float" {
            if let w = wins.first(where: { $0.on && $0.space == space })?.wid {
                if floating.contains(w) { floating.remove(w) } else { floating.insert(w) }
            }
        } else if cmd == "fullscreen" {
            let mode = a.count > 1 ? a[1] : "fullscreen"
            if s.full == cur && s.fullmode == mode {
                s.full = nil
            } else {
                s.full = cur; s.fullmode = mode; s.hasFullmode = true
            }
        } else if cmd == "close" {
            let w = a.count > 1 && WM.isDigits(a[1]) ? wins.first { $0.wid == Int(a[1])! } : front(wins, space)
            guard let w else { return "нет окна" }
            return closeAnim(area, space, wins, w)
        } else if cmd == "quit" {
            guard let w = front(wins, space) else { return "нет окна" }
            return "завершить \(w.owner) -> \(sys.wsQuit(w.pid))"
        } else if cmd == "hide" {
            return hide(area, space, wins, a.count > 1 && WM.isDigits(a[1]) ? Int(a[1]) : nil)
        } else if cmd == "unhide" {
            if a.count > 1 && WM.isDigits(a[1]) { return unhide(area, space, wins, which: .wids([Int(a[1])!])) }
            return unhide(area, space, wins, everything: a.count > 1 && a[1] == "all")
        } else if cmd == "rescue" {
            return rescue(area, space, wins)
        } else if cmd == "balance" {
            func bal(_ n: Node?) {
                if let n, !n.isLeaf { n.ratio = 0.5; bal(n.a); bal(n.b) }
            }
            bal(s.tree)
        } else if cmd == "resize" && a.count == 3 {
            let dx = try WM.pyFloatParse(a[1]), dy = try WM.pyFloatParse(a[2])
            resizeActive(s, area, cur, dx, dy)
        } else if cmd == "exec" {
            return execApp(Array(a.dropFirst()))
        } else if cmd == "reset" {
            s.tree = nil; s.full = nil
            mins.removeAll()
            info.removeAll()
        } else if cmd != "retile" {
            return "не знаю команду: \(line)"
        }
        let (_, opened) = sync(area, space, wins)
        apply(area, space, wins, force: cmd == "retile" || cmd == "reset", opening: opened)
        return "ok"
    }

    func statusJSON(_ space: Int, _ s: SpaceState, _ cur: Int?, _ rects: OrderedMap<Int, Rect>) -> JSON {
        let st = eng.c.stats
        func r1(_ v: Double) -> Double { (v * 10).rounded(.toNearestOrEven) / 10 }
        return .object([
            ("space", .int(space)), ("tree", s.tree?.json ?? .null), ("focus", cur.map { .int($0) } ?? .null),
            ("mins", minsJSON),
            ("rects", .object(rects.map { (String($0.0), $0.1.json) })),
            ("floating", .array(floating.sorted().map { .int($0) })), ("hidden", .array(hidden.map { .int($0.wid) })),
            ("engine", .object([("ticks", .int(st.ticks)), ("active", .int(st.nactive)), ("errors", .int(st.errors)),
                                ("slots", .int(eng.c.wins().count)), ("tick_us_max", .double(r1(st.tickUsMax))),
                                ("tick_us_last", .double(r1(st.tickUsLast))), ("ticks_late", .int(st.ticksLate)),
                                ("te_skips", .int(st.teSkips))])),
            ("snaps", .int(snaps)),
        ])
    }

    /// movewindow Hyprland (dwindle moveTargetInDirection): окно вынимается из дерева и вставляется у узла,
    /// ближайшего к точке на 1 px за серединой его стороны; сторона — по этой точке.
    func moveDir(_ s: SpaceState, _ area: Rect, _ cur: Int, _ d: String, _ rects: OrderedMap<Int, Rect>) {
        let r = rects[cur]!
        let g = tile.gapsIn + 1
        let focal: (Double, Double)
        switch d {
        case "left": focal = (r.x - g, r.y + r.h / 2)
        case "right": focal = (r.x + r.w + g, r.y + r.h / 2)
        case "up": focal = (r.x + r.w / 2, r.y - g)
        default: focal = (r.x + r.w / 2, r.y + r.h + g)
        }
        s.tree = Dwindle.remove(s.tree, cur)
        var bx = OrderedMap<Int, Rect>()
        for (k, b) in tile.boxes(s.tree, area) { bx[k] = tile.withGaps(b, area) }
        if bx.isEmpty {
            s.tree = tile.insert(s.tree, cur, nil, area)
            return
        }
        func dist(_ b: Rect) -> Double {
            let dx = max(b.x - focal.0, 0, focal.0 - (b.x + b.w))
            let dy = max(b.y - focal.1, 0, focal.1 - (b.y + b.h))
            return dx * dx + dy * dy
        }
        var near = bx.keys[0], nd = dist(bx[near]!)
        for (k, b) in bx { let v = dist(b); if v < nd { near = k; nd = v } }
        s.tree = insert(s, cur, near, area, point: focal)
    }

    /// killactive как в Hyprland: окно уходит из раскладки (соседи едут в том же кадре), само сжимается
    /// до popin 92% от центра (windowsOut) и гаснет (fadeOut); приложение закрывается в конце.
    /// Не закрылось (диалог «Сохранить?») — вернуть в раскладку.
    public func closeAnim(_ area: Rect, _ space: Int, _ wins: [WinInfo], _ w: WinInfo) -> String {
        let wid = w.wid, s = sp(space)
        let c = eng.c
        let ew = c.wins().last { $0.wid == wid }
        let cur = ew?.visible ?? eng.real()[wid] ?? w.rect
        let (oc, od, on) = eng.anim("windowsOut")
        let (fc, fd, fon) = eng.anim("fadeOut")
        let k = cfg.popin("windowsOut") ?? 0.92
        let to = Rect(cur.x + cur.w * (1 - k) / 2, cur.y + cur.h * (1 - k) / 2, cur.w * k, cur.h * k)
        s.tree = Dwindle.remove(s.tree, wid)
        target[wid] = nil
        closing.insert(wid)
        c.geom(wid, to, oc, oc, dpos: on ? od : 0, dsize: on ? od : 0, frm: cur, move: false, stretch: true)
        c.alpha(wid, 0.0, fc, fon ? fd : 0.0)
        apply(area, space, wins)                                  // соседи — в том же кадре
        c.commit()
        let done = max(on ? od : 0, fon ? fd : 0)
        let pid = w.pid
        later.append((sys.now() + done, { [unowned self] in _ = self.sys.wsClose(pid, wid) }))
        later.append((sys.now() + done + 0.6, { [unowned self] in
            self.closing.remove(wid)
            if self.sys.winBounds(wid) != nil && c.wins().contains(where: { $0.wid == wid }) {
                log("окно \(wid) не закрылось — возвращаю")
                self.restoring.insert(wid)                        // sync вставит обратно: drift из сжатой рамки +
                self.target[wid] = nil                            // fadeIn, а не второй popin (P32)
                self.later.append((self.sys.now() + 1.5, { [unowned self] in self.restoreCheck(wid) }))
            }
        }))
        return String(format: "закрываю %d (%.0f мс)", wid, done * 1000)
    }

    /// Окно в фокусе: самое переднее видимое окно этого стола. Скрытые/закрываемые/невидимые (α≈0) — мимо.
    public func front(_ wins: [WinInfo], _ space: Int) -> WinInfo? {
        let skip = Set(hidden.map(\.wid)).union(closing)
        let dim = Set(eng.c.wins().filter { $0.curAlpha < 0.05 && !$0.alphaActive }.map(\.wid))
        return wins.first { $0.on && $0.space == space && $0.w >= 120 && $0.h >= 120 && !skip.contains($0.wid) && !dim.contains($0.wid) }
    }

    /// M+W: окно гаснет на месте (fadeOut), соседи сразу занимают место; потом уводим за экран.
    public func hide(_ area: Rect, _ space: Int, _ wins: [WinInfo], _ wid0: Int? = nil) -> String {
        let w = (wid0 != nil && wid0 != 0) ? wins.first { $0.wid == wid0 } : front(wins, space)
        guard let w else { return "нет окна" }
        let wid = w.wid
        if hidden.contains(where: { $0.wid == wid }) { return "уже скрыто \(wid)" }
        restoring.remove(wid)
        let s = sp(space)
        let rect = eng.real()[wid] ?? w.rect
        s.tree = Dwindle.remove(s.tree, wid)
        if s.full == wid { s.full = nil }
        target[wid] = nil
        hidden.append(Hidden(wid: wid, pid: w.pid, owner: w.owner, space: space, rect: rect.arr))
        let (foC, foD, foOn) = eng.anim("fadeOut")
        eng.c.alpha(wid, 0.0, foC, foOn ? foD : 0.0)
        apply(area, space, wins)                                  // соседи — в том же кадре, что и затухание
        eng.c.commit()
        let park = Rect(area.x + area.w + 200, rect.y, rect.w, rect.h)
        later.append((sys.now() + foD + 0.05, { [unowned self] in
            if self.hidden.contains(where: { $0.wid == wid }) {
                self.eng.c.geom(wid, park, 0, 0, move: true, warp: true)
                self.eng.c.commit()
            }
        }))
        save()
        return "скрыто \(wid)"
    }

    /// M+Shift+W: последнее скрытое — назад в раскладку ТЕКУЩЕГО стола: drift из прежнего места + fadeIn.
    /// which — выбрать (список wid или фильтр). everything — все сразу и мгновенно (при остановке демона).
    public func unhide(_ area: Rect, _ space: Int?, _ wins: [WinInfo]?, everything: Bool = false, which: HiddenPick? = nil) -> String {
        if hidden.isEmpty { return "скрытых нет" }
        let todo: [Hidden]
        switch which {
        case let .filter(f)?: todo = hidden.filter(f)
        case let .wids(ws)?: todo = hidden.filter { ws.contains($0.wid) }
        case nil: todo = everything ? hidden : [hidden.last!]
        }
        if todo.isEmpty { return "таких скрытых нет" }
        let c = eng.c
        for h in todo {
            if let i = hidden.firstIndex(of: h) { hidden.remove(at: i) }
            let wid = h.wid
            if let space, (h.space.map(String.init) ?? "None") != String(space) {
                sys.moveToSpace([wid], space)                       // скрыли на другом столе — вернуть сюда (P28)
            }
            if let r = Rect(h.rect) { c.geom(wid, r, 0, 0, move: true, warp: true) }   // невидимым — на прежнее место
            let w = (wins ?? []).first { $0.wid == wid }
            if everything {
                c.alpha(wid, 1.0, 0, 0.0)
            } else if let w, !tileable(w) {                        // плавающее — проявить на месте
                let (fiC, fiD, fiOn) = eng.anim("fadeIn")
                c.alpha(wid, 1.0, fiC, fiOn ? fiD : 0.0)
            } else {
                restoring.insert(wid)
                target[wid] = nil
                later.append((sys.now() + 1.5, { [unowned self] in self.restoreCheck(wid) }))
            }
        }
        c.commit()
        save()
        return "возвращено \(pyList(todo.map(\.wid)))"
    }

    /// Возвращаемое окно так и не попало в раскладку (не тайлится, другой стол) — просто показать.
    func restoreCheck(_ wid: Int) {
        if restoring.contains(wid) && hidden.allSatisfy({ $0.wid != wid }) {
            restoring.remove(wid)
            eng.c.alpha(wid, 1.0, 0, 0.0)
            eng.c.commit()
            log("возврат окна \(wid): в раскладку не попало — показываю на месте")
        }
    }

    /// Приложение стало передним не нашим фокусом (Dock, Cmd+Tab, open, уведомление): его скрытые окна
    /// возвращаются в раскладку текущего стола — как Hyprland при активации окна со special:hidden (P44).
    public func onActivate(_ area: Rect, _ space: Int, _ wins: [WinInfo], _ pid: Int) {
        if hidden.isEmpty { return }
        for i in hidden.indices where hidden[i].pid == nil { hidden[i].pid = sys.winPidLevel(hidden[i].wid).pid }
        let mine = hidden.filter { $0.pid == pid }.map(\.wid)
        if mine.isEmpty { return }
        // Клик по видимому окну того же приложения — не повод возвращать скрытое. Возвращаем, если у
        // приложения на этом столе нет видимых окон (Dock/Cmd+Tab/open) или macOS вывел вперёд именно скрытое.
        let hid = Set(hidden.map(\.wid))
        let own = wins.filter { $0.pid == pid && $0.on && $0.w >= 120 && $0.h >= 120 }
        let visible = own.filter { !hid.contains($0.wid) && $0.space == space }
        if visible.isEmpty || (!own.isEmpty && hid.contains(own[0].wid)) {
            log("приложение \(pid) активировано извне — возвращаю скрытые: \(unhide(area, space, wins, which: .wids(mine)))")
        }
    }

    /// Страховка (P44): все скрытые — назад (команда rescue; при старте демона скрытые остаются скрытыми —
    /// keepHidden); окна, оставшиеся невидимыми или за экраном без причины, — показать и вернуть на экран.
    public func rescue(_ area: Rect, _ space: Int, _ wins: [WinInfo], keepHidden: Bool = false) -> String {
        var out: [String] = []
        let alive = Set(wins.map(\.wid))
        hidden = hidden.filter { alive.contains($0.wid) }          // закрытые, пока демона не было
        if !hidden.isEmpty && !keepHidden {
            out.append(unhide(area, space, wins, which: .filter { _ in true }))
        } else if !hidden.isEmpty {                                 // скрытые должны быть скрыты: α=0 и за экраном
            let c = eng.c
            for h in hidden {
                let r = sys.winBounds(h.wid)
                if (sys.winAlpha(h.wid) ?? 0) > 0.001 || (r.map { $0.x < area.x + area.w } ?? false) {
                    c.alpha(h.wid, 0.0, 0, 0.0)
                    if let r { c.geom(h.wid, Rect(area.x + area.w + 200, r.y, r.w, r.h), 0, 0, move: true, warp: true) }
                    out.append("спрятано снова \(h.wid)")
                }
            }
            c.commit()
        }
        let hid = Set(hidden.map(\.wid))
        let c = eng.c
        var fixed: [Int] = []
        for w in wins {
            let wid = w.wid
            if hid.contains(wid) || closing.contains(wid) || w.owner == "hyprdeco" || w.w < 120 || w.h < 120 { continue }
            let a = sys.winAlpha(wid)
            let r = sys.winBounds(wid) ?? w.rect
            let off = r.x >= area.x + area.w - 20 || r.x + r.w <= area.x + 20 || r.y >= area.y + area.h - 20
            if (a == nil || a! >= 0.999) && !off { continue }
            if !restoring.contains(wid) && !tileable(w) { continue }   // служебные невидимые окна приложений не трогаем
            if off && !restoring.contains(wid) {
                c.geom(wid, Rect(area.x + 40, area.y + 40, min(r.w, area.w - 80), min(r.h, area.h - 80)), 0, 0, move: true, warp: true)
            }
            if !restoring.contains(wid) { c.alpha(wid, 1.0, 0, 0.0) }
            target[wid] = nil
            fixed.append(wid)
        }
        c.commit()
        if !fixed.isEmpty { out.append("показаны \(pyList(fixed))") }
        save()
        return out.isEmpty ? "всё видно" : out.joined(separator: "; ")
    }

    /// Движок: покоящееся тайловое окно ушло с цели. Плитка главнее: вернуть тем же drift, но не больше
    /// 3 раз за 10 с на окно. Перетаскивание мышью — не сюда (realign после отпускания).
    public func onMoved(_ wid: Int, _ a: Rect) -> Bool {
        if sys.mouseDown() || target[wid] == nil || closing.contains(wid) { return false }
        let now = sys.now()
        let hist = (movedT[wid] ?? []).filter { now - $0 < 10 }
        if hist.count >= 3 { return false }
        movedT[wid] = hist + [now]
        log("окно \(wid) ушло с плитки \(target[wid]!) -> \(pyIntTuple(a.arr)) — возвращаю")
        target[wid] = nil
        return true
    }

    /// Страж: окно в слоте движка стоит с α<1 без анимации и без причины дольше 1 с — вернуть α=1.
    public func alphaGuard(_ wins: [WinInfo]) {
        let now = sys.now()
        let busy = closing.union(restoring).union(newbies.keys).union(optimistic.keys).union(hidden.map(\.wid))
        let on = Set(wins.filter(\.on).map(\.wid))
        let c = eng.c
        var fix: [Int] = []
        for w in c.wins() {
            if busy.contains(w.wid) || !on.contains(w.wid) || w.curAlpha >= 0.999 || w.alphaActive || w.held {
                dimSince[w.wid] = nil
                continue
            }
            if dimSince[w.wid] == nil { dimSince[w.wid] = now }
            if now - dimSince[w.wid]! > 1.0 { fix.append(w.wid) }
        }
        for wid in fix {
            dimSince[wid] = nil
            c.alpha(wid, 1.0, 0, 0.0)
        }
        if !fix.isEmpty {
            c.commit()
            log("страж: α=1 окнам \(pyList(fix)) (оставались невидимыми без причины)")
        }
    }

    /// resizeactive Hyprland: двигается разделитель ближайшего сплита по оси на dx/dy pt.
    func resizeActive(_ s: SpaceState, _ area: Rect, _ cur: Int?, _ dx: Double, _ dy: Double) {
        var path: [(Node, Rect)] = []
        func walk(_ n: Node?, _ box: Rect) -> Bool {
            guard let n else { return false }
            if let w = n.wid { return cur != nil && w == cur! }
            let (ba, bb) = tile.splitBox(box, n)
            path.append((n, box))
            if walk(n.a, ba) || walk(n.b, bb) { return true }
            path.removeLast()
            return false
        }
        _ = walk(s.tree, area)
        // max/min Python: при NaN возвращается первый аргумент
        func pmax(_ a: Double, _ b: Double) -> Double { b > a ? b : a }
        func pmin(_ a: Double, _ b: Double) -> Double { b < a ? b : a }
        for (d, split) in [(dx, "v"), (dy, "h")] {
            if d == 0 { continue }
            for (n, box) in path.reversed() where n.split == split {
                n.ratio = pmin(0.95, pmax(0.05, (n.ratio ?? 0.5) + d / (split == "v" ? box.w : box.h)))
                break
            }
        }
    }

    /// exec из дотфайла. «Ghostty --new» — новое окно терминала (пункт меню New Window через AX);
    /// «-e prog» — терминал с программой; «spotlight» — лаунчер.
    func execApp(_ args: [String]) -> String {
        guard let app = args.first else { return "нечего запускать" }
        let rest = Array(args.dropFirst())
        if app == "spotlight" {
            sys.spotlight()
            return "лаунчер"
        }
        if rest.first == "--new" {
            if let pid = sys.pgrep(app.lowercased()) {           // обход меню AX — не в главном цикле (S5.3)
                let sys = self.sys
                sys.background {
                    if sys.axMenuPress(pid, "New Window") != 0 { sys.spawn(["open", "-a", app]) }
                }
                return "новое окно \(app)"
            }
            sys.spawn(["open", "-a", app])
        } else if rest.first == "-e" {
            sys.spawn(["open", "-na", app, "--args", "-e"] + rest.dropFirst())
        } else {
            sys.spawn(["open", "-a", app])
        }
        return "запуск \(args.joined(separator: " "))"
    }

    /// Новое окно, которое пойдёт в раскладку, прячется ДО первого показа (альфа 0), чтобы macOS не показал
    /// его на «своём» месте; дальше sync вставляет его в дерево, и оно вырастает popin в плитке.
    public func hideNewbies(_ space: Int, _ wins: [WinInfo]) {
        if newbies.isEmpty && optimistic.isEmpty { return }
        var by: [Int: WinInfo] = [:]
        for w in wins { by[w.wid] = w }
        let c = eng.c
        var touched = false
        var tiledApps = Set<String?>(), tiledPids = Set<Int?>()
        for (_, sp) in spaces {
            for n in Dwindle.leaves(sp.tree) { tiledApps.insert(owner[n.wid!]); tiledPids.insert(pids[n.wid!]) }
        }
        func tab(_ pid: Int?, _ wid: Int) -> Bool {
            // вкладка: новое окно встаёт ровно на рамку тайлового окна того же приложения — его не прятать
            guard let r = sys.winBounds(wid) else { return false }
            return target.contains { pids[$0.key] == pid && $0.value.maxDiff(r) <= TOL }
        }
        for (wid, t) in newbies {
            let w = by[wid]
            if sys.now() - t > 1.5 {
                newbies[wid] = nil
                continue
            }
            if w == nil || w!.w < 120 || w!.h < 120 {
                // окна ещё нет в списке: спросить сервер напрямую — обычный уровень и тайловое приложение
                let (pid, lv) = sys.winPidLevel(wid)
                if lv == 0 && tiledPids.contains(pid) && !optimistic.contains(wid) && !tab(pid, wid) {
                    optimistic[wid] = sys.now()
                    c.alpha(wid, 0.0, 0, 0.0, frm: 0.0)
                    touched = true
                }
                continue
            }
            let w1 = w!
            if tab(w1.pid, wid) {
                newbies[wid] = nil
                if optimistic.removeValue(forKey: wid) != nil {
                    c.alpha(wid, 1.0, 0, 0.0)
                    touched = true
                }
                continue
            }
            if tileable(w1) {
                c.alpha(wid, 0.0, 0, 0.0, frm: 0.0)
                touched = true
                newbies[wid] = nil
                optimistic[wid] = nil
                log(String(format: "новое окно %@ %d спрятано до popin (через %.0f мс после создания)", w1.owner, wid, (sys.now() - t) * 1000))
            } else if info[w1.pid]?[wid] != nil {
                newbies[wid] = nil                                  // точно не тайлится
                if optimistic.removeValue(forKey: wid) != nil {
                    c.alpha(wid, 1.0, 0, 0.0)
                    touched = true
                }
            } else if tiledApps.contains(w1.owner) && !optimistic.contains(wid) {
                optimistic[wid] = sys.now()                         // приложение тайлится — спрятать сразу
                c.alpha(wid, 0.0, 0, 0.0, frm: 0.0)
                touched = true
            }
        }
        for (wid, t) in optimistic {                               // так и не стало тайловым — вернуть видимость
            if !newbies.contains(wid) && sys.now() - t > 1.5 {
                optimistic[wid] = nil
                c.alpha(wid, 1.0, 0, 0.0)
                touched = true
            }
        }
        if touched { c.commit() }
    }

    /// input:follow_mouse = 1: фокус у окна под курсором, как только курсор на него зашёл.
    public func followMouse(_ space: Int, _ wins: [WinInfo]) {
        let p = sys.mouse()
        if let m = mp, m == p { return }
        if sys.mouseDown() { return }
        mp = p
        let s = sp(space)
        let tiled = Set(Dwindle.leaves(s.tree).map { $0.wid! })
        let hid = Set(hidden.map(\.wid))
        let top = wins.first { $0.on && !hid.contains($0.wid) && $0.x <= p.0 && p.0 < $0.x + $0.w && $0.y <= p.1 && p.1 < $0.y + $0.h }
        let frontW = wins.first { $0.on && $0.space == space && $0.w >= 120 && $0.h >= 120 }
        if ProcessInfo.processInfo.environment["HYPRWM_DEBUG"].map({ !$0.isEmpty }) == true {
            log("курсор", "(\(pyFloat(p.0)), \(pyFloat(p.1)))", "верх", top.map { String($0.wid) } ?? "None",
                "перед", frontW.map { String($0.wid) } ?? "None", "тайлы", tiled.sorted())
        }
        guard let top, tiled.contains(top.wid) else { return }
        // без AXRaise z-порядок не меняется, поэтому «уже в фокусе» — по нашей памяти
        if fwant == top.wid && (frontPid == top.pid || sys.now() - ft < 0.3) { return }
        if fwant == nil, let f = frontW, f.wid == top.wid { return }
        fwant = top.wid; ft = sys.now()
        ownFocus = (top.pid, sys.now())
        let r = sys.axFocus(top.pid, top.wid, raise: false)       // без AXRaise: Hyprland не меняет z тайловых (Q3)
        s.focus = top.wid
        log("фокус за курсором -> \(top.owner) \(top.wid) (\(r))")
    }

    /// После отпускания мыши: окно, утащенное из своей плитки, вернуть (как Hyprland после drag).
    public func realign(_ area: Rect, _ space: Int, _ wins: [WinInfo]) -> Bool {
        let s = sp(space)
        let rects = layout(area, s)
        let busy = Set(eng.c.wins().filter(\.moving).map(\.wid))
        let real = eng.real()
        var moved = false
        for (wid, to) in rects {
            let a = real[wid] ?? wins.first { $0.wid == wid }?.rect
            guard !busy.contains(wid), let a else { continue }
            if a.maxDiff(to) > TOL {
                target[wid] = nil
                moved = true
            }
        }
        return moved
    }

    // ── события движка ───────────────────────────────────────────────────
    /// Разбор кольца событий (из run() в Python). -> было ли EV_MOVED, требующее ретаргета.
    public func handleEvents(_ evs: [EngEvent]) -> Bool {
        var drifted = false
        for ev in evs {
            if ev.type == Ev.new {
                newbies[ev.wid] = sys.now()
                continue
            }
            if ev.type == Ev.moved {
                if onMoved(ev.wid, ev.rect) { drifted = true }
                continue
            }
            if ev.type == Ev.gone {
                let wid = ev.wid
                goneT[wid] = sys.now()
                target[wid] = nil
                deco.drop(wid)
                sys.axForget(wid)                                 // AX-кэш не копит мёртвые окна (P7)
                dimSince[wid] = nil
                for pid in Array(info.keys) { info[pid]![wid] = nil }
                miss[wid] = nil
                owner[wid] = nil
            }
        }
        return drifted
    }

    /// Отложенные действия, срок которых настал.
    public func runDue() {
        let now = sys.now()
        let due = later.filter { $0.0 <= now }.map(\.1)
        later = later.filter { $0.0 > now }
        for f in due { f() }
    }

    /// Ближайший срок отложенного действия (для таймера главной очереди).
    public var nextDue: Double? { later.map(\.0).min() }

    // ── такт главного цикла (тело while True в WM.run) ──────────────────
    /// socketReady — по сокету пришла команда (в Python: select вернул сокет).
    public func tick(socketReady r: Bool) {
        if r, let l = last { server?.drain { try self.command($0, l.area, l.space, l.wins) } }   // команды — сразу, до снимка
        runDue()
        if sys.now() - lastEng > 2.0 {                             // WindowServer перезапускался?
            lastEng = sys.now()
            if !eng.alive() {
                target.removeAll()
                do { try eng.ensure(startup: false) } catch { log("движок: \(error)") }
            }
            let e = eng.c.stats.errors
            if e != errorsSeen {
                errorsSeen = e
                log("движок: ошибок \(e) (слотов занято \(eng.c.wins().count) из 64)")
            }
        }
        // Полный снимок окон — только когда что-то могло измениться (Q2); иначе сверка раз в 250 мс.
        let evs = eng.c.events()
        let drifted = handleEvents(evs)
        let fp = sys.frontPid()
        let md = sys.mouseDown()
        let spNow = sys.activeSpace()
        let need = last == nil || r || !evs.isEmpty || !newbies.isEmpty || !optimistic.isEmpty || !restoring.isEmpty ||
            !closing.isEmpty || spNow != lastSp || md != wasDown || fp != frontPid || !cfgQ.isEmpty || sys.now() - lastSnap > 0.25
        let area: Rect, space: Int, wins: [WinInfo]
        if need {
            let d: Snapshot
            do { d = try sys.snapshot() } catch { log("снимок окон: \(error)"); return }
            if !d.stable { return }                               // стол переключается посреди снимка
            space = d.space; area = d.area
            wins = d.windows.filter { $0.owner != "hyprdeco" }     // без подложек
            lastSnap = sys.now(); lastSp = spNow
            snaps += 1
            if r && last == nil { server?.drain { try self.command($0, area, space, wins) } }
            last = (area, space, wins)
        } else {
            (area, space, wins) = last!
        }
        if space != lastSpace {
            log("рабочий стол", space)
            lastSpace = space
        }
        if !rescued {                                             // после (пере)запуска: невидимые без причины — показать
            rescued = true
            log("старт: \(rescue(area, space, wins, keepHidden: true))")
        }
        let top = wins.map(\.wid).max() ?? 0
        // номера новых окон сканирует движок и сам ведёт wid_max; демон только будит застрявший скан (S5.5)
        if top > eng.c.widMax + 24 || eng.c.widMax == 0 { eng.c.widMax = top }
        if let fp, fp != 0, fp != frontPid {
            let prev = frontPid
            frontPid = fp
            let own = ownFocus.pid == fp && sys.now() - ownFocus.t < 1.0
            if prev != nil && !own { onActivate(area, space, wins, fp) }
        }
        followMouse(space, wins)
        for w in wins { owner[w.wid] = w.owner }
        hideNewbies(space, wins)
        if sys.now() - sampled > 2.0 {                             // цвет края окон для подложек
            sampled = sys.now()
            let busy = Set(eng.c.wins().filter(\.moving).map(\.wid))
            for n in Dwindle.leaves(sp(space).tree) where !busy.contains(n.wid!) { deco.sample(n.wid!) }
        }
        var (changed, opened) = sync(area, space, wins)
        changed = changed || drifted
        let cf = configured()                                     // окно не приняло размер — ретаргет сразу
        changed = changed || cf
        if wasDown && !md {                                       // отпустили кнопку: окно могли утащить мышью
            let ra = realign(area, space, wins)
            changed = changed || ra
        }
        wasDown = md
        if changed { apply(area, space, wins, opening: opened) }
        if sys.now() - lastGuard > 0.25 {
            lastGuard = sys.now()
            alphaGuard(wins)
        }
    }
}
