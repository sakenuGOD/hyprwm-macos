import lldb
t = lldb.debugger.GetSelectedTarget()
opt = lldb.SBExpressionOptions(); opt.SetIgnoreBreakpoints(True); opt.SetTimeoutInMicroSeconds(3000000)
def ev(e):
    r = t.EvaluateExpression(e, opt); return r.GetValue() or str(r.GetError().GetCString())
print("P4 main", ev("(int)pthread_main_np()"))
print("P4 thread", t.GetProcess().GetSelectedThread().GetIndexID(), t.GetProcess().GetSelectedThread().GetFrameAtIndex(0).GetFunctionName())
print("P4 disableActions", ev('(int)((BOOL(*)(id,SEL))objc_msgSend)((id)NSClassFromString(@"CATransaction"), @selector(disableActions))'))
