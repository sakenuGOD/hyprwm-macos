import lldb, re
t = lldb.debugger.GetSelectedTarget()
o = lldb.SBExpressionOptions(); o.SetLanguage(lldb.eLanguageTypeObjC_plus_plus); o.SetUnwindOnError(True); o.SetTimeoutInMicroSeconds(4000000)
ev = lambda e: t.EvaluateExpression(e, o)
d = ev('(id)[(id)[(id)0x93aefea00 objectForKey:@"928D1C15-311B-4FD0-BA05-B34283297A70"] description]').GetObjectDescription() or ""
print("PK3 len", len(d))
for chunk in re.split(r",\s*", d): print("PK3|", chunk[:200])
