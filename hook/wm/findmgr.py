# lldb: найти AppKitApplicationConnectionManager в WindowManager (кэш в hook/wm.state по pid).
import lldb, re, os
dbg = lldb.debugger; t = dbg.GetSelectedTarget(); p = t.GetProcess(); ci = dbg.GetCommandInterpreter()
o = lldb.SBExpressionOptions(); o.SetLanguage(lldb.eLanguageTypeObjC_plus_plus); o.SetUnwindOnError(True); o.SetTimeoutInMicroSeconds(4000000)
ev = lambda e: t.EvaluateExpression(e, o)
STATE = "/Users/fsociety/Developer/re-tools/hook/wm.state"
def is_mgr(a):
    return a and ev('(char*)object_getClassName((id)0x%x)' % a).GetSummary() == '"WindowManagerAgent.AppKitApplicationConnectionManager"'
pid = p.GetProcessID(); mgr = None
if os.path.exists(STATE):
    s = open(STATE).read().split()
    if len(s) == 2 and int(s[0]) == pid and is_mgr(int(s[1], 16)): mgr = int(s[1], 16)
if mgr is None:
    r = lldb.SBCommandReturnObject(); ci.HandleCommand("command script import lldb.macosx.heap", r)
    cls = ev('(unsigned long)objc_getClass("_TtC18WindowManagerAgent34AppKitApplicationConnectionManager")').GetValueAsUnsigned()
    r = lldb.SBCommandReturnObject(); ci.HandleCommand("ptr_refs --max-matches 64 0x%x" % cls, r)
    for base in re.findall(r"-> (0x[0-9a-f]+) \+ 0\b", r.GetOutput() or ""):
        if is_mgr(int(base, 16)): mgr = int(base, 16); break
if mgr: open(STATE, "w").write("%d %x\n" % (pid, mgr)); print("FINDMGR 0x%x" % mgr)
else: print("FINDMGR none")
