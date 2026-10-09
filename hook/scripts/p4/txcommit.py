# Закрыть застрявший уровень CATransaction на главном потоке WS (после упавшего выражения lldb между begin и commit).
import lldb
t = lldb.debugger.GetSelectedTarget()
opt = lldb.SBExpressionOptions(); opt.SetIgnoreBreakpoints(True); opt.SetTimeoutInMicroSeconds(3000000)
def ev(e):
    r = t.EvaluateExpression(e, opt); return r.GetValue() or str(r.GetError().GetCString())
print("P4 main", ev("(int)pthread_main_np()"))
print("P4 T", ev('unsigned long $T = (unsigned long)NSClassFromString(@"CATransaction"); $T'))
print("P4 commit", ev('((void(*)(id,SEL))objc_msgSend)((id)$T, @selector(commit)); (int)0'))
print("P4 disableActions", ev('(int)((BOOL(*)(id,SEL))objc_msgSend)((id)$T, @selector(disableActions))'))
