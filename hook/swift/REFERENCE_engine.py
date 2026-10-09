"""Движок анимаций v4 в WindowServer со стороны демона.

ensure() — канал /tmp/hyprwm/chan и живой движок (если WindowServer перезапускался или движка нет —
ставит его одним attach lldb: экран замирает на ~2 с). Кривые из конфига Hyprland регистрируются по
номерам; anim(leaf) отдаёт (номер кривой, длительность безье, включено ли) для листа дерева анимаций.
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
# 60 Гц мака против 180 Гц монитора пользователя: та же форма кривых, время ×1.2 (notes/anim_feel.md) —
# шаг за кадр меньше, движение мягче. 1.0 — строго как конфиг Hyprland.
TIME_SCALE = float(os.environ.get("HYPRWM_TIME_SCALE", "1.2"))
# Листья, к которым применяется TIME_SCALE. Пружины в конфиге (bounce, drift) есть только у геометрии,
# поэтому k/s², d/s в setup() задевают только её.
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
            return False                                   # канал другой версии структуры — переставить
        if not os.path.exists(STATE) or int(open(STATE).read().split()[0]) != ws_pid():
            return False
        t = self.c.h.ticks
        if t != getattr(self, "_pt", None):                # тикал с прошлой проверки — без сна в главном цикле
            self._pt = t
            return True
        time.sleep(0.05)
        self._pt = self.c.h.ticks
        return self._pt != t

    def ensure(self, startup=False):
        """startup=True (только при запуске демона — свежий процесс, свежие библиотеки): если движок в WS
        другой сборки, чем anim4.bin, — переставить безопасно. Работающий демон движок сам не трогает."""
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
        """Поставить движок заново. Старый сначала останавливается (stop) и мы ждём, пока его тик
        перестанет идти; новый получает НОВЫЙ файл канала — старый файл никогда не обрезается."""
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
                os.unlink(old)                              # отображение у старого движка остаётся валидным
            except OSError:
                pass

    def setup(self):
        """Кривые Hyprland -> номера в канале; параметры такта и ожидания размера."""
        h = self.c.h
        h.idle_poll, h.phase, h.margin = 0.004, 0.1, 0.002   # простой тик ~2–6 мкс: опрос команд каждые 4 мс (A2)
        # Ожидание кадра приложения перед стартом стоило 2 кадра задержки (A2: ≤1 кадр + 5 мс). Hyprland
        # не ждёт: старый буфер показывается 1:1 (обрезка/край) до нового. HYPRWM_HOLD=0.017 — вернуть.
        h.hold_max = float(os.environ.get("HYPRWM_HOLD", "-1"))
        h.settle, h.settle_px = 1.0, 8.0          # ждать конечный размер от приложения; сетка терминалов
        for i, (name, cv) in enumerate(sorted(hyprcfg.curves().items())):
            if i >= 16:
                break
            if cv["type"] == "spring":                 # время ×TIME_SCALE без изменения формы: k/s², d/s
                self.c.spring(i, cv["mass"], cv["stiffness"] / TIME_SCALE ** 2, cv["damping"] / TIME_SCALE)
            else:
                (p1, p2) = cv["points"][:2] if len(cv["points"]) >= 2 else ([0, 0], [1, 1])
                self.c.bezier(i, p1, p2)
            self.ids[name] = i

    def anim(self, leaf):
        """(номер кривой, длительность безье в с, включено). TIME_SCALE — только геометрии (движение
        окон и столов); альфа и рамка идут строго по конфигу (fadeIn 300 мс = 18 кадров)."""
        a = hyprcfg.animation(leaf)
        s = TIME_SCALE if leaf in GEOM_LEAVES else 1.0
        return self.ids.get(a["curve"], self.ids.get("default", 0)), a["speed"] * 0.1 * s, a["enabled"]

    def real(self):
        """wid -> фактическая рамка окна на сервере (без нашего трансформа)."""
        return {w.wid: (w.ax, w.ay, w.aw, w.ah) for w in self.c.wins()}
