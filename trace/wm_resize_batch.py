# Пакет нативных resize через WindowManager.app (одно подключение lldb на весь пакет).
# Вход /tmp/wmresize_jobs.json: [{"conn":"0x..","uuid":"..","x":..,"y":..,"w":..,"h":..}, ...]
# Опционально "spring": [m,k,d,eps] (по умолчанию drift Hyprland 1/210/24/0.001), "gravity": 2.
import lldb, json
t = lldb.debugger.GetSelectedTarget()
o = lldb.SBExpressionOptions(); o.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
o.SetUnwindOnError(True); o.SetTimeoutInMicroSeconds(5000000)
sel = lambda n: '((SEL(*)(const char*))sel_registerName)("%s")' % n

def ev(name, e):
    r = t.EvaluateExpression(e, o); v = r.GetValueAsUnsigned()
    if not v: raise RuntimeError("%s: %s" % (name, r.GetError().GetCString()))
    return v

jobs = json.load(open("/tmp/wmresize_jobs.json"))
for j in jobs:
    M, K, D, EPS = j.get("spring", [1.0, 210.0, 24.0, 0.001]); G = int(j.get("gravity", 2))
    try:
        geo = ev("geo", 'struct R_ { double a, b, c, d; }; R_ r = {%r, %r, %r, %r};'
                 '(void*)((id(*)(id,SEL,R_,long long))objc_msgSend)((id)NSClassFromString(@"_WMResizeTargetGeometry"), %s, r, %dLL)'
                 % (float(j["x"]), float(j["y"]), float(j["w"]), float(j["h"]), sel("targetGeometryWithFrame:contentsGravity:"), G))
        sp = ev("spring", '(void*)((id(*)(id,SEL,double,double,double,double))objc_msgSend)((id)[(id)NSClassFromString(@"_WMSpringAnimationSettings") alloc], %s, %r, %r, %r, %r)'
                % (sel("initWithMass:stiffness:damping:epsilon:"), float(M), float(K), float(D), float(EPS)))
        rid = ev("rid", '(void*)[[(id)NSClassFromString(@"NSUUID") UUID] UUIDString]')
        wid = ev("wid", '(void*)[(id)NSClassFromString(@"NSString") stringWithUTF8String:"%s"]' % j["uuid"])
        req = ev("req", '(void*)((id(*)(id,SEL,id,id,id,id,BOOL))objc_msgSend)((id)[(id)NSClassFromString(@"_WMClientResizeWindowRequest") alloc], %s, (id)0x%x, (id)0x%x, (id)0x%x, (id)0x%x, (BOOL)0)'
                 % (sel("initWithRequestID:windowID:targetGeometry:springSettings:requiresResponse:"), rid, wid, geo, sp))
        rt = ev("rt", '(void*)[(id)%s remoteTarget]' % j["conn"])
        t.EvaluateExpression('((void(*)(id,SEL,id))objc_msgSend)((id)0x%x, %s, (id)0x%x); (int)1' % (rt, sel("performResizeWindowRequest:"), req), o)
        print("WMBATCH ok %s -> %g,%g %gx%g" % (j["uuid"][:8], j["x"], j["y"], j["w"], j["h"]))
    except Exception as e:
        print("WMBATCH FAIL %s: %s" % (j["uuid"][:8], e))
