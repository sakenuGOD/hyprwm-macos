"""Стенд: захват ЭКРАНА (что видно глазами, с нашими трансформом/обрезкой) ~50 к/с во время сценария.
python3 scripts/rec2.py <сек> "<команда>" [выход]  -> кадры /tmp/rec2/f_XXX.png (1/4 размера) + лист.
CGDisplayCreateImage видит серверные трансформы и обрезку (как screencapture), в отличие от SCK-видео."""
import ctypes, os, subprocess, sys, time
cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
V = ctypes.c_void_p
cg.CGMainDisplayID.restype = ctypes.c_uint32
cg.CGDisplayCreateImage.restype = V; cg.CGDisplayCreateImage.argtypes = [ctypes.c_uint32]
cg.CGImageGetWidth.restype = ctypes.c_size_t; cg.CGImageGetWidth.argtypes = [V]
cg.CGImageGetHeight.restype = ctypes.c_size_t; cg.CGImageGetHeight.argtypes = [V]
cg.CGColorSpaceCreateDeviceRGB.restype = V
cg.CGBitmapContextCreate.restype = V
cg.CGBitmapContextCreate.argtypes = [V, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_size_t, V, ctypes.c_uint32]
class R(ctypes.Structure): _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double), ("w", ctypes.c_double), ("h", ctypes.c_double)]
cg.CGContextDrawImage.argtypes = [V, R, V]
cg.CGContextSetInterpolationQuality.argtypes = [V, ctypes.c_int]
cg.CGImageRelease.argtypes = [V]
dur = float(sys.argv[1]); cmd = sys.argv[2] if len(sys.argv) > 2 else None
out = sys.argv[3] if len(sys.argv) > 3 else "/tmp/rec2"
os.makedirs(out, exist_ok=True)
for f in os.listdir(out): os.unlink(os.path.join(out, f))
d = cg.CGMainDisplayID(); cs = cg.CGColorSpaceCreateDeviceRGB()
frames, t0, fired = [], time.time(), False
tf = t0
W = H = None
while time.time() - t0 < dur:
    if cmd and not fired and time.time() - t0 > 0.25:
        subprocess.Popen(cmd, shell=True); fired = True; tf = time.time()
    im = cg.CGDisplayCreateImage(d)
    t = time.time()
    if not W:
        W, H = cg.CGImageGetWidth(im) // 4, cg.CGImageGetHeight(im) // 4
    buf = ctypes.create_string_buffer(W * H * 4)
    cx = cg.CGBitmapContextCreate(buf, W, H, 8, W * 4, cs, 0x2001)    # BGRA premultiplied first
    cg.CGContextSetInterpolationQuality(cx, 1)
    cg.CGContextDrawImage(cx, R(0, 0, W, H), im)
    cf.CFRelease(V(cx)); cg.CGImageRelease(im)
    frames.append((t, buf.raw))
# запись: raw -> ffmpeg png
dts = [b[0] - a[0] for a, b in zip(frames, frames[1:])]
print("кадров %d за %.2f с, шаг ср %.1f мс, макс %.1f мс" % (len(frames), frames[-1][0] - frames[0][0],
      1000 * sum(dts) / len(dts), 1000 * max(dts)))
p = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "abgr", "-s", "%dx%d" % (W, H),
                      "-i", "-", os.path.join(out, "f_%03d.png")], stdin=subprocess.PIPE)
for t, b in frames: p.stdin.write(b)
p.stdin.close(); p.wait()
open(os.path.join(out, "times.txt"), "w").write("\n".join("%03d %.1f" % (i + 1, 1000 * (t - tf)) for i, (t, b) in enumerate(frames)))
print("кадры в", out, "; t=0 — запуск команды")
