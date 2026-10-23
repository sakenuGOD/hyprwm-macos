import lldb
t = lldb.debugger.GetSelectedTarget()
o = lldb.SBExpressionOptions(); o.SetLanguage(lldb.eLanguageTypeObjC_plus_plus); o.SetUnwindOnError(True); o.SetTimeoutInMicroSeconds(3000000)
def ev(name, e):
    r = t.EvaluateExpression(e, o)
    v = r.GetValue() or r.GetError().GetCString()
    print("STEP", name, "->", v); return r.GetValueAsUnsigned()
cls = lambda n: '((id(*)(const char*))objc_getClass)("%s")' % n
sel = lambda n: '((SEL(*)(const char*))sel_registerName)("%s")' % n
geo = ev("geo", '(void*)((id(*)(id,SEL,CGRect,long long))objc_msgSend)(%s, %s, CGRectMake(100,120,640,480), 2LL)' % (cls("_WMResizeTargetGeometry"), sel("targetGeometryWithFrame:contentsGravity:")))
if geo: print("STEP geo.desc ->", t.EvaluateExpression('(id)0x%x' % geo, o).GetObjectDescription())
sp = ev("spring", '(void*)((id(*)(id,SEL,double,double,double,double))objc_msgSend)((id)[(id)NSClassFromString(@"_WMSpringAnimationSettings") alloc], %s, 1.0, 210.0, 24.0, 0.001)' % sel("initWithMass:stiffness:damping:epsilon:"))
rt = ev("remoteTarget", '(void*)[(id)0x93b1fa5d0 remoteTarget]')
if rt: print("STEP rt.class ->", t.EvaluateExpression('(char*)object_getClassName((id)0x%x)' % rt, o).GetSummary())
