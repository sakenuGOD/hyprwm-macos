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
MAGIC = 0x3531574d52505948   # HYPRWM15 (src/chan.h)
# Жёсткие смещения в CGXWindow (0x30 соединение, 0x170 форма, 0x18 CAWindowContent) проверены только на
# этой сборке. На другой — не ставить: запись по чужому указателю внутри WS (P31).
BUILDS = {"25G241"}
import subprocess
_b = subprocess.run(["sw_vers", "-buildVersion"], capture_output=True, text=True).stdout.strip()
if _b not in BUILDS and not os.environ.get("HYPRWM_FORCE_BUILD"):
    raise RuntimeError("сборка macOS %s не проверена (есть %s) — сверить смещения и добавить в BUILDS" % (_b, BUILDS))

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


# Bounded compositor qualification on the existing engine. This explicit mode
# never runs the normal replacement path below and never changes anim_tick.
def observe_metal(mode):
    import hashlib
    import stat
    import tempfile
    import time

    if mode not in ("on", "off", "status"):
        raise RuntimeError("unknown compositor observer mode")
    module = [m for m in t.modules if m.GetFileSpec().fullpath.endswith("/SkyLight")]
    if len(module) != 1 or module[0].GetUUIDString().upper() != "CD5F2362-8462-38D4-8C57-0BCD4E04F962":
        raise RuntimeError("unqualified SkyLight observer ABI")
    if proc.GetState() != lldb.eStateStopped:
        raise RuntimeError("observer requires stopped process")

    def read(address, size):
        failure = lldb.SBError()
        data = proc.ReadMemory(address, size, failure)
        if failure.Fail() or len(data) != size:
            raise RuntimeError("observer bounded read failed")
        return data

    def write(address, data):
        failure = lldb.SBError()
        count = proc.WriteMemory(address, data, failure)
        if failure.Fail() or count != len(data):
            raise RuntimeError("observer bounded write failed")

    def get64(address): return struct.unpack("<Q", read(address, 8))[0]
    def put64(address, value): write(address, struct.pack("<Q", value))
    def evaluate(expression):
        result = t.EvaluateExpression(expression, opt)
        if not result.IsValid() or result.GetError().Fail() or result.GetValue() is None:
            raise RuntimeError("observer target expression failed")
        return result.GetValueAsUnsigned()
    def save_record(value, initial=False):
        fd, temporary = tempfile.mkstemp(prefix=".metal-observer-", dir=os.path.dirname(state_path))
        try:
            with os.fdopen(fd, "w") as output:
                json.dump(value, output); output.flush(); os.fsync(output.fileno())
            if initial:
                os.link(temporary, state_path)  # Exclusive, atomic first receipt.
            else:
                os.replace(temporary, state_path)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
    def initial_bytes(value):
        data = bytearray(struct.pack("<QIIQ", magic, 1, 1, value["is_main"])+bytes(0x60-24))
        struct.pack_into("<Q", data, 0x50, value["epoch"])
        return bytes(data), struct.pack("<QQQ", 0, value["function"], context)

    engine_path = os.environ.get("HYPRWM_OBSERVE_ENGINE_STATE", os.path.join(HOOK, "anim4.state"))
    state_path = os.environ.get("HYPRWM_OBSERVE_STATE", os.path.join(HOOK, "anim4.observe.json"))
    words = open(engine_path).read().split()
    if len(words) != 5 or int(words[0]) != proc.GetProcessID():
        raise RuntimeError("observer engine generation mismatch")
    context, channel = int(words[2], 16), int(words[3], 16)
    if (get64(context+0x60) != channel or get64(channel) != MAGIC or
            read(context+0x74, 4) != bytes(4) or read(context+0x68, 4) != struct.pack("<I", KEY)):
        raise RuntimeError("observer live engine identity refused")
    node, state = context+0x660, context+0x680
    magic = 0x3142534f4d575948
    head = sym("metalCallbacks")

    def chain():
        previous, current, seen, rows = head, get64(head), set(), []
        while current:
            if len(seen) >= 128 or current in seen or current < 0x100000000 or current & 7:
                raise RuntimeError("observer callback chain refused")
            seen.add(current)
            nxt, function, owner = struct.unpack("<QQQ", read(current, 24))
            rows.append((previous, current, nxt, function, owner))
            previous, current = current, nxt
        return rows

    rows = chain()
    record = None
    if os.path.lexists(state_path):
        info = os.lstat(state_path)
        if (not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or
                info.st_uid != os.geteuid() or info.st_size > 16384):
            raise RuntimeError("observer receipt file refused")
        record = json.load(open(state_path))
        if (record.get("schema") != 1 or record.get("pid") != proc.GetProcessID() or
                record.get("engine_state") != words or record.get("ctx") != context or record.get("node") != node or
                record.get("phase") not in ("preparing", "prepared") or
                not record.get("function") or not record.get("is_main") or not record.get("epoch")):
            raise RuntimeError("observer exact ownership refused")
    elif mode != "on":
        raise RuntimeError("observer has no owned receipt")

    owned = [row for row in rows if row[1] == node]
    if len(owned) > 1 or any(row[4] == context and row[1] != node for row in rows):
        raise RuntimeError("unexpected callback using engine context")
    if mode == "on" and not record:
        if owned or any(read(context+0x658, 0x800-0x658)):
            raise RuntimeError("observer private gap is occupied")
        meta = json.load(open(os.path.join(HOOK, "anim4.syms")))
        blob = open(os.path.join(HOOK, "anim4.bin"), "rb").read()
        if not 0 < len(blob) <= meta["vmsize"] <= 1048576 or not 0 < meta["syms"]["anim_observe_metal"] < len(blob):
            raise RuntimeError("observer image extent refused")
        code = evaluate("(unsigned long)mmap(0,%d,3,0x1002,-1,0)" % meta["vmsize"])
        if code in (0, 0xffffffffffffffff): raise RuntimeError("observer mmap failed")
        for offset in range(0, len(blob), 512): write(code+offset, blob[offset:offset+512])
        if evaluate("(int)mprotect((void*)0x%x,%d,5)" % (code, meta["vmsize"])) != 0:
            raise RuntimeError("observer mprotect failed")
        entry = code+meta["syms"]["anim_observe_metal"]
        function = evaluate("(unsigned long)__builtin_ptrauth_sign_unauthenticated((void*)0x%x,0,0)" % entry)
        # Host-only code-address comparison: arm64e signatures can occupy bit47.
        # Preserve the complete IA/0 signed pointer in the actual callback node.
        if not function or function & 0x00007fffffffffff != entry:
            raise RuntimeError("observer signed entry refused")
        region = lldb.SBMemoryRegionInfo()
        if proc.GetMemoryRegionInfo(entry, region).Fail() or not region.IsExecutable() or region.IsWritable():
            raise RuntimeError("observer image is not RX")
        is_main = evaluate('(unsigned long)dlsym((void*)-2,"pthread_main_np")')
        if not is_main: raise RuntimeError("observer pthread_main_np missing")
        epoch = time.monotonic_ns()
        record = {"schema": 1, "pid": proc.GetProcessID(), "engine_state": words, "ctx": context,
                  "node": node, "function": function, "code": code, "vmsize": meta["vmsize"],
                  "sha256": hashlib.sha256(blob).hexdigest(), "epoch": epoch,
                  "is_main": is_main, "phase": "preparing"}
        # Durable preparation receipt precedes writes. Until prepared is saved,
        # no callback can be published; partial zero-to-initial writes can retry.
        save_record(record, initial=True)
        rows = chain()  # Expressions above may run target code. Revalidate now.
        if any(row[1] == node or row[4] == context for row in rows):
            raise RuntimeError("observer callback changed during preparation")

    if record["phase"] == "preparing":
        expected_state, expected_node = initial_bytes(record)
        if owned or any(a not in (0, b) for a, b in zip(read(state, 0x60), expected_state)) or any(
                a not in (0, b) for a, b in zip(read(node, 24), expected_node)):
            raise RuntimeError("observer partial preparation does not match receipt")
        if mode == "status":
            print("METAL_OBSERVER "+json.dumps({"mode": mode, "attached": False, "phase": "preparing"}))
            return
        write(state, expected_state); write(node, expected_node)
        if read(state, 0x60) != expected_state or read(node, 24) != expected_node:
            raise RuntimeError("observer preparation readback failed")
        record["phase"] = "prepared"
        save_record(record)
    if (get64(state) != magic or read(state+8, 4) != struct.pack("<I", 1) or
            get64(state+0x10) != record["is_main"] or get64(state+0x50) != record["epoch"] or
            get64(node+8) != record["function"] or get64(node+16) != context):
        raise RuntimeError("observer initialized ownership refused")
    if mode == "on":
        if not owned: put64(node, get64(head))
        write(state+0xc, struct.pack("<I", 0))
        if not owned: put64(head, node)  # Publish LAST; no target expression follows.
    elif mode == "off":
        write(state+0xc, struct.pack("<I", 1))
        if owned: put64(owned[0][0], owned[0][2])
        # Keep mapping: a stopped callback may still have its return PC in it.
    present = any(row[1] == node for row in chain())
    values = struct.unpack("<QII"+"Q"*10, read(state, 0x60))
    print("METAL_OBSERVER "+json.dumps({"mode": mode, "attached": present, "dead": values[2],
          "callbacks": values[4], "main": values[5], "other": values[6], "first_tick": values[7],
          "last_tick": values[8], "nonzero_third_arg": values[12], "image_sha256": record["sha256"]}))


_observe_mode = os.environ.get("HYPRWM_OBSERVE_METAL")
if _observe_mode:
    observe_metal(_observe_mode)
    raise SystemExit(0)


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
if r64(ch) != MAGIC:
    raise RuntimeError("в канале нет магии HYPRWM15 — сначала chan.Chan(create=True)")

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
_ma = ev('(unsigned long)dlsym((void*)-2,"mach_absolute_time")')    # подписан IA/0, как exp/sin/cos
if not _ma:
    raise RuntimeError("dlsym mach_absolute_time")
w64(ctx + 0xb0, _ma)
import ctypes
class _TB(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
_tb = _TB()
ctypes.CDLL("/usr/lib/libSystem.B.dylib").mach_timebase_info(ctypes.byref(_tb))
w(ctx + 0xb8, struct.pack("<d", _tb.numer / _tb.denom / 1000.0))   # мкс на mach-тик
# П4: ObjC/CA и транзакция WS (указатели из dlsym уже подписаны IA/0, символы WS — sign())
for off, name in ((0xc0, "objc_msgSend"), (0xc8, "sel_registerName"), (0xd0, "objc_getClass"), (0xd8, "CGColorCreateSRGB")):
    p = ev('(unsigned long)dlsym((void*)-2,"%s")' % name)
    if not p:
        raise RuntimeError("dlsym " + name)
    w64(ctx + off, p)
w64(ctx + 0xe0, sign(sym("_ZN27WSCAContextScopeTransactionC1E19WSCAScopeParameters")))
w64(ctx + 0xe8, sign(sym("_ZN27WSCAContextScopeTransaction18addContextToCommitEP9CAContext")))
w64(ctx + 0xf0, sign(sym("_ZN27WSCAContextScopeTransactionD1Ev")))
# перенос окна на стол изнутри WS (OP_SPACE)
w64(ctx + 0x148, sign(sym("PKGSpaceForID")))
w64(ctx + 0x150, sign(sym("window_ordering_group_list_create_from_window_id_array")))
w64(ctx + 0x158, sign(sym("PKGWindowsMoveToManagedSpace")))
_fr = ev('(unsigned long)dlsym((void*)-2,"free")')
if not _fr:
    raise RuntimeError("dlsym free")
w64(ctx + 0x160, _fr)
w64(ctx + 0x280, sign(sym("CGXScheduleUpdateDisplaysIntersectingWindow")))
w64(ctx + 0x338, sign(sym("CGXOrderWindow")))
w64(ctx + 0x3b0, sign(sym("_ZN9CGXWindow20set_window_list_tagsEP13CGXConnectionPKPS_m18WSWindowTagBitMaskb")))
w64(ctx + 0x3c0, sign(sym("WSPostNotificationToConnection")))   # OP_CFG (native_hooks §1)
w64(ctx + 0x3c8, sign(sym("CGXWindowGetOwner")))
try:                                             # невидимая тень override-ом (beyond_bounds §1.7); нет — режим 2
    w64(ctx + 0x3d8, sign(sym("WSWindowSetWindowManagerShadowProperties")))
    w64(ctx + 0x3e0, sign(sym("WSWindowInvalidateShadowFrame")))
    w64(ctx + 0x3e8, sign(sym("_ZN9CGXWindow37invalidate_shadow_and_schedule_updateEP13CGXConnection")))
except Exception as e:
    print("override тени выключен:", e)
    for off in (0x3d8, 0x3e0, 0x3e8):
        w64(ctx + off, 0)
# native_hooks §5.2: при свайпе столов WS рисует окна из плоской копии (FlatteningPolicy swipe) — Telegram на
# минимуме «стирался». 1 = set_should_flatten_barring_change (меняющееся окно рисуется живым). Пользователь
# проверил 2026-10-09 16:25 («всё норм»). Отладочный байт SkyLight, живёт до перезапуска WS.
try:
    w(sym("_ZN7cgdebugL28allow_unflatten_during_swipeE"), b"\x01")
except Exception as e:
    print("allow_unflatten_during_swipe:", e)
# П8 снимок закрытия (необязательно: нет символа — П8 выключен, движок ставится)
try:
    for off, name in ((0x340, "_ZL19CreateCloneOfWindowP9CGXWindow6CGRectPK10PKGDisplayb"),
                      (0x348, "_ZNK9CGXWindow21screen_rect_from_rectE6CGRect"), (0x350, "PKGWindowGetDisplay"),
                      (0x358, "PKGDisplayGetMain"), (0x360, "_ZN9CGXWindow18set_level_internalEP13CGXConnectionis"),
                      (0x368, "_ZN9CGXWindow14release_windowEP13CGXConnectionPS_"),
                      (0x370, "WSAddNotificationCallback"), (0x378, "WSRemoveNotificationCallback"),
                      (0x388, "WSWindowGetID")):
        w64(ctx + off, sign(sym(name)))
    w64(ctx + 0x380, sign(code + meta["syms"]["anim_will_release"]))   # paciza: blraaz в invoke_callbacks
except Exception as e:
    print("П8 выключен:", e)
    for off in range(0x340, 0x390, 8):
        w64(ctx + off, 0)
w64(ctx + 0x228, sign(sym("_ZN9CGXWindow23set_debug_corner_radiusEd")))
w64(ctx + 0x230, sign(sym("_ZN9CGXWindow25clear_debug_corner_radiusEv")))
# П6 тень: путь скруглённого прямоугольника (CoreGraphics, dlsym — уже подписаны)
for off, name in ((0x218, "CGPathCreateWithRoundedRect"), (0x220, "CGPathRelease"), (0x238, "CGPathCreateMutable"),
                  (0x240, "CGPathAddRoundedRect"), (0x248, "CGPathAddRect")):
    p = ev('(unsigned long)dlsym((void*)-2,"%s")' % name)
    if not p:
        raise RuntimeError("dlsym " + name)
    w64(ctx + off, p)


ev("((void(*)(void*,void*,void*,void*,int,int,double))reschedule_callback_on_session)"
   "((void*)0x%x,(void*)0x%x,(void*)0x%x,(void*)0x%x,1,1,((double(*)(void))SLSCurrentRealTime)()+0.01); (int)0"
   % (sym("gMainThreadQueue"), sign(tick), ctx, r64(ctx + 0x20)))

import hashlib
build = hashlib.sha1(blob).hexdigest()[:12]
open(os.path.join(HOOK, "anim4.state"), "w").write("%d %x %x %x %s\n" % (pid, code, ctx, ch, build))
print("INST v4 установлен: pid=%d code=0x%x ctx=0x%x ch=0x%x" % (pid, code, ctx, ch))
