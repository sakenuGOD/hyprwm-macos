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
import copy
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
sys.path.insert(0, os.path.join(HOOK, "active"))
import chan      # noqa: E402
import hyprcfg   # noqa: E402
import tile      # noqa: E402  дерево dwindle, зазоры, учёт минимумов
from engine import Engine  # noqa: E402
from deco import Deco      # noqa: E402
import inject    # noqa: E402  активный вид окон в процессах приложений (П3)

CTL = "/tmp/hyprwm.ctl"
STATE = os.path.join(HOOK, "hyprwm.state.json")
MINSIZE = os.path.join(HOOK, "minsize_app.json")   # минимумы окон по приложению (owner)
POLL = 0.016           # такт демона, с (снимок в процессе ~2 мс): фокус за курсором без задержки
BORDER = hyprcfg.border()["size"]   # general.border_size: рамка внутри слота плитки (P19)
SNAP = os.environ.get("HYPRWM_SNAP", "0") != "0"   # подкладка-снимок при сжатии (см. apply); 0 — сжатие в конце хода
SHRINK_LATE = os.environ.get("HYPRWM_SHRINK_LATE", "0") != "0"
# Сжатие (решение 13:40 после жалоб на обои в полосе, «телепорт в конце», «летящую подложку»): сжимающаяся
# сторона сразу встаёт в целевой размер вместе с новым содержимым, плавно — перемещение и растущие стороны.
# На macOS окно не рисует дальше своего буфера, а бокс при сжатии больше буфера. HYPRWM_SHRINK_SNAP=0 — анимировать.
SHRINK_SNAP = os.environ.get("HYPRWM_SHRINK_SNAP", "1") != "0"   # запасной путь без подкладки: сжатие в конце
RAISE = int(os.environ.get("HYPRWM_RAISE", "1"))   # фокус поднимает окно (AXRaise), как Hyprland рисует активное сверху
TOL = 6                # допуск размера, pt (Terminal округляет до сетки символов)
# configure родным путём AppKit через модуль в приложении (native_hooks §1, PROGRESS 15:10): рамка+содержимое
# одним коммитом, без трёх синхронных AX-вызовов и промежуточной рамки «позиция при старом размере».
# Для приложений без модуля этой версии — AX, как раньше. 0 — всем AX.
NATIVE = os.environ.get("HYPRWM_NATIVE", "1") != "0"
CFG_WS = os.environ.get("HYPRWM_CFG_WS", "1") != "0"   # рамку модулю шлёт движок в тик старта пачки (OP_CFG)
DEBUG_CFG = os.environ.get("HYPRWM_DEBUG_CFG", "1") != "0"   # путь configure в журнал (пока проверяется NATIVE)
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
_ax.ax_edge_color.argtypes = [ctypes.c_uint] + [ctypes.c_double] * 4 + [ctypes.POINTER(ctypes.c_double)]
_ax.ax_menu_press.argtypes = [ctypes.c_int, ctypes.c_char_p]
_ax.ax_get_frame.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.POINTER(ctypes.c_double)]
_sl = ctypes.CDLL("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")
_cid = _sl.SLSMainConnectionID()
_nt = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
_nt.notify_register_check.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int)]
_nt.notify_set_state.argtypes = [ctypes.c_int, ctypes.c_uint64]
_nt.notify_post.argtypes = [ctypes.c_char_p]


def srv_frame(wid, buf):
    """Рамка окна у сервера (CG, pt) -> 0 при успехе. Без AX: та, что AppKit поставил одним коммитом."""
    r = win_bounds(wid)
    if r is None:
        return 1
    buf[:] = r
    return 0


class NativeCfg:
    """Цели окон модулю hyprforce: "hyprwm.r.<wid>" = рамка (4 × int16 в полупунктах), post "hyprwm.cfg.<pid>".
    Регистрацию имени держим сами, пока окно не встало: notifyd стирает состояние без регистраций."""
    def __init__(self):
        self.tok = {}

    def send(self, pid, jobs):
        for j in jobs:
            v = 0
            for i, c in enumerate(j["to"]):
                v |= (int(round(c * 2)) & 0xffff) << (16 * i)
            t = self.tok.get(j["wid"])
            if t is None:
                t = ctypes.c_int()
                if _nt.notify_register_check(("hyprwm.r.%d" % j["wid"]).encode(), ctypes.byref(t)) != 0:
                    continue
                self.tok[j["wid"]] = t
            _nt.notify_set_state(t, v)
        _nt.notify_post(("hyprwm.cfg.%d" % pid).encode())

    def next(self, r, pids):
        """"hyprwm.next.<pid>" = рамка следующего окна (0 — нет); только при изменении."""
        v = 0
        if r:
            for i, c in enumerate(r):
                v |= (int(round(c * 2)) & 0xffff) << (16 * i)
        nt = getattr(self, "ntok", None)
        if nt is None:
            nt = self.ntok = {}
        for pid in pids:
            t, old = nt.get(pid, (None, None))
            if old == v:
                continue
            if t is None:
                t = ctypes.c_int()
                if _nt.notify_register_check(("hyprwm.next.%d" % pid).encode(), ctypes.byref(t)) != 0:
                    continue
            _nt.notify_set_state(t, v)
            nt[pid] = (t, v)
        for pid in list(nt):                                  # приложение ушло из списка — снять
            if pid not in pids:
                t, _ = nt.pop(pid)
                _nt.notify_set_state(t, 0)
                _nt.notify_cancel(t)

    def done(self, wid):
        t = self.tok.pop(wid, None)
        if t is not None:
            _nt.notify_set_state(t, 0)
            _nt.notify_cancel(t)


def win_pid_level(wid):
    """Владелец (pid) и уровень окна у сервера — сразу после создания, без ожидания списка окон."""
    o, p, lv = ctypes.c_int(), ctypes.c_int(), ctypes.c_int()
    if _sl.SLSGetWindowOwner(_cid, wid, ctypes.byref(o)) or _sl.SLSConnectionGetPID(o, ctypes.byref(p)):
        return None, None
    _sl.SLSGetWindowLevel(_cid, wid, ctypes.byref(lv))
    return p.value, lv.value


class _PSN(ctypes.Structure):
    _fields_ = [("hi", ctypes.c_uint32), ("lo", ctypes.c_uint32)]


_hi = ctypes.CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")


def front_pid():
    """Переднее приложение у сервера (NSWorkspace без run loop в демоне не обновляется)."""
    psn, pid = _PSN(), ctypes.c_int(0)
    if _sl._SLPSGetFrontProcess(ctypes.byref(psn)) or _hi.GetProcessPID(ctypes.byref(psn), ctypes.byref(pid)):
        return None
    return pid.value


class _Rect(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double), ("w", ctypes.c_double), ("h", ctypes.c_double)]


def win_bounds(wid):
    """Реальная рамка окна у сервера (без нашего трансформа) или None."""
    r = _Rect()
    return None if _sl.SLSGetWindowBounds(_cid, wid, ctypes.byref(r)) else (r.x, r.y, r.w, r.h)


def win_alpha(wid):
    a = ctypes.c_float(-1)
    return None if _sl.SLSGetWindowAlpha(_cid, wid, ctypes.byref(a)) else a.value


_cfa = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
_cfa.CFNumberCreate.restype = ctypes.c_void_p
_cfa.CFNumberCreate.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p]
_cfa.CFArrayCreate.restype = ctypes.c_void_p
_cfa.CFArrayCreate.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p), ctypes.c_long, ctypes.c_void_p]
_cfa.CFRelease.argtypes = [ctypes.c_void_p]
_sl.SLSMoveWindowsToManagedSpace.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint64]
_sl.SLSGetActiveSpace.restype = ctypes.c_uint64


def move_to_space(wids, space):
    """Перенести окна на рабочий стол space (как yabai: SLSMoveWindowsToManagedSpace)."""
    nums = [_cfa.CFNumberCreate(None, 3, ctypes.byref(ctypes.c_int32(w))) for w in wids]   # kCFNumberSInt32Type
    arr = (ctypes.c_void_p * len(nums))(*nums)
    a = _cfa.CFArrayCreate(None, arr, len(nums), ctypes.addressof(ctypes.c_void_p.in_dll(_cfa, "kCFTypeArrayCallBacks")))
    _sl.SLSMoveWindowsToManagedSpace(_cid, a, ctypes.c_uint64(int(space)))
    _cfa.CFRelease(a)
    for n in nums:
        _cfa.CFRelease(n)


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


_cg.CGEventSourceSecondsSinceLastEventType.restype = ctypes.c_double
_cg.CGEventSourceSecondsSinceLastEventType.argtypes = [ctypes.c_int, ctypes.c_uint32]


_cg.CGSessionCopyCurrentDictionary.restype = ctypes.c_void_p
_cfa.CFDictionaryGetValue.restype = ctypes.c_void_p
_cfa.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
_cfa.CFStringCreateWithCString.restype = ctypes.c_void_p
_cfa.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
_cfa.CFBooleanGetValue.argtypes = [ctypes.c_void_p]
_K_LOCKED = _cfa.CFStringCreateWithCString(None, b"CGSSessionScreenIsLocked", 0x08000100)


def screen_locked():
    """Экран заблокирован: приложения не отдают окна через AX (kAXWindows пуст) — раскладку не трогать."""
    d = _cg.CGSessionCopyCurrentDictionary()
    if not d:
        return False
    v = _cfa.CFDictionaryGetValue(d, _K_LOCKED)
    r = bool(v) and bool(_cfa.CFBooleanGetValue(v))
    _cfa.CFRelease(d)
    return r


def snapshot():
    n = _snap.ws_snapshot(_buf, len(_buf))
    if n < 0:
        raise RuntimeError("снимок окон не влез в буфер")
    d = json.loads(_buf.value)
    v = d["visible"]
    return d, (v["x"], v["y"], v["w"], v["h"])


class NoDeco:
    """Подложки выключены: тот же интерфейс, ничего не делает."""
    def ensure(self, *a): pass
    def place(self, *a): return None
    def sample(self, *a): pass
    def drop(self, *a): pass


class WM:
    def __init__(self):
        self.eng = Engine(log=log)
        # Подложки hyprdeco (отдельный процесс, асинхронно тику) давали серые прямоугольники, отстающие от окна
        # (при закрытии содержимое уходит, подложка висит). Выключены: полоса «буфер меньше рамки» прозрачна, пока
        # приложение не перерисовалось. Замена — край окна в CA-дереве окна (П4). HYPRWM_DECO=1 — вернуть.
        self.deco = Deco(log) if os.environ.get("HYPRWM_DECO") == "1" else NoDeco()
        st = json.load(open(STATE)) if os.path.exists(STATE) else {}
        self.spaces = st.get("spaces", {})          # space -> {tree, focus, full, presel}
        self.floating = set(st.get("floating", []))
        self.mins = json.load(open(MINSIZE)) if os.path.exists(MINSIZE) else {}   # owner -> [w, h]
        for k, (mw, mh) in list(self.mins.items()):             # ложные «минимумы во весь экран» прошлых версий
            if mw > 900 or mh > 700:
                self.mins[k] = [mw if mw <= 900 else 0, mh if mh <= 700 else 0]
        self.owner = {}      # wid -> имя приложения
        self.cfg_q = queue.Queue()   # ответы configure: (wid, owner, цель, фактическая рамка)
        self.info = {}       # pid -> {wid(str): {type, style, uuid}, "_conn": ...}
        self.miss = {}       # wid -> (попыток, когда) — окна, которых пока нет у WindowManager
        self.target = {}     # wid -> последняя цель, отданная движку
        self.pids = {}       # wid -> pid (для узнавания вкладок)
        self.gone_t = {}     # wid -> когда движок сообщил, что окна нет (замер задержки)
        self.newbies = {}    # wid -> когда движок увидел новое окно (ещё не в раскладке)
        self.optimistic = {}  # wid -> когда спрятано заранее (приложение тайлится, AX ещё не ответил)
        self.hidden = []                             # [{wid, pid, owner, space, rect}] — скрытые (special:hidden)
        for h in st.get("hidden", []):               # без дублей (старый баг: прятали уже скрытое)
            if all(x["wid"] != h["wid"] for x in self.hidden):
                self.hidden.append(h)
        self.restoring = set()                       # возвращаемые из скрытых: drift + fadeIn, не popin
        self.restore_from = {}                       # wid -> рамка, из которой возвращаемое окно начнёт drift
        self.cfg_final = {}                          # wid -> конечная плитка: сжатие окна — по концу хода (EV_DONE)
        self.seen = {}                               # wid -> когда демон впервые увидел окно (новое ≠ пришедшее с другого стола)
        self.later = []                              # [(когда, функция)]
        # configure: последняя цель окна побеждает; один рабочий поток на приложение (AX приложения
        # всё равно сериализуется его главным потоком) — поздний ответ со старой целью не перетирает новую
        self.cfg_lock = threading.Lock()
        # цвет края окон для заливки пустой полосы (движок, OP_FILL) — фоновый поток, снимок окна 15–40 мс
        self.fill_jobs, self.fill_q, self.fill_sent = [], queue.Queue(), {}
        threading.Thread(target=self._fill_worker, daemon=True).start()
        self.cfg_want = {}                           # wid -> последнее задание (с серийным номером)
        self.cfg_seq = 0
        self.cfg_workers = {}                        # pid -> очередь wid этого приложения
        self.closing = set()
        self.last_area = None
        self.front_pid = None                        # переднее приложение (из снимка)
        self.own_focus = (None, 0.0)                 # (pid, когда) — активацию сделали мы сами (follow_mouse)
        self.dim_since = {}                          # wid -> когда замечено «α<1 без причины» (страж)
        self.moved_t = {}                            # wid -> [когда] возвращали в плитку по EV_MOVED
        # П3: все тайловые окна выглядят активными — модуль hyprforce в процессе приложения. Загрузка через
        # lldb ставит приложение на паузу ~2 с, поэтому один раз на процесс и не во время открытия окна.
        self.forced = {}                             # pid -> когда впервые увидели / True, если загружено
        self.native = NativeCfg()                    # configure через модуль (NATIVE)
        self.force_q = queue.Queue()
        if os.environ.get("HYPRWM_ACTIVE", "1") != "0":
            threading.Thread(target=self._force_worker, daemon=True).start()
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
        now = time.time()
        i = self.info.get(pid, {}).get(k)
        if pid == getattr(self, "injecting", None):         # процесс стоит под lldb — AX ждал бы таймаут 0.25 с
            return i
        # положительный ответ — навсегда; отрицательный — переспросить: только что созданное окно
        # бывает ещё не AXStandardWindow / без settable размера (S5.2); первые ~3 с раз в 0.25 с
        if i and (i["type"] == "primary" or i.get("n", 9) >= 12 or now - i["t"] < 0.25):
            return i
        n, t = self.miss.get(wid, (0, 0))
        # окна ещё нет у приложения: первую секунду — каждый такт, потом с паузой (P26)
        if now - t < (0.0 if n < 60 else min(0.05 * 2 ** (n - 60), 1.0)):
            return None
        r = _ax.ax_tileable(pid, wid)
        if r < 0:
            self.miss[wid] = (n + 1, now)
            return i
        self.miss.pop(wid, None)
        i = {"type": "primary" if r == 1 else "other", "style": RESIZABLE if r == 1 else 0,
             "t": now, "n": (i or {}).get("n", 0) + 1}
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
        # у окна с модулем — минимум от самого AppKit (_validSize:force:), иначе выученный по приложению
        tile.MINS = {}
        for n in tile.leaves(s["tree"]):
            m = self.win_min(n["wid"])
            if m is None and self.owner.get(n["wid"]) in self.mins:
                m = self.mins[self.owner[n["wid"]]]
            if m is not None:
                tile.MINS[n["wid"]] = m
        rects = {wid: tile.with_gaps(b, area) for wid, b in tile.boxes(s["tree"], area, {}).items()}
        # рамка рисуется внутри окна (WS не рисует за его прямоугольником) — слот не уменьшаем, иначе двойной отступ
        bs = BORDER if self.eng.c.deco.on and self.eng.c.deco.sys_off != 1 else 0   # рамка снаружи — слот минус рамка
        if bs:
            rects = {wid: (r[0] + bs, r[1] + bs, r[2] - 2 * bs, r[3] - 2 * bs) for wid, r in rects.items()}
        if s.get("full") in rects:
            x, y, w, h = area
            go = tile.GAPS_OUT
            if s.get("fullmode") == "fullscreen":               # весь экран без зазоров
                rects[s["full"]] = (x, y, w, h)
            else:                                              # maximized: рабочая область минус gaps_out
                rects[s["full"]] = (x + go["left"] + bs, y + go["top"] + bs, w - go["left"] - go["right"] - 2 * bs,
                                    h - go["top"] - go["bottom"] - 2 * bs)
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
                if wid not in self.restoring:              # возвращаемое уже невидимо и пойдёт drift+fadeIn
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
            # цель та же — пропустить, но только если движок окно уже ведёт: рамка/маска живут в его слоте (после
            # перезапуска демона окна с прежней целью иначе оставались без рамки, пока не сдвинутся)
            if not force and self.target.get(wid) == to and wid in eng_w:
                continue
            back = wid in self.restoring                     # возврат/перенос — не новое окно (сжатие тоже в конце)
            if wid in opening and in_on and wid not in self.restoring:
                frm = None
                if pop:                                        # popin: от pop% цели, масштаб от центра
                    sw, sh = max(5.0, to[2] * pop), max(5.0, to[3] * pop)
                    frm = (to[0] + (to[2] - sw) / 2, to[1] + (to[3] - sh) / 2, sw, sh)
                # popin стартует, когда приложение прислало кадр размера плитки (wait, ≤150 мс): без растянутого
                # кадра размера по умолчанию
                # минимум приложения больше плитки — буфер размера плитки не придёт: popin без растяжения и без
                # ожидания (как перекладка: буфер 1:1 в растущем боксе), иначе прыжок в конце [daily_bugs F3]
                mw, mh = self.mins.get(cur[wid]["owner"], (0, 0))
                fixed = mw > to[2] + TOL or mh > to[3] + TOL
                c.geom(wid, to, in_c, in_c, frm=frm, move=True, stretch=not fixed, wait=not fixed)
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
                if wid in self.restore_from:                   # возврат: старт явно с прежней рамки (не с парковки)
                    frm = self.restore_from.pop(wid)
                hold = mv_on and any(o not in self.restoring for o in opening) and wid not in opening
                if SHRINK_SNAP and not SNAP and not SHRINK_LATE:
                    ew2 = eng_w.get(wid)
                    st = frm or ((ew2.pos.v[0], ew2.pos.v[1], ew2.size.v[0], ew2.size.v[1]) if ew2 else vis.get(wid))
                    if st and (to[2] < st[2] - 1 or to[3] < st[3] - 1):
                        frm = (st[0], st[1], min(st[2], to[2]), min(st[3], to[3]))   # сжимающаяся сторона — сразу
                c.geom(wid, to, mv_c, mv_c, frm=frm, move=True, warp=not mv_on, hold=hold)
                if wid in self.restoring:
                    self.restoring.discard(wid)
                    c.alpha(wid, 1.0, fi_c, fi_d if fi_on else 0.0)
            self.target[wid] = to
            posted.append(wid)
            # Приложению — конечный размер сразу и один раз по обеим осям (как xdg configure в Hyprland);
            # позицию ставит движок сразу. Пока буфер не совпал с видимой рамкой, движок показывает его
            # 1:1 от левого верхнего угла: больше рамки — обрезка, меньше — край закрыт подложкой.
            a = real.get(wid) or (cur[wid]["x"], cur[wid]["y"], cur[wid]["w"], cur[wid]["h"])
            if wid in opening or max(abs(p - q) for p, q in zip(a, to)) > 1:
                j = self.job(cur[wid]["pid"], wid, to)       # конечный размер сразу и один раз (Hyprland)
                # macOS: WS не рисует слои окна дальше его формы — при сжатии бокс B больше буфера показывал обои
                # («сосед прыгает к цели за кадр», live_test_1 №1). Сжимающаяся ось — прежний размер до конца хода
                # (EV_DONE), растущая — сразу. HYPRWM_SHRINK_LATE=0 — как Hyprland, всё сразу.
                self.cfg_final.pop(wid, None)
                shrink = j and (to[2] < a[2] - 1 or to[3] < a[3] - 1) and (wid not in opening or back)
                if shrink and SNAP:
                    # подкладка-снимок под окном на время хода: размер приложению сразу (перерисовка в начале, как
                    # Hyprland), а где бокс больше нового буфера — растянутое прежнее содержимое, не обои
                    c.snap(wid)
                elif j and SHRINK_LATE and (wid not in opening or back):
                    nw, nh = (max(to[2], a[2]) if to[2] < a[2] - 1 else to[2]), (max(to[3], a[3]) if to[3] < a[3] - 1 else to[3])
                    if (nw, nh) != (to[2], to[3]):
                        j["to"] = (to[0], to[1], nw, nh)
                        self.cfg_final[wid] = (to, (nw > to[2], nh > to[3]))   # цель и какие оси сжимаются
                if j:
                    jobs.append(j)
        if NATIVE and CFG_WS:                              # рамка приложению — из того же тика, что старт хода (A1)
            for j in jobs:
                if self.capable(j["pid"]):
                    c.cfg(j["wid"], j["to"])
                    j["ws"] = True
        if posted:
            c.commit()
        if jobs:                                           # размеры — сразу после публикации пачки (стартовые рамки
            for j in jobs:                                 # явные — «телепорта» нет), новые окна первыми [F1]
                j["new"] = j["wid"] in opening
            self.configure(sorted(jobs, key=lambda j: not j["new"]))
        if posted:
            t = time.time()                                # движок принимает пачку в ближайшем тике
            while c.h.cmd_tail != c.h.cmd_head and time.time() - t < 0.05:
                time.sleep(0.001)
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
        """Конечный размер приложениям (как configure Hyprland) — сразу после того, как движок принял пачку.
        На окно — только последняя цель (серийный номер); на приложение — один рабочий поток, задания
        окон одного приложения идут по очереди (S3: N потоков на одно окно перетирали друг друга).
        Поток перечитывает, что окно реально приняло, и кладёт ответ в очередь — главный цикл учит минимум."""
        with self.cfg_lock:
            for j in jobs:
                self.cfg_seq += 1
                j["seq"] = self.cfg_seq
                self.cfg_want[j["wid"]] = j
                q = self.cfg_workers.get(j["pid"])
                if q is None:
                    q = self.cfg_workers[j["pid"]] = queue.Queue()
                    threading.Thread(target=self._cfg_worker, args=(j["pid"], q), daemon=True).start()
                q.put(j["wid"])

    def _cfg_latest(self, wid, seq):
        with self.cfg_lock:
            j = self.cfg_want.get(wid)
            return j is not None and j["seq"] == seq

    def _cfg_worker(self, pid, q):
        """Все ждущие окна приложения — разом: размеры подряд без пауз, проверка ответа одним циклом
        (раньше окно за окном с ожиданием до 0.6 с — второе окно получало размер на сотни мс позже) [daily_bugs F1]."""
        while True:
            try:
                wids = [q.get(timeout=30)]
            except queue.Empty:
                with self.cfg_lock:                         # простаивает — уйти (новое задание заведёт поток)
                    if q.empty():
                        self.cfg_workers.pop(pid, None)
                        return
                continue
            while True:
                try:
                    wids.append(q.get_nowait())
                except queue.Empty:
                    break
            jobs = []
            with self.cfg_lock:
                for wid in dict.fromkeys(wids):
                    j = self.cfg_want.get(wid)
                    if j is None or j.get("taken"):
                        continue                             # уже сделано более новым заданием из очереди
                    j["taken"] = True
                    jobs.append(j)
            jobs.sort(key=lambda j: not j.get("new"))        # новые окна — первыми (их popin ждёт кадр размера)
            try:
                self._cfg_many(jobs)
            except Exception as e:
                log("configure окон %s упал: %r" % ([j["wid"] for j in jobs], e))

    def _cfg_many(self, jobs):
        buf = (ctypes.c_double * 4)()
        st = {}
        nat = bool(jobs) and NATIVE and self.capable(jobs[0]["pid"])   # одно приложение на поток
        get = (lambda j, b: srv_frame(j["wid"], b)) if nat else (lambda j, b: _ax.ax_get_frame(j["pid"], j["wid"], b))
        for j in jobs:                                      # 1) размеры всем подряд
            pre = tuple(buf) if get(j, buf) == 0 else None
            e = 0 if nat else _ax.ax_frame(j["pid"], j["wid"], *j["to"])
            st[j["wid"]] = {"j": j, "pre": pre, "e": e, "got": None, "same": 0, "done": bool(e)}
        if nat and not all(j.get("ws") for j in jobs):
            self.native.send(jobs[0]["pid"], [j for j in jobs if not j.get("ws")])
        if DEBUG_CFG:
            log("configure %s: %s" % ([j["wid"] for j in jobs],
                                     ("движок→модуль" if all(j.get("ws") for j in jobs) else "модуль") if nat else "AX"))
        t0 = time.time()
        while time.time() - t0 < 0.6 and not all(v["done"] for v in st.values()):   # 2) проверка одним циклом
            time.sleep(0.03)
            for v in st.values():
                if v["done"]:
                    continue
                j = v["j"]
                if not self._cfg_latest(j["wid"], j["seq"]):
                    v["done"], v["stale"] = True, True       # пришла новая цель — этот ответ не нужен
                    continue
                if get(j, buf) != 0:
                    continue
                cur, (w, h) = tuple(buf), j["to"][2:]
                if abs(cur[2] - w) <= TOL and abs(cur[3] - h) <= TOL:
                    v["got"], v["done"] = cur, True
                    continue
                v["same"] = v["same"] + 1 if cur == v["got"] else 0
                v["got"] = cur
                pre = v["pre"]
                # встало, где смогло: 90 мс без изменений; не сдвинулось с прежнего размера — ждать дольше
                # (Ghostty/Telegram применяют размер асинхронно), чтобы не принять «ещё не ответило» за минимум
                if v["same"] >= 3 and (pre is None or max(abs(p - q) for p, q in zip(cur[2:], pre[2:])) > 1 or
                                       time.time() - t0 > 0.35):
                    v["done"] = True
        for v in st.values():
            j = v["j"]
            if nat:
                self.native.done(j["wid"])
            if not v.get("stale") and self._cfg_latest(j["wid"], j["seq"]):
                self.cfg_q.put((j["wid"], j["owner"], j["to"], v["got"], v["e"], v["pre"]))

    def configured(self):  # noqa: C901
        """Ответы configure: окно стабильно стоит больше цели — это его минимум; запомнить по приложению.
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
            # Минимум: окно стабильно (поток дождался тишины) и по оси осталось больше цели. Неважно,
            # сдвигалось ли оно: окно, уже стоящее на минимуме, тоже должно учиться (S2).
            if self.win_min(wid) is not None:          # минимум знает сам AppKit — не учиться
                if abs(got[2] - to[2]) > TOL or abs(got[3] - to[3]) > TOL:
                    log("окно %s %d стоит %s вместо %s (минимум AppKit %s)" % (owner, wid, tuple(round(v) for v in got[2:]),
                                                                            to[2:], self.win_min(wid)))
                continue
            mw, mh = self.mins.get(owner, (0, 0))
            # Ложный минимум: окно ещё стоит в прошлом (большом) размере — Ghostty применяет размер асинхронно и
            # после развёртывания выучилось 1470×923 = весь экран. Минимум — только если окно сдвинулось к цели
            # и встало, либо, не сдвинувшись, всё равно не больше 60% экрана по оси (настоящие минимумы такие).
            ar = self.last_area or (0, 0, 1e9, 1e9)
            moved = pre is not None and max(abs(p - q) for p, q in zip(got[2:], pre[2:])) > 1
            def ok(g, limit):
                return g < 0.6 * limit or (moved and g < 0.9 * limit)
            # порог выучки шире сетки символов: Терминал округляет высоту до строки (455 при цели 448 — ложный
            # минимум, стопка с Telegram переставала влезать и обрезалась навсегда) [daily_bugs п.7]
            lt = max(TOL, 12)
            nw = max(mw, got[2]) if got[2] > to[2] + lt and ok(got[2], ar[2]) else mw
            nh = max(mh, got[3]) if got[3] > to[3] + lt and ok(got[3], ar[3]) else mh
            if (nw, nh) != (mw, mh):
                self.mins[owner] = [nw, nh]
                log("минимум %s: %s (окно %d: %s -> %s, цель %s)" % (owner, self.mins[owner], wid,
                    pre and tuple(round(v) for v in pre[2:]), tuple(round(v) for v in got[2:]), to[2:]))
                changed = True
            elif abs(got[2] - to[2]) > TOL or abs(got[3] - to[3]) > TOL:
                log("окно %s %d стоит %s вместо %s — держу в плитке" % (owner, wid, tuple(round(v) for v in got[2:]), to[2:]))

    def sync(self, area, space, wins):
        """Дерево стола <- его видимые окна. -> (изменилось ли, новые окна)."""
        s = self.sp(space)
        hid = {h["wid"] for h in self.hidden}
        closing = self.closing
        live = [w for w in wins if w["space"] == space and w["on"] and w["wid"] not in hid and
                w["wid"] not in closing and self.tileable(w)]
        ids = [w["wid"] for w in live]
        have = {n["wid"] for n in tile.leaves(s["tree"])}
        changed, opened = False, []
        # Вкладки (Ghostty, Finder, Safari): у macOS это отдельные окна одной группы, видна одна.
        # Ушло окно X и в этот же момент появилось окно того же приложения на его месте —
        # это переключение вкладки: новое окно занимает лист X, раскладка не меняется.
        gone = [x for x in have - set(ids)]
        alive = {w["wid"] for w in wins}
        # ушедшие «на задний план» (вкладку заслонила другая) или закрытые (Cmd+W вкладки — показалась соседняя)
        offscreen = {x for x in gone if x not in hid and (x not in alive or
                     any(w["wid"] == x and not w["on"] for w in wins))}
        for w in live:
            if w["wid"] in have:
                continue
            twin = next((x for x in gone if self.pids.get(x) == w["pid"] and self.target.get(x) and
                         max(abs(a - b) for a, b in zip(self.target[x], (w["x"], w["y"], w["w"], w["h"]))) <= TOL), None)
            if twin is None:
                # рамка новой вкладки в первые кадры бывает ещё не рамкой группы; признак надёжнее: окно того
                # же приложения в этот же момент ушло с экрана, но живо (не закрыто) — его заслонила вкладка
                twin = next((x for x in gone if self.pids.get(x) == w["pid"] and x in offscreen), None)
            if twin is None:
                continue
            for n in tile.leaves(s["tree"]):
                if n["wid"] == twin:
                    n["wid"] = w["wid"]
            gone.remove(twin)
            have.discard(twin); have.add(w["wid"])
            t = self.target.pop(twin, None)           # цель старой вкладки могли уже сбросить (EV_GONE)
            if t is not None:
                self.target[w["wid"]] = t
            if s.get("focus") == twin:
                s["focus"] = w["wid"]
            if s.get("full") == twin:
                s["full"] = w["wid"]
            # Вкладка у macOS появляется мгновенно — без анимации. Её могли спрятать до popin
            # (hide_newbies): вернуть альфу. Старой вкладке — освободить слот движка (трансформ, обрезка,
            # альфа сняты); при возврате на неё она снова пройдёт этой веткой.
            c = self.eng.c
            c.alpha(w["wid"], 1.0, 0, 0.0)
            c.forget(twin)
            c.commit()
            self.newbies.pop(w["wid"], None)
            self.optimistic.pop(w["wid"], None)
            self.dim_since.pop(w["wid"], None)
            self.deco.drop(twin)
            self.deco.ensure(w["wid"], w["owner"], 0)
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
        # активное окно (Hyprland делит именно его: use_active_for_splits) — активное по фокусу за курсором/биндам;
        # z-переднее только как запасной вариант (без AXRaise z при фокусе не меняется — делилось не то окно)
        a = getattr(self, "active", None)
        s["focus"] = (a if a in have else
                      next((x for x in ids if x in have), s.get("focus") if s.get("focus") in have else None))
        for w in live:
            if w["wid"] in have:
                continue
            target = s.get("focus") if s.get("focus") in have else None
            s["tree"] = self.insert(s, w["wid"], target, area)
            have.add(w["wid"])
            s["focus"] = w["wid"]
            opened.append(w["wid"])
            # Окно не новое (видели давно, не созданное только что): пришло с другого стола — перетащили, вернули
            # на стол системой. Как movetoworkspace в Hyprland: drift из текущей рамки, без popin и без гашения.
            wid = w["wid"]
            if (wid not in self.restoring and wid not in self.newbies and wid not in self.optimistic and
                    time.time() - self.seen.get(wid, time.time()) > 1.0):
                self.restoring.add(wid)
                self.target.pop(wid, None)
                log("окно %s (%d) пришло на стол -> в раскладку переносом" % (w["owner"], wid))
                self.deco.ensure(wid, w["owner"], 0)
                changed = True
                continue
            self.active = w["wid"]                              # новое окно получает фокус (Hyprland)
            log("%s %s (%d) -> в раскладку" % ("возврат окна" if wid in self.restoring else "новое окно", w["owner"], w["wid"]))
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
        self.last_area = area
        a = line.split()
        if not a:
            return "пусто"
        s, cmd = self.sp(space), a[0]
        rects = self.layout(area, s)
        # активное окно — под курсором (follow_mouse, как в Hyprland), иначе переднее разложенное: z-порядок
        # отстаёт, если курсор быстро ушёл на другое окно и сразу нажат бинд
        u = self.under_cursor(wins, space, rects)
        cur = u["wid"] if u and u["wid"] in rects else next((w["wid"] for w in wins if w["wid"] in rects and w["on"]), None)
        if cmd == "status":
            h = self.eng.c.h
            return json.dumps({"space": space, "tree": s["tree"], "focus": cur, "mins": self.mins,
                               "rects": {str(k): v for k, v in rects.items()},
                               "floating": sorted(self.floating), "hidden": [x["wid"] for x in self.hidden],
                               "engine": {"ticks": h.ticks, "active": h.nactive, "errors": h.errors,
                                          "slots": len(self.eng.c.wins()), "tick_us_max": round(h.tick_us_max, 1),
                                          "tick_us_last": round(h.tick_us_last, 1), "ticks_late": h.ticks_late,
                                          "te_skips": h.te_skips}, "snaps": self.snaps},
                              ensure_ascii=False)
        if cmd in ("focus", "move") and len(a) > 1:
            d = DIRS.get(a[1])
            tgt = tile.neighbour(rects, cur, d) if cur and d else None
            if tgt is None:
                return "нет окна: %s" % a[1]
            if cmd == "focus":
                pid = next(w["pid"] for w in wins if w["wid"] == tgt)
                self.own_focus = (pid, time.time())
                self._fwant, self._ft = tgt, time.time()
                self.active = tgt
                r = _ax.ax_focus(pid, tgt, RAISE)              # активное — поверх соседей (Hyprland Renderer.cpp:496)
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
            if len(a) > 1 and a[1].isdigit():                  # float <wid> — окно явно (стенды, не переднее)
                w = int(a[1])
            else:
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
            w = (next((x for x in wins if x["wid"] == int(a[1])), None) if len(a) > 1 and a[1].isdigit()
                 else self.front(wins, space))
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
            if len(a) > 1 and a[1].isdigit():
                return self.unhide(area, space, wins, which=[int(a[1])])
            return self.unhide(area, space, wins, everything=len(a) > 1 and a[1] == "all")
        elif cmd == "tospace" and len(a) == 3 and a[1].isdigit() and a[2].isdigit():
            self.eng.c.space(int(a[1]), int(a[2]))         # окно на стол (движок изнутри WS)
            self.eng.c.commit()
            return "окно %s -> стол %s" % (a[1], a[2])
        elif cmd == "raise" and len(a) >= 2 and a[1].isdigit():
            self.eng.c.raise_(int(a[1]), int(a[2]) if len(a) > 2 and a[2].isdigit() else 0)
            self.eng.c.commit()
            return "поднято %s" % a[1]
        elif cmd == "rescue":
            return self.rescue(area, space, wins)
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
        self.closing.add(wid)
        c.geom(wid, to, oc, oc, od if on else 0.0, od if on else 0.0, frm=cur, move=False, stretch=True)
        c.alpha(wid, 0.0, fc, fd if fon else 0.0)
        self.apply(area, space, wins)                      # соседи — в том же кадре
        c.commit()
        done = max(od if on else 0, fd if fon else 0)

        def shut():
            _snap.ws_close(w["pid"], wid)

        def check():
            self.closing.discard(wid)
            if win_bounds(wid) is not None and any(x.wid == wid for x in c.wins()):
                log("окно %d не закрылось — возвращаю" % wid)
                self.restoring.add(wid)                    # sync вставит обратно: drift из сжатой рамки + fadeIn,
                self.target.pop(wid, None)                 # а не второй popin (P32)
                self.later.append((time.time() + 1.5, lambda: self._restore_check(wid)))
        self.later.append((time.time() + done, shut))
        self.later.append((time.time() + done + 0.6, check))
        return "закрываю %d (%.0f мс)" % (wid, done * 1000)

    def _eligible(self, wins, space):
        skip = {h["wid"] for h in self.hidden} | self.closing
        dim = {w.wid for w in self.eng.c.wins() if w.cur_alpha < 0.05 and not w.alpha.active}
        return [w for w in wins if w["on"] and w["space"] == space and w["w"] >= 120 and w["h"] >= 120 and
                w["wid"] not in skip and w["wid"] not in dim]

    def under_cursor(self, wins, space, rects=None):
        """Окно под курсором прямо сейчас. У тайловых — их плитка (цель), а не рамка из снимка: снимок
        бывает старше 250 мс, а окно могло уже уехать."""
        rects = rects if rects is not None else self.layout(self.last_area, self.sp(space)) if self.last_area else {}
        x, y = mouse()
        for w in self._eligible(wins, space):              # z-порядок: спереди назад
            r = rects.get(w["wid"]) or (w["x"], w["y"], w["w"], w["h"])
            if r[0] <= x < r[0] + r[2] and r[1] <= y < r[1] + r[3]:
                return w
        return None

    def front(self, wins, space):
        """Окно для бинда (закрыть, скрыть, …): под курсором, как активное окно Hyprland при follow_mouse;
        если под курсором нет — самое переднее видимое окно стола. Скрытые/закрываемые/невидимые пропускаем."""
        return self.under_cursor(wins, space) or next(iter(self._eligible(wins, space)), None)

    def hide(self, area, space, wins, wid=None):
        """M+W: окно гаснет на месте (fadeOut), соседи сразу занимают место; потом уводим за экран."""
        w = next((x for x in wins if x["wid"] == wid), None) if wid else self.front(wins, space)
        if not w:
            return "нет окна"
        wid = w["wid"]
        if any(h["wid"] == wid for h in self.hidden):
            return "уже скрыто %d" % wid
        self.restoring.discard(wid)
        s = self.sp(space)
        rect = self.eng.real().get(wid) or (w["x"], w["y"], w["w"], w["h"])
        tiled = any(n["wid"] == wid for n in tile.leaves(s["tree"]))
        s["tree"] = tile.remove(s["tree"], wid)
        if s.get("full") == wid:
            s["full"] = None
        self.target.pop(wid, None)
        self.hidden.append({"wid": wid, "pid": w["pid"], "owner": w["owner"], "space": space, "rect": list(rect),
                            "tiled": tiled})
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

    def unhide(self, area, space, wins, everything=False, which=None):
        """M+Shift+W: последнее скрытое — назад в раскладку ТЕКУЩЕГО стола: drift из прежнего места +
        fadeIn (sync вставит его, apply поведёт как «возврат», не popin).
        which — выбрать: список wid или функция-фильтр по записи. everything — все сразу и мгновенно
        (только при остановке демона: дальше их никто не поведёт)."""
        if not self.hidden:
            return "скрытых нет"
        if callable(which):
            todo = [h for h in self.hidden if which(h)]
        elif which is not None:
            todo = [h for h in self.hidden if h["wid"] in which]
        else:
            todo = list(self.hidden) if everything else [self.hidden[-1]]
        if not todo:
            return "таких скрытых нет"
        c = self.eng.c
        for h in todo:
            self.hidden.remove(h)
            wid = h["wid"]
            w0 = next((x for x in wins or () if x["wid"] == wid), None)
            was = w0["space"] if w0 and w0.get("space") else h.get("space")   # фактический стол окна, не из записи
            if space is not None and str(was) != str(space):
                # скрыли на другом столе — вернуть сюда (P28). Клиентский SLSMoveWindowsToManagedSpace чужие окна
                # молча не двигает [V 08:58: окно 1591 осталось на столе 3] — переносит движок изнутри WS
                c.space(wid, int(space))
            # α=0 явно (frm): слот движка после переустановки считает α=1, а сервер при переносе на стол может
            # показать окно — переутверждаем невидимость в том же тике, до первого кадра
            if not everything:
                c.alpha(wid, 0.0, 0, 0.0, frm=0.0)
            c.geom(wid, tuple(h["rect"]), 0, 0, move=True, warp=True)   # невидимым — на прежнее место
            self.restore_from[wid] = tuple(h["rect"])
            w = next((x for x in wins or () if x["wid"] == wid), None)
            # тайловое ли — по записи скрытия: AX у окна на другом столе молчит (-1) [V 09:02], и окно ошибочно
            # считалось плавающим (вход popin вместо drift+fadeIn)
            tiled = h.get("tiled", True) if w is None or h.get("tiled") is not None else self.tileable(w)
            if everything:
                c.alpha(wid, 1.0, 0, 0.0)
            elif not tiled:                                         # плавающее — проявить на месте
                fi_c, fi_d, fi_on = self.eng.anim("fadeIn")
                c.alpha(wid, 1.0, fi_c, fi_d if fi_on else 0.0)
            else:
                self.restoring.add(wid)
                self.target.pop(wid, None)
                self.later.append((time.time() + 1.5, lambda wid=wid: self._restore_check(wid)))
        c.commit()
        self.save()
        return "возвращено %s" % [h["wid"] for h in todo]

    def _restore_check(self, wid):
        """Возвращаемое окно так и не попало в раскладку (не тайлится, другой стол) — просто показать."""
        if wid in self.restoring and all(h["wid"] != wid for h in self.hidden):
            self.restoring.discard(wid)
            self.eng.c.alpha(wid, 1.0, 0, 0.0)
            self.eng.c.commit()
            log("возврат окна %d: в раскладку не попало — показываю на месте" % wid)

    def on_activate(self, area, space, wins, pid):
        """Приложение стало передним не нашим фокусом (Dock, Cmd+Tab, open, уведомление): его скрытые окна
        возвращаются в раскладку текущего стола — как Hyprland при активации окна со special:hidden (P44)."""
        if not self.hidden:
            return
        for h in self.hidden:
            if h.get("pid") is None:
                h["pid"] = win_pid_level(h["wid"])[0]
        mine = [h["wid"] for h in self.hidden if h.get("pid") == pid]
        if not mine:
            return
        # Клик по видимому окну того же приложения — не повод возвращать скрытое. Возвращаем, если у
        # приложения на этом столе нет видимых окон (Dock/Cmd+Tab/open) или macOS вывел вперёд именно
        # скрытое окно (его key-окно).
        hid = {h["wid"] for h in self.hidden}
        own = [w for w in wins if w["pid"] == pid and w["on"] and w["w"] >= 120 and w["h"] >= 120]
        visible = [w for w in own if w["wid"] not in hid and w["space"] == space]
        if not visible or (own and own[0]["wid"] in hid):
            log("приложение %d активировано извне — возвращаю скрытые: %s" % (pid, self.unhide(area, space, wins, which=mine)))

    def rescue(self, area, space, wins, keep_hidden=False):
        """Страховка (P44): все скрытые — назад (команда rescue; при старте демона скрытые остаются
        скрытыми — keep_hidden); окна, оставшиеся невидимыми или за экраном без причины (альфа хранится
        в WS и переживает перезапуск демона и движка), — показать и вернуть на экран."""
        out = []
        alive = {w["wid"] for w in wins}
        self.hidden = [h for h in self.hidden if h["wid"] in alive]     # закрытые, пока демона не было
        if self.hidden and not keep_hidden:
            out.append(self.unhide(area, space, wins, which=lambda h: True))
        elif self.hidden:                                    # скрытые должны быть скрыты: α=0 и за экраном
            c = self.eng.c
            for h in self.hidden:
                r = win_bounds(h["wid"])
                if (win_alpha(h["wid"]) or 0) > 0.001 or (r and r[0] < area[0] + area[2]):
                    c.alpha(h["wid"], 0.0, 0, 0.0)
                    if r:
                        c.geom(h["wid"], (area[0] + area[2] + 200, r[1], r[2], r[3]), 0, 0, move=True, warp=True)
                    out.append("спрятано снова %d" % h["wid"])
            c.commit()
        hid = {h["wid"] for h in self.hidden}
        c, fixed = self.eng.c, []
        for w in wins:
            wid = w["wid"]
            if wid in hid or wid in self.closing or w["owner"] == "hyprdeco" or w["w"] < 120 or w["h"] < 120:
                continue
            a = win_alpha(wid)
            r = win_bounds(wid) or (w["x"], w["y"], w["w"], w["h"])
            off = r[0] >= area[0] + area[2] - 20 or r[0] + r[2] <= area[0] + 20 or r[1] >= area[1] + area[3] - 20
            if (a is None or a >= 0.999) and not off:
                continue
            if wid not in self.restoring and not self.tileable(w):
                continue                                    # служебные невидимые окна приложений не трогаем
            if off and wid not in self.restoring:
                c.geom(wid, (area[0] + 40, area[1] + 40, min(r[2], area[2] - 80), min(r[3], area[3] - 80)),
                       0, 0, move=True, warp=True)
            if wid not in self.restoring:
                c.alpha(wid, 1.0, 0, 0.0)
            self.target.pop(wid, None)
            fixed.append(wid)
        c.commit()
        if fixed:
            out.append("показаны %s" % fixed)
        self.save()
        return "; ".join(out) or "всё видно"

    def on_moved(self, wid, a):
        """Движок: покоящееся тайловое окно ушло с цели (приложение/система сами двинули, поздний AX).
        Как в Hyprland, плитка главнее: вернуть в неё тем же drift. Не воевать: не больше 3 раз за 10 с
        на окно (иначе окно, которое само упорно встаёт иначе, держится как есть). Перетаскивание мышью —
        не сюда: его разбирает realign после отпускания."""
        if mouse_down() or wid not in self.target or wid in self.closing:
            return False
        now = time.time()
        hist = [t for t in self.moved_t.get(wid, []) if now - t < 10]
        if len(hist) >= 3:
            return False
        self.moved_t[wid] = hist + [now]
        log("окно %d ушло с плитки %s -> %s — возвращаю" % (wid, self.target[wid], tuple(round(v) for v in a)))
        self.target.pop(wid, None)
        return True

    def _force_worker(self):
        """Загрузка модуля останавливает приложение через lldb на ~2 с: делать, когда с ним не работают —
        не переднее или ввод простаивает ≥ 1.5 с, и анимаций нет; не дольше 30 с ожидания [daily_bugs F9]."""
        while True:
            pid, owner = self.force_q.get()
            t0 = time.time()
            while time.time() - t0 < 30:
                idle = _cg.CGEventSourceSecondsSinceLastEventType(0, 0xFFFFFFFF)
                busy = self.eng.c is not None and self.eng.c.h.nactive > 0
                if (self.front_pid != pid or idle >= 1.5) and not busy:
                    break
                time.sleep(0.25)
            self.injecting = pid                     # главный цикл не шлёт AX остановленному процессу
            try:
                ok, msg, dt = inject.inject(pid)
            except Exception as e:
                ok, msg, dt = False, repr(e), 0.0
            self.injecting = None
            self.forced[pid] = True
            log("активный вид %s (%d): %s за %.1f с%s" % (owner, pid, "включён" if ok else "НЕ включён", dt,
                                                         "" if ok else " — " + msg[:200]))

    def publish_next(self, area, space, wins):
        """native_hooks §2: «куда встанет следующее окно» — модулю каждого приложения заранее. Модуль ставит эту
        рамку в NSWindowWillOrderOnScreen, и AppKit рисует первый кадр окна уже размера плитки (как
        predictSizeForNewTiledTarget в Hyprland до map) [V PROGRESS 15:10 шаг 2]. Раз в 50 мс; меняется с фокусом,
        стороной курсора, preselect и раскладкой."""
        if not NATIVE or not area or time.time() - getattr(self, "_next_t", 0) < 0.05:
            return
        self._next_t = time.time()
        s = self.sp(space)
        have = {n["wid"] for n in tile.leaves(s["tree"])}
        a = getattr(self, "active", None)
        target = a if a in have else (s.get("focus") if s.get("focus") in have else None)
        probe = {"tree": copy.deepcopy(s["tree"]), "presel": s.get("presel"), "full": None}
        probe["tree"] = self.insert(probe, -1, target, area)
        r = self.layout(area, probe).get(-1)
        apps = {}
        for w in wins:
            if w["pid"] not in apps:
                apps[w["pid"]] = w["owner"]
        self.native.next(r, {pid for pid, owner in apps.items() if self.forced.get(pid) is True and
                             self.capable(pid) and not self.float_owner(owner)})

    def win_min(self, wid):
        """Минимум окна от модуля hyprforce v3 ("hyprwm.min.<wid>", полупункты) -> [w, h] или None (кэш 1 с)."""
        pid = self.pids.get(wid)
        if pid is None or not NATIVE or not self.capable(pid):
            return None
        c = getattr(self, "_wmin", None)
        if c is None:
            c = self._wmin = {}
        v = c.get(wid)
        if v is None or time.time() - v[1] > 1.0:
            t, x = ctypes.c_int(), ctypes.c_uint64()
            m = None
            if _nt.notify_register_check(("hyprwm.min.%d" % wid).encode(), ctypes.byref(t)) == 0:
                _nt.notify_get_state(t, ctypes.byref(x))
                _nt.notify_cancel(t)
                if x.value:
                    m = [(x.value & 0xffff) / 2.0, ((x.value >> 16) & 0xffff) / 2.0]
            v = c[wid] = (m, time.time())
        return v[0]

    def capable(self, pid):
        """В процессе модуль с configure этой версии (кэш на 5 с: notifyd — IPC)."""
        c = getattr(self, "_cap", None)
        if c is None:
            c = self._cap = {}
        v = c.get(pid)
        if v is None or time.time() - v[1] > 5:
            v = c[pid] = (inject.cap(pid) >= inject.CAP, time.time())
        return v[0]

    def float_owner(self, owner):
        """У приложения есть правило float по классу (OpenRunner и т.п.) — его новым окнам рамку плитки не давать."""
        for r in self.float_rules:
            c = r.get("match", {}).get("class")
            try:
                if c and re.search(c, owner):
                    return True
            except re.error:
                pass
        return False

    def force_active(self, wins):
        """Приложения с окнами в раскладке — в очередь на загрузку модуля (через 1.5 с после первого появления)."""
        if os.environ.get("HYPRWM_ACTIVE", "1") == "0":
            return
        tiled = {n["wid"] for sp in self.spaces.values() for n in tile.leaves(sp.get("tree"))}
        now = time.time()
        for w in wins:
            pid = w["pid"]
            if w["wid"] not in tiled or self.forced.get(pid) is True or pid == os.getpid():
                continue
            t = self.forced.setdefault(pid, now)
            if t is not True and t != -1 and now - t > 1.5:
                self.forced[pid] = -1                  # в очереди
                self.force_q.put((pid, w["owner"]))

    def alpha_guard(self, wins):
        """Страж: окно в слоте движка стоит с α<1 без анимации и без причины (не скрыто, не закрывается,
        не ждёт popin) дольше 1 с — вернуть α=1. Ловит любые пропущенные пути вроде P1."""
        now = time.time()
        busy = (self.closing | self.restoring | set(self.newbies) | set(self.optimistic) |
                {h["wid"] for h in self.hidden})
        on = {w["wid"] for w in wins if w["on"]}          # невидимость важна только у окна на экране
        c, fix = self.eng.c, []
        for w in c.wins():
            if w.wid in busy or w.wid not in on or w.cur_alpha >= 0.999 or w.alpha.active or w.held:
                self.dim_since.pop(w.wid, None)
                continue
            t = self.dim_since.setdefault(w.wid, now)
            if now - t > 1.0:
                fix.append(w.wid)
        for wid in fix:
            self.dim_since.pop(wid, None)
            c.alpha(wid, 1.0, 0, 0.0)
        if fix:
            c.commit()
            log("страж: α=1 окнам %s (оставались невидимыми без причины)" % fix)

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
            if pid:                                    # обход меню AX — не в главном цикле (S5.3)
                def press():
                    if _ax.ax_menu_press(pid, b"New Window") != 0:
                        subprocess.Popen(["open", "-a", app])
                threading.Thread(target=press, daemon=True).start()
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
        rescued, last_guard, last = False, 0.0, None
        last_snap, last_sp = 0.0, None
        self.snaps = 0
        log("hyprwm запущен")
        while True:
            r, _, _ = select.select([srv], [], [], POLL)
            if r and last is not None:
                self.commands(srv, *last)                  # команды — сразу, до снимка (его выбросы до 30 мс)
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
                if self.eng.c.h.errors != getattr(self, "_errors", 0):
                    self._errors = self.eng.c.h.errors
                    log("движок: ошибок %d (слотов занято %d из 64)" % (self._errors, len(self.eng.c.wins())))
            # Полный снимок окон — только когда что-то могло измениться (Q2): событие движка, команда,
            # смена стола/переднего приложения, кнопка мыши, окна в процессе открытия/возврата/закрытия;
            # иначе сверка раз в 250 мс. Остальное время — данные прошлого снимка (раньше 60 снимков/с).
            drifted, evs = False, list(self.eng.c.events())
            for ev in evs:
                if ev[0] == chan.EV_NEW:
                    self.newbies[ev[1]] = time.time()
                    if ev[3][0] == 1:                      # движок уже спрятал (тайловое приложение, уровень 0)
                        self.optimistic[ev[1]] = time.time()
                    continue
                if ev[0] == chan.EV_DONE and ev[1] in self.cfg_final:   # бокс доехал — теперь сжать окно
                    wid = ev[1]
                    to = self.cfg_final.pop(wid)[0]
                    if self.target.get(wid) == to and wid in self.pids:
                        self.configure([{"wid": wid, "pid": self.pids[wid], "owner": self.owner.get(wid, ""),
                                         "to": tuple(to)}])
                    continue
                if ev[0] == chan.EV_REL:                   # П8: окно освобождается (журнал: на экране ли ещё)
                    x = ev[3]
                    if x[3]:                               # только окна, которые ведёт движок (служебные — шум)
                        log("закрытие окна %d: на экране=%d уровень=%d слот=%d" % (ev[1], x[0], x[2], x[3]))
                    continue
                if ev[0] == chan.EV_CLONE:
                    log("закрытие окна %d: снимок %d уходит (windowsOut)" % (int(ev[3][0]), ev[1]))
                    continue
                if ev[0] == chan.EV_MOVED:
                    drifted |= self.on_moved(ev[1], ev[3])
                    continue
                if ev[0] == chan.EV_GONE:
                    wid = ev[1]
                    self.gone_t[wid] = time.time()
                    self.target.pop(wid, None)
                    self.deco.drop(wid)
                    _ax.ax_forget(wid)                         # AX-кэш не копит мёртвые окна (P7)
                    self.dim_since.pop(wid, None)
                    for pid in list(self.info):
                        self.info[pid].pop(str(wid), None)
                    self.miss.pop(wid, None)
                    self.owner.pop(wid, None)
                    self.seen.pop(wid, None)
            if time.time() - getattr(self, "_lock_t", 0) > 0.25:
                self._lock_t = time.time()
                lk = screen_locked()
                if lk != getattr(self, "_locked", False):
                    self._locked = lk
                    log("экран заблокирован — раскладка заморожена" if lk else "экран разблокирован")
                    last_snap = 0.0                              # после разблокировки — сразу полный снимок
            if getattr(self, "_locked", False):
                continue                                         # AX молчит: sync выкинул бы все окна из дерева
            fp = front_pid()
            md = mouse_down()
            sp_now = _sl.SLSGetActiveSpace(_cid)
            need = (last is None or r or evs or self.newbies or self.optimistic or self.restoring or self.closing
                    or sp_now != last_sp or md != was_down or fp != self.front_pid or not self.cfg_q.empty()
                    or time.time() - last_snap > 0.25)
            if need:
                d, area = snapshot()
                if not d["stable"]:
                    continue                                     # стол переключается посреди снимка
                space, wins = d["space"], [w for w in d["windows"] if w["owner"] != "hyprdeco"]   # без подложек
                last_snap, last_sp = time.time(), sp_now
                self.snaps += 1
                if r and last is None:
                    self.commands(srv, area, space, wins)
                last = (area, space, wins)
                self.last_area = area
            else:
                area, space, wins = last
            if space != last_space:
                log("рабочий стол", space)
                last_space = space
            if not rescued:                                  # после (пере)запуска: скрытые — назад, а
                rescued = True                               # невидимые без причины — показать (P33, P44)
                log("старт: %s" % self.rescue(area, space, wins, keep_hidden=True))
                self.sync(area, space, wins)
                self.apply(area, space, wins, force=True)  # движок узнаёт соединения тайловых приложений (prehide)
            top = max((w["wid"] for w in wins), default=0)
            # номера новых окон сканирует движок и сам ведёт wid_max; демон только будит застрявший скан
            # (первый запуск или разрыв > 24 номеров) — иначе две стороны пишут поле наперегонки (S5.5)
            if top > self.eng.c.h.wid_max + 24 or not self.eng.c.h.wid_max:
                self.eng.c.h.wid_max = top
            if fp and fp != self.front_pid:
                prev, self.front_pid = self.front_pid, fp
                own = self.own_focus[0] == fp and time.time() - self.own_focus[1] < 1.0
                if prev is not None and not own:
                    self.on_activate(area, space, wins, fp)
                    # фокус пришёл извне — активным становится переднее окно этого приложения
                    self.active = next((w["wid"] for w in wins if w["pid"] == fp and w["on"] and
                                        w["space"] == space), None)
            self.follow_mouse(space, wins)
            self.border_focus(space, wins)
            if self.cfg_final:                             # сжатие окна — когда бокс подошёл к цели (< 2 pt), не
                ew = {w.wid: w for w in self.eng.c.wins()}  # дожидаясь хвоста пружины (EV_DONE через ~1 с)
                for wid, (to, sh) in list(self.cfg_final.items()):
                    e = ew.get(wid)
                    # сжимающаяся ось: бокс опустился до цели + 2 pt (недолёт пружины ниже цели — тоже «доехал»)
                    if e is None or all(not sh[i] or e.size.v[i] <= to[2 + i] + 2 for i in (0, 1)):
                        self.cfg_final.pop(wid)
                        if e is not None and self.target.get(wid) == to and wid in self.pids:
                            self.configure([{"wid": wid, "pid": self.pids[wid], "owner": self.owner.get(wid, ""),
                                             "to": tuple(to)}])
            self.fills(space, wins)
            self.publish_next(area, space, wins)
            for w in wins:
                self.owner[w["wid"]] = w["owner"]
                self.seen.setdefault(w["wid"], time.time())
            self.hide_newbies(space, wins)
            if self.hidden and time.time() - getattr(self, "_hpurge", 0) > 2.0:
                self._hpurge = time.time()                 # закрытые скрытые окна — из списка (unhide брал мёртвое)
                dead = [h["wid"] for h in self.hidden if win_bounds(h["wid"]) is None]   # сервер: окна нет
                if dead:
                    self.hidden = [h for h in self.hidden if h["wid"] not in dead]
                    log("скрытые: убраны закрытые %s" % dead)
                    self.save()
            if time.time() - getattr(self, "_sampled", 0) > 2.0:     # цвет края окон для подложек
                self._sampled = time.time()
                busy = {w.wid for w in self.eng.c.wins() if w.pos.active or w.size.active or w.settling}
                for n in tile.leaves(self.sp(space)["tree"]):
                    if n["wid"] not in busy:
                        self.deco.sample(n["wid"])
            changed, opened = self.sync(area, space, wins)
            changed |= drifted
            changed |= self.configured()                   # окно не приняло размер — ретаргет сразу
            if was_down and not md:                        # отпустили кнопку: окно могли утащить мышью
                changed |= self.realign(area, space, wins)
            was_down = md
            # тайловое окно стола без слота движка (после перезапуска цель «та же») — без рамки/маски: подать
            if not changed and time.time() - getattr(self, "_slot_t", 0) > 1.0:
                here = {w["wid"] for w in wins if w["on"] and w["space"] == space}
                miss = ({n["wid"] for n in tile.leaves(self.sp(space)["tree"])} & here) - {w.wid for w in self.eng.c.wins()}
                if miss:
                    self._slot_t = time.time()
                    changed = True
            if changed:
                self.apply(area, space, wins, opening=opened)
            if time.time() - last_guard > 0.25:
                last_guard = time.time()
                self.alpha_guard(wins)
                self.force_active(wins)

    def commands(self, srv, area, space, wins):
        """Все ждущие команды сокета за раз (автоповтор бинда не морит голодом остальное — P42)."""
        while select.select([srv], [], [], 0)[0]:
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
        def tab(pid, wid):
            # вкладка (Ghostty/Finder/Safari): новое окно встаёт ровно на рамку тайлового окна того же
            # приложения — его не прятать, оно просто заменит лист (sync, ветка «вкладка»)
            r = win_bounds(wid)
            return r is not None and any(self.pids.get(x) == pid and max(abs(a - b) for a, b in zip(t, r)) <= TOL
                                         for x, t in self.target.items())
        for wid, t in list(self.newbies.items()):
            w = by.get(wid)
            if time.time() - t > 1.5:
                self.newbies.pop(wid)
                continue
            if not w or w["w"] < 120 or w["h"] < 120:
                # окна ещё нет в списке: спросить сервер напрямую — обычный уровень и тайловое приложение
                pid, lv = win_pid_level(wid)
                if lv == 0 and pid in tiled_pids and wid not in self.optimistic and not tab(pid, wid):
                    self.optimistic[wid] = time.time()
                    c.alpha(wid, 0.0, 0, 0.0, frm=0.0)
                    touched = True
                continue
            if tab(w["pid"], wid):
                self.newbies.pop(wid)
                if self.optimistic.pop(wid, None):
                    c.alpha(wid, 1.0, 0, 0.0)
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
            if wid not in self.newbies and time.time() - t > 1.5:
                self.optimistic.pop(wid)
                c.alpha(wid, 1.0, 0, 0.0)
                touched = True
        if touched:
            c.commit()

    def _fill_worker(self):
        while True:
            time.sleep(2.0)
            for wid, r in list(self.fill_jobs):
                o = (ctypes.c_double * 3)()
                try:
                    if _ax.ax_edge_color(wid, r[0], r[1], r[2], r[3], o) == 0:
                        v = [min(255, max(0, round(x * 255))) for x in o]
                        self.fill_q.put((wid, v[0] << 24 | v[1] << 16 | v[2] << 8 | 255))
                except Exception:
                    pass

    def fills(self, space, wins):
        """Задания цвета края — покоящиеся тайловые окна стола; готовые цвета — в движок (только изменившиеся)."""
        s = self.sp(space)
        tiled = {n["wid"] for n in tile.leaves(s["tree"])}
        busy = {w.wid for w in self.eng.c.wins() if w.pos.active or w.size.active or w.settling}
        self.fill_jobs = [(w["wid"], (w["x"], w["y"], w["w"], w["h"])) for w in wins
                          if w["wid"] in tiled and w["wid"] not in busy and w["on"]]
        sent = False
        while not self.fill_q.empty():
            wid, rgba = self.fill_q.get()
            if self.fill_sent.get(wid) != rgba:
                self.fill_sent[wid] = rgba
                self.eng.c.fill(wid, rgba)
                sent = True
        if sent:
            self.eng.c.commit()

    def border_focus(self, space, wins):
        """П6: активная рамка = активное окно Hyprland: то, которому фокус отдали мы (follow_mouse, бинд, новое
        окно) — сразу, без ожидания macOS (активация приложения приходит с задержкой или не приходит, и рамка
        откатывалась на старое окно). Активация извне (Cmd+Tab, Dock, клик) — по событию смены переднего
        приложения (on_front): тогда активным становится переднее окно этого приложения."""
        s = self.sp(space)
        here = {w["wid"] for w in wins if w["on"] and w["space"] == space}
        tiled = {n["wid"] for n in tile.leaves(s["tree"])}
        a = getattr(self, "active", None)
        if a not in here or a not in tiled:
            a = None
        if a is None:                                        # окно ушло / стол сменился: как Hyprland — окно под
            u = self.under_cursor(wins, space)               # курсором, иначе переднее окно переднего приложения
            a = (u["wid"] if u and u["wid"] in tiled else
                 next((w["wid"] for w in wins if w["wid"] in here and w["wid"] in tiled and
                       w["pid"] == self.front_pid), None) or
                 next((w["wid"] for w in wins if w["wid"] in here and w["wid"] in tiled), None))
            self.active = a
            if a and u and u["wid"] == a:                    # и клавиатурный фокус туда же (как после закрытия в Hyprland)
                self._fwant, self._ft = a, time.time()
                self.own_focus = (u["pid"], time.time())
                self.focus_async(u["pid"], a)
        nf = s.get("full") if s.get("fullmode") == "fullscreen" else 0
        d = self.eng.c.deco
        if d.focus != (a or 0):
            d.focus = a or 0
        if d.nofull != (nf or 0):
            d.nofull = nf or 0

    def focus_async(self, pid, wid):
        """AX-фокус (+AXRaise) в отдельном потоке: приложение отвечает до десятков мс — главный цикл и рамка не ждут.
        Выполняется только последний запрос."""
        with self.cfg_lock:
            self._fq = (pid, wid)
        if not getattr(self, "_fthread", None):
            def run():
                while True:
                    self._fev.wait()
                    self._fev.clear()
                    with self.cfg_lock:
                        q, self._fq = self._fq, None
                    if q:
                        try:
                            _ax.ax_focus(q[0], q[1], RAISE)
                        except Exception as e:
                            log("фокус %d: %r" % (q[1], e))
            self._fev = threading.Event()
            self._fthread = threading.Thread(target=run, daemon=True)
            self._fthread.start()
        self._fev.set()

    def follow_mouse(self, space, wins):
        """input:follow_mouse = 1: фокус у окна под курсором, как только курсор на него зашёл.
        Берётся самое верхнее окно под курсором (меню/попапы/плавающие перекрывают — их не трогаем)."""
        p = mouse()
        if p == getattr(self, "_mp", None) or mouse_down():
            return
        self._mp = p
        s = self.sp(space)
        tiled = {n["wid"] for n in tile.leaves(s["tree"])}
        hid = {h["wid"] for h in self.hidden}
        # окно под курсором по ВИДИМОМУ боксу (как Hyprland): у тайловых — плитка, а не фактическая рамка. Окно,
        # не ужавшееся до плитки (минимум), обрезано маской, но его рамка шире — и по z-порядку оно перехватывало
        # курсор над соседом: фокус уходил не туда, рамка «загоралась только после клика» [V 10:11]
        rects = self.layout(self.last_area, s) if self.last_area else {}

        def box(w):
            return rects.get(w["wid"]) or (w["x"], w["y"], w["w"], w["h"])
        top = next((w for w in wins if w["on"] and w["wid"] not in hid and
                    box(w)[0] <= p[0] < box(w)[0] + box(w)[2] and box(w)[1] <= p[1] < box(w)[1] + box(w)[3]), None)
        front = next((w for w in wins if w["on"] and w["space"] == space and w["w"] >= 120 and w["h"] >= 120), None)
        if os.environ.get("HYPRWM_DEBUG"):
            log("курсор", p, "верх", top and top["wid"], "перед", front and front["wid"], "тайлы", tiled)
        if not top or top["wid"] not in tiled:
            return
        # без AXRaise z-порядок не меняется, поэтому «уже в фокусе» — по нашей памяти: фокус отдан этому
        # окну и его приложение переднее (если кто-то активировал другое приложение — фокус снова нужен)
        # «уже в фокусе» — только если и рамка (активное окно) на нём: новое окно/активация извне могли забрать
        # активное, а наша память фокуса осталась прежней → курсор возвращался, рамка не шла [скрины 12:36/12:38]
        same = getattr(self, "active", None) == top["wid"]
        if same and getattr(self, "_fwant", None) == top["wid"] and (self.front_pid == top["pid"] or time.time() - self._ft < 0.3):
            return
        if same and getattr(self, "_fwant", None) is None and front and front["wid"] == top["wid"]:
            return
        self._fwant, self._ft = top["wid"], time.time()
        self.active = top["wid"]
        self.eng.c.deco.focus = top["wid"]                # рамка — сразу, не ждём ответа приложения на AX
        self.own_focus = (top["pid"], time.time())
        # AXRaise: Hyprland рисует активное окно последним — поверх соседей и их теней (Renderer.cpp:496–510 [V
        # decor_v2]); без подъёма тени соседей ложились на кольцо активного («ярко по углам, ярче после клика»).
        # Q3 («Hyprland не меняет z») опровергнут исходником. Серверный CGXOrderWindow порядок не меняет [V 12:14].
        self.focus_async(top["pid"], top["wid"])
        r = 0
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
