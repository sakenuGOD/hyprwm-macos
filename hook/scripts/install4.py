# Установка движка v4 (src/anim4.c) в живой WindowServer — один attach lldb, дальше движок
# живёт сам и берёт команды из общей памяти /tmp/hyprwm/chan (её заранее создаёт демон: chan.Chan(create=True)).
# Состояние: hook/anim4.state "pid code ctx ch". Прошлую установку (v3/v4) снимает: узел из
# metalCallbacks убирается, старому v4 ставится ctx.dead=1 (его таймер перестаёт перепланироваться).
# Запуск: hook/run_lldb.sh hook/scripts/install4.py
import json
import os
import struct

import lldb

HOOK = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHAN = open("/tmp/hyprwm/chan_path").read().strip()     # новый файл на каждую установку (chan.py)
KEY = 0x30000000
SHAPE_OFF = 0x170       # CGXWindow -> CGSRegion формы (WSWindowGetScreenRect, macOS 26.7.1)

t = lldb.debugger.GetSelectedTarget()
proc = t.GetProcess()
err = lldb.SBError()
opt = lldb.SBExpressionOptions()
opt.SetIgnoreBreakpoints(True)
opt.SetTimeoutInMicroSeconds(3000000)


def ev(expr):
    r = t.EvaluateExpression(expr, opt)
    e = r.GetError()
    if e.Fail() and "unknown error" not in (e.GetCString() or ""):
        raise RuntimeError("%s -> %s" % (expr[:90], e.GetCString()))
    return r.GetValueAsUnsigned()


def sym(name):
    for s in t.FindSymbols(name):
        a = s.GetSymbol().GetStartAddress().GetLoadAddress(t)
        if a != lldb.LLDB_INVALID_ADDRESS:
            return a
    raise RuntimeError("нет символа " + name)


def sign(a):
    return ev("(unsigned long)__builtin_ptrauth_sign_unauthenticated((void*)0x%x,0,0)" % a)


def r64(a): return int.from_bytes(proc.ReadMemory(a, 8, err), "little")
def w(a, b): proc.WriteMemory(a, b, err)
def w64(a, v): w(a, int(v).to_bytes(8, "little"))
def w32(a, v): w(a, int(v).to_bytes(4, "little"))


pid = proc.GetProcessID()
head = sym("metalCallbacks")

# ── снять прошлые установки ──────────────────────────────────────────────
old_ctx = set()
for f, idx in (("anim.state", 2), ("anim4.state", 2)):
    p = os.path.join(HOOK, f)
    if os.path.exists(p):
        s = open(p).read().split()
        if len(s) > idx and int(s[0]) == pid:
            old_ctx.add(int(s[idx], 16))
            if f == "anim4.state":
                w32(int(s[idx], 16) + 0x74, 1)          # ctx.dead = 1
prev, cur = head, r64(head)
while cur:
    nxt = r64(cur)
    if r64(cur + 16) in old_ctx:
        w64(prev, nxt)
        print("INST снят узел 0x%x (ctx 0x%x)" % (cur, r64(cur + 16)))
    else:
        prev = cur
    cur = nxt

# ── код ──────────────────────────────────────────────────────────────────
meta = json.load(open(os.path.join(HOOK, "anim4.syms")))
blob = open(os.path.join(HOOK, "anim4.bin"), "rb").read()
code = ev("(unsigned long)mmap(0,%d,3,0x1002,-1,0)" % meta["vmsize"])
ctx = ev("(unsigned long)mmap(0,16384,3,0x1002,-1,0)")
for off in range(0, len(blob), 512):
    w(code + off, blob[off:off + 512])
if ev("(int)mprotect((void*)0x%x,%d,5)" % (code, meta["vmsize"])) != 0:
    raise RuntimeError("mprotect")
tick = code + meta["syms"]["anim_tick"]
frame_fn = code + meta["syms"]["anim_frame"]

# ── общая память ─────────────────────────────────────────────────────────
size = (os.path.getsize(CHAN) + 0x3fff) & ~0x3fff
fd = ev('(int)open("%s", 2)' % CHAN) & 0xffffffff
if fd >= 0x80000000:
    raise RuntimeError("WS не открыл " + CHAN)
ch = ev("(unsigned long)mmap(0,%d,3,1,%d,0)" % (size, fd))
ev("(int)close(%d)" % fd)
if ch in (0, 0xffffffffffffffff):
    raise RuntimeError("mmap канала")
if int.from_bytes(proc.ReadMemory(ch + 0xc, 4, err), "little") > os.path.getsize(CHAN):
    raise RuntimeError("канал меньше структуры движка — не ставлю")
if r64(ch) != 0x3530574d52505948:
    raise RuntimeError("в канале нет магии HYPRWM05 — сначала chan.Chan(create=True)")

# ── ctx ──────────────────────────────────────────────────────────────────
w64(ctx + 0x00, sign(sym("CGXSetWindowTransform3DList")))
w64(ctx + 0x08, sign(sym("reschedule_callback_on_session")))
w64(ctx + 0x10, sign(tick))
w64(ctx + 0x18, sym("gMainThreadQueue"))
w64(ctx + 0x20, r64(r64(sym("__sessionControlRef")) + 0x20))
w64(ctx + 0x28, sign(sym("CGXWindowByID")))
w64(ctx + 0x30, sign(sym("CGRegionGetBoundingBox")))
w64(ctx + 0x38, sign(sym("CGXMoveWindowList")))
w64(ctx + 0x40, sign(sym("CGXSetWindowListAlpha")))
for i, name in enumerate(("exp", "sin", "cos")):
    p = ev('(unsigned long)dlsym((void*)-2,"%s")' % name)        # уже подписан IA/0
    if not p:
        raise RuntimeError("dlsym " + name)
    w64(ctx + 0x48 + 8 * i, p)
w64(ctx + 0x60, ch)
w32(ctx + 0x68, KEY)
w32(ctx + 0x6c, 0)
w32(ctx + 0x70, SHAPE_OFF)
w32(ctx + 0x74, 0)
w64(ctx + 0x78, sign(sym("WSDisplayScheduleGetPrevNextVBL")))
w32(ctx + 0x80, int(open("/tmp/hyprwm/display").read()) if os.path.exists("/tmp/hyprwm/display") else 1)
w64(ctx + 0x88, sign(sym("_ZN9CGXWindow33set_window_list_global_clip_shapeEP13CGXConnectionP15CGSRegionObjectPKjj")))
w64(ctx + 0x90, sign(sym("CGRegionCreateWithRect")))
w64(ctx + 0x98, sign(sym("CFRelease")))
w64(ctx + 0xa0, sign(sym("_ZNK9CGXWindow22resolved_corner_radiusEv")))
w64(ctx + 0xa8, sign(sym("CGRegionCreateDifferenceWithRegion")))


ev("((void(*)(void*,void*,void*,void*,int,int,double))reschedule_callback_on_session)"
   "((void*)0x%x,(void*)0x%x,(void*)0x%x,(void*)0x%x,1,1,((double(*)(void))SLSCurrentRealTime)()+0.01); (int)0"
   % (sym("gMainThreadQueue"), sign(tick), ctx, r64(ctx + 0x20)))

import hashlib
build = hashlib.sha1(blob).hexdigest()[:12]
open(os.path.join(HOOK, "anim4.state"), "w").write("%d %x %x %x %s\n" % (pid, code, ctx, ch, build))
print("INST v4 установлен: pid=%d code=0x%x ctx=0x%x ch=0x%x" % (pid, code, ctx, ch))
