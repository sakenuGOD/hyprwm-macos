import lldb
t = lldb.debugger.GetSelectedTarget()
def enc(cls, sel, inst=True):
    getm = "class_getInstanceMethod" if inst else "class_getClassMethod"
    e = '(char*)method_getTypeEncoding((void*)%s((void*)objc_getClass("%s"),(void*)sel_registerName("%s")))' % (getm, cls, sel)
    r = t.EvaluateExpression(e)
    print("TYPE %s %s%s -> %s" % (cls, "-" if inst else "+", sel, r.GetSummary() or r.GetError().GetCString()))
enc("_WMClientResizeWindowRequest", "initWithRequestID:windowID:targetGeometry:springSettings:requiresResponse:")
enc("_WMResizeTargetGeometry", "targetGeometryWithFrame:contentsGravity:", False)
enc("_WMSpringAnimationSettings", "initWithMass:stiffness:damping:epsilon:")
r = t.EvaluateExpression('(char*)object_getClassName((id)0x93b1fa5d0)')
print("CONN class:", r.GetSummary() or r.GetError().GetCString())
