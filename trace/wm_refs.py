import lldb, re
dbg = lldb.debugger; t = dbg.GetSelectedTarget(); ci = dbg.GetCommandInterpreter()
o = lldb.SBExpressionOptions(); o.SetLanguage(lldb.eLanguageTypeObjC_plus_plus); o.SetUnwindOnError(True); o.SetTimeoutInMicroSeconds(3000000)
def cmd(c):
    r = lldb.SBCommandReturnObject(); ci.HandleCommand(c, r); return (r.GetOutput() or "") + (r.GetError() or "")
cmd("command script import lldb.macosx.heap")
s = cmd("ptr_refs 0x93ac32d80")
for line in s.splitlines()[:40]: print("REF|", line[:200])
