#!/usr/bin/env python3
"""Первая рамка новых окон: опрос SLSGetWindowBounds по номерам выше <от> каждую 1 мс (только чтение).
firstframe.py <от> <сек> "<команда>" -> по каждому новому окну: время первого появления и все смены рамки."""
import subprocess, sys, time
from cfgtest import frame
lo, dur, cmd = int(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
seen = {}
t0 = time.time()
subprocess.Popen(cmd, shell=True)
while time.time() - t0 < dur:
    for wid in range(lo + 1, lo + 60):
        f = frame(wid)
        if f is None:
            continue
        h = seen.setdefault(wid, [])
        if not h or h[-1][1] != f:
            h.append(((time.time() - t0) * 1e3, f))
    time.sleep(0.001)
for wid, h in seen.items():
    print(wid, " | ".join("%.0f мс %s" % x for x in h))
