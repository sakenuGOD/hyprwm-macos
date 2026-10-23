# Диагностика: флаг "move event pending" у окон из /tmp/mevdiag.args (wid через пробел)
import lldb
t = lldb.debugger.GetSelectedTarget()
def sym(name):
    for n in (name, name[1:] if name.startswith("_") else "_" + name):
        for s in t.FindSymbols(n):
            a = s.GetSymbol().GetStartAddress().GetLoadAddress(t)
            if a != lldb.LLDB_INVALID_ADDRESS: return a
    raise RuntimeError(name)
def fn(name, sig): return "((%s)__builtin_ptrauth_sign_unauthenticated((void*)0x%x,0,0))" % (sig, sym(name))
BY_ID = fn("__ZL12window_by_idj", "void*(*)(unsigned int)")
PEND = fn("WSWindowIsMoveEventPending", "int(*)(void*)")
for wid in open("/tmp/mevdiag.args").read().split():
    win = t.EvaluateExpression("(unsigned long)%s(%s)" % (BY_ID, wid)).GetValueAsUnsigned()
    p = t.EvaluateExpression("(int)%s((void*)0x%x)" % (PEND, win)).GetValueAsSigned() if win else -1
    print("MEV wid=%s win=0x%x pending=%d" % (wid, win, p))
