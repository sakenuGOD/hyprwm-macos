"""Движок анимаций v4 в WindowServer со стороны демона.

ensure() — канал /tmp/hyprwm/chan и живой движок (если WindowServer перезапускался или движка нет —
ставит его одним attach lldb: экран замирает на ~2 с). Кривые из конфига Hyprland регистрируются по
номерам; anim(leaf) отдаёт (номер кривой, длительность безье, включено ли) для листа дерева анимаций.
"""
import ctypes
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


_proc = ctypes.CDLL("/usr/lib/libproc.dylib")


def ws_pid():
    """pid WindowServer через libproc. Не через pgrep: 2026-10-09 15:51 pgrep завис в своём цикле на 4 мин, а
    главный цикл демона ждал его (alive() раз в 2 с) — раскладка и сокет стояли."""
    n = _proc.proc_listallpids(None, 0)
    pids = (ctypes.c_int * (n + 64))()
    n = _proc.proc_listallpids(pids, ctypes.sizeof(pids))
    path = ctypes.create_string_buffer(1024)            # proc_name чужого (root) процесса пуст — путь отдаётся
    for p in pids[:max(n, 0)]:
        if p > 0 and _proc.proc_pidpath(p, path, 1024) > 0 and path.value.endswith(b"/WindowServer"):
            return p
    return None


def _lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _gam(c):
    c = min(max(c, 0.0), 1.0)
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def _oklab(rgb):
    r, g, b = (_lin(x) for x in rgb)
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


def _srgb(lab):
    L, A, B = lab
    l = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3
    m = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3
    s = (L - 0.0894841775 * A - 1.2914855480 * B) ** 3
    return (_gam(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            _gam(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            _gam(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))


def oklab_mix(c1, c2, t):
    """Смешение RGBA в OkLab (как gradient.glsl Hyprland), альфа — линейно."""
    a, b = _oklab(c1[:3]), _oklab(c2[:3])
    return _srgb(tuple(x + (y - x) * t for x, y in zip(a, b))) + (c1[3] + (c2[3] - c1[3]) * t,)


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
        # Как Wayland: configure → кадр приложения нового размера → движение. Пачка стоит, пока окна с новым размером
        # не перерисовались (≤ 120 мс), и стартует одной волной уже с новым содержимым — без «превращения» на ходу
        # [жалоба 13:30]. HYPRWM_HOLD=-1 — не ждать (меньше задержка старта, но перерисовка посреди хода).
        h.hold_max = float(os.environ.get("HYPRWM_HOLD", "0.2"))
        # новое окно тайлового приложения движок прячет сам в тик появления (HYPRWM_PREHIDE=0 — выключить)
        self.c.set_prehide(os.environ.get("HYPRWM_PREHIDE", "1") != "0")
        # П4: обрезка маской в CA-дереве окна (HYPRWM_MASK=1 — все окна, =<wid> — одно окно, 0 — экранный клип)
        m = os.environ.get("HYPRWM_MASK", "1")
        h.use_mask, h.mask_only = (0, 0) if m == "0" else (1, 0 if m == "1" else int(m))
        h.mask_flip = int(os.environ.get("HYPRWM_MASK_FLIP", "1"))
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
        self.setup_border()
        self.setup_close()

    def setup_border(self):
        """П6: рамка фокуса в канал. Градиент Hyprland смешивает цвета в OkLab — CAGradientLayer смешивает в sRGB,
        поэтому градиент запекается в 8 точек OkLab. Направление — аппроксимация Hyprland для угла a ≤ 90°:
        progress = y·sin a + x·(1 − sin a) от левого верхнего угла (spec §5.1)."""
        import math
        b = hyprcfg.border()
        d = self.c.deco
        on = os.environ.get("HYPRWM_BORDER", "1") != "0" and b["size"] > 0
        cols = b["active"] if len(b["active"]) > 1 else b["active"] * 2
        n = 8
        for i in range(n):
            t = i / (n - 1) * (len(cols) - 1)
            k = min(int(t), len(cols) - 2)
            d.grad[i][:] = oklab_mix(cols[k], cols[k + 1], t - k)
        d.ngrad = n
        d.inact[:] = b["inactive"]
        a = math.radians(b["angle"] % 360)
        sa = min(max(math.sin(a), 0.0), 1.0)
        vx, vy = 1 - sa, sa                              # прогресс = vx·x + vy·y (x вправо, y вниз)
        n2 = vx * vx + vy * vy or 1.0
        ex, ey = vx / n2, vy / n2
        d.start[:] = (0.0, 1.0)                          # у слоя ось Y вверх: верх = 1
        d.end[:] = (ex, 1.0 - ey)
        d.width, d.radius = float(b["size"]), float(b["rounding"])
        cv, dur, en = self.anim("border")
        # Решение пользователя (09:40): 600 мс по конфигу при фокусе за курсором — «долго, костыльно». По умолчанию
        # 150 мс той же кривой; HYPRWM_BORDER_MS=600 — как в конфиге Hyprland.
        ms = os.environ.get("HYPRWM_BORDER_MS", "")       # пусто — по конфигу (600 мс); кроссфейд ведёт CA
        d.curve, d.dur = cv, (float(ms) / 1000 if ms else dur) if en else 0.0
        # тень: профиль Hyprland (1 − e/range)^power при range 34, power 3 ≈ гаусс σ ≈ range/3.1 с плотностью ×1.95
        # (spec §5.3: ошибка ≤ 0.01); у CA shadowRadius — σ [H: сверить замером профиля на скриншоте]
        sh = hyprcfg.shadow()
        d.sh_on = int(bool(sh["on"]) and os.environ.get("HYPRWM_SHADOW", "1") != "0")
        d.srad = sh["range"] / 3.1
        d.soff = float(sh["offset"])
        dens = float(os.environ.get("HYPRWM_SHADOW_DENS", "1.0"))   # 1.95 — точный профиль, но затемняет кольца соседей
        d.sop_act, d.sop_in = min(1.0, sh["act"] * dens), min(1.0, sh["inact"] * dens)
        scv, sdur, sen = self.anim("fadeShadow")
        d.scurve, d.sdur = scv, (d.dur if os.environ.get("HYPRWM_BORDER_MS", "") else sdur) if sen else 0.0
        # системная тень/контур Tahoe: 0 — невидимы, но окно «теневое» (клип отрисовки расширен — рамка/тень снаружи
        # видны, beyond_bounds.md §1); tag — тегом DisableShadow (клип = прямоугольник окна); 1 — системные как есть
        # 3 — override тени (WS сам держит её невидимой), 2 — гасить слой Shadow каждый тик, 1 — тег, 0 — тень Tahoe
        d.sys_off = {"0": 3, "police": 2, "tag": 1, "1": 0}.get(os.environ.get("HYPRWM_SYS_SHADOW", "0"), 3)
        d.only = int(os.environ.get("HYPRWM_BORDER_ONLY", "0"))
        # WS обрезает слои окна прямоугольником окна [V 13:58: снаружи прямого края — пусто, на углах — видно] →
        # кольцо целиком ВНУТРИ окна (поверх края содержимого); слот плитки не уменьшается на рамку (см. hyprwm.BORDER)
        # внутрь края окна: 1 pt — закрыть обводку приложения (Tahoe); в режиме «тег» кольцо целиком внутри
        d.inset10 = int(float(os.environ.get("HYPRWM_BORDER_INSET", "1" if d.sys_off != 1 else str(d.width))) * 10)   # закрыть внутренний контур приложения
        # кривые кроссфейда — в CA (CAMediaTimingFunction): точки безье из конфига; пружина/нет — ease-out
        cvs = hyprcfg.curves()
        for leaf, arr in (("border", d.bez), ("fadeShadow", d.sbez)):
            pts = cvs.get(hyprcfg.animation(leaf)["curve"], {}).get("points")
            arr[:] = (pts[0][0], pts[0][1], pts[1][0], pts[1][1]) if pts and len(pts) >= 2 else (0.25, 1.0, 0.5, 1.0)
        d.on = int(on)

    def setup_close(self):
        """П8: снимок закрытия любого окна (Cmd+W, кнопка, выход) — windowsOut popin + fadeOut из конфига.
        HYPRWM_CLOSE: 1 — клон, log — только журнал событий освобождения, 0 — выкл."""
        import re
        import struct as st
        mode = os.environ.get("HYPRWM_CLOSE", "1")
        oc, od, on = self.anim("windowsOut")
        fc, fd, fon = self.anim("fadeOut")
        m = re.search(r"popin\s+(\d+)", hyprcfg.animation("windowsOut")["style"])
        k = float(m.group(1)) / 100 if m else 0.92
        h = self.c.h
        h.reserved[0] = (0 if mode == "0" else 1) | (2 if mode == "1" else 0) | (oc & 255) << 8 | (fc & 255) << 16
        h.reserved[1] = st.unpack("<Q", st.pack("<d", od if on else 0.0))[0]
        h.reserved[2] = st.unpack("<Q", st.pack("<d", fd if fon else 0.0))[0]
        h.reserved[3] = st.unpack("<Q", st.pack("<d", k))[0]

    def anim(self, leaf):
        """(номер кривой, длительность безье в с, включено). TIME_SCALE — только геометрии (движение
        окон и столов); альфа и рамка идут строго по конфигу (fadeIn 300 мс = 18 кадров)."""
        a = hyprcfg.animation(leaf)
        s = TIME_SCALE if leaf in GEOM_LEAVES else 1.0
        return self.ids.get(a["curve"], self.ids.get("default", 0)), a["speed"] * 0.1 * s, a["enabled"]

    def real(self):
        """wid -> фактическая рамка окна на сервере (без нашего трансформа)."""
        return {w.wid: (w.ax, w.ay, w.aw, w.ah) for w in self.c.wins()}
