import lldb
dbg = lldb.debugger; t = dbg.GetSelectedTarget(); p = t.GetProcess(); ci = dbg.GetCommandInterpreter(); err = lldb.SBError()
o = lldb.SBExpressionOptions(); o.SetLanguage(lldb.eLanguageTypeObjC_plus_plus); o.SetUnwindOnError(True)
def cmd(c):
    r = lldb.SBCommandReturnObject(); ci.HandleCommand(c, r); return (r.GetOutput() or "") + (r.GetError() or "")
cls = t.EvaluateExpression('(unsigned long)objc_getClass("_TtC18WindowManagerAgent34AppKitApplicationConnectionManager")', o).GetValueAsUnsigned()
isa = int.from_bytes(p.ReadMemory(0x93ac32d80, 8, err), "little")
print("DBG cls=0x%x isa_raw=0x%x isa_masked=0x%x" % (cls, isa, isa & 0x0000000ffffffff8))
cmd("command script import lldb.macosx.heap")
for v in (cls, isa & 0x0000ffffffffffff):
    s = cmd("ptr_refs --max-matches 8 0x%x" % v)
    print("DBG refs for 0x%x:" % v); [print("DBG|", l[:160]) for l in s.splitlines()[:6]]
