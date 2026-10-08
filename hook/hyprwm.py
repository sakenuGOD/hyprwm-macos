#!/usr/bin/env python3
"""hyprwm — демон тайлинга: dwindle как в Hyprland; анимации — центральный движок в WindowServer.

Кто что делает:
- демон: дерево dwindle на каждый рабочий стол macOS, события (открытие/закрытие окна, бинды) ->
  целевые рамки -> ОДНА пачка команд движку (все окна события стартуют в одном кадре, как в Hyprland);
- движок v4 (src/anim4.c, внутри WS): каждый кадр по кривым Hyprland ведёт видимую рамку и альфу,
  сразу ставит реальную позицию окна, растягивает прошлый буфер, пока приложение не перерисовалось;
- приложению конечный размер сообщается один раз (WindowManager.app, мост wm/), без его анимации.

Снимок окон — в процессе (build/libwinsnap.dylib): у каждого окна свой рабочий стол, поэтому окна
разных столов не смешиваются в одном дереве. Реальные рамки — от движка (CGWindowList отдаёт видимые).
Бинды приходят от keys/hyprkeys через сокет /tmp/hyprwm.ctl (строка = команда):
  focus <l|r|u|d>   move <l|r|u|d>   togglesplit   preselect <l|r|u|d|none>
  float   fullscreen   retile   reset   status
Лог: /tmp/hyprwm.log. Запуск: hook/start.sh.
"""
import ctypes
import json
import os
import re
import select
import socket
import subprocess
import sys
import queue
import threading
import time

HOOK = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HOOK)
sys.path.insert(0, os.path.join(HOOK, "scripts"))
sys.path.insert(0, os.path.join(HOOK, "config"))
sys.path.insert(0, os.path.join(HOOK, "wm"))
import chan      # noqa: E402
import hyprcfg   # noqa: E402
import tile      # noqa: E402  дерево dwindle, зазоры, учёт минимумов
from engine import Engine  # noqa: E402
from deco import Deco      # noqa: E402

CTL = "/tmp/hyprwm.ctl"
STATE = os.path.join(HOOK, "hyprwm.state.json")
MINSIZE = os.path.join(HOOK, "minsize_app.json")   # минимумы окон по приложению (owner)
POLL = 0.016           # такт демона, с (снимок в процессе ~2 мс): фокус за курсором без задержки
TOL = 6                # допуск размера, pt (Terminal округляет до сетки символов)
RESIZABLE = 1 << 3     # NSWindowStyleMaskResizable
APP_SPRING = [1.0, 1e5, 2 * 1e5 ** 0.5, 0.001]   # приложению: сразу в конечный размер, без своей анимации
DIRS = {"l": "left", "r": "right", "u": "up", "d": "down",
        "left": "left", "right": "right", "up": "up", "down": "down"}

_snap = ctypes.CDLL(os.path.join(HOOK, "build", "libwinsnap.dylib"))
_buf = ctypes.create_string_buffer(1 << 21)
_snap.ws_close.argtypes = _snap.ws_focus.argtypes = [ctypes.c_int, ctypes.c_uint]
_snap.ws_quit.argtypes = [ctypes.c_int]
_ax = ctypes.CDLL(os.path.join(HOOK, "build", "libax.dylib"))   # configure приложению (src/axlib.c)
_ax.ax_tileable.argtypes = [ctypes.c_int, ctypes.c_uint]
_ax.ax_frame.argtypes = [ctypes.c_int, ctypes.c_uint] + [ctypes.c_double] * 4
_ax.ax_forget.argtypes = [ctypes.c_uint]
_ax.ax_focus.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.c_int]
_ax.ax_menu_press.argtypes = [ctypes.c_int, ctypes.c_char_p]
_ax.ax_get_frame.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.POINTER(ctypes.c_double)]
_sl = ctypes.CDLL("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")
_cid = _sl.SLSMainConnectionID()


def win_pid_level(wid):
    """Владелец (pid) и уровень окна у сервера — сразу после создания, без ожидания списка окон."""
    o, p, lv = ctypes.c_int(), ctypes.c_int(), ctypes.c_int()
    if _sl.SLSGetWindowOwner(_cid, wid, ctypes.byref(o)) or _sl.SLSConnectionGetPID(o, ctypes.byref(p)):
        return None, None
    _sl.SLSGetWindowLevel(_cid, wid, ctypes.byref(lv))
    return p.value, lv.value


_cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")


class _Pt(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


_cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
_cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
_cg.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
_cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
_cg.CGEventCreate.restype = ctypes.c_void_p
_cg.CGEventCreate.argtypes = [ctypes.c_void_p]
_cg.CGEventGetLocation.restype = _Pt
_cg.CGEventGetLocation.argtypes = [ctypes.c_void_p]
_cg.CGEventSourceButtonState.argtypes = [ctypes.c_int, ctypes.c_uint32]
_cg.CGEventSourceButtonState.restype = ctypes.c_bool
_cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
_cf.CFRelease.argtypes = [ctypes.c_void_p]


def log(*a):
    t = time.time()
    print(time.strftime("%H:%M:%S", time.localtime(t)) + ".%03d" % int(t % 1 * 1000), *a, flush=True)


def mouse():
    e = _cg.CGEventCreate(None)
    p = _cg.CGEventGetLocation(e)
    _cf.CFRelease(e)
    return p.x, p.y


def mouse_down():
    return _cg.CGEventSourceButtonState(1, 0)        # combinedSessionState, левая кнопка


def snapshot():
    n = _snap.ws_snapshot(_buf, len(_buf))
    if n < 0:
        raise RuntimeError("снимок окон не влез в буфер")
    d = json.loads(_buf.value)
    v = d["visible"]
    return d, (v["x"], v["y"], v["w"], v["h"])


class WM:
    def __init__(self):
        self.eng = Engine(log=log)
        self.deco = Deco(log)
        st = json.load(open(STATE)) if os.path.exists(STATE) else {}
        self.spaces = st.get("spaces", {})          # space -> {tree, focus, full, presel}
        self.floating = set(st.get("floating", []))
        self.mins = json.load(open(MINSIZE)) if os.path.exists(MINSIZE) else {}   # owner -> [w, h]
        self.owner = {}      # wid -> имя приложения
        self.cfg_q = queue.Queue()   # ответы configure: (wid, owner, цель, фактическая рамка)
        self.info = {}       # pid -> {wid(str): {type, style, uuid}, "_conn": ...}
        self.miss = {}       # wid -> (попыток, когда) — окна, которых пока нет у WindowManager
        self.target = {}     # wid -> последняя цель, отданная движку
        self.pids = {}       # wid -> pid (для узнавания вкладок)
        self.gone_t = {}     # wid -> когда движок сообщил, что окна нет (замер задержки)
        self.newbies = {}    # wid -> когда движок увидел новое окно (ещё не в раскладке)
        self.optimistic = {}  # wid -> когда спрятано заранее (приложение тайлится, AX ещё не ответил)
        self.hidden = st.get("hidden", [])           # [{wid, space, rect}] — скрытые (special:hidden)
        self.restoring = set()                       # возвращаемые из скрытых: drift + fadeIn, не popin
        self.later = []                              # [(когда, функция)]
        self.float_rules = [r for r in hyprcfg.load()["window_rules"] if r.get("float")]
        log("конфиг: зазоры", tile.GAPS_IN, tile.GAPS_OUT, "windowsMove", hyprcfg.animation("windowsMove"),
            "windowsIn", hyprcfg.animation("windowsIn"), "правил float:", len(self.float_rules))

    # ── состояние ────────────────────────────────────────────────────────
    def save(self):
        json.dump({"spaces": self.spaces, "floating": sorted(self.floating), "hidden": self.hidden},
                  open(STATE, "w"), indent=1)
        json.dump(self.mins, open(MINSIZE, "w"))

    def sp(self, space):
        return self.spaces.setdefault(str(space), {"tree": None, "focus": None, "full": None, "presel": None})

    # ── какие окна тайлить ───────────────────────────────────────────────
    def wm_info(self, pid, wid):
        """Тайлить ли окно: обычное окно с изменяемым размером (спрашиваем приложение напрямую, ~1 мс).
        Окна, которых приложение ещё не показало, переспрашиваются с паузой (backoff)."""
        k = str(wid)
        if pid in self.info and k in self.info[pid]:
            return self.info[pid][k]
        n, t = self.miss.get(wid, (0, 0))
        if time.time() - t < min(0.02 * 2 ** n, 2.0):
            return None
        r = _ax.ax_tileable(pid, wid)
        if r < 0:
            self.miss[wid] = (n + 1, time.time())
            return None
        self.miss.pop(wid, None)
        i = {"type": "primary" if r == 1 else "other", "style": RESIZABLE if r == 1 else 0}
        self.info.setdefault(pid, {})[k] = i
        return i

    def rule_float(self, w):
        for r in self.float_rules:
            m = r.get("match", {})
            try:
                if "title" in m and not re.search(m["title"], w["name"]):
                    continue
                if "class" in m and not re.search(m["class"], w["owner"]):
                    continue
            except re.error:
                continue
            if set(m) - {"title", "class"}:
                continue
            return r.get("name", "rule")
        return None

    def tileable(self, w):
        if w["wid"] in self.floating:
            return False
        i = self.wm_info(w["pid"], w["wid"])
        if not i or i.get("type") != "primary" or not (i.get("style", 0) & RESIZABLE):
            return False
        return self.rule_float(w) is None

    # ── раскладка ────────────────────────────────────────────────────────
    def layout(self, area, s):
        # минимумы известны ДО раскладки (по приложению) — окно сразу получает место, в которое влезает
        tile.MINS = {n["wid"]: self.mins[self.owner[n["wid"]]] for n in tile.leaves(s["tree"])
                     if self.owner.get(n["wid"]) in self.mins}
        rects = {wid: tile.with_gaps(b, area) for wid, b in tile.boxes(s["tree"], area, {}).items()}
        if s.get("full") in rects:
            x, y, w, h = area
            go = tile.GAPS_OUT
            if s.get("fullmode") == "fullscreen":               # весь экран без зазоров
                rects[s["full"]] = (x, y, w, h)
            else:                                              # maximized: рабочая область минус gaps_out
                rects[s["full"]] = (x + go["left"], y + go["top"], w - go["left"] - go["right"],
                                    h - go["top"] - go["bottom"])
        return {wid: tuple(float(round(v)) for v in r) for wid, r in rects.items()}

    def apply(self, area, space, wins, force=False, opening=()):
        """Цели всех окон стола -> одна пачка движку (общий t0) + конечные размеры приложениям."""
        s = self.sp(space)
        rects = self.layout(area, s)
        cur = {w["wid"]: w for w in wins}
        real = self.eng.real()
        c = self.eng.c
        mv_c, _, mv_on = self.eng.anim("windowsMove")
        in_c, _, in_on = self.eng.anim("windowsIn")
        fi_c, fi_d, fi_on = self.eng.anim("fadeIn")
        style = hyprcfg.animation("windowsIn")["style"]
        pop = float(re.search(r"popin\s+(\d+)", style).group(1)) / 100 if re.search(r"popin\s+(\d+)", style) else None
        posted, jobs = [], []
        if opening and in_on:                              # новое окно — сразу невидимо, до размера и popin
            for wid in opening:
                c.alpha(wid, 0.0, 0, 0.0, frm=0.0)
            c.commit()
        eng_w = {w.wid: w for w in c.wins()}
        vis = {}
        for w in wins:                                     # видимая рамка: у покоящегося окна = реальная
            ew = eng_w.get(w["wid"])
            vis[w["wid"]] = ((ew.pos.v[0], ew.pos.v[1], ew.size.v[0], ew.size.v[1]) if ew and
                             (ew.pos.active or ew.size.active or ew.settling) else
                             real.get(w["wid"]) or (w["x"], w["y"], w["w"], w["h"]))
        for wid, to in rects.items():
            if wid not in cur:
                continue
            if not force and self.target.get(wid) == to:
                continue
            if wid in opening and in_on and wid not in self.restoring:
                frm = None
                if pop:                                        # popin: от pop% цели, масштаб от центра
                    sw, sh = max(5.0, to[2] * pop), max(5.0, to[3] * pop)
                    frm = (to[0] + (to[2] - sw) / 2, to[1] + (to[3] - sh) / 2, sw, sh)
                c.geom(wid, to, in_c, in_c, frm=frm, move=True, stretch=True)   # popin тянет содержимое
                if fi_on:
                    c.alpha(wid, 1.0, fi_c, fi_d, frm=0.0)
            else:
                # стартовая ВИДИМАЯ рамка явно: приложение может встать в цель раньше, чем движок
                # заберёт команду (AX быстрее тика) — тогда движок взял бы уже новую рамку = телепорт
                frm = None
                ew = eng_w.get(wid)
                if ew is None or not (ew.pos.active or ew.size.active or ew.settling):
                    v = vis.get(wid)
                    frm = v if v else None
                ew0 = eng_w.get(wid)
                self.deco.ensure(wid, cur[wid]["owner"], ew0.radius if ew0 else 0)
                u = self.deco.place(wid, to)
                if u:
                    c.under(wid, u)
                c.geom(wid, to, mv_c, mv_c, frm=frm, move=True, warp=not mv_on)
                if wid in self.restoring:
                    self.restoring.discard(wid)
                    c.alpha(wid, 1.0, fi_c, fi_d if fi_on else 0.0)
            self.target[wid] = to
            posted.append(wid)
            # Приложению размер (позицию ставит движок сразу). Как в Hyprland, содержимое в рамке
            # обрезается 1:1, поэтому буфер не должен быть меньше рамки: по растущей оси — сразу
            # конечный размер, по сжимающейся — прежний, пока рамка едет; конечный — по EV_DONE.
            a = real.get(wid) or (cur[wid]["x"], cur[wid]["y"], cur[wid]["w"], cur[wid]["h"])
            if wid in opening or max(abs(p - q) for p, q in zip(a, to)) > 1:
                j = self.job(cur[wid]["pid"], wid, to)       # конечный размер сразу и один раз (Hyprland)
                if j:
                    jobs.append(j)
        if posted:
            c.commit()
            t = time.time()                                # движок принимает пачку в ближайшем тике
            while c.h.cmd_tail != c.h.cmd_head and time.time() - t < 0.05:
                time.sleep(0.001)
        if jobs:
            self.configure(jobs)
        if posted:
            log("событие: %d окон в движок, configure %d" % (len(posted), len(jobs)))
        if posted or force:
            self.save()

    def job(self, pid, wid, r):
        i = self.wm_info(pid, wid)
        if not i:
            return None
        return {"wid": wid, "pid": pid, "owner": self.owner.get(wid, ""), "to": tuple(r)}

    def configure(self, jobs):
        """Конечный размер приложениям (как configure Hyprland) — каждому в своём потоке, сразу после того,
        как движок принял пачку анимаций. Поток перечитывает, что окно реально приняло (до 150 мс:
        Ghostty применяет асинхронно), и кладёт ответ в очередь — главный цикл ретаргетит раскладку."""
        def work(j):
            x, y, w, h = j["to"]
            buf = (ctypes.c_double * 4)()
            pre = tuple(buf) if _ax.ax_get_frame(j["pid"], j["wid"], buf) == 0 else None
            e = _ax.ax_frame(j["pid"], j["wid"], x, y, w, h)
            got, same, t0 = None, 0, time.time()
            while not e and time.time() - t0 < 0.4:
                time.sleep(0.03)
                if _ax.ax_get_frame(j["pid"], j["wid"], buf) != 0:
                    continue
                cur = tuple(buf)
                if abs(cur[2] - w) <= TOL and abs(cur[3] - h) <= TOL:
                    got = cur
                    break
                same = same + 1 if cur == got else 0
                got = cur
                if same >= 3:                          # 90 мс без изменений — окно встало, где смогло
                    break
            self.cfg_q.put((j["wid"], j["owner"], j["to"], got, e, pre))
        for j in jobs:
            threading.Thread(target=work, args=(j,), daemon=True).start()

    def configured(self):
        """Ответы configure: окно не сжалось до цели — это его минимум; запомнить по приложению.
        -> True, если раскладку надо пересчитать (ретаргет в этом же цикле)."""
        changed = False
        while True:
            try:
                wid, owner, to, got, e, pre = self.cfg_q.get_nowait()
            except queue.Empty:
                return changed
            if e:
                log("configure окна %d: ошибка %s" % (wid, e))
                continue
            if not got or self.target.get(wid) != to:
                continue
            # Настоящий минимум: окно ИЗМЕНИЛО размер в сторону цели, но остановилось раньше (Telegram:
            # 903 -> 584 при цели 444). Окно, которое ещё не ответило (размер = прежний), — не минимум.
            mw, mh = self.mins.get(owner, (0, 0))
            nw, nh = mw, mh
            for i, (g, t, p) in enumerate(((got[2], to[2], pre and pre[2]), (got[3], to[3], pre and pre[3]))):
                if p is not None and g > t + TOL and abs(g - p) > TOL and (p - g) * (p - t) > 0:
                    if i == 0:
                        nw = max(mw, g)
                    else:
                        nh = max(mh, g)
            if (nw, nh) != (mw, mh):
                self.mins[owner] = [nw, nh]
                log("минимум %s: %s (окно %d: %s -> %s, цель %s)" % (owner, self.mins[owner], wid,
                    tuple(round(v) for v in pre[2:]), tuple(round(v) for v in got[2:]), to[2:]))
                changed = True
            elif abs(got[2] - to[2]) > TOL or abs(got[3] - to[3]) > TOL:
                log("окно %s %d стоит %s вместо %s — держу в плитке" % (owner, wid, tuple(round(v) for v in got[2:]), to[2:]))

    def sync(self, area, space, wins):
        """Дерево стола <- его видимые окна. -> (изменилось ли, новые окна)."""
        s = self.sp(space)
        hid = {h["wid"] for h in self.hidden}
        closing = getattr(self, "closing", set())
        live = [w for w in wins if w["space"] == space and w["on"] and w["wid"] not in hid and
                w["wid"] not in closing and self.tileable(w)]
        ids = [w["wid"] for w in live]
        have = {n["wid"] for n in tile.leaves(s["tree"])}
        changed, opened = False, []
        # Вкладки (Ghostty, Finder, Safari): у macOS это отдельные окна одной группы, видна одна.
        # Ушло окно X и в этот же момент появилось окно того же приложения на его месте —
        # это переключение вкладки: новое окно занимает лист X, раскладка не меняется.
        gone = [x for x in have - set(ids)]
        for w in live:
            if w["wid"] in have:
                continue
            twin = next((x for x in gone if self.pids.get(x) == w["pid"] and self.target.get(x) and
                         max(abs(a - b) for a, b in zip(self.target[x], (w["x"], w["y"], w["w"], w["h"]))) <= TOL), None)
            if twin is None:
                continue
            for n in tile.leaves(s["tree"]):
                if n["wid"] == twin:
                    n["wid"] = w["wid"]
            gone.remove(twin)
            have.discard(twin); have.add(w["wid"])
            self.target[w["wid"]] = self.target.pop(twin)
            if s.get("focus") == twin:
                s["focus"] = w["wid"]
            if s.get("full") == twin:
                s["full"] = w["wid"]
            log("вкладка %s: %d -> %d (место в раскладке то же)" % (w["owner"], twin, w["wid"]))
        for w in live:
            self.pids[w["wid"]] = w["pid"]
        for wid in have - set(ids):
            g = self.gone_t.pop(wid, None)
            log("окно %d ушло из раскладки%s" % (wid, " (через %.0f мс после движка)" % ((time.time() - g) * 1000) if g else " (движок не сообщал)"))
            s["tree"] = tile.remove(s["tree"], wid)
            self.target.pop(wid, None)
            if s.get("full") == wid:
                s["full"] = None
            changed = True
        have &= set(ids)
        # активное окно (Hyprland делит именно его) — самое переднее тайловое окно стола
        s["focus"] = next((x for x in ids if x in have), s.get("focus") if s.get("focus") in have else None)
        for w in live:
            if w["wid"] in have:
                continue
            target = s.get("focus") if s.get("focus") in have else None
            s["tree"] = self.insert(s, w["wid"], target, area)
            have.add(w["wid"])
            s["focus"] = w["wid"]
            opened.append(w["wid"])
            log("новое окно %s (%d) -> в раскладку" % (w["owner"], w["wid"]))
            self.deco.ensure(w["wid"], w["owner"], 0)
            changed = True
        return changed, opened

    def insert(self, s, wid, target, area, point=None):
        """dwindle-вставка: preselect задаёт сторону; без него — сторона по курсору (force_split 0)
        или по точке point (перенос направлением: focal за краем окна)."""
        pre = s.get("presel")
        boxes = tile.boxes(s["tree"], area, {}) if target is not None else {}
        tree = tile.insert(s["tree"], wid, target, area)
        par = tile.find_parent(tree, wid) if target is not None else None
        if par and par["b"].get("wid") == wid:
            first = False
            if pre:
                par["split"] = "v" if pre in ("left", "right") else "h"
                first = pre in ("left", "up")
                s["presel"] = None
            elif target in boxes:
                x, y, w, h = boxes[target]
                mx, my = point or mouse()
                first = mx < x + w / 2 if par["split"] == "v" else my < y + h / 2
            if first:
                par["a"], par["b"] = par["b"], par["a"]
        return tree

    # ── команды (бинды) ──────────────────────────────────────────────────
    def command(self, line, area, space, wins):
        a = line.split()
        if not a:
            return "пусто"
        s, cmd = self.sp(space), a[0]
        rects = self.layout(area, s)
        cur = next((w["wid"] for w in wins if w["wid"] in rects and w["on"]), None)   # переднее разложенное
        if cmd == "status":
            return json.dumps({"space": space, "tree": s["tree"], "focus": cur, "mins": self.mins,
                               "floating": sorted(self.floating),
                               "engine": {"ticks": self.eng.c.h.ticks, "active": self.eng.c.h.nactive}},
                              ensure_ascii=False)
        if cmd in ("focus", "move") and len(a) > 1:
            d = DIRS.get(a[1])
            tgt = tile.neighbour(rects, cur, d) if cur and d else None
            if tgt is None:
                return "нет окна: %s" % a[1]
            if cmd == "focus":
                pid = next(w["pid"] for w in wins if w["wid"] == tgt)
                r = _ax.ax_focus(pid, tgt, 1)                  # именно окно, а не всё приложение
                return "фокус -> %d (%d)" % (tgt, r)
            self.move_dir(s, area, cur, d, rects)
        elif cmd == "togglesplit":
            par = tile.find_parent(s["tree"], cur)
            if par:
                par["split"] = "h" if par["split"] == "v" else "v"
        elif cmd == "preselect":
            s["presel"] = DIRS.get(a[1]) if len(a) > 1 else None
            return "preselect %s" % s["presel"]
        elif cmd == "float":
            w = next((w["wid"] for w in wins if w["on"] and w["space"] == int(space)), None)
            if w in self.floating:
                self.floating.discard(w)
            elif w is not None:
                self.floating.add(w)
        elif cmd == "fullscreen":
            mode = a[1] if len(a) > 1 else "fullscreen"
            if s.get("full") == cur and s.get("fullmode") == mode:
                s["full"] = None
            else:
                s["full"], s["fullmode"] = cur, mode
        elif cmd == "close":
            w = self.front(wins, space)
            if not w:
                return "нет окна"
            return self.close_anim(area, space, wins, w)
        elif cmd == "quit":
            w = self.front(wins, space)
            if not w:
                return "нет окна"
            return "завершить %s -> %d" % (w["owner"], _snap.ws_quit(w["pid"]))
        elif cmd == "hide":
            return self.hide(area, space, wins, int(a[1]) if len(a) > 1 and a[1].isdigit() else None)
        elif cmd == "unhide":
            return self.unhide(area, space, wins, everything=len(a) > 1 and a[1] == "all")
        elif cmd == "balance":
            def bal(n):
                if n and "wid" not in n:
                    n["ratio"] = 0.5
                    bal(n["a"]); bal(n["b"])
            bal(s["tree"])
        elif cmd == "resize" and len(a) == 3:
            self.resize_active(s, area, cur, float(a[1]), float(a[2]))
        elif cmd == "exec":
            return self.exec_app(a[1:])
        elif cmd == "reset":
            s["tree"], s["full"] = None, None
            self.mins.clear()
            self.info.clear()
        elif cmd != "retile":
            return "не знаю команду: %s" % line
        _, opened = self.sync(area, space, wins)
        self.apply(area, space, wins, force=cmd in ("retile", "reset"), opening=opened)
        return "ok"

    def move_dir(self, s, area, cur, d, rects):
        """movewindow Hyprland (dwindle moveTargetInDirection): окно вынимается из дерева и
        вставляется у узла, ближайшего к точке на 1 px за серединой его стороны; сторона — по этой точке."""
        x, y, w, h = rects[cur]
        g = tile.GAPS_IN + 1
        focal = {"left": (x - g, y + h / 2), "right": (x + w + g, y + h / 2),
                 "up": (x + w / 2, y - g), "down": (x + w / 2, y + h + g)}[d]
        s["tree"] = tile.remove(s["tree"], cur)
        bx = {k: tile.with_gaps(b, area) for k, b in tile.boxes(s["tree"], area, {}).items()}
        if not bx:
            s["tree"] = tile.insert(s["tree"], cur, None, area)
            return

        def dist(b):
            dx = max(b[0] - focal[0], 0, focal[0] - (b[0] + b[2]))
            dy = max(b[1] - focal[1], 0, focal[1] - (b[1] + b[3]))
            return dx * dx + dy * dy
        near = min(bx, key=lambda k: dist(bx[k]))
        s["tree"] = self.insert(s, cur, near, area, point=focal)

    def close_anim(self, area, space, wins, w):
        """killactive как в Hyprland: окно уходит из раскладки (соседи едут в том же кадре), само
        сжимается до popin 92% от центра (windowsOut) и гаснет (fadeOut); приложение закрывается в конце.
        Не закрылось (диалог «Сохранить?») — вернуть в раскладку."""
        wid, s = w["wid"], self.sp(space)
        c = self.eng.c
        ew = {x.wid: x for x in c.wins()}.get(wid)
        cur = ((ew.pos.v[0], ew.pos.v[1], ew.size.v[0], ew.size.v[1]) if ew else
               self.eng.real().get(wid) or (w["x"], w["y"], w["w"], w["h"]))
        oc, od, on = self.eng.anim("windowsOut")
        fc, fd, fon = self.eng.anim("fadeOut")
        m = re.search(r"popin\s+(\d+)", hyprcfg.animation("windowsOut")["style"])
        k = float(m.group(1)) / 100 if m else 0.92
        to = (cur[0] + cur[2] * (1 - k) / 2, cur[1] + cur[3] * (1 - k) / 2, cur[2] * k, cur[3] * k)
        s["tree"] = tile.remove(s["tree"], wid)
        self.target.pop(wid, None)
        self.closing = getattr(self, "closing", set()) | {wid}
        c.geom(wid, to, oc, oc, od if on else 0.0, od if on else 0.0, frm=cur, move=False, stretch=True)
        c.alpha(wid, 0.0, fc, fd if fon else 0.0)
        self.apply(area, space, wins)                      # соседи — в том же кадре
        c.commit()
        done = max(od if on else 0, fd if fon else 0)

        def shut():
            _snap.ws_close(w["pid"], wid)

        def check():
            self.closing.discard(wid)
            if any(x.wid == wid for x in c.wins()) and self.eng.real().get(wid):
                log("окно %d не закрылось — возвращаю" % wid)
                c.alpha(wid, 1.0, fc, fd)
                c.commit()
                self.target.pop(wid, None)                 # sync вставит его обратно
        self.later.append((time.time() + done, shut))
        self.later.append((time.time() + done + 0.6, check))
        return "закрываю %d (%.0f мс)" % (wid, done * 1000)

    def front(self, wins, space):
        """Окно в фокусе: самое переднее видимое окно этого стола (CGWindowList идёт спереди назад)."""
        return next((w for w in wins if w["on"] and w["space"] == space and w["w"] >= 120 and w["h"] >= 120), None)

    def hide(self, area, space, wins, wid=None):
        """M+W: окно гаснет на месте (fadeOut), соседи сразу занимают место; потом уводим за экран."""
        w = next((x for x in wins if x["wid"] == wid), None) if wid else self.front(wins, space)
        if not w:
            return "нет окна"
        wid = w["wid"]
        s = self.sp(space)
        rect = self.eng.real().get(wid) or (w["x"], w["y"], w["w"], w["h"])
        s["tree"] = tile.remove(s["tree"], wid)
        if s.get("full") == wid:
            s["full"] = None
        self.target.pop(wid, None)
        self.hidden.append({"wid": wid, "space": space, "rect": list(rect)})
        fo_c, fo_d, fo_on = self.eng.anim("fadeOut")
        self.eng.c.alpha(wid, 0.0, fo_c, fo_d if fo_on else 0.0)
        self.apply(area, space, wins)                      # соседи — в том же кадре, что и затухание
        self.eng.c.commit()
        park = (area[0] + area[2] + 200, rect[1], rect[2], rect[3])

        def away():
            if any(h["wid"] == wid for h in self.hidden):
                self.eng.c.geom(wid, park, 0, 0, move=True, warp=True)
                self.eng.c.commit()
        self.later.append((time.time() + fo_d + 0.05, away))
        self.save()
        return "скрыто %d" % wid

    def unhide(self, area, space, wins, everything=False):
        """M+Shift+W: последнее скрытое — назад в раскладку текущего стола: drift из прежнего места + fadeIn."""
        if not self.hidden:
            return "скрытых нет"
        todo = list(self.hidden) if everything else [self.hidden[-1]]
        for h in todo:
            self.hidden.remove(h)
            self.eng.c.geom(h["wid"], tuple(h["rect"]), 0, 0, move=True, warp=True)   # невидимым — на прежнее место
            if everything:
                self.eng.c.alpha(h["wid"], 1.0, 0, 0.0)
            else:
                self.restoring.add(h["wid"])
        self.eng.c.commit()
        self.save()
        return "возвращено %s" % [h["wid"] for h in todo]

    def resize_active(self, s, area, cur, dx, dy):
        """resizeactive Hyprland: двигается разделитель ближайшего сплита по оси на dx/dy pt."""
        path = []

        def walk(n, box):
            if n is None or "wid" in n:
                return n is not None and n["wid"] == cur
            ba, bb = tile.split_box(box, n)
            path.append((n, box))
            if walk(n["a"], ba) or walk(n["b"], bb):
                return True
            path.pop()
            return False
        walk(s["tree"], area)
        for d, split in ((dx, "v"), (dy, "h")):
            if not d:
                continue
            for n, (x, y, w, h) in reversed(path):
                if n["split"] == split:
                    n["ratio"] = min(0.95, max(0.05, n.get("ratio", 0.5) + d / (w if split == "v" else h)))
                    break

    def exec_app(self, args):
        """exec из дотфайла. «Ghostty --new» — новое окно терминала (пункт меню New Window через AX:
        у osascript нет Универсального доступа, его нажатия macOS молча блокирует); «-e prog» — терминал
        с программой; «spotlight» — лаунчер (openrunner на Линуксе)."""
        if not args:
            return "нечего запускать"
        app, rest = args[0], args[1:]
        if app == "spotlight":
            for down in (True, False):                 # Cmd+Space — Spotlight
                e = _cg.CGEventCreateKeyboardEvent(None, 49, down)
                _cg.CGEventSetFlags(e, 1 << 20)
                _cg.CGEventPost(0, e)
                _cf.CFRelease(e)
            return "лаунчер"
        if rest[:1] == ["--new"]:
            pid = next((int(p) for p in subprocess.run(["/usr/bin/pgrep", "-x", app.lower()], capture_output=True,
                                                        text=True).stdout.split()), None)
            if pid and _ax.ax_menu_press(pid, b"New Window") == 0:
                return "новое окно %s" % app
            subprocess.Popen(["open", "-a", app])
        elif rest[:1] == ["-e"]:
            subprocess.Popen(["open", "-na", app, "--args", "-e"] + rest[1:])
        else:
            subprocess.Popen(["open", "-a", app])
        return "запуск %s" % " ".join(args)

    # ── цикл ─────────────────────────────────────────────────────────────
    def run(self):
        try:
            os.unlink(CTL)
        except FileNotFoundError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(CTL)
        os.chmod(CTL, 0o600)
        srv.listen(8)
        self.eng.ensure(startup=True)
        last_space, last_eng, was_down = None, time.time(), False
        if self.hidden:                                          # после перезапуска демона — вернуть всё
            log("возвращаю скрытые окна:", self.unhide(None, None, None, everything=True))
        log("hyprwm запущен")
        while True:
            r, _, _ = select.select([srv], [], [], POLL)
            due = [f for t, f in self.later if t <= time.time()]
            self.later = [(t, f) for t, f in self.later if t > time.time()]
            for f in due:
                try:
                    f()
                except Exception as e:
                    log("отложенное упало:", repr(e))
            if time.time() - last_eng > 2.0:                     # WindowServer перезапускался?
                last_eng = time.time()
                if not self.eng.alive():
                    self.target.clear()
                    self.eng.ensure()
            d, area = snapshot()
            if not d["stable"]:
                continue                                         # стол переключается посреди снимка
            space, wins = d["space"], [w for w in d["windows"] if w["owner"] != "hyprdeco"]   # без подложек
            if space != last_space:
                log("рабочий стол", space)
                last_space = space
            top = max((w["wid"] for w in wins), default=0)
            if top > self.eng.c.h.wid_max:                 # движок сканирует номера выше этого
                self.eng.c.h.wid_max = top
            for ev in self.eng.c.events():
                if ev[0] == chan.EV_NEW:
                    self.newbies[ev[1]] = time.time()
                    continue
                if ev[0] == chan.EV_GONE:
                    self.gone_t[ev[1]] = time.time()
                    self.target.pop(ev[1], None)
                    self.deco.drop(ev[1])
            if r:
                c, _ = srv.accept()
                c.settimeout(1)
                try:
                    line = c.makefile().readline().strip()
                    t = time.time()
                    out = self.command(line, area, space, wins)
                    log("команда '%s' -> %s (%.2f с)" % (line, out[:200], time.time() - t))
                    c.sendall((out + "\n").encode())
                except Exception as e:
                    log("команда упала:", repr(e))
                finally:
                    c.close()
                continue
            self.follow_mouse(space, wins)
            for w in wins:
                self.owner[w["wid"]] = w["owner"]
            self.hide_newbies(space, wins)
            if time.time() - getattr(self, "_sampled", 0) > 2.0:     # цвет края окон для подложек
                self._sampled = time.time()
                busy = {w.wid for w in self.eng.c.wins() if w.pos.active or w.size.active or w.settling}
                for n in tile.leaves(self.sp(space)["tree"]):
                    if n["wid"] not in busy:
                        self.deco.sample(n["wid"])
            changed, opened = self.sync(area, space, wins)
            changed |= self.configured()                   # окно не приняло размер — ретаргет сразу
            md = mouse_down()
            if was_down and not md:                        # отпустили кнопку: окно могли утащить мышью
                changed |= self.realign(area, space, wins)
            was_down = md
            if changed:
                self.apply(area, space, wins, opening=opened)

    def hide_newbies(self, space, wins):
        """Новое окно, которое пойдёт в раскладку, прячется ДО первого показа (альфа 0), чтобы macOS не
        показал его на «своём» месте; дальше sync вставляет его в дерево, и оно вырастает popin в плитке.
        Окна приложений, которые уже тайлились, прячутся сразу (не ждём AX: Finder отдаёт окно ~150 мс);
        если окно оказалось не обычным (диалог, панель) — альфа возвращается."""
        if not self.newbies and not self.optimistic:
            return
        by = {w["wid"]: w for w in wins}
        c, touched = self.eng.c, False
        tiled_apps = {self.owner.get(n["wid"]) for sp in self.spaces.values() for n in tile.leaves(sp.get("tree"))}
        tiled_pids = {self.pids.get(n["wid"]) for sp in self.spaces.values() for n in tile.leaves(sp.get("tree"))}
        for wid, t in list(self.newbies.items()):
            w = by.get(wid)
            if time.time() - t > 0.6:
                self.newbies.pop(wid)
                continue
            if not w or w["w"] < 120 or w["h"] < 120:
                # окна ещё нет в списке: спросить сервер напрямую — обычный уровень и тайловое приложение
                pid, lv = win_pid_level(wid)
                if lv == 0 and pid in tiled_pids and wid not in self.optimistic:
                    self.optimistic[wid] = time.time()
                    c.alpha(wid, 0.0, 0, 0.0, frm=0.0)
                    touched = True
                continue
            r = self.tileable(w)
            if r:
                c.alpha(wid, 0.0, 0, 0.0, frm=0.0)
                touched = True
                self.newbies.pop(wid)
                self.optimistic.pop(wid, None)
                log("новое окно %s %d спрятано до popin (через %.0f мс после создания)" % (w["owner"], wid, (time.time() - t) * 1000))
            elif self.info.get(w["pid"], {}).get(str(wid)):
                self.newbies.pop(wid)                      # точно не тайлится
                if self.optimistic.pop(wid, None):
                    c.alpha(wid, 1.0, 0, 0.0)
                    touched = True
            elif w and w["owner"] in tiled_apps and wid not in self.optimistic:
                self.optimistic[wid] = time.time()         # приложение тайлится — спрятать сразу
                c.alpha(wid, 0.0, 0, 0.0, frm=0.0)
                touched = True
        for wid, t in list(self.optimistic.items()):        # так и не стало тайловым — вернуть видимость
            if wid not in self.newbies and time.time() - t > 0.6:
                self.optimistic.pop(wid)
                c.alpha(wid, 1.0, 0, 0.0)
                touched = True
        if touched:
            c.commit()

    def follow_mouse(self, space, wins):
        """input:follow_mouse = 1: фокус у окна под курсором, как только курсор на него зашёл.
        Берётся самое верхнее окно под курсором (меню/попапы/плавающие перекрывают — их не трогаем)."""
        p = mouse()
        if p == getattr(self, "_mp", None) or mouse_down():
            return
        self._mp = p
        s = self.sp(space)
        tiled = {n["wid"] for n in tile.leaves(s["tree"])}
        top = next((w for w in wins if w["on"] and w["x"] <= p[0] < w["x"] + w["w"] and
                    w["y"] <= p[1] < w["y"] + w["h"]), None)
        front = next((w for w in wins if w["on"] and w["space"] == space and w["w"] >= 120 and w["h"] >= 120), None)
        if os.environ.get("HYPRWM_DEBUG"):
            log("курсор", p, "верх", top and top["wid"], "перед", front and front["wid"], "тайлы", tiled)
        if not top or top["wid"] not in tiled or (front and front["wid"] == top["wid"]):
            return
        if getattr(self, "_fwant", None) == top["wid"] and time.time() - self._ft < 0.3:
            return                                         # уже просили — ждём, пока приложение выйдет вперёд
        self._fwant, self._ft = top["wid"], time.time()
        r = _ax.ax_focus(top["pid"], top["wid"], 1)
        s["focus"] = top["wid"]
        log("фокус за курсором -> %s %d (%d)" % (top["owner"], top["wid"], r))

    def realign(self, area, space, wins):
        """После отпускания мыши: окно, утащенное из своей плитки, вернуть (как Hyprland после drag)."""
        s = self.sp(space)
        rects = self.layout(area, s)
        busy = {w.wid for w in self.eng.c.wins() if w.pos.active or w.size.active or w.settling}
        real = self.eng.real()
        moved = False
        for wid, to in rects.items():
            a = real.get(wid) or next(((w["x"], w["y"], w["w"], w["h"]) for w in wins if w["wid"] == wid), None)
            if wid in busy or not a:
                continue
            if max(abs(a[0] - to[0]), abs(a[1] - to[1]), abs(a[2] - to[2]), abs(a[3] - to[3])) > TOL:
                self.target.pop(wid, None)
                moved = True
        return moved

if __name__ == "__main__":
    WM().run()
