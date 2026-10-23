# Плавный переезд окон внутри WindowServer: реальная позиция ставится сразу
# (CGXMoveWindowList), визуальный сдвиг гасится пружиной Hyprland в нашем коде (src/anim.c).
# Шаг анимации привязан к кадру: anim_frame висит в metalCallbacks и ставит anim_tick
# в очередь главного потока; на кадр приходится ровно один шаг.
#
# Задания: /tmp/anim.args — строки "WID DX DY" (дельты в точках) или "WID=.. DX=.. DY=..".
# Опции там же: K=210 D=24 (пружина), EPS=0.001.
# Состояние в живом WS: hook/anim.state "pid code ctx ver".
# Снять хук: записать 0 в head metalCallbacks (scripts/unhook.py) с подтверждённым обратным действием.
import json, os, struct
import lldb

HOOK = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VER = "v3"
KEY = 0x30000000          # слот стека трансформов (его же шлёт клиентский путь)
FRAME = 1.0 / 60          # dt первого шага, дальше реальный dt между кадрами

t = lldb.debugger.GetSelectedTarget()
proc = t.GetProcess()
err = lldb.SBError()

O_K, O_D, O_LAST, O_KEY, O_N, O_FRAME = 40, 48, 56, 64, 68, 72
O_TICKS, O_RUN, O_EXP, O_SIN, O_COS, O_EPS, O_ONE, O_W = 80, 84, 88, 96, 104, 112, 120, 128
W_SZ = 48
W_WID, W_ACT, W_X0, W_Y0, W_V, W_VEL = 0, 4, 8, 16, 24, 32


def ev(expr):
    r = t.EvaluateExpression(expr)
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


def r(a, n): return proc.ReadMemory(a, n, err)
def w(a, b): proc.WriteMemory(a, b, err)
def r64(a): return int.from_bytes(r(a, 8), "little")
def r32(a): return int.from_bytes(r(a, 4), "little")
def rd(a): return struct.unpack("<d", r(a, 8))[0]
def w64(a, v): w(a, int(v).to_bytes(8, "little"))
def w32(a, v): w(a, int(v).to_bytes(4, "little"))
def wd(a, v): w(a, struct.pack("<d", float(v)))


# ---- задания ------------------------------------------------------------
jobs, opt = [], {}
for line in open("/tmp/anim.args").read().splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    if "=" in line:
        kv = dict(p.split("=", 1) for p in line.split())
        if "WID" in kv:
            jobs.append((int(kv["WID"]), float(kv.get("DX", 0)), float(kv.get("DY", 0))))
        else:
            opt.update(kv)
    else:
        p = line.split()
        jobs.append((int(p[0]), float(p[1]), float(p[2])))
# пружина: из аргументов, иначе из конфига Hyprland (лист windowsMove), иначе drift
try:
    import sys as _sys
    _sys.path.insert(0, os.path.join(HOOK, "config"))
    import hyprcfg
    _sp = hyprcfg.spring("windowsMove") or (1.0, 210.0, 24.0)
except Exception as _e:
    print("ANIM конфиг недоступен (%s), drift по умолчанию" % _e)
    _sp = (1.0, 210.0, 24.0)
K = float(opt.get("K", _sp[1])); D = float(opt.get("D", _sp[2])); EPS = float(opt.get("EPS", 0.001))

# ---- установка кода -----------------------------------------------------
pid = proc.GetProcessID()
sp = os.path.join(HOOK, "anim.state")
state = None
if os.path.exists(sp):
    s = open(sp).read().split()
    if len(s) >= 4 and int(s[0]) == pid and s[3] == VER:
        state = (int(s[1], 16), int(s[2], 16))

if state is None:
    meta = json.load(open(os.path.join(HOOK, "anim.syms")))
    blob = open(os.path.join(HOOK, "anim.bin"), "rb").read()
    code = ev("(unsigned long)mmap(0,%d,3,0x1002,-1,0)" % meta["vmsize"])
    ctx = ev("(unsigned long)mmap(0,16384,3,0x1002,-1,0)")
    for off in range(0, len(blob), 512):          # запись кусками: длинные выражения lldb не любит
        w(code + off, blob[off:off + 512])
    ev("(int)mprotect((void*)0x%x,%d,5)" % (code, meta["vmsize"]))
    tick = code + meta["syms"]["anim_tick"]
    frame_fn = code + meta["syms"]["anim_frame"]

    w64(ctx + 0, sign(sym("CGXSetWindowTransform3DList")))
    w64(ctx + 8, sign(sym("reschedule_callback_on_session")))
    w64(ctx + 16, sign(tick))
    w64(ctx + 24, sym("gMainThreadQueue"))
    scr = r64(sym("__sessionControlRef"))
    w64(ctx + 32, r64(scr + 0x20))                # session: как делает scheduleDragFadeTimer
    w32(ctx + O_KEY, KEY); w32(ctx + O_N, 0); wd(ctx + O_FRAME, FRAME); wd(ctx + O_ONE, 1.0)
    for name, off in (("exp", O_EXP), ("sin", O_SIN), ("cos", O_COS)):
        p = ev('(unsigned long)dlsym((void*)-2,"%s")' % name)   # уже подписан IA/0
        if not p:
            raise RuntimeError("dlsym " + name)
        w64(ctx + off, p)

    head = sym("metalCallbacks")
    # снять наши прошлые узлы (другая версия кода/ctx), чужие не трогать
    if os.path.exists(sp):
        old = open(sp).read().split()
        if len(old) >= 3 and int(old[0]) == pid:
            old_ctx = int(old[2], 16)
            prev, cur = head, r64(head)
            while cur:
                nxt = r64(cur)
                if r64(cur + 16) == old_ctx:
                    w64(prev, nxt); print("ANIM снят старый узел 0x%x" % cur)
                else:
                    prev = cur
                cur = nxt

    node = ctx + 0x1000                            # узел metalCallbacks {next, fn IA/0, ctx}
    w64(node, r64(head)); w64(node + 8, sign(frame_fn)); w64(node + 16, ctx)
    w64(head, node)

    open(sp, "w").write("%d %x %x %s\n" % (pid, code, ctx, VER))
    print("ANIM установлен: code=0x%x ctx=0x%x" % (code, ctx))
    state = (code, ctx)

code, ctx = state
wd(ctx + O_K, K); wd(ctx + O_D, D); wd(ctx + O_EPS, EPS)

# ---- постановка заданий -------------------------------------------------
for wid, dx, dy in jobs:
    n = r32(ctx + O_N)
    slot = next((i for i in range(n) if r32(ctx + O_W + i * W_SZ + W_WID) == wid), None)
    if slot is None:
        if n >= 16:
            raise RuntimeError("слотов больше нет")
        slot = n; w32(ctx + O_N, n + 1)
    wb = ctx + O_W + slot * W_SZ

    # текущий визуальный сдвиг (если окно уже едет) — чтобы не было скачка
    if r32(wb + W_ACT):
        v = rd(wb + W_V)
        ox, oy = rd(wb + W_X0) * (1.0 - v), rd(wb + W_Y0) * (1.0 - v)
    else:
        ox = oy = 0.0

    ev("unsigned int w=%d; ((void(*)(void*,unsigned int*,int,long,float,float))CGXMoveWindowList)"
       "((void*)0,&w,1,(long)0,(float)%r,(float)%r); (int)0" % (wid, dx, dy))

    x0, y0 = ox - dx, oy - dy
    w32(wb + W_WID, wid); wd(wb + W_X0, x0); wd(wb + W_Y0, y0)
    wd(wb + W_V, 0.0); wd(wb + W_VEL, 0.0); w32(wb + W_ACT, 1)
    # кадр 0: окно визуально остаётся на старом месте
    ev("unsigned int w=%d; unsigned int k=%u; double m[16]={1,0,0,0, 0,1,0,0, 0,0,1,0, %r,%r,0,1};"
       "((void(*)(void*,unsigned int*,unsigned int*,double*))CGXSetWindowTransform3DList)"
       "((void*)0,&w,&k,m); (int)0" % (wid, KEY, -x0, -y0))
    print("ANIM wid=%d d=(%g,%g) сдвиг=(%g,%g) слот=%d" % (wid, dx, dy, x0, y0, slot))

if jobs and not r32(ctx + O_RUN):
    w32(ctx + O_RUN, 1); wd(ctx + O_LAST, 0.0)
    ev("((void(*)(void*,void*,void*,void*,int,int,double))reschedule_callback_on_session)"
       "((void*)0x%x,(void*)0x%x,(void*)0x%x,(void*)0x%x,1,1,"
       "((double(*)(void))SLSCurrentRealTime)()+%r); (int)0"
       % (sym("gMainThreadQueue"), sign(code + json.load(open(os.path.join(HOOK, "anim.syms")))["syms"]["anim_tick"]),
          ctx, r64(ctx + 32), FRAME))
print("ANIM тиков всего: %d" % r32(ctx + O_TICKS))
