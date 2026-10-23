# Нативный resize окна изнутри WS: серверная форма + событие WindowMoved -> AppKit сам
# перечитывает frame, делает relayout и перерисовку (notes/resize_re.md, путь "б").
# /tmp/resize.args: строки "WID X Y W H" (глобальные точки, origin сверху-слева).
import lldb
t = lldb.debugger.GetSelectedTarget()

def ev(expr):
    r = t.EvaluateExpression(expr)
    e = r.GetError()
    if e.Fail() and "unknown error" not in (e.GetCString() or ""):
        raise RuntimeError("%s -> %s" % (expr[:100], e.GetCString()))
    return r.GetValueAsUnsigned()

def sym(name):
    # Mach-O хранит "__Z…"/"_C", lldb — без одного ведущего "_"
    for n in (name, name[1:] if name.startswith("_") else "_" + name):
        for s in t.FindSymbols(n):
            a = s.GetSymbol().GetStartAddress().GetLoadAddress(t)
            if a != lldb.LLDB_INVALID_ADDRESS: return a
    raise RuntimeError("нет символа " + name)

def fn(name, sig):   # указатель на локальную функцию, подписанный IA/0 — вызов через blraaz
    return "((%s)__builtin_ptrauth_sign_unauthenticated((void*)0x%x,0,0))" % (sig, sym(name))

BY_ID = fn("__ZL12window_by_idj", "void*(*)(unsigned int)")
SHAPE = fn("__ZN9CGXWindow22shape_window_with_rectE6CGRect22CGSWindowSaveWeighting",
           "void(*)(void*,double,double,double,double,long)")
MOVEV = fn("WSPackagesScheduleCoalescedWindowMoveEventIfNeeded", "void(*)(void*,unsigned long)")

for line in open("/tmp/resize.args").read().splitlines():
    p = line.split()
    if len(p) != 5: continue
    wid, x, y, w, h = int(p[0]), *map(float, p[1:])
    win = ev("(unsigned long)%s(%d)" % (BY_ID, wid))
    if not win:
        print("RESIZE wid=%d: окно не найдено" % wid); continue
    ev("%s((void*)0x%x,%r,%r,%r,%r,0); (int)0" % (SHAPE, win, x, y, w, h))
    ev("%s((void*)0x%x,0); (int)0" % (MOVEV, win))
    print("RESIZE wid=%d -> %g,%g %gx%g (win=0x%x)" % (wid, x, y, w, h, win))
