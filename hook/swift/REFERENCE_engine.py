# Python reference model used to generate Swift test fixtures. Not used at runtime.
"""Daemon-side animation engine model.

ensure() manages a channel and checks whether the engine is running.
The saved runtime helper can reinstall an engine through LLDB.
Configuration curves map to channel IDs. anim(leaf) returns the curve ID,
Bezier duration and enabled state for an animation leaf.
"""
import os
import subprocess
import sys
import time

HOOK = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HOOK, "config"))
import chan      # noqa: E402
import hyprcfg   # noqa: E402

STATE = os.path.join(HOOK, "anim4.state")
# Stretch duration without changing curve shape. Smaller per-frame steps
# smooth motion; 1.0 uses the original Hyprland configuration timing.
TIME_SCALE = float(os.environ.get("HYPRWM_TIME_SCALE", "1.2"))
# Apply TIME_SCALE to geometry leaves. Configured springs are used only
# for geometry, so k/s^2 and d/s in setup affect only those leaves.
GEOM_LEAVES = {"windows", "windowsIn", "windowsOut", "windowsMove", "workspaces", "workspacesIn",
               "workspacesOut", "specialWorkspace", "specialWorkspaceIn", "specialWorkspaceOut"}


def ws_pid():
    out = subprocess.run(["pgrep", "-x", "WindowServer"], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


class Engine:
    def __init__(self, log=print):
        self.log = log
        self.c = None
        self.ids = {}

    def alive(self):
        if self.c is None or self.c.h.magic != chan.CH_MAGIC:
            return False
        if self.c.h.size != self.c.L.ch_abi():
            return False                                   # Replace a channel with a different structure version.
        if not os.path.exists(STATE) or int(open(STATE).read().split()[0]) != ws_pid():
            return False
        t = self.c.h.ticks
        if t != getattr(self, "_pt", None):                # The tick advanced since the previous check; avoid sleeping in the main loop.
            self._pt = t
            return True
        time.sleep(0.05)
        self._pt = self.c.h.ticks
        return self._pt != t

    def ensure(self, startup=False):
        """At daemon startup, check whether the native image changed.
        Only a fresh process may reinstall; a running daemon leaves it alone."""
        if startup and self._stale_build():
            if self.c is None and os.path.exists(chan.PTR):
                try:
                    self.c = chan.Chan()
                except Exception:
                    self.c = None
            self.install()
            return
        self._ensure()

    def _stale_build(self):
        import hashlib
        try:
            st = open(STATE).read().split()
            have = st[4] if len(st) > 4 else ""
        except OSError:
            return True
        return have != hashlib.sha1(open(os.path.join(HOOK, "anim4.bin"), "rb").read()).hexdigest()[:12]

    def _ensure(self):
        if self.c is None and os.path.exists(chan.PTR):
            try:
                self.c = chan.Chan()
            except Exception:
                self.c = None
        if self.alive():
            self.setup()
            return
        self.install()

    def install(self):
        """Stop the old engine and wait until its tick stops before reinstalling.
        Create a new channel file. Never truncate the old mapped file."""
        if self.c is not None and self.c.h.magic == chan.CH_MAGIC:
            self.c.h.stop = 1
            for _ in range(20):
                t = self.c.h.ticks
                time.sleep(0.05)
                if self.c.h.ticks == t:
                    break
        old = self.c.path if self.c is not None else None
        self.log("ставлю движок в WindowServer (экран замрёт на ~2 с)")
        self.c = chan.Chan(create=True)
        self.setup()
        open("/tmp/hyprwm/display", "w").write("1")
        out = subprocess.run([os.path.join(HOOK, "run_lldb.sh"), os.path.join(HOOK, "scripts", "install4.py")],
                             capture_output=True, text=True).stdout
        inst = [l for l in out.splitlines() if l.startswith("INST")]
        self.log(*inst or [out[-400:]])
        if not self.alive():
            raise RuntimeError("движок не запустился: " + out[-400:])
        if old and old != self.c.path:
            try:
                os.unlink(old)                              # The old engine mapping remains valid.
            except OSError:
                pass

    def setup(self):
        """Register configuration curves and set tick and size-wait parameters."""
        h = self.c.h
        h.idle_poll, h.phase, h.margin = 0.004, 0.1, 0.002   # Idle ticks take about 2-6 microseconds; check commands every 4 ms.
        # Waiting for an application frame added two frames of latency. Show the
        # old buffer at 1:1 scale instead; HYPRWM_HOLD=0.017 restores the wait.
        h.hold_max = float(os.environ.get("HYPRWM_HOLD", "-1"))
        h.settle, h.settle_px = 1.0, 8.0          # Wait for the application final size, allowing terminal character grids.
        for i, (name, cv) in enumerate(sorted(hyprcfg.curves().items())):
            if i >= 16:
                break
            if cv["type"] == "spring":                 # Scale time without changing curve shape: k/s^2, d/s.
                self.c.spring(i, cv["mass"], cv["stiffness"] / TIME_SCALE ** 2, cv["damping"] / TIME_SCALE)
            else:
                (p1, p2) = cv["points"][:2] if len(cv["points"]) >= 2 else ([0, 0], [1, 1])
                self.c.bezier(i, p1, p2)
            self.ids[name] = i

    def anim(self, leaf):
        """Return (curve ID, Bezier duration in seconds, enabled).
        TIME_SCALE affects geometry. Opacity and borders use configuration time."""
        a = hyprcfg.animation(leaf)
        s = TIME_SCALE if leaf in GEOM_LEAVES else 1.0
        return self.ids.get(a["curve"], self.ids.get("default", 0)), a["speed"] * 0.1 * s, a["enabled"]

    def real(self):
        """Return actual server bounds for a window, without our transform."""
        return {w.wid: (w.ax, w.ay, w.aw, w.ah) for w in self.c.wins()}
