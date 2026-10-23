"""Live-resize: каждый кадр приложению — промежуточный размер видимой рамки B (как при перетаскивании
угла мышью, только по пружине Hyprland). Тогда контент на каждом кадре настоящий и чёткий.

Поток-опросчик читает из общей памяти движка B всех окон с активной анимацией размера (~240 Гц) и
кладёт последний нужный размер окну; у каждого окна свой рабочий поток — медленное приложение не
тормозит остальные, а устаревшие размеры пропускаются (берётся самый свежий).
Первый вызов окна в анимации — позиция+размер (AppKit должен знать новое место, иначе подрежет
рост о край экрана), дальше — только размер. Конец — точная цель (позиция+размер)."""
import ctypes
import threading
import time

LEAD = 2.0        # кадров опережения для растущей оси


class Live:
    def __init__(self, eng, ax, log):
        self.eng, self.ax, self.log = eng, ax, log
        self.ax.ax_size.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.c_double, ctypes.c_double]
        self.mu = threading.Condition()
        self.jobs = {}       # wid -> {pid, target, first, want, sent, busy}
        self.stats = {"calls": 0, "ms": 0.0, "max": 0.0}
        threading.Thread(target=self._poll, daemon=True).start()

    def start(self, wid, pid, target):
        """Окно начало анимацию размера к target (глобальные pt)."""
        with self.mu:
            j = self.jobs.get(wid)
            if j:
                j.update(target=target, pid=pid, first=True, done=False)
                return
            self.jobs[wid] = j = {"pid": pid, "target": target, "first": True, "want": None, "sent": None,
                                  "done": False, "busy": False}
            threading.Thread(target=self._worker, args=(wid,), daemon=True).start()

    def finish(self, wid):
        """EV_DONE: точная цель."""
        with self.mu:
            j = self.jobs.get(wid)
            if j:
                j["done"] = True
                self.mu.notify_all()

    def active(self, wid):
        return wid in self.jobs

    def _poll(self):
        while True:
            try:
                wins = {w.wid: w for w in self.eng.c.wins()} if self.eng.c else {}
                with self.mu:
                    for wid, j in self.jobs.items():
                        w = wins.get(wid)
                        if not w or j["done"]:
                            continue
                        # опережение по растущей оси: буфер должен успеть стать ≥ рамки к моменту
                        # показа (AX + перерисовка приложения ≈ 2 кадра) — тогда только обрезка 1:1
                        tk = self.eng.c.h.ticks
                        cur = (w.size.v[0], w.size.v[1])
                        hist = j.setdefault("hist", [tk, cur, (0.0, 0.0)])
                        if tk != hist[0]:
                            hist[2] = (cur[0] - hist[1][0], cur[1] - hist[1][1])
                            hist[0], hist[1] = tk, cur
                        vel, tg = hist[2], j["target"]
                        want = []
                        for i in (0, 1):
                            x = cur[i] + max(0.0, vel[i]) * LEAD
                            if vel[i] > 0 and x > tg[2 + i]:
                                x = max(cur[i], tg[2 + i])
                            want.append(round(x))
                        want = tuple(want)
                        if want != j["want"]:
                            j["want"] = want
                            self.mu.notify_all()
            except Exception as e:
                self.log("live poll:", repr(e))
            time.sleep(1 / 240)

    def _worker(self, wid):
        while True:
            with self.mu:
                j = self.jobs.get(wid)
                while j and not j["done"] and (j["want"] is None or j["want"] == j["sent"]) and not j["first"]:
                    self.mu.wait(0.5)
                    j = self.jobs.get(wid)
                if not j:
                    return
                pid, tgt, first, done, want = j["pid"], j["target"], j["first"], j["done"], j["want"]
                j["first"] = False
            t = time.time()
            if done:
                e = self.ax.ax_frame(pid, wid, *tgt)
                with self.mu:
                    if self.jobs.get(wid) is j and j["done"]:
                        del self.jobs[wid]
                        return
                continue
            if want is None:
                continue
            if first:
                e = self.ax.ax_frame(pid, wid, tgt[0], tgt[1], want[0], want[1])
            else:
                e = self.ax.ax_size(pid, wid, want[0], want[1])
            dt = (time.time() - t) * 1000
            with self.mu:
                j["sent"] = want
                self.stats["calls"] += 1
                self.stats["ms"] += dt
                self.stats["max"] = max(self.stats["max"], dt)
            if e:
                self.log("live-resize %d: ошибка %s" % (wid, e))
