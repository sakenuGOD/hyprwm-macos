import lldb
t = lldb.debugger.GetSelectedTarget(); proc = t.GetProcess(); err = lldb.SBError()
opt = lldb.SBExpressionOptions(); opt.SetIgnoreBreakpoints(True); opt.SetTimeoutInMicroSeconds(3000000)
def ev(e):
    r = t.EvaluateExpression(e, opt); return r.GetValue() or r.GetSummary() or str(r.GetError().GetCString())
def r64(a): return int.from_bytes(proc.ReadMemory(a, 8, err), "little")
wid = int(open("/tmp/hyprwm/p4_mask").read().split()[0])
win = int(ev("(unsigned long)CGXWindowByID(%d)" % wid), 0) if ev("(unsigned long)CGXWindowByID(%d)" % wid).startswith("0x") else int(ev("(unsigned long)CGXWindowByID(%d)" % wid))
cwc = r64(win + 0x18); H = r64(cwc + 0x98); ctx = r64(cwc + 0x38)
print("P4 mask", ev("(unsigned long)((id(*)(id,SEL))objc_msgSend)((id)0x%x, @selector(mask))" % H))
print("P4 thread", ev("(int)pthread_main_np()"))
print("P4 currentState", ev("(unsigned long)((id(*)(id,SEL))objc_msgSend)((id)NSClassFromString(@\"CATransaction\"), @selector(currentState))"))
print("P4 ctx layer", ev("(unsigned long)((id(*)(id,SEL))objc_msgSend)((id)0x%x, @selector(layer))" % ctx), "root", hex(r64(cwc + 0x80)))
print("P4 desc", ev("(char*)((const char*(*)(id,SEL))objc_msgSend)(((id(*)(id,SEL))objc_msgSend)((id)0x%x, @selector(debugDescription)), @selector(UTF8String))" % H)[:300])
