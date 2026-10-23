#!/usr/bin/env python3
"""Проверка «окно мелькает до плитки»: N раз exec нового окна через сокет демона; каждые 2 мс у сервера
альфа и рамка новых окон. Окно «мелькнуло», если оно было упорядочено на экране с α>0.05 вне своей конечной
рамки. Пишет в канал только демон — скрипт лишь читает сервер и шлёт команды в сокет."""
import ctypes, os, socket, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
import chan          # только чтение видимой рамки B (pos/size) — команд не пишем
sl = ctypes.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight'); cid = sl.SLSMainConnectionID()
class R(ctypes.Structure): _fields_ = [('x', ctypes.c_double), ('y', ctypes.c_double), ('w', ctypes.c_double), ('h', ctypes.c_double)]
def cmd(s):
    k = socket.socket(socket.AF_UNIX); k.connect("/tmp/hyprwm.ctl"); k.sendall((s + "\n").encode()); r = k.recv(65536).decode(); k.close(); return r
CH = chan.Chan()
def state(w):
    r = R(); a = ctypes.c_float(); on = ctypes.c_int()
    if sl.SLSGetWindowBounds(cid, w, ctypes.byref(r)): return None
    sl.SLSGetWindowAlpha(cid, w, ctypes.byref(a)); sl.SLSWindowIsOrderedIn(cid, w, ctypes.byref(on))
    rect = (r.x, r.y, r.w, r.h)
    e = next((x for x in CH.wins() if x.wid == w), None)
    if e and (abs(e.m[0] - 1) > 1e-6 or abs(e.m[1] - 1) > 1e-6 or abs(e.m[2]) > 1e-4 or abs(e.m[3]) > 1e-4):
        rect = (e.pos.v[0], e.pos.v[1], e.size.v[0], e.size.v[1])     # видна рамка B (наш трансформ)
    return tuple(round(v) for v in rect), a.value, on.value
n = int(sys.argv[1]) if len(sys.argv) > 1 else 4
gap = float(sys.argv[2]) if len(sys.argv) > 2 else 0.15
probe = sys.argv[3] if len(sys.argv) > 3 else "exec Ghostty --new"
top = 0
for w in range(1, 30000):
    if state(w): top = w
seen = {}
t0 = time.time(); sent = 0
while time.time() - t0 < n * gap + 2.0:
    if sent < n and time.time() - t0 >= sent * gap:
        cmd(probe); sent += 1
    for w in range(top + 1, top + 200):
        s = state(w)
        if s: seen.setdefault(w, []).append((time.time() - t0, s))
    time.sleep(0.002)
for w, hist in seen.items():
    final = hist[-1][1][0]
    vis = [(round(t * 1000), r, round(a, 2)) for t, (r, a, on) in hist if on and a > 0.05]
    if not vis: continue
    # мелькание = видно (α>0.3) далеко от конечной плитки: центр дальше 40 pt (popin от центра — не мелькание)
    cf = (final[0] + final[2] / 2, final[1] + final[3] / 2)
    flash = [v for v in vis if v[1][2] > 120 and v[2] > 0.3 and
             max(abs(v[1][0] + v[1][2] / 2 - cf[0]), abs(v[1][1] + v[1][3] / 2 - cf[1])) > 40]
    print("окно %d: первый показ %d мс, конечная %s, мелькания вне плитки: %d%s" % (
        w, vis[0][0], final, len(flash), (" первое %s" % (flash[0],)) if flash else ""))
