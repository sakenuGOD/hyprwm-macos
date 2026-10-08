# Повесить узел anim_frame движка v4 в metalCallbacks (если его ещё нет).
import json, os, lldb
HOOK = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
t = lldb.debugger.GetSelectedTarget(); p = t.GetProcess(); err = lldb.SBError()
o = lldb.SBExpressionOptions(); o.SetIgnoreBreakpoints(True); o.SetTimeoutInMicroSeconds(3000000)
pid, code, ctx, ch = open(os.path.join(HOOK, "anim4.state")).read().split()
code, ctx = int(code, 16), int(ctx, 16)
assert int(pid) == p.GetProcessID()
meta = json.load(open(os.path.join(HOOK, "anim4.syms")))
head = [s.GetSymbol().GetStartAddress().GetLoadAddress(t) for s in t.FindSymbols("metalCallbacks")][0]
def r64(a): return p.ReadPointerFromMemory(a, err)
def w64(a, v): p.WriteMemory(a, int(v).to_bytes(8, "little"), err)
cur = r64(head)
while cur:
    if r64(cur + 16) == ctx:
        print("NODE уже есть 0x%x" % cur); break
    cur = r64(cur)
else:
    fn = t.EvaluateExpression("(unsigned long)__builtin_ptrauth_sign_unauthenticated((void*)0x%x,0,0)" % (code + meta["syms"]["anim_frame"]), o).GetValueAsUnsigned()
    node = ctx + 0x1000
    w64(node, r64(head)); w64(node + 8, fn); w64(node + 16, ctx); w64(head, node)
    print("NODE добавлен 0x%x" % node)
