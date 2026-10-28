#!/usr/bin/env python3
"""Generate deterministic Swift fixtures from the preserved Python reference.

Runs without WindowServer, an engine channel or the daemon socket. The WM class
is loaded through AST with fake OS adapters. --wm-only regenerates the large
ignored scenario file while preserving the tracked tile/config snapshots.
"""
import ast
import copy
import importlib.util
import json
import os
import queue
import random
import re
import shutil
import sys
import tempfile
import textwrap
import types

HERE = os.path.dirname(os.path.abspath(__file__))
SW = os.path.dirname(HERE)
HOOK = os.path.dirname(SW)
FIX = os.path.join(SW, "Tests", "HyprCoreTests", "Fixtures")
os.makedirs(FIX, exist_ok=True)
os.environ.pop("HYPRWM_TIME_SCALE", None)
os.environ.pop("HYPRWM_DEBUG", None)

# Configuration snapshot: read hypr_cfg.json without changing it
CFG_FIX = os.path.join(FIX, "hypr_cfg.json")
if not os.path.exists(CFG_FIX) or "--refresh-config" in sys.argv:
    shutil.copy(os.path.join(HOOK, "config", "hypr_cfg.json"), CFG_FIX)
CFG = json.load(open(CFG_FIX))

spec = importlib.util.spec_from_file_location("hyprcfg", os.path.join(HOOK, "config", "hyprcfg.py"))
hyprcfg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hyprcfg)
hyprcfg._cfg = CFG                               # load() now uses memory without disk access or Lua.
sys.modules["hyprcfg"] = hyprcfg


def load_ref(name, modname):
    s = importlib.util.spec_from_file_location(modname, os.path.join(SW, name))
    m = importlib.util.module_from_spec(s)
    sys.modules[modname] = m
    s.loader.exec_module(m)
    return m


tile = load_ref("REFERENCE_tile.py", "tile")
chan = load_ref("REFERENCE_chan.py", "chan")      # Classes and constants only; no native library is loaded.
engine = load_ref("REFERENCE_engine.py", "engine")
TILE0 = (tile.GAPS_IN, dict(tile.GAPS_OUT), tile.SPLIT_WIDTH_MULT, tile.DEFAULT_RATIO)


def tree_json(n):
    return copy.deepcopy(n)


# A. Dwindle layout
def internal_paths(n, p=""):
    if n is None or "wid" in n:
        return []
    return [p] + internal_paths(n["a"], p + "a") + internal_paths(n["b"], p + "b")


def at(n, p):
    for c in p:
        n = n[c]
    return n


def gen_tile(ncases=400):
    out = []
    for k in range(ncases):
        rnd = random.Random(1000 + k)
        gi = rnd.choice([0, 5, 5, 10])
        go = {s: rnd.choice([0, 8, 12, 12, 20]) for s in ("top", "right", "bottom", "left")}
        swm = rnd.choice([1.0, 1.0, 1.5, 0.7])
        dr = rnd.choice([0.5, 0.5, 0.3, 0.65])
        area = rnd.choice([[0, 33, 1470, 923], [0, 25, 2560, 1415], [0, 0, 1280, 800],
                           [rnd.randint(-50, 50), rnd.randint(0, 40), rnd.randint(500, 3000), rnd.randint(400, 1800)],
                           [round(rnd.uniform(0, 30), 3), round(rnd.uniform(0, 30), 3),
                            round(rnd.uniform(300, 2000), 3), round(rnd.uniform(300, 1400), 3)]])
        tile.GAPS_IN, tile.GAPS_OUT, tile.SPLIT_WIDTH_MULT, tile.DEFAULT_RATIO = gi, go, swm, dr
        mins = {}
        for wid in range(1, 20):
            r = rnd.random()
            if r < 0.15:
                mins[wid] = [rnd.choice([0, 470.0, 640.0, 800.0, 1200.0]), rnd.choice([0, 584.0, 428.0, 900.0])]
            elif r < 0.2:
                mins[wid] = [round(rnd.uniform(100, 1600), 2), round(rnd.uniform(100, 1200), 2)]
        tile.MINS = {int(k2): v for k2, v in mins.items()}
        tree, alive, nxt, ops = None, [], 1, []
        for _ in range(rnd.randint(1, 16)):
            r = rnd.random()
            paths = internal_paths(tree)
            if r < 0.55 or not alive:
                wid = nxt
                nxt += 1
                tgt = rnd.choice(alive + [None] + ([rnd.randint(50, 60)] if rnd.random() < 0.1 else [])) if alive else None
                tree = tile.insert(tree, wid, tgt, tuple(area))
                if tgt is None or tgt in alive or not alive:
                    pass
                alive = [n["wid"] for n in tile.leaves(tree)]
                ops.append({"op": "insert", "wid": wid, "target": tgt})
            elif r < 0.75:
                wid = rnd.choice(alive)
                tree = tile.remove(tree, wid)
                alive = [n["wid"] for n in tile.leaves(tree)]
                ops.append({"op": "remove", "wid": wid})
            elif r < 0.87 and paths:
                p = rnd.choice(paths)
                n = at(tree, p)
                n["split"] = "h" if n["split"] == "v" else "v"
                ops.append({"op": "toggle", "path": p})
            elif paths:
                p = rnd.choice(paths)
                v = round(rnd.uniform(0.05, 0.95), 4)
                at(tree, p)["ratio"] = v
                ops.append({"op": "ratio", "path": p, "value": v})
            else:
                continue
            ops[-1]["tree"] = tree_json(tree)
        bx = tile.boxes(tree, tuple(area), {})
        res = {
            "boxes": [[w, list(b)] for w, b in bx.items()],
            "gaps": [[w, list(tile.with_gaps(b, tuple(area)))] for w, b in bx.items()],
            "rounded": [[w, [float(round(v)) for v in tile.with_gaps(b, tuple(area))]] for w, b in bx.items()],
            "need": list(tile.need(tree)) if tree else None,
        }
        rects = {w: tuple(float(round(v)) for v in tile.with_gaps(b, tuple(area))) for w, b in bx.items()}
        res["neighbour"] = [[w, d, tile.neighbour(rects, w, d)] for w in rects for d in ("left", "right", "up", "down")]
        res["parents"] = [[w, (lambda p: None if p is None else {"split": p["split"], "a": tile.leaves(p["a"])[0]["wid"]})(
            tile.find_parent(tree, w))] for w in rects]
        out.append({"gaps_in": gi, "gaps_out": go, "swm": swm, "ratio": dr, "area": area,
                    "mins": {str(k2): v for k2, v in mins.items()}, "ops": ops, "result": res})
    tile.GAPS_IN, tile.GAPS_OUT, tile.SPLIT_WIDTH_MULT, tile.DEFAULT_RATIO = TILE0[0], dict(TILE0[1]), TILE0[2], TILE0[3]
    tile.MINS = {}
    return out


# B. Configuration
class _NullChan:
    class _H:
        pass

    def __init__(self):
        self.h = self._H()

    def spring(self, *a):
        pass

    def bezier(self, *a):
        pass


def gen_config():
    e = engine.Engine(log=lambda *a: None)
    e.c = _NullChan()
    e.setup()
    leaves = sorted(set(hyprcfg.PARENT) | {"global", "nosuchleaf"})
    return {
        "gaps": [hyprcfg.gaps()[0], hyprcfg.gaps()[1]],
        "dwindle": {"swm": tile.SPLIT_WIDTH_MULT, "ratio": tile.DEFAULT_RATIO},
        "ids": e.ids,
        "animations": {l: hyprcfg.animation(l) for l in leaves},
        "anim": {l: list(e.anim(l)) for l in leaves},
        "curves": hyprcfg.curves(),
        "float_rules": len([r for r in hyprcfg.load()["window_rules"] if r.get("float")]),
    }


# C. Daemon differential scenarios
SRC = open(os.path.join(SW, "REFERENCE_hyprwm.py")).read()
MOD = ast.parse(SRC)
CLS = next(n for n in MOD.body if isinstance(n, ast.ClassDef) and n.name == "WM")
CLS_SRC = ast.get_source_segment(SRC, CLS)
# Python set order varies. Sort departed window IDs to match Swift;
# this is the only reference-model adjustment for comparison.
_G = "gone = [x for x in have - set(ids)]"
assert CLS_SRC.count(_G) == 1
CLS_SRC = CLS_SRC.replace(_G, "gone = sorted(have - set(ids))")
RUN = next(n for n in CLS.body if isinstance(n, ast.FunctionDef) and n.name == "run")
EVFOR = next(n for n in ast.walk(RUN) if isinstance(n, ast.For) and isinstance(n.iter, ast.Name) and n.iter.id == "evs")
EV_SRC = textwrap.dedent(ast.get_source_segment(SRC, EVFOR, padded=True))
CONSTS = {}
for n in MOD.body:
    if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id in ("TOL", "RESIZABLE", "DIRS") for t in n.targets):
        exec(ast.get_source_segment(SRC, n), CONSTS)


class W:                       # Shared scenario world for fake adapters
    now = 1000.0
    mouse = (100.0, 100.0)
    md = False
    front = None
    tileable = {}
    bounds = {}
    alpha = {}
    pidlevel = {}
    eng = []
    events = []
    calls = []


class FakeTime:
    @staticmethod
    def time():
        return W.now

    @staticmethod
    def sleep(s):
        pass

    strftime = staticmethod(lambda *a: "")
    localtime = staticmethod(lambda *a: None)


class Var:
    def __init__(self, v, active):
        self.v, self.active = list(v), active


class FakeWin:
    def __init__(self, d):
        self.d = d
        self.wid = d["wid"]
        self.pos = Var(d["pos"], d["posActive"])
        self.size = Var(d["size"], d["sizeActive"])
        self.alpha = Var([0, 0], d["alphaActive"])
        self.settling = d["settling"]
        self.cur_alpha = d["curAlpha"]
        self.held = d["held"]
        self.radius = d["radius"]
        self.ax, self.ay, self.aw, self.ah = d["a"]


class FakeH:
    cmd_head = cmd_tail = 0
    wid_max = 0
    ticks = 7
    nactive = 1
    errors = 0
    tick_us_max = 147.25
    tick_us_last = 3.04
    ticks_late = 0
    te_skips = 0


class FakeChan:
    def __init__(self):
        self.h = FakeH()
        self.ops = []

    def geom(self, wid, to, cpos, csize, dpos=0.0, dsize=0.0, frm=None, move=True, warp=False, stretch=False):
        self.ops.append({"op": "warp" if warp else "geom", "wid": wid, "to": [float(v) for v in to],
                         "frm": [float(v) for v in frm] if frm else None, "cpos": cpos, "csize": csize,
                         "dpos": float(dpos), "dsize": float(dsize), "move": bool(move), "stretch": bool(stretch)})

    def alpha(self, wid, a, curve, dur=0.0, frm=None):
        self.ops.append({"op": "alpha", "wid": wid, "a": float(a), "curve": curve, "dur": float(dur),
                         "frm": None if frm is None else float(frm)})

    def under(self, wid, u):
        self.ops.append({"op": "under", "wid": wid, "under": u})

    def forget(self, wid):
        self.ops.append({"op": "forget", "wid": wid})

    def commit(self):
        self.ops.append({"op": "commit"})

    def spring(self, *a):
        pass

    def bezier(self, *a):
        pass

    def events(self):
        ev, W.events = W.events, []
        for e in ev:
            yield (e[0], e[1], e[2], tuple(e[3]))

    def wins(self):
        return [FakeWin(d) for d in W.eng]


class FakeEngine(engine.Engine):
    def __init__(self, log=print):
        super().__init__(log)
        self.c = FakeChan()
        self.setup()

    def alive(self):
        return True


class FakeDeco:
    def __init__(self, log):
        pass

    def ensure(self, *a):
        pass

    def place(self, wid, rect):
        return None

    def sample(self, wid):
        pass

    def drop(self, wid):
        pass


class FakeAX:
    @staticmethod
    def ax_tileable(pid, wid):
        W.calls.append(["ax_tileable", pid, wid])
        return W.tileable.get(str(wid), -1)

    @staticmethod
    def ax_focus(pid, wid, raise_):
        W.calls.append(["ax_focus", pid, wid])
        return 0

    @staticmethod
    def ax_forget(wid):
        W.calls.append(["ax_forget", wid])


class FakeSnap:
    @staticmethod
    def ws_close(pid, wid):
        W.calls.append(["ws_close", pid, wid])
        return 0

    @staticmethod
    def ws_quit(pid):
        W.calls.append(["ws_quit", pid])
        return 0


def win_pid_level(wid):
    v = W.pidlevel.get(str(wid))
    return (v[0], v[1]) if v else (None, None)


def win_bounds(wid):
    v = W.bounds.get(str(wid))
    return tuple(v) if v else None


def win_alpha(wid):
    return W.alpha.get(str(wid))


def move_to_space(wids, space):
    W.calls.append(["move_to_space", list(wids), space])


class _Sub:
    def __getattr__(self, k):
        raise RuntimeError("subprocess в сценарии запрещён")


def make_wm(tmp):
    ns = dict(CONSTS)
    ns.update(json=json, os=os, re=re, time=FakeTime, tile=tile, chan=chan, hyprcfg=hyprcfg,
              Engine=FakeEngine, Deco=FakeDeco, log=lambda *a: None, mouse=lambda: W.mouse,
              mouse_down=lambda: W.md, _ax=FakeAX, _snap=FakeSnap, win_pid_level=win_pid_level,
              win_bounds=win_bounds, win_alpha=win_alpha, move_to_space=move_to_space,
              front_pid=lambda: W.front, queue=queue, threading=__import__("threading"), subprocess=_Sub(), ctypes=None,
              STATE=os.path.join(tmp, "state.json"), MINSIZE=os.path.join(tmp, "mins.json"))
    exec(CLS_SRC, ns)
    exec("def handle_events(self, evs):\n    drifted = False\n" + textwrap.indent(EV_SRC, "    ") +
         "\n    return drifted\n", ns)
    wm = ns["WM"]()
    wm.snaps = 0
    wm.jobs = []
    wm.configure = lambda jobs: wm.jobs.extend([[j["wid"], j["pid"], j["owner"], [float(v) for v in j["to"]]] for j in jobs])
    return wm, ns["handle_events"]


def state(wm):
    sps = {}
    for k, s in wm.spaces.items():
        sps[k] = {"tree": tree_json(s.get("tree")), "focus": s.get("focus"), "full": s.get("full"),
                  "presel": s.get("presel"), "fullmode": s.get("fullmode")}
    return {"spaces": sps, "target": {str(k): [float(x) for x in v] for k, v in wm.target.items()},
            "hidden": copy.deepcopy(wm.hidden), "floating": sorted(wm.floating), "restoring": sorted(wm.restoring),
            "closing": sorted(wm.closing), "newbies": list(wm.newbies), "optimistic": list(wm.optimistic),
            "mins": copy.deepcopy(wm.mins), "own_focus": wm.own_focus[0], "fwant": getattr(wm, "_fwant", None),
            "later": len(wm.later), "pids": {str(k): v for k, v in wm.pids.items()}}


OWNERS = [("Ghostty", 501), ("Telegram", 502), ("Finder", 503), ("Safari", 504), ("Zen", 505)]


class Sim:
    """Model snapshots, engine slots and AX replies between scenario steps."""

    def __init__(self, rnd):
        self.rnd = rnd
        self.space = 3
        self.area = rnd.choice([[0, 33, 1470, 923], [0, 25, 1710, 1080]])
        self.wins = []
        self.eng = {}
        self.tileable = {}
        self.pending = {}          # Window ID -> (PID, rectangle): present on server but absent from snapshot
        self.nxt = 100 + rnd.randint(0, 50)
        for _ in range(rnd.randint(1, 5)):
            self.new_window(appear=True)

    def new_window(self, appear, owner=None, rect=None, space=None):
        rnd = self.rnd
        o, pid = owner or rnd.choice(OWNERS)
        wid = self.nxt
        self.nxt += rnd.randint(1, 9)
        if rect is None:
            w = rnd.choice([rnd.uniform(300, 900), 100.0, rnd.uniform(200, 1200)])
            h = rnd.choice([rnd.uniform(250, 700), 90.0, rnd.uniform(200, 800)])
            rect = [round(rnd.uniform(0, 600), 1), round(rnd.uniform(30, 300), 1), round(w, 1), round(h, 1)]
        name = rnd.choice(["", "main", "Open File", "Сохранить как", "doc"])
        d = {"wid": wid, "pid": pid, "owner": o, "name": name, "x": rect[0], "y": rect[1], "w": rect[2], "h": rect[3],
             "on": 1, "space": space if space is not None else (self.space if rnd.random() < 0.85 else 5)}
        r = rnd.random()
        self.tileable[wid] = 1 if r < 0.75 else (0 if r < 0.88 else -1)
        if appear:
            self.wins.insert(0, d)
        else:
            self.pending[wid] = d
        return wid

    def world(self):
        bounds, alpha, pidlevel = {}, {}, {}
        for d in self.wins + list(self.pending.values()):
            bounds[str(d["wid"])] = [d["x"], d["y"], d["w"], d["h"]]
            pidlevel[str(d["wid"])] = [d["pid"], 0]
            e = self.eng.get(d["wid"])
            alpha[str(d["wid"])] = e["curAlpha"] if e else 1.0
        return {"now": W.now, "mouse": list(W.mouse), "md": W.md, "front": W.front, "area": self.area,
                "space": self.space, "wins": copy.deepcopy(self.wins), "eng": copy.deepcopy(list(self.eng.values())),
                "tileable": {str(k): v for k, v in self.tileable.items()}, "bounds": bounds, "alpha": alpha,
                "pidlevel": pidlevel, "events": copy.deepcopy(W.events)}

    def install(self, w):
        W.tileable, W.bounds, W.alpha, W.pidlevel = w["tileable"], w["bounds"], w["alpha"], w["pidlevel"]
        W.eng = w["eng"]

    def slot(self, wid):
        d = next((x for x in self.wins if x["wid"] == wid), None)
        r = [d["x"], d["y"], d["w"], d["h"]] if d else [0.0, 0.0, 10.0, 10.0]
        return self.eng.setdefault(wid, {"wid": wid, "pos": r[:2], "size": r[2:], "posActive": False,
                                         "sizeActive": False, "alphaActive": False, "settling": False,
                                         "curAlpha": 1.0, "held": False, "radius": 0.0, "a": list(r)})

    def apply_ops(self, ops):
        rnd = self.rnd
        for o in ops:
            if o["op"] in ("geom", "warp"):
                e = self.slot(o["wid"])
                to = o["to"]
                if o["move"]:
                    e["a"] = list(to)
                    d = next((x for x in self.wins if x["wid"] == o["wid"]), None)
                    if d and rnd.random() < 0.7:
                        d["x"], d["y"], d["w"], d["h"] = to
                if o["op"] == "geom" and rnd.random() < 0.3:
                    f = o["frm"] or e["a"]
                    e["pos"] = [(f[0] + to[0]) / 2, (f[1] + to[1]) / 2]
                    e["size"] = [(f[2] + to[2]) / 2, (f[3] + to[3]) / 2]
                    e["posActive"] = True
                else:
                    e["pos"], e["size"], e["posActive"] = to[:2], to[2:], False
            elif o["op"] == "alpha":
                e = self.slot(o["wid"])
                e["curAlpha"] = o["a"]
                e["alphaActive"] = o["dur"] > 0 and rnd.random() < 0.3
            elif o["op"] == "forget":
                self.eng.pop(o["wid"], None)

    def settle(self):
        for e in self.eng.values():
            if self.rnd.random() < 0.6:
                e["posActive"] = False
                e["alphaActive"] = False


CMDS = ["focus l", "focus r", "focus u", "focus d", "move left", "move right", "move up", "move down", "togglesplit",
        "preselect l", "preselect up", "preselect none", "preselect", "float", "fullscreen", "fullscreen maximized",
        "balance", "resize 30 0", "resize -40 25", "resize 0 -60", "resize abc 1", "resize 5", "hide", "unhide",
        "unhide all", "retile", "reset", "status", "close", "quit", "rescue", "bogus cmd", "", "focus", "exec",
        "focus x"]


def gen_scenario(seed, nsteps):
    rnd = random.Random(seed)
    W.now, W.mouse, W.md, W.front, W.events, W.calls = 1000.0, (200.0, 200.0), False, None, [], []
    tmp = tempfile.mkdtemp(prefix="hyprwm-fix-")
    sim = Sim(rnd)
    wm, handle_events = make_wm(tmp)
    steps = []

    def area():
        return tuple(sim.area)

    def visible_wins():
        return [dict(d) for d in sim.wins]

    for i in range(nsteps):
        r = rnd.random()
        op = {}
        if i == 0:
            op = {"op": "rescue", "keep_hidden": True}
        elif r < 0.22:
            op = {"op": "sync"}
        elif r < 0.50:
            c = rnd.choice(CMDS)
            if c in ("hide", "unhide", "close") and rnd.random() < 0.4:
                ids = [d["wid"] for d in sim.wins] + [h["wid"] for h in wm.hidden]
                if ids:
                    c += " %d" % rnd.choice(ids)
            op = {"op": "cmd", "line": c}
        elif r < 0.58:
            # A new window emits an engine event before appearing in a snapshot.
            appear = rnd.random() < 0.5
            tab = rnd.random() < 0.3 and wm.target
            if tab:
                tw = rnd.choice(sorted(wm.target))
                d = next((x for x in sim.wins if x["wid"] == tw), None)
                if d:
                    t = wm.target[tw]
                    jitter = rnd.choice([0, 0, 3, 40])
                    wid = sim.new_window(appear, owner=(d["owner"], d["pid"]),
                                         rect=[t[0] + jitter, t[1], t[2], t[3]], space=d["space"])
                    sim.tileable[wid] = 1
                    if appear:
                        if rnd.random() < 0.6:
                            d["on"] = 0             # A new tab covers the previous tab.
                        else:
                            sim.wins.remove(d)      # Cmd+W closes one tab and shows its neighbor.
                            sim.eng.pop(tw, None)
                else:
                    wid = sim.new_window(appear)
            else:
                wid = sim.new_window(appear)
            W.events.append([chan.EV_NEW, wid, W.now, [0, 0, 0, 0]])
            op = {"op": "events"}
        elif r < 0.62:
            if sim.pending:
                wid = rnd.choice(sorted(sim.pending))
                sim.wins.insert(rnd.randint(0, len(sim.wins)), sim.pending.pop(wid))
                if sim.tileable.get(wid) == -1 and rnd.random() < 0.7:
                    sim.tileable[wid] = 1
            op = {"op": "hide_newbies"}
        elif r < 0.66:
            if sim.wins:
                d = rnd.choice(sim.wins)
                sim.wins.remove(d)
                sim.eng.pop(d["wid"], None)
                if rnd.random() < 0.8:
                    W.events.append([chan.EV_GONE, d["wid"], W.now, [0, 0, 0, 0]])
            op = {"op": "events"}
        elif r < 0.70:
            if wm.target and rnd.random() < 0.8:
                wid = rnd.choice(sorted(wm.target))
                t = wm.target[wid]
                W.events.append([chan.EV_MOVED, wid, W.now, [t[0] + 30, t[1] + 14, t[2], t[3]]])
            op = {"op": "events"}
        elif r < 0.76:
            W.mouse = (round(rnd.uniform(0, sim.area[2]), 1), round(rnd.uniform(0, sim.area[3] + 33), 1))
            W.md = rnd.random() < 0.1
            op = {"op": "follow_mouse"}
        elif r < 0.82:
            W.now += rnd.choice([0.05, 0.3, 0.7, 0.95, 1.05, 1.2, 1.45, 1.55, 1.6, 2.5])
            sim.settle()
            op = {"op": "advance"}
        elif r < 0.86:
            if wm.target:
                wid = rnd.choice(sorted(wm.target))
                to = wm.target[wid]
                own = wm.owner.get(wid, "")
                big = rnd.random() < 0.7
                got = [to[0], to[1], to[2] + (rnd.choice([0, 120, 300]) if big else 2), to[3] + rnd.choice([0, 0, 80])]
                op = {"op": "cfg", "wid": wid, "owner": own, "to": [float(v) for v in to], "got": got,
                      "e": rnd.choice([0, 0, 0, -25204]), "pre": rnd.choice([None, [0, 0, 500.0, 400.0]])}
            else:
                op = {"op": "sync"}
        elif r < 0.89:
            # Simulate unexplained opacity below 1 on an onscreen tiled window.
            cand = [w for w in sorted(wm.target) if w in sim.eng and w not in wm.restoring and w not in wm.closing]
            if cand and rnd.random() < 0.6:
                e = sim.eng[rnd.choice(cand)]
                e["curAlpha"], e["alphaActive"] = rnd.choice([0.0, 0.4, 0.99]), False
            op = {"op": "alpha_guard"}
        elif r < 0.91:
            op = {"op": "realign"}
        elif r < 0.94:
            op = {"op": "activate", "pid": rnd.choice(OWNERS)[1]}
        elif r < 0.96:
            if sim.wins:                               # Move a window forward in the stacking order.
                d = rnd.choice(sim.wins)
                sim.wins.remove(d)
                sim.wins.insert(0, d)
            W.front = rnd.choice([None] + [p for _, p in OWNERS])
            op = {"op": "sync"}
        elif r < 0.98:
            sim.space = 5 if sim.space == 3 else 3
            op = {"op": "sync"}
        else:
            op = {"op": "rescue", "keep_hidden": rnd.random() < 0.5}

        world = sim.world()
        sim.install(world)
        W.calls = []
        wm.eng.c.ops = []
        wm.jobs = []
        a, sp, wins = area(), sim.space, visible_wins()
        res = None
        try:
            if op["op"] == "sync":
                ch, op_ = wm.sync(a, sp, wins)
                if ch:
                    wm.apply(a, sp, wins, opening=op_)
                res = [ch, op_]
            elif op["op"] == "cmd":
                try:
                    res = wm.command(op["line"], a, sp, wins)
                except (ValueError, StopIteration) as e:
                    res = "EXC"
            elif op["op"] == "events":
                res = handle_events(wm, list(wm.eng.c.events()))
                if res:
                    wm.apply(a, sp, wins)
            elif op["op"] == "hide_newbies":
                wm.hide_newbies(sp, wins)
            elif op["op"] == "follow_mouse":
                wm.follow_mouse(sp, wins)
            elif op["op"] == "advance":
                due = [f for t, f in wm.later if t <= W.now]
                wm.later = [(t, f) for t, f in wm.later if t > W.now]
                for f in due:
                    f()
            elif op["op"] == "cfg":
                wm.cfg_q.put((op["wid"], op["owner"], tuple(op["to"]), tuple(op["got"]), op["e"],
                              tuple(op["pre"]) if op["pre"] else None))
                res = wm.configured()
                if res:
                    wm.apply(a, sp, wins)
            elif op["op"] == "alpha_guard":
                wm.alpha_guard(wins)
            elif op["op"] == "realign":
                res = wm.realign(a, sp, wins)
                if res:
                    wm.apply(a, sp, wins)
            elif op["op"] == "activate":
                wm.on_activate(a, sp, wins, op["pid"])
            elif op["op"] == "rescue":
                res = wm.rescue(a, sp, wins, keep_hidden=op["keep_hidden"])
        except Exception as e:                      # Reject a scenario if the reference crashes outside command processing.
            shutil.rmtree(tmp, ignore_errors=True)
            return None, "%s: %r (шаг %d, %s)" % (type(e).__name__, e, i, op)
        ops = list(wm.eng.c.ops)
        steps.append({"world": world, "op": op, "res": res, "chan": ops, "jobs": list(wm.jobs),
                      "calls": list(W.calls), "state": state(wm)})
        sim.apply_ops(ops)
        # Compare saved daemon state and file formats as well.
    saved = {"state": open(os.path.join(tmp, "state.json")).read() if os.path.exists(os.path.join(tmp, "state.json")) else None,
             "mins": open(os.path.join(tmp, "mins.json")).read() if os.path.exists(os.path.join(tmp, "mins.json")) else None}
    shutil.rmtree(tmp, ignore_errors=True)
    return {"seed": seed, "steps": steps, "saved": saved}, None


def main():
    if "--wm-only" not in sys.argv:
        json.dump(gen_tile(), open(os.path.join(FIX, "tile_golden.json"), "w"))
        json.dump(gen_config(), open(os.path.join(FIX, "config_golden.json"), "w"), ensure_ascii=False)
    scen, rejected = [], {}
    seed = 0
    while len(scen) < 160:
        s, why = gen_scenario(seed, 60)
        seed += 1
        if s is None:
            rejected.setdefault(why.split(":")[0], []).append(why)
            continue
        scen.append(s)
    json.dump(scen, open(os.path.join(FIX, "wm_scenarios.json"), "w"), ensure_ascii=False)
    print("Generated %d WM scenarios (%d seeds, 60 steps each)" % (len(scen), seed))
    for k, v in rejected.items():
        print("Reference rejected %d scenarios (%s), example: %s" % (len(v), k, v[0]))


if __name__ == "__main__":
    main()
