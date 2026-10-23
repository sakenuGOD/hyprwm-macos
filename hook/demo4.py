"""Демо движка v4: окно WID плавно уезжает/сжимается пружиной drift и возвращается (2 раза).
usage: PYTHONPATH=hook python3 hook/demo4.py WID [задержка_с]"""
import sys, time
import chan
c = chan.Chan()
wid = int(sys.argv[1]); delay = float(sys.argv[2]) if len(sys.argv) > 2 else 0
c.spring(0, 1, 210, 24)
w = [x for x in c.wins() if x.wid == wid]
time.sleep(delay)
c.h.settle = 4.0
c.geom(wid, (0, 0, 1, 1), 0, 0, move=False, warp=True); c.commit(); time.sleep(0.05)   # узнать рамку
w = [x for x in c.wins() if x.wid == wid][0]
x, y, W, H = w.ax, w.ay, w.aw, w.ah
c.geom(wid, (x, y, W, H), 0, 0, move=False, warp=True); c.commit(); time.sleep(0.05)
for _ in range(2):
    c.geom(wid, (x + 250, y + 120, W * 0.7, H * 0.7), 0, 0, move=False); c.commit(); time.sleep(3.5)
    c.geom(wid, (x, y, W, H), 0, 0, move=False); c.commit(); time.sleep(2.0)
c.h.settle = 1.0
print("demo done", (x, y, W, H))
