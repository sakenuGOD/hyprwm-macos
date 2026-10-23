# Нативный resize через WindowManager.app: свой _WMClientResizeWindowRequest в remoteTarget
# соединения приложения (BSServiceListenerConnection). Аргументы /tmp/wmresize.args:
#   CONN=0x.. WIN=<windowID UUID> X Y W H [K=210 D=24 M=1 EPS=0.001 G=2 RESP=0]
# Короткие отдельные выражения: длинное многострочное с typedef ловило PAC-сбой в lldb.
import lldb
t = lldb.debugger.GetSelectedTarget()
A = open("/tmp/wmresize.args").read().split()
kv = dict(a.split("=", 1) for a in A if "=" in a); X, Y, W, H = [float(a) for a in A if "=" not in a]
M, K, D, EPS = (float(kv.get(k, v)) for k, v in (("M", 1), ("K", 210), ("D", 24), ("EPS", 0.001)))
G = int(kv.get("G", 2)); RESP = int(kv.get("RESP", 0))
o = lldb.SBExpressionOptions(); o.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
o.SetUnwindOnError(True); o.SetTimeoutInMicroSeconds(5000000)
sel = lambda n: '((SEL(*)(const char*))sel_registerName)("%s")' % n

def ev(name, e):
    r = t.EvaluateExpression(e, o)
    v = r.GetValueAsUnsigned()
    if not v and name != "send":
        raise RuntimeError("%s: %s" % (name, r.GetError().GetCString()))
    return v

geo = ev("geo", 'struct R_ { double a, b, c, d; }; R_ r = {%r, %r, %r, %r};'
         '(void*)((id(*)(id,SEL,R_,long long))objc_msgSend)((id)NSClassFromString(@"_WMResizeTargetGeometry"), %s, r, %dLL)'
         % (X, Y, W, H, sel("targetGeometryWithFrame:contentsGravity:"), G))
sp = ev("spring", '(void*)((id(*)(id,SEL,double,double,double,double))objc_msgSend)((id)[(id)NSClassFromString(@"_WMSpringAnimationSettings") alloc], %s, %r, %r, %r, %r)'
        % (sel("initWithMass:stiffness:damping:epsilon:"), M, K, D, EPS))
rid = ev("rid", '(void*)[[(id)NSClassFromString(@"NSUUID") UUID] UUIDString]')
wid = ev("wid", '(void*)[(id)NSClassFromString(@"NSString") stringWithUTF8String:"%s"]' % kv["WIN"])
req = ev("req", '(void*)((id(*)(id,SEL,id,id,id,id,BOOL))objc_msgSend)((id)[(id)NSClassFromString(@"_WMClientResizeWindowRequest") alloc], %s, (id)0x%x, (id)0x%x, (id)0x%x, (id)0x%x, (BOOL)%d)'
         % (sel("initWithRequestID:windowID:targetGeometry:springSettings:requiresResponse:"), rid, wid, geo, sp, RESP))
print("WMRESIZE req:", t.EvaluateExpression('(id)0x%x' % req, o).GetObjectDescription())
rt = ev("rt", '(void*)[(id)%s remoteTarget]' % kv["CONN"])
r = t.EvaluateExpression('((void(*)(id,SEL,id))objc_msgSend)((id)0x%x, %s, (id)0x%x); (int)1'
                         % (rt, sel("performResizeWindowRequest:"), req), o)
print("WMRESIZE send:", r.GetValue(), r.GetError().GetCString())
