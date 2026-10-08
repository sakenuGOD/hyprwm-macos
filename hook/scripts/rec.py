"""Самописец движка: каждый тик пишет по окнам видимую рамку B, реальную A, масштаб, обрезку.
python3 scripts/rec.py <сек> [команда оболочки, запускаемая через 0.3 с]
Анализ: шаг времени te между тиками, скорость края рамки по кадрам (рывки = выбросы ускорения),
кадры, где масштаб != 1 (растяжение), и переход растяжение->обрезка (приход буфера приложения)."""
import ctypes, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import chan
c = chan.Chan()
dur = float(sys.argv[1]) if len(sys.argv) > 1 else 2.0
cmd = sys.argv[2] if len(sys.argv) > 2 else None
rows, last, t0, fired = [], None, time.time(), False
while time.time() - t0 < dur:
    if cmd and not fired and time.time() - t0 > 0.3:
        subprocess.Popen(cmd, shell=True); fired = True
    tk = c.h.ticks
    if tk != last:
        last = tk
        for w in c.wins():
            if w.pos.active or w.size.active or w.alpha.active or w.settling:
                rows.append((c.h.te, w.wid, w.pos.v[0], w.pos.v[1], w.size.v[0], w.size.v[1],
                             w.ax, w.ay, w.aw, w.ah, w.m[0], w.m[1], w.clipped, w.stretch, w.alpha.v[0]))
    time.sleep(0.0007)
by = {}
for r in rows:
    by.setdefault(r[1], []).append(r)
for wid, rs in by.items():
    # уникальные кадры по te
    seen, fr = set(), []
    for r in rs:
        if r[0] not in seen:
            seen.add(r[0]); fr.append(r)
    T = [b[0] - a[0] for a, b in zip(fr, fr[1:])]
    right = [r[2] + r[4] for r in fr]
    v = [(b - a) for a, b in zip(right, right[1:])]
    acc = [abs(b - a) for a, b in zip(v, v[1:])]
    stretch = sum(1 for r in fr if (abs(r[10] - 1) > 1e-3 or abs(r[11] - 1) > 1e-3) and not r[13])
    popin = sum(1 for r in fr if r[13])
    clip = sum(1 for r in fr if r[12])
    sw = [i for i, (a, b) in enumerate(zip(fr, fr[1:])) if (a[8], a[9]) != (b[8], b[9])]
    print("окно %d: кадров %d, шаг te мин/макс %.1f/%.1f мс, пропусков %d" % (
        wid, len(fr), 1000 * min(T or [0]), 1000 * max(T or [0]), sum(1 for t in T if t > 0.025)))
    print("   правый край B: %.0f -> %.0f; макс |Δv| за кадр %.1f pt; масштаб при resize кадров %d (popin %d); обрезано %d; смена буфера A на кадрах %s" % (
        right[0], right[-1], max(acc or [0]), stretch, popin, clip, sw[:6]))
    lag = [abs(r[8] - r[4]) + abs(r[9] - r[5]) for r in fr]
    print("   отставание буфера от рамки |A-B|: среднее %.1f, макс %.1f pt; первый шаг рамки %.1f pt" % (
        sum(lag) / max(1, len(lag)), max(lag or [0]), abs(fr[1][2] - fr[0][2]) + abs(fr[1][4] - fr[0][4]) if len(fr) > 1 else 0))
    for i in sw[:4]:
        a, b = fr[i], fr[i + 1]
        print("   буфер %dx%d -> %dx%d при B.w=%.0f (t=%.0f мс от старта)" % (a[8], a[9], b[8], b[9], b[4], 1000 * (b[0] - fr[0][0])))
open("/tmp/rec.tsv", "w").write("\n".join("\t".join("%.4f" % x for x in r) for r in rows))
