import lldb
t = lldb.debugger.GetSelectedTarget()
o = lldb.SBExpressionOptions(); o.SetLanguage(lldb.eLanguageTypeObjC_plus_plus); o.SetUnwindOnError(True); o.SetTimeoutInMicroSeconds(3000000)
sel = lambda n: '((SEL(*)(const char*))sel_registerName)("%s")' % n
e = ('struct R_ { double a, b, c, d; }; R_ r = {100, 120, 640, 480};'
     '(void*)((id(*)(id,SEL,R_,long long))objc_msgSend)((id)NSClassFromString(@"_WMResizeTargetGeometry"), %s, r, 2LL)'
     % sel("targetGeometryWithFrame:contentsGravity:"))
r = t.EvaluateExpression(e, o)
print("GEO value:", r.GetValue()); print("GEO err:", r.GetError().GetCString())
if r.GetValueAsUnsigned():
    print("GEO desc:", t.EvaluateExpression('(id)0x%x' % r.GetValueAsUnsigned(), o).GetObjectDescription())
