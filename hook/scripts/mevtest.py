# Вызвать Schedule для окна и сразу прочитать флаг pending (та же остановка процесса)
import lldb
t = lldb.debugger.GetSelectedTarget()
def sym(name):
    for n in (name, name[1:] if name.startswith("_") else "_" + name):
        for s in t.FindSymbols(n):
            a = s.GetSymbol().GetStartAddress().GetLoadAddress(t)
            if a != lldb.LLDB_INVALID_ADDRESS: return a
    raise RuntimeError(name)
def fn(name, sig): return "((%s)__builtin_ptrauth_sign_unauthenticated((void*)0x%x,0,0))" % (sig, sym(name))
def ev(e):
    r = t.EvaluateExpression(e); er = r.GetError()
    return r.GetValueAsSigned(), (er.GetCString() if er.Fail() else "OK")
BY_ID = fn("__ZL12window_by_idj", "void*(*)(unsigned int)")
PEND = fn("WSWindowIsMoveEventPending", "int(*)(void*)")
MOVEV = fn("WSPackagesScheduleCoalescedWindowMoveEventIfNeeded", "void(*)(void*,unsigned long)")
wid = int(open("/tmp/mevdiag.args").read().split()[0])
win, e0 = ev("(unsigned long)%s(%d)" % (BY_ID, wid))
print("MEV win=0x%x %s" % (win & 0xffffffffffffffff, e0))
print("MEV pending до:", ev("(int)%s((void*)0x%x)" % (PEND, win)))
print("MEV schedule:", ev("%s((void*)0x%x,0); (int)0" % (MOVEV, win)))
print("MEV pending после:", ev("(int)%s((void*)0x%x)" % (PEND, win)))
