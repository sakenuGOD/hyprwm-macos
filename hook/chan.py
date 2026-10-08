"""Канал демон <-> движок v4 в WindowServer (общая память /tmp/hyprwm/chan, см. src/chan.h).

Команды пишутся пачкой (geom/alpha/forget) и публикуются commit() — движок применяет всю
пачку в одном тике с одним t0. Кривые Hyprland задаются по номерам (curves()).
"""
import ctypes
import os
import subprocess

HOOK = os.path.dirname(os.path.abspath(__file__))
DIR = "/tmp/hyprwm"
PTR = DIR + "/chan_path"     # путь к текущему каналу. Каждая установка — НОВЫЙ файл: файл под живым
                             # движком нельзя пересоздавать/обрезать (обрезка = SIGBUS в WindowServer,
                             # так упала сессия 2026-10-08 20:27)
LIB = os.path.join(HOOK, "build", "libhyprchan.dylib")

CH_MAGIC = 0x3530574d52505948
CV_NONE, CV_BEZIER, CV_SPRING = 0, 1, 2
OP_GEOM, OP_ALPHA, OP_FORGET, OP_WARP, OP_UNDER = 1, 2, 3, 4, 5
F_FROM, F_MOVE, F_STRETCH = 1, 2, 4
EV_GONE, EV_SETTLED, EV_DONE, EV_NEW = 1, 2, 3, 4


class Var(ctypes.Structure):
    _fields_ = [("b", ctypes.c_double * 2), ("g", ctypes.c_double * 2), ("v", ctypes.c_double * 2),
                ("sv", ctypes.c_double), ("svel", ctypes.c_double), ("t0", ctypes.c_double),
                ("last", ctypes.c_double), ("dur", ctypes.c_double), ("curve", ctypes.c_uint32),
                ("active", ctypes.c_uint32)]


class Win(ctypes.Structure):
    _fields_ = [("wid", ctypes.c_uint32), ("used", ctypes.c_uint32), ("settling", ctypes.c_uint32),
                ("clipped", ctypes.c_uint32), ("pos", Var), ("size", Var), ("alpha", Var),
                ("ax", ctypes.c_double), ("ay", ctypes.c_double), ("aw", ctypes.c_double), ("ah", ctypes.c_double),
                ("m", ctypes.c_double * 4), ("done_t", ctypes.c_double), ("cur_alpha", ctypes.c_double),
                ("clip", ctypes.c_double * 4), ("stretch", ctypes.c_uint32), ("under", ctypes.c_uint32),
                ("um", ctypes.c_double * 4), ("ualpha", ctypes.c_double),
                ("radius", ctypes.c_double), ("pa", ctypes.c_double * 4),
                ("stable", ctypes.c_uint32), ("pad3", ctypes.c_uint32),
                ("a0", ctypes.c_double * 2), ("held", ctypes.c_uint32), ("needs", ctypes.c_uint32)]


class Hdr(ctypes.Structure):
    _fields_ = [("magic", ctypes.c_uint64), ("version", ctypes.c_uint32), ("size", ctypes.c_uint32),
                ("cmd_head", ctypes.c_uint32), ("cmd_tail", ctypes.c_uint32),
                ("evt_head", ctypes.c_uint32), ("evt_tail", ctypes.c_uint32),
                ("ticks", ctypes.c_uint32), ("frames", ctypes.c_uint32), ("now", ctypes.c_double),
                ("nactive", ctypes.c_uint32), ("errors", ctypes.c_uint32),
                ("idle_poll", ctypes.c_double), ("settle", ctypes.c_double), ("settle_px", ctypes.c_double),
                ("stop", ctypes.c_uint32), ("applied", ctypes.c_uint32), ("last_dt", ctypes.c_double),
                ("phase", ctypes.c_double), ("period", ctypes.c_double), ("margin", ctypes.c_double),
                ("te", ctypes.c_double), ("wid_max", ctypes.c_uint32), ("holding", ctypes.c_uint32),
                ("hold_t", ctypes.c_double), ("hold_max", ctypes.c_double)]


class Evt(ctypes.Structure):
    _fields_ = [("type", ctypes.c_uint32), ("wid", ctypes.c_uint32), ("t", ctypes.c_double),
                ("x", ctypes.c_double), ("y", ctypes.c_double), ("w", ctypes.c_double), ("h", ctypes.c_double)]


def build():
    os.makedirs(os.path.dirname(LIB), exist_ok=True)
    src = os.path.join(HOOK, "src", "chanlib.c")
    if not os.path.exists(LIB) or os.path.getmtime(LIB) < max(os.path.getmtime(src),
                                                              os.path.getmtime(os.path.join(HOOK, "src", "chan.h"))):
        subprocess.check_call(["clang", "-O2", "-Wall", "-dynamiclib", src, "-o", LIB])


class Chan:
    def __init__(self, create=False):
        build()
        L = self.L = ctypes.CDLL(LIB)
        L.ch_open.restype = ctypes.c_void_p
        L.ch_open.argtypes = [ctypes.c_char_p, ctypes.c_int]
        d = ctypes.c_double
        L.ch_geom.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.c_uint] + [d] * 8 + [ctypes.c_uint] * 2 + [d] * 2
        L.ch_alpha.argtypes = [ctypes.c_uint, ctypes.c_uint, d, d, ctypes.c_uint, d]
        L.ch_curve_bezier.argtypes = [ctypes.c_int] + [ctypes.c_float] * 4
        L.ch_curve_spring.argtypes = [ctypes.c_int, d, d, d]
        L.ch_event.argtypes = [ctypes.POINTER(Evt)]
        if create:
            import time
            os.makedirs(DIR, exist_ok=True)
            os.chmod(DIR, 0o777)
            self.path = "%s/chan.%d.%d" % (DIR, os.getpid(), int(time.time() * 1000))
            assert not os.path.exists(self.path)
        else:
            self.path = open(PTR).read().strip()
        self.base = L.ch_open(self.path.encode(), int(create))
        if not self.base:
            raise OSError("не открыть " + self.path)
        if create:
            tmp = PTR + ".tmp"
            open(tmp, "w").write(self.path)
            os.rename(tmp, PTR)
        assert L.ch_off(0) == ctypes.sizeof(Win) and L.ch_off(3) == ctypes.sizeof(Var), "chan.h и chan.py разошлись"
        self.h = Hdr.from_address(self.base)
        self.win_off = L.ch_off(1)

    # ── команды ──────────────────────────────────────────────────────────
    def geom(self, wid, to, cpos, csize, dpos=0.0, dsize=0.0, frm=None, move=True, warp=False, stretch=False):
        fl = (F_FROM if frm else 0) | (F_MOVE if move else 0) | (F_STRETCH if stretch else 0)
        f = frm or (0, 0, 0, 0)
        r = self.L.ch_geom(OP_WARP if warp else OP_GEOM, wid, fl, *map(float, to), *map(float, f),
                           cpos, csize, float(dpos), float(dsize))
        if r:
            raise RuntimeError("кольцо команд полно (движок не забирает)")

    def alpha(self, wid, a, curve, dur=0.0, frm=None):
        if self.L.ch_alpha(wid, F_FROM if frm is not None else 0, float(a), float(frm or 0), curve, float(dur)):
            raise RuntimeError("кольцо команд полно")

    def under(self, wid, under):
        self.L.ch_under(wid, under)

    def forget(self, wid):
        self.L.ch_forget(wid)

    def commit(self):
        self.L.ch_commit()

    # ── кривые ───────────────────────────────────────────────────────────
    def bezier(self, i, p1, p2):
        self.L.ch_curve_bezier(i, p1[0], p1[1], p2[0], p2[1])

    def spring(self, i, mass, k, d):
        self.L.ch_curve_spring(i, mass, k, d)

    # ── состояние ────────────────────────────────────────────────────────
    def events(self):
        e = Evt()
        while self.L.ch_event(ctypes.byref(e)):
            yield (e.type, e.wid, e.t, (e.x, e.y, e.w, e.h))

    def wins(self):
        arr = (Win * 64).from_address(self.base + self.win_off)
        return [w for w in arr if w.used]

    def alive(self, wait=0.1):
        import time
        t0 = self.h.ticks
        time.sleep(wait)
        return self.h.ticks != t0
