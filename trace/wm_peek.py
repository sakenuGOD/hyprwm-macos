import lldb
t = lldb.debugger.GetSelectedTarget(); p = t.GetProcess(); err = lldb.SBError()
o = lldb.SBExpressionOptions(); o.SetLanguage(lldb.eLanguageTypeObjC_plus_plus); o.SetUnwindOnError(True); o.SetTimeoutInMicroSeconds(3000000)
ev = lambda e: t.EvaluateExpression(e, o)
r64 = lambda a: int.from_bytes(p.ReadMemory(a, 8, err), "little")
r32 = lambda a: int.from_bytes(p.ReadMemory(a, 4, err), "little")
def cls(a):
    if not a or a < 0x100000000: return "-"
    return ev('(char*)object_getClassName((id)0x%x)' % a).GetSummary()
C = 0x93ae5d540
print("PK pid:", r32(C + 0x30))
for off in (0x8, 0x48, 0x50, 0x58, 0x70, 0x78, 0x80, 0x88):
    v = r64(C + off); v2 = v & 0x0000ffffffffffff
    print("PK +0x%x = 0x%x  %s" % (off, v, cls(v2)))
lst = r64(C + 0x80) & 0x0000ffffffffffff
if lst:
    print("PK list desc:", (ev('(id)0x%x' % lst).GetObjectDescription() or "")[:1500])
