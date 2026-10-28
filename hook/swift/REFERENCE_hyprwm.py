#!/usr/bin/env python3
# Python reference model used to generate Swift test fixtures. Not used at runtime.
"""Python tiling model with a dwindle tree for each macOS desktop.

The daemon turns window and keyboard events into one batch of target rectangles.
The WindowServer engine animates geometry and opacity together. The application
receives its final size once; the engine crops the previous buffer until redraw.

Window snapshots come from libwinsnap. Each desktop has a separate layout tree.
The engine supplies actual window bounds; CGWindowList supplies visible bounds.
Keyboard commands use /tmp/hyprwm.ctl, with one command per line:
  focus <l|r|u|d>   move <l|r|u|d>   togglesplit   preselect <l|r|u|d|none>
  float   fullscreen   retile   reset   status
This saved model is used by the fixture generator with fake system adapters.
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
import tile      # noqa: E402  dwindle tree, gaps and minimum sizes
from engine import Engine  # noqa: E402
from deco import Deco      # noqa: E402

CTL = "/tmp/hyprwm.ctl"
STATE = os.path.join(HOOK, "hyprwm.state.json")
MINSIZE = os.path.join(HOOK, "minsize_app.json")   # Per-application minimum window sizes (owner)
POLL = 0.016           # Daemon interval in seconds; in-process snapshots take about 2 ms
TOL = 6                # Size tolerance in points; Terminal rounds to its character grid
RESIZABLE = 1 << 3     # NSWindowStyleMaskResizable
APP_SPRING = [1.0, 1e5, 2 * 1e5 ** 0.5, 0.001]   # Apply the final application size immediately, without its own animation
DIRS = {"l": "left", "r": "right", "u": "up", "d": "down",
        "left": "left", "right": "right", "up": "up", "down": "down"}

_snap = ctypes.CDLL(os.path.join(HOOK, "build", "libwinsnap.dylib"))
_buf = ctypes.create_string_buffer(1 << 21)
_snap.ws_close.argtypes = _snap.ws_focus.argtypes = [ctypes.c_int, ctypes.c_uint]
_snap.ws_quit.argtypes = [ctypes.c_int]
_ax = ctypes.CDLL(os.path.join(HOOK, "build", "libax.dylib"))   # Application configure calls (src/axlib.c)
_ax.ax_tileable.argtypes = [ctypes.c_int, ctypes.c_uint]
_ax.ax_frame.argtypes = [ctypes.c_int, ctypes.c_uint] + [ctypes.c_double] * 4
_ax.ax_forget.argtypes = [ctypes.c_uint]
_ax.ax_focus.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.c_int]
_ax.ax_menu_press.argtypes = [ctypes.c_int, ctypes.c_char_p]
_ax.ax_get_frame.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.POINTER(ctypes.c_double)]
_sl = ctypes.CDLL("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")
_cid = _sl.SLSMainConnectionID()


def win_pid_level(wid):
    """Read the server owner PID and level as soon as a window appears."""
    o, p, lv = ctypes.c_int(), ctypes.c_int(), ctypes.c_int()
    if _sl.SLSGetWindowOwner(_cid, wid, ctypes.byref(o)) or _sl.SLSConnectionGetPID(o, ctypes.byref(p)):
        return None, None
    _sl.SLSGetWindowLevel(_cid, wid, ctypes.byref(lv))
    return p.value, lv.value


class _PSN(ctypes.Structure):
    _fields_ = [("hi", ctypes.c_uint32), ("lo", ctypes.c_uint32)]


_hi = ctypes.CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")


def front_pid():
    """Read the front application; NSWorkspace needs a run loop to update."""
    psn, pid = _PSN(), ctypes.c_int(0)
    if _sl._SLPSGetFrontProcess(ctypes.byref(psn)) or _hi.GetProcessPID(ctypes.byref(psn), ctypes.byref(pid)):
        return None
    return pid.value


class _Rect(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double), ("w", ctypes.c_double), ("h", ctypes.c_double)]


def win_bounds(wid):
    """Return actual server bounds without our transform, or None."""
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
    """Move windows to a desktop using SLSMoveWindowsToManagedSpace."""
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
    return _cg.CGEventSourceButtonState(1, 0)        # combinedSessionState, left mouse button


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
        self.owner = {}      # Window ID -> application name
        self.cfg_q = queue.Queue()   # Configure replies: (window ID, owner, target, actual bounds)
        self.info = {}       # pid -> {wid(str): {type, style, uuid}, "_conn": ...}
        self.miss = {}       # Window ID -> (attempts, time), while WindowManager has not seen it
        self.target = {}     # Window ID -> latest target sent to the engine
        self.pids = {}       # Window ID -> PID, for tab detection
        self.gone_t = {}     # Window ID -> time the engine reported it missing
        self.newbies = {}    # Window ID -> time the engine first saw it, before layout
        self.optimistic = {}  # Window ID -> time hidden before the application answered AX
        self.hidden = []                             # Hidden windows: [{wid, pid, owner, space, rect}]
        for h in st.get("hidden", []):               # Avoid hiding a window that is already hidden
            if all(x["wid"] != h["wid"] for x in self.hidden):
                self.hidden.append(h)
        self.restoring = set()                       # Restored windows use drift + fadeIn, without popin
        self.later = []                              # [(time, callback)]
        # Configure uses the latest target and one worker per application.
        # AX runs on the application main thread; old replies must not replace new targets.
        self.cfg_lock = threading.Lock()
        self.cfg_want = {}                           # Window ID -> latest job, with a serial number
        self.cfg_seq = 0
        self.cfg_workers = {}                        # PID -> queued window IDs for this application
        self.closing = set()
        self.front_pid = None                        # Front application from the snapshot
        self.own_focus = (None, 0.0)                 # (PID, time) for an activation triggered by follow_mouse
        self.dim_since = {}                          # Window ID -> time unexplained opacity below 1 was first seen
        self.moved_t = {}                            # Window ID -> times restored to a tile after EV_MOVED
        self.float_rules = [r for r in hyprcfg.load()["window_rules"] if r.get("float")]
        log("конфиг: зазоры", tile.GAPS_IN, tile.GAPS_OUT, "windowsMove", hyprcfg.animation("windowsMove"),
            "windowsIn", hyprcfg.animation("windowsIn"), "правил float:", len(self.float_rules))

    # State
    def save(self):
        json.dump({"spaces": self.spaces, "floating": sorted(self.floating), "hidden": self.hidden},
                  open(STATE, "w"), indent=1)
        json.dump(self.mins, open(MINSIZE, "w"))

    def sp(self, space):
        return self.spaces.setdefault(str(space), {"tree": None, "focus": None, "full": None, "presel": None})

    # Which windows can be tiled
    def wm_info(self, pid, wid):
        """Ask the application whether this is a normal resizable window.
        Retry with backoff while the application has not shown it yet."""
        k = str(wid)
        now = time.time()
        i = self.info.get(pid, {}).get(k)
        # Cache positive results; retry negative results while a new window
        # may still lack the AXStandardWindow role or a writable size.
        if i and (i["type"] == "primary" or i.get("n", 9) >= 12 or now - i["t"] < 0.25):
            return i
        n, t = self.miss.get(wid, (0, 0))
        # If the application has not seen it, retry each tick for one second, then back off.
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

    # Layout
    def layout(self, area, s):
        # Read application minimum sizes before layout so each tile fits immediately.
        tile.MINS = {n["wid"]: self.mins[self.owner[n["wid"]]] for n in tile.leaves(s["tree"])
                     if self.owner.get(n["wid"]) in self.mins}
        rects = {wid: tile.with_gaps(b, area) for wid, b in tile.boxes(s["tree"], area, {}).items()}
        if s.get("full") in rects:
            x, y, w, h = area
            go = tile.GAPS_OUT
            if s.get("fullmode") == "fullscreen":               # Entire screen without gaps
                rects[s["full"]] = (x, y, w, h)
            else:                                              # Maximized: work area minus gaps_out
                rects[s["full"]] = (x + go["left"], y + go["top"], w - go["left"] - go["right"],
                                    h - go["top"] - go["bottom"])
        return {wid: tuple(float(round(v)) for v in r) for wid, r in rects.items()}

    def apply(self, area, space, wins, force=False, opening=()):
        """Send one desktop batch with a shared start time, then final application sizes."""
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
        if opening and in_on:                              # Hide new windows until their final size and popin are ready.
            for wid in opening:
                if wid not in self.restoring:              # A restored window is already hidden and uses drift + fadeIn.
                    c.alpha(wid, 0.0, 0, 0.0, frm=0.0)
            c.commit()
        eng_w = {w.wid: w for w in c.wins()}
        vis = {}
        for w in wins:                                     # Visible bounds equal actual bounds when the window is stationary.
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
                if pop:                                        # Popin starts at pop% of the target, scaled around its center.
                    sw, sh = max(5.0, to[2] * pop), max(5.0, to[3] * pop)
                    frm = (to[0] + (to[2] - sw) / 2, to[1] + (to[3] - sh) / 2, sw, sh)
                c.geom(wid, to, in_c, in_c, frm=frm, move=True, stretch=True)   # Popin stretches window contents.
                if fi_on:
                    c.alpha(wid, 1.0, fi_c, fi_d, frm=0.0)
            else:
                # Supply initial visible bounds explicitly: AX may place the application at
                # its target before the engine reads the command, causing an immediate jump.
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
            # Send the final size once for both axes, like Hyprland configure.
            # The engine sets position immediately and shows the old buffer at 1:1 scale.
            # Crop larger buffers; cover a smaller buffer edge with a backing window.
            a = real.get(wid) or (cur[wid]["x"], cur[wid]["y"], cur[wid]["w"], cur[wid]["h"])
            if wid in opening or max(abs(p - q) for p, q in zip(a, to)) > 1:
                j = self.job(cur[wid]["pid"], wid, to)       # Apply the final size immediately and only once.
                if j:
                    jobs.append(j)
        if posted:
            c.commit()
            t = time.time()                                # The engine accepts the batch on its next tick.
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
        """Configure applications after the engine accepts the batch.
        Keep only the latest target for each window. One worker per application
        processes its windows in order. Read accepted sizes back into a reply
        queue so the main loop can learn minimum window sizes."""
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
        while True:
            try:
                wid = q.get(timeout=30)
            except queue.Empty:
                with self.cfg_lock:                         # Exit when idle; a new job starts another worker.
                    if q.empty():
                        self.cfg_workers.pop(pid, None)
                        return
                continue
            with self.cfg_lock:
                j = self.cfg_want.get(wid)
                if j is None or j.get("taken"):
                    continue                                 # A newer queued job already completed this work.
                j["taken"] = True
            try:
                self._cfg_one(j)
            except Exception as e:
                log("configure окна %d упал: %r" % (wid, e))

    def _cfg_one(self, j):
        x, y, w, h = j["to"]
        wid, seq = j["wid"], j["seq"]
        buf = (ctypes.c_double * 4)()
        pre = tuple(buf) if _ax.ax_get_frame(j["pid"], wid, buf) == 0 else None
        e = _ax.ax_frame(j["pid"], wid, x, y, w, h)
        got, same, t0 = None, 0, time.time()
        while not e and time.time() - t0 < 0.6:
            time.sleep(0.03)
            if not self._cfg_latest(wid, seq):
                return                                       # A new target arrived; discard this reply.
            if _ax.ax_get_frame(j["pid"], wid, buf) != 0:
                continue
            cur = tuple(buf)
            if abs(cur[2] - w) <= TOL and abs(cur[3] - h) <= TOL:
                got = cur
                break
            same = same + 1 if cur == got else 0
            got = cur
            # Treat bounds as stable after 90 ms without changes. If the old size persists,
            # wait longer because applications can apply size asynchronously; avoid
            # mistaking a delayed response for a minimum size.
            if same >= 3 and (pre is None or max(abs(p - q) for p, q in zip(cur[2:], pre[2:])) > 1 or
                              time.time() - t0 > 0.35):
                break
        if self._cfg_latest(wid, seq):
            self.cfg_q.put((wid, j["owner"], j["to"], got, e, pre))

    def configured(self):
        """Learn a stable accepted size larger than the target as an application minimum.
        Return True when layout needs to run again in this cycle."""
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
            # Learn the minimum when stable bounds exceed the target on an axis.
            # Also learn from a window that was already at its minimum.
            mw, mh = self.mins.get(owner, (0, 0))
            nw = max(mw, got[2]) if got[2] > to[2] + TOL else mw
            nh = max(mh, got[3]) if got[3] > to[3] + TOL else mh
            if (nw, nh) != (mw, mh):
                self.mins[owner] = [nw, nh]
                log("минимум %s: %s (окно %d: %s -> %s, цель %s)" % (owner, self.mins[owner], wid,
                    pre and tuple(round(v) for v in pre[2:]), tuple(round(v) for v in got[2:]), to[2:]))
                changed = True
            elif abs(got[2] - to[2]) > TOL or abs(got[3] - to[3]) > TOL:
                log("окно %s %d стоит %s вместо %s — держу в плитке" % (owner, wid, tuple(round(v) for v in got[2:]), to[2:]))

    def sync(self, area, space, wins):
        """Sync the desktop tree with visible windows; return (changed, new windows)."""
        s = self.sp(space)
        hid = {h["wid"] for h in self.hidden}
        closing = self.closing
        live = [w for w in wins if w["space"] == space and w["on"] and w["wid"] not in hid and
                w["wid"] not in closing and self.tileable(w)]
        ids = [w["wid"] for w in live]
        have = {n["wid"] for n in tile.leaves(s["tree"])}
        changed, opened = False, []
        # Native tabs are separate windows in one group, with only one visible.
        # If a window disappears and another from the same application replaces it,
        # keep the existing leaf so switching tabs does not change the layout.
        gone = [x for x in have - set(ids)]
        alive = {w["wid"] for w in wins}
        # Windows hidden behind another tab or closed with Cmd+W
        offscreen = {x for x in gone if x not in hid and (x not in alive or
                     any(w["wid"] == x and not w["on"] for w in wins))}
        for w in live:
            if w["wid"] in have:
                continue
            twin = next((x for x in gone if self.pids.get(x) == w["pid"] and self.target.get(x) and
                         max(abs(a - b) for a, b in zip(self.target[x], (w["x"], w["y"], w["w"], w["h"]))) <= TOL), None)
            if twin is None:
                # A new tab may not have the group bounds yet. A stronger signal is another
                # live window from the same application disappearing at the same time.
                twin = next((x for x in gone if self.pids.get(x) == w["pid"] and x in offscreen), None)
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
            # Native tabs appear immediately. Restore opacity if hide_newbies hid one
            # before popin. Release the old tab engine slot and its transform, crop and
            # opacity; the same path handles it when it becomes visible again.
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
        # Split the frontmost tiled window on this desktop, as Hyprland does.
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
        """Insert into dwindle using preselect, the cursor, or an explicit point.
        Directional moves use a point just beyond the target edge."""
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

    # Keyboard commands
    def command(self, line, area, space, wins):
        a = line.split()
        if not a:
            return "пусто"
        s, cmd = self.sp(space), a[0]
        rects = self.layout(area, s)
        cur = next((w["wid"] for w in wins if w["wid"] in rects and w["on"]), None)   # Frontmost tiled window
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
                r = _ax.ax_focus(pid, tgt, 0)                  # Focus this window without changing the tile stacking order.
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
        """Move a window beside the closest node in the requested direction.
        Remove it from the tree and insert using a point beyond the edge midpoint."""
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
        """Remove a closing window while neighbors animate in the same frame.
        Shrink it with windowsOut and fadeOut, then ask the application to close.
        Restore it to the tree if a save dialog prevents closing."""
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
        self.apply(area, space, wins)                      # Move neighbors in the same frame.
        c.commit()
        done = max(od if on else 0, fd if fon else 0)

        def shut():
            _snap.ws_close(w["pid"], wid)

        def check():
            self.closing.discard(wid)
            if win_bounds(wid) is not None and any(x.wid == wid for x in c.wins()):
                log("окно %d не закрылось — возвращаю" % wid)
                self.restoring.add(wid)                    # Sync inserts it again with drift from the smaller rectangle and fadeIn,
                self.target.pop(wid, None)                 # without starting another popin.
                self.later.append((time.time() + 1.5, lambda: self._restore_check(wid)))
        self.later.append((time.time() + done, shut))
        self.later.append((time.time() + done + 0.6, check))
        return "закрываю %d (%.0f мс)" % (wid, done * 1000)

    def front(self, wins, space):
        """Find the frontmost visible window on this desktop.
        Skip hidden, closing and transparent windows that the server lists."""
        skip = {h["wid"] for h in self.hidden} | self.closing
        dim = {w.wid for w in self.eng.c.wins() if w.cur_alpha < 0.05 and not w.alpha.active}
        return next((w for w in wins if w["on"] and w["space"] == space and w["w"] >= 120 and w["h"] >= 120 and
                     w["wid"] not in skip and w["wid"] not in dim), None)

    def hide(self, area, space, wins, wid=None):
        """Fade the focused window in place, retile neighbors, then move it offscreen."""
        w = next((x for x in wins if x["wid"] == wid), None) if wid else self.front(wins, space)
        if not w:
            return "нет окна"
        wid = w["wid"]
        if any(h["wid"] == wid for h in self.hidden):
            return "уже скрыто %d" % wid
        self.restoring.discard(wid)
        s = self.sp(space)
        rect = self.eng.real().get(wid) or (w["x"], w["y"], w["w"], w["h"])
        s["tree"] = tile.remove(s["tree"], wid)
        if s.get("full") == wid:
            s["full"] = None
        self.target.pop(wid, None)
        self.hidden.append({"wid": wid, "pid": w["pid"], "owner": w["owner"], "space": space, "rect": list(rect)})
        fo_c, fo_d, fo_on = self.eng.anim("fadeOut")
        self.eng.c.alpha(wid, 0.0, fo_c, fo_d if fo_on else 0.0)
        self.apply(area, space, wins)                      # Move neighbors in the same frame as fadeOut.
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
        """Restore hidden windows into the current desktop with drift and fadeIn.
        Select records with window IDs or a predicate. everything restores all
        windows immediately when the daemon stops."""
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
            if space is not None and str(h.get("space")) != str(space):
                try:
                    move_to_space([wid], space)                # Return a window hidden on another desktop to the current desktop.
                except Exception as e:
                    log("перенос окна %d на стол %s: %r" % (wid, space, e))
            c.geom(wid, tuple(h["rect"]), 0, 0, move=True, warp=True)   # Restore the previous location while the window is invisible.
            w = next((x for x in wins or () if x["wid"] == wid), None)
            if everything:
                c.alpha(wid, 1.0, 0, 0.0)
            elif w is not None and not self.tileable(w):           # Show floating windows at their existing location.
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
        """Show restored windows that did not enter the current layout."""
        if wid in self.restoring and all(h["wid"] != wid for h in self.hidden):
            self.restoring.discard(wid)
            self.eng.c.alpha(wid, 1.0, 0, 0.0)
            self.eng.c.commit()
            log("возврат окна %d: в раскладку не попало — показываю на месте" % wid)

    def on_activate(self, area, space, wins, pid):
        """Restore hidden windows when their application is activated externally.
        Dock, Cmd+Tab, open and notifications can trigger this path."""
        if not self.hidden:
            return
        for h in self.hidden:
            if h.get("pid") is None:
                h["pid"] = win_pid_level(h["wid"])[0]
        mine = [h["wid"] for h in self.hidden if h.get("pid") == pid]
        if not mine:
            return
        # Clicking a visible window from the same application should not restore
        # hidden windows. Restore only if this desktop has no visible window from
        # that application or macOS explicitly made a hidden window the key window.
        hid = {h["wid"] for h in self.hidden}
        own = [w for w in wins if w["pid"] == pid and w["on"] and w["w"] >= 120 and w["h"] >= 120]
        visible = [w for w in own if w["wid"] not in hid and w["space"] == space]
        if not visible or (own and own[0]["wid"] in hid):
            log("приложение %d активировано извне — возвращаю скрытые: %s" % (pid, self.unhide(area, space, wins, which=mine)))

    def rescue(self, area, space, wins, keep_hidden=False):
        """Restore all hidden windows and recover unexplained invisible windows.
        keep_hidden preserves intentional hiding at startup. Server opacity can
        survive daemon or engine restarts, so recover stray offscreen windows too."""
        out = []
        alive = {w["wid"] for w in wins}
        self.hidden = [h for h in self.hidden if h["wid"] in alive]     # Windows closed while the daemon was stopped
        if self.hidden and not keep_hidden:
            out.append(self.unhide(area, space, wins, which=lambda h: True))
        elif self.hidden:                                    # Keep intentionally hidden windows transparent and offscreen.
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
                continue                                    # Leave application utility windows invisible.
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
        """Return a stationary tiled window that drifted away from its target.
        Limit retries to three per ten seconds to avoid fighting an application.
        Mouse dragging is handled by realign after the button is released."""
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

    def alpha_guard(self, wins):
        """Restore opacity when a visible engine window is unexpectedly transparent.
        Wait one second and skip hidden, closing or opening windows."""
        now = time.time()
        busy = (self.closing | self.restoring | set(self.newbies) | set(self.optimistic) |
                {h["wid"] for h in self.hidden})
        on = {w["wid"] for w in wins if w["on"]}          # Opacity matters only for an onscreen window.
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
        """Resize the nearest split on the requested axis by dx/dy points."""
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
        """Run a command from the configuration.
        Ghostty --new opens a window through its AX menu; -e runs a program.
        spotlight opens the system launcher."""
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
            if pid:                                    # Walk the AX menu outside the main loop.
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

    # Main loop
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
                self.commands(srv, *last)                  # Read commands before the snapshot, which can occasionally take 30 ms.
            due = [f for t, f in self.later if t <= time.time()]
            self.later = [(t, f) for t, f in self.later if t > time.time()]
            for f in due:
                try:
                    f()
                except Exception as e:
                    log("отложенное упало:", repr(e))
            if time.time() - last_eng > 2.0:                     # Did WindowServer restart?
                last_eng = time.time()
                if not self.eng.alive():
                    self.target.clear()
                    self.eng.ensure()
                if self.eng.c.h.errors != getattr(self, "_errors", 0):
                    self._errors = self.eng.c.h.errors
                    log("движок: ошибок %d (слотов занято %d из 64)" % (self._errors, len(self.eng.c.wins())))
            # Take a complete snapshot after engine events, commands, desktop changes,
            # front application changes, mouse activity or pending window transitions.
            # Otherwise check every 250 ms and reuse the previous snapshot.
            drifted, evs = False, list(self.eng.c.events())
            for ev in evs:
                if ev[0] == chan.EV_NEW:
                    self.newbies[ev[1]] = time.time()
                    continue
                if ev[0] == chan.EV_MOVED:
                    drifted |= self.on_moved(ev[1], ev[3])
                    continue
                if ev[0] == chan.EV_GONE:
                    wid = ev[1]
                    self.gone_t[wid] = time.time()
                    self.target.pop(wid, None)
                    self.deco.drop(wid)
                    _ax.ax_forget(wid)                         # Remove dead windows from the AX cache.
                    self.dim_since.pop(wid, None)
                    for pid in list(self.info):
                        self.info[pid].pop(str(wid), None)
                    self.miss.pop(wid, None)
                    self.owner.pop(wid, None)
            fp = front_pid()
            md = mouse_down()
            sp_now = _sl.SLSGetActiveSpace(_cid)
            need = (last is None or r or evs or self.newbies or self.optimistic or self.restoring or self.closing
                    or sp_now != last_sp or md != was_down or fp != self.front_pid or not self.cfg_q.empty()
                    or time.time() - last_snap > 0.25)
            if need:
                d, area = snapshot()
                if not d["stable"]:
                    continue                                     # The desktop can change during a snapshot.
                space, wins = d["space"], [w for w in d["windows"] if w["owner"] != "hyprdeco"]   # Exclude backing windows.
                last_snap, last_sp = time.time(), sp_now
                self.snaps += 1
                if r and last is None:
                    self.commands(srv, area, space, wins)
                last = (area, space, wins)
            else:
                area, space, wins = last
            if space != last_space:
                log("рабочий стол", space)
                last_space = space
            if not rescued:                                  # After startup or restart, restore hidden windows and show windows
                rescued = True                               # that are invisible without an explicit reason.
                log("старт: %s" % self.rescue(area, space, wins, keep_hidden=True))
            top = max((w["wid"] for w in wins), default=0)
            # The engine scans new window IDs and owns wid_max. Wake a stalled scan
            # only at startup or after a gap larger than 24 IDs to avoid competing writes.
            if top > self.eng.c.h.wid_max + 24 or not self.eng.c.h.wid_max:
                self.eng.c.h.wid_max = top
            if fp and fp != self.front_pid:
                prev, self.front_pid = self.front_pid, fp
                own = self.own_focus[0] == fp and time.time() - self.own_focus[1] < 1.0
                if prev is not None and not own:
                    self.on_activate(area, space, wins, fp)
            self.follow_mouse(space, wins)
            for w in wins:
                self.owner[w["wid"]] = w["owner"]
            self.hide_newbies(space, wins)
            if time.time() - getattr(self, "_sampled", 0) > 2.0:     # Sample window edge colors for backing windows.
                self._sampled = time.time()
                busy = {w.wid for w in self.eng.c.wins() if w.pos.active or w.size.active or w.settling}
                for n in tile.leaves(self.sp(space)["tree"]):
                    if n["wid"] not in busy:
                        self.deco.sample(n["wid"])
            changed, opened = self.sync(area, space, wins)
            changed |= drifted
            changed |= self.configured()                   # Retarget immediately if the application rejected its size.
            if was_down and not md:                        # On mouse release, a window may have been dragged out of its tile.
                changed |= self.realign(area, space, wins)
            was_down = md
            if changed:
                self.apply(area, space, wins, opening=opened)
            if time.time() - last_guard > 0.25:
                last_guard = time.time()
                self.alpha_guard(wins)

    def commands(self, srv, area, space, wins):
        """Drain pending socket commands together so shortcut repeat cannot starve work."""
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
        """Hide new tiled windows before their first visible frame.
        sync inserts them into the tree and popin shows them in their tile.
        Hide windows from tiled applications immediately while AX catches up.
        Restore opacity if the window turns out to be a dialog or panel."""
        if not self.newbies and not self.optimistic:
            return
        by = {w["wid"]: w for w in wins}
        c, touched = self.eng.c, False
        tiled_apps = {self.owner.get(n["wid"]) for sp in self.spaces.values() for n in tile.leaves(sp.get("tree"))}
        tiled_pids = {self.pids.get(n["wid"]) for sp in self.spaces.values() for n in tile.leaves(sp.get("tree"))}
        def tab(pid, wid):
            # A native tab that matches an existing tiled window replaces that leaf.
            # Leave it visible; sync handles the tab switch.
            r = win_bounds(wid)
            return r is not None and any(self.pids.get(x) == pid and max(abs(a - b) for a, b in zip(t, r)) <= TOL
                                         for x, t in self.target.items())
        for wid, t in list(self.newbies.items()):
            w = by.get(wid)
            if time.time() - t > 1.5:
                self.newbies.pop(wid)
                continue
            if not w or w["w"] < 120 or w["h"] < 120:
                # If absent from the snapshot, ask the server for its level and application.
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
                self.newbies.pop(wid)                      # Definitely not tileable
                if self.optimistic.pop(wid, None):
                    c.alpha(wid, 1.0, 0, 0.0)
                    touched = True
            elif w and w["owner"] in tiled_apps and wid not in self.optimistic:
                self.optimistic[wid] = time.time()         # This application is tiled; hide the new window immediately.
                c.alpha(wid, 0.0, 0, 0.0, frm=0.0)
                touched = True
        for wid, t in list(self.optimistic.items()):        # If it never became tileable, restore visibility.
            if wid not in self.newbies and time.time() - t > 1.5:
                self.optimistic.pop(wid)
                c.alpha(wid, 1.0, 0, 0.0)
                touched = True
        if touched:
            c.commit()

    def follow_mouse(self, space, wins):
        """Focus the topmost window as the pointer enters it with follow_mouse = 1.
        Leave menus, popups and floating windows above tiles untouched."""
        p = mouse()
        if p == getattr(self, "_mp", None) or mouse_down():
            return
        self._mp = p
        s = self.sp(space)
        tiled = {n["wid"] for n in tile.leaves(s["tree"])}
        hid = {h["wid"] for h in self.hidden}
        top = next((w for w in wins if w["on"] and w["wid"] not in hid and w["x"] <= p[0] < w["x"] + w["w"] and
                    w["y"] <= p[1] < w["y"] + w["h"]), None)
        front = next((w for w in wins if w["on"] and w["space"] == space and w["w"] >= 120 and w["h"] >= 120), None)
        if os.environ.get("HYPRWM_DEBUG"):
            log("курсор", p, "верх", top and top["wid"], "перед", front and front["wid"], "тайлы", tiled)
        if not top or top["wid"] not in tiled:
            return
        # Without AXRaise the stacking order stays unchanged. Track the last focused
        # window and require its application to remain frontmost.
        if getattr(self, "_fwant", None) == top["wid"] and (self.front_pid == top["pid"] or time.time() - self._ft < 0.3):
            return
        if getattr(self, "_fwant", None) is None and front and front["wid"] == top["wid"]:
            return
        self._fwant, self._ft = top["wid"], time.time()
        self.own_focus = (top["pid"], time.time())
        r = _ax.ax_focus(top["pid"], top["wid"], 0)         # Avoid AXRaise to preserve tile stacking order.
        s["focus"] = top["wid"]
        log("фокус за курсором -> %s %d (%d)" % (top["owner"], top["wid"], r))

    def realign(self, area, space, wins):
        """Return a window to its tile after the mouse button is released."""
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
