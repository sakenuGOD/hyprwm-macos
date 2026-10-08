import lldb
t = lldb.debugger.GetSelectedTarget(); p = t.GetProcess(); err = lldb.SBError()
o = lldb.SBExpressionOptions(); o.SetLanguage(lldb.eLanguageTypeObjC_plus_plus); o.SetUnwindOnError(True); o.SetTimeoutInMicroSeconds(3000000)
ev = lambda e: t.EvaluateExpression(e, o)
print("IV client class:", ev('(char*)object_getClassName((id)0x93ae5d540)').GetSummary())
for cls in ("_TtC18WindowManagerAgent27AppKitApplicationConnection",
            "_TtC18WindowManagerAgent34AppKitApplicationConnectionManager",
            "_TtC18WindowManagerAgent6Window"):
    n = ev('unsigned int n=0; void **l=(void**)class_copyIvarList((Class)objc_getClass("%s"), &n); (unsigned long)n' % cls).GetValueAsUnsigned()
    print("IV ===", cls, "полей:", n)
    for i in range(n):
        nm = ev('unsigned int n=0; void **l=(void**)class_copyIvarList((Class)objc_getClass("%s"), &n); (char*)ivar_getName(l[%d])' % (cls, i)).GetSummary()
        of = ev('unsigned int n=0; void **l=(void**)class_copyIvarList((Class)objc_getClass("%s"), &n); (long)ivar_getOffset(l[%d])' % (cls, i)).GetValueAsSigned()
        print("IV   +0x%x %s" % (of, nm))
