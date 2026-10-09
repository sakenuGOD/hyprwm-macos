#!/usr/bin/env python3
"""Стенд native_hooks §8 шаги 1–2: команда модулю hyprforce в приложении (Darwin notify) + замер серверной рамки.
WindowServer не трогает: только notify и SLSGetWindowBounds (чтение).

  cfgtest.py cfg  <pid> <wid> <mode> x y w h [сек]   mode 0 — родной метод сразу, 1 — пружина drift, 2 — setFrame:
  cfgtest.py next <pid> x y w h                      рамка первого кадра следующего нового окна (0 0 0 0 — снять)
  cfgtest.py watch <wid> [сек]                       только журнал рамки

Журнал: время от команды (мс) и рамка окна на сервере при каждом изменении."""
import ctypes, os, sys, time
PFX = os.environ.get("NPFX", "hyprwm")

sl = ctypes.CDLL("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")
sl.SLSMainConnectionID.restype = ctypes.c_int
sl.SLSGetWindowBounds.argtypes = [ctypes.c_int, ctypes.c_uint32, ctypes.c_void_p]
CID = sl.SLSMainConnectionID()

libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
libc.notify_register_check.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int)]
libc.notify_set_state.argtypes = [ctypes.c_int, ctypes.c_uint64]
libc.notify_post.argtypes = [ctypes.c_char_p]


def setstate(name, v):
    t = ctypes.c_int()
    assert libc.notify_register_check(name.encode(), ctypes.byref(t)) == 0
    assert libc.notify_set_state(t, ctypes.c_uint64(v)) == 0
    libc.notify_cancel(t)


def getstate(name):
    t, v = ctypes.c_int(), ctypes.c_uint64()
    libc.notify_register_check(name.encode(), ctypes.byref(t))
    libc.notify_get_state(t, ctypes.byref(v))
    libc.notify_cancel(t)
    return v.value


def ack(pid):
    v = getstate(PFX + ".ack.%d" % pid)
    return "ack #%d код 0x%x" % (v >> 32, v & 0xffffffff)


def pack(x, y, w, h):
    """4 × int16 в полупунктах (как hyprforce.m unpack)."""
    v = 0
    for i, c in enumerate((x, y, w, h)):
        v |= (int(round(c * 2)) & 0xffff) << (16 * i)
    return v


def frame(wid):
    """Рамка окна на сервере (CG, pt) — SLSGetWindowBounds, только чтение."""
    r = (ctypes.c_double * 4)()
    if sl.SLSGetWindowBounds(CID, wid, r) != 0:
        return None
    return tuple(round(v, 1) for v in r)


def watch(wid, dur, t0):
    last, out = None, []
    while time.time() - t0 < dur:
        f = frame(wid)
        if f != last:
            out.append(((time.time() - t0) * 1e3, f))
            last = f
        time.sleep(0.001)
    for t, f in out:
        print("%8.1f мс  %s" % (t, f))
    return out


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[0] == "cfg":
        pid, wid, mode = int(a[1]), int(a[2]), int(a[3])
        x, y, w, h = map(float, a[4:8])
        dur = float(a[8]) if len(a) > 8 else 1.5
        print("до:", frame(wid))
        setstate(PFX + ".cfgw.%d" % pid, wid | mode << 32)
        setstate(PFX + ".cfg.%d" % pid, pack(x, y, w, h))
        t0 = time.time()
        libc.notify_post((PFX + ".cfg.%d" % pid).encode())
        watch(wid, dur, t0)
        print(ack(pid))
    elif a[0] == "next":
        pid = int(a[1])
        setstate(PFX + ".next.%d" % pid, pack(*map(float, a[2:6])))
        print("ok")
    elif a[0] == "ax":                                  # тот же замер через AX демона (позиция→размер→позиция)
        ax = ctypes.CDLL(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../build/libax.dylib"))
        ax.ax_frame.argtypes = [ctypes.c_int, ctypes.c_uint] + [ctypes.c_double] * 4
        pid, wid = int(a[1]), int(a[2])
        x, y, w, h = map(float, a[3:7])
        dur = float(a[7]) if len(a) > 7 else 1.5
        print("до:", frame(wid))
        t0 = time.time()
        r = ax.ax_frame(pid, wid, x, y, w, h)
        print("ax_frame -> %d за %.1f мс" % (r, (time.time() - t0) * 1e3))
        watch(wid, dur, t0)
    elif a[0] == "ack":
        print(ack(int(a[1])))
    elif a[0] == "watch":
        watch(int(a[1]), float(a[2]) if len(a) > 2 else 2, time.time())
