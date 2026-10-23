"""Окна-подложки (build/hyprdeco): по одной на тайловое окно. Видны только во время анимации и
только в пустой полосе «рамка B минус буфер приложения» — как краевые пиксели Hyprland
(expand_undersized_textures). Цвет: фон приложения из его конфига, иначе системный фон окна темы."""
import os
import subprocess
import threading

HOOK = os.path.dirname(os.path.abspath(__file__))

# фон приложений, которые рисуют свой цвет (Ghostty: Catppuccin Mocha base, background-opacity 0.85)
COLORS = {"Ghostty": (0x1e / 255, 0x1e / 255, 0x2e / 255, 0.85)}


class Deco:
    def __init__(self, log):
        self.log = log
        self.p = subprocess.Popen([os.path.join(HOOK, "build", "hyprdeco")], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True, bufsize=1)
        self.wids = {}       # wid окна -> wid подложки
        self.asked = set()
        self.radius = {}
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            a = line.split()
            if len(a) == 3 and a[0] == "wid":
                self.wids[int(a[1])] = int(a[2])

    def _send(self, s):
        try:
            self.p.stdin.write(s + "\n")
        except Exception as e:
            self.log("подложки:", repr(e))

    def ensure(self, wid, owner, radius):
        """Создать подложку; когда движок узнает радиус скругления окна у сервера — обновить его."""
        if wid in self.asked and (not radius or self.radius.get(wid) == radius):
            return
        self.asked.add(wid)
        self.radius[wid] = radius
        r, g, b, a = COLORS.get(owner, (-1, -1, -1, 1.0))
        self._send("new %d %.4f %.4f %.4f %.1f %.3f" % (wid, r, g, b, radius or 16, a))

    def place(self, wid, rect):
        """Перед анимацией: реальная рамка = цель (в конце масштаб 1, скругление точное), прямо под окном."""
        if wid in self.wids:
            self._send("frame %d %.1f %.1f %.1f %.1f" % ((wid,) + tuple(rect)))
            self._send("below %d %d" % (wid, wid))
        return self.wids.get(wid)

    def sample(self, wid):
        """Цвет края буфера окна (снимок ScreenCaptureKit в hyprdeco) — раз в несколько секунд в покое."""
        if wid in self.wids:
            self._send("sample %d %d" % (wid, wid))

    def drop(self, wid):
        if wid in self.asked:
            self.asked.discard(wid)
            self.wids.pop(wid, None)
            self._send("del %d" % wid)
