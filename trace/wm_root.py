import lldb
t = lldb.debugger.GetSelectedTarget(); p = t.GetProcess(); err = lldb.SBError()
o = lldb.SBExpressionOptions(); o.SetLanguage(lldb.eLanguageTypeObjC_plus_plus); o.SetUnwindOnError(True); o.SetTimeoutInMicroSeconds(3000000)
ev = lambda e: t.EvaluateExpression(e, o)
r64 = lambda a: int.from_bytes(p.ReadMemory(a, 8, err), "little") & 0x0000ffffffffffff
def cname(a):
    if a < 0x100000000: return "-"
    return ev('(char*)object_getClassName((id)0x%x)' % a).GetSummary()
def ivars(obj, depth, seen):
    c = cname(obj)
    if depth > 3 or obj in seen or not c or c == "-": return
    seen.add(obj)
    n = ev('unsigned int n=0; class_copyIvarList((Class)object_getClass((id)0x%x), &n); (unsigned long)n' % obj).GetValueAsUnsigned()
    for i in range(min(n, 40)):
        nm = ev('unsigned int n=0; void **l=(void**)class_copyIvarList((Class)object_getClass((id)0x%x), &n); (char*)ivar_getName(l[%d])' % (obj, i)).GetSummary()
        of = ev('unsigned int n=0; void **l=(void**)class_copyIvarList((Class)object_getClass((id)0x%x), &n); (long)ivar_getOffset(l[%d])' % (obj, i)).GetValueAsSigned()
        v = r64(obj + of); vc = cname(v) if v > 0x100000000 else "-"
        if vc and vc != "-" and "WindowManagerAgent" in (vc or ""):
            print("ROOT" + "  " * depth, "%s +0x%x %s = 0x%x %s" % (c, of, nm, v, vc))
            if "AppKitApplicationConnectionManager" in vc:
                print("ROOT FOUND manager path ->", hex(v)); return True
            if ivars(v, depth + 1, seen): return True
d = ev('(unsigned long)[(id)[(id)NSClassFromString(@"NSApplication") sharedApplication] delegate]').GetValueAsUnsigned()
print("ROOT delegate 0x%x %s" % (d, cname(d)))
ivars(d, 0, set())
