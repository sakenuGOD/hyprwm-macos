import lldb
t = lldb.debugger.GetSelectedTarget()
o = lldb.SBExpressionOptions(); o.SetLanguage(lldb.eLanguageTypeObjC_plus_plus); o.SetUnwindOnError(True); o.SetTimeoutInMicroSeconds(3000000)
for e in [
  '(void*)((id(*)(const char*))objc_getClass)("NSUUID")',
  '(void*)((SEL(*)(const char*))sel_registerName)("UUID")',
  '(void*)((id(*)(id,SEL))objc_msgSend)(((id(*)(const char*))objc_getClass)("NSUUID"), ((SEL(*)(const char*))sel_registerName)("UUID"))',
  '(void*)[(id)NSClassFromString(@"NSUUID") UUID]',
  '(void*)[[(id)NSClassFromString(@"NSUUID") UUID] UUIDString]',
]:
    r = t.EvaluateExpression(e, o)
    print("PROBE", e[:70], "->", r.GetValue() or r.GetError().GetCString())
