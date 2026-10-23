import lldb
t = lldb.debugger.GetSelectedTarget(); p = t.GetProcess(); err = lldb.SBError()
o = lldb.SBExpressionOptions(); o.SetLanguage(lldb.eLanguageTypeObjC_plus_plus); o.SetUnwindOnError(True); o.SetTimeoutInMicroSeconds(4000000)
ev = lambda e: t.EvaluateExpression(e, o)
D = 0x93aefea00
print("PK2 count:", ev('(long)[(id)0x%x count]' % D).GetValueAsSigned())
d = ev('(id)[(id)0x%x description]' % D).GetObjectDescription() or ""
for line in d.splitlines()[:40]: print("PK2|", line[:220])
M = 0x93ac32d80
r64 = lambda a: int.from_bytes(p.ReadMemory(a, 8, err), "little")
ac = r64(M + 0x18) & 0x0000ffffffffffff
print("PK2 mgr.activeConnections class:", ev('(char*)object_getClassName((id)0x%x)' % ac).GetSummary(), hex(ac))
print("PK2 active count:", ev('(long)[(id)0x%x count]' % ac).GetValueAsSigned())
