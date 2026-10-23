# П4 шаг 2: маска вместо клипа на одном окне (compositor.md шаги, п.2). /tmp/hyprwm/p4_mask: "wid w h" — поставить
# маску (0,0,w,h) со скруглением 18 continuous; "wid clear" — снять (mask=nil). Запуск: run_lldb.sh этот_файл
import lldb
t = lldb.debugger.GetSelectedTarget(); proc = t.GetProcess(); err = lldb.SBError()
opt = lldb.SBExpressionOptions(); opt.SetIgnoreBreakpoints(True); opt.SetTimeoutInMicroSeconds(3000000)
opt.SetLanguage(lldb.eLanguageTypeObjC)
def ev(e):
    r = t.EvaluateExpression(e, opt)
    if r.GetError().Fail() and "unknown error" not in (r.GetError().GetCString() or ""):
        raise RuntimeError(e[:80] + " -> " + (r.GetError().GetCString() or ""))
    return r
def r64(a): return int.from_bytes(proc.ReadMemory(a, 8, err), "little")
a = open("/tmp/hyprwm/p4_mask").read().split()
wid = int(a[0])
win = ev("(unsigned long)CGXWindowByID(%d)" % wid).GetValueAsUnsigned()
cwc = r64(win + 0x18)
H = r64(cwc + 0x98)
CTX = r64(cwc + 0x38)
name = ev('(char*)[[(id)0x%x name] UTF8String]' % H).GetSummary()
if name != '"Hosting"':
    raise RuntimeError("не Hosting: %s" % name)
PRE = ('struct R4 { double x, y, w, h; };'
       'typedef void (*setr_t)(id, SEL, struct R4); typedef struct R4 (*getr_t)(id, SEL);'
       'typedef void (*setd_t)(id, SEL, double); typedef void (*seto_t)(id, SEL, id); typedef void (*setp_t)(id, SEL, void*);'
       'typedef void (*setb_t)(id, SEL, BOOL); typedef id (*get_t)(id, SEL);'
       '')
r = ev(PRE + 'struct R4 b = ((getr_t)objc_msgSend)((id)0x%x, @selector(bounds)); b.w * 100000.0 + b.h' % H)
v = float(r.GetValue()); bw, bh = v // 100000, v % 100000
print("P4 Hosting 0x%x bounds %.1f x %.1f" % (H, bw, bh))
if a[1] == "clear":
    for e in ['unsigned long $T = (unsigned long)NSClassFromString(@"CATransaction"); $T',
              '((get_t)objc_msgSend)((id)$T, @selector(begin)); (int)0',
              '((setb_t)objc_msgSend)((id)$T, @selector(setDisableActions:), YES); (int)0',
              'unsigned long $NA = (unsigned long)NSClassFromString(@"NSArray"); $NA',
              'unsigned long $A = (unsigned long)((id(*)(id,SEL,id))objc_msgSend)((id)$NA, @selector(arrayWithObject:), (id)0x%x); $A' % CTX,
              '((get_t)objc_msgSend)((id)$A, @selector(retain)); (int)0',
              '((seto_t)objc_msgSend)((id)$T, @selector(setCommittingContexts:), (id)$A); (int)0',
              '((seto_t)objc_msgSend)((id)0x%x, @selector(setMask:), (id)0); (int)0' % H,
              '((get_t)objc_msgSend)((id)$T, @selector(commit)); (int)0']:
        ev(PRE + e)
    print("P4 маска снята")
else:
    w, h = float(a[1]), float(a[2])
    steps = [
        ('слой', 'unsigned long $M = (unsigned long)((get_t)objc_msgSend)((id)NSClassFromString(@"CALayer"), @selector(layer)); $M'),
        ('retain', '((get_t)objc_msgSend)((id)$M, @selector(retain)); (int)0'),
        ('frame', '((setr_t)objc_msgSend)((id)$M, @selector(setFrame:), (struct R4){0, 0, %f, %f}); (int)0' % (w, h)),
        ('радиус', '((setd_t)objc_msgSend)((id)$M, @selector(setCornerRadius:), 18.0); (int)0'),
        ('кривая', '((seto_t)objc_msgSend)((id)$M, @selector(setCornerCurve:), @"continuous"); (int)0'),
        ('цвет', 'void *$C = ((void*(*)(double,double,double,double))CGColorCreateSRGB)(0.0, 0.0, 0.0, 1.0); (int)0'),
        ('цвет2', '((setp_t)objc_msgSend)((id)$M, @selector(setBackgroundColor:), $C); (int)0'),
        ('класс', 'unsigned long $T = (unsigned long)NSClassFromString(@"CATransaction"); $T'),
        ('begin', '((get_t)objc_msgSend)((id)$T, @selector(begin)); (int)0'),
        ('без анимаций', '((setb_t)objc_msgSend)((id)$T, @selector(setDisableActions:), YES); (int)0'),
        ('NSArray', 'unsigned long $NA = (unsigned long)NSClassFromString(@"NSArray"); $NA'),
        ('массив', 'unsigned long $A = (unsigned long)((id(*)(id,SEL,id))objc_msgSend)((id)$NA, @selector(arrayWithObject:), (id)0x%x); $A' % CTX),
        ('retain массива', '((get_t)objc_msgSend)((id)$A, @selector(retain)); (int)0'),
        ('контексты', '((seto_t)objc_msgSend)((id)$T, @selector(setCommittingContexts:), (id)$A); (int)0'),
        ('setMask', '((seto_t)objc_msgSend)((id)0x%x, @selector(setMask:), (id)$M); (int)0' % H),
        ('commit', '((get_t)objc_msgSend)((id)$T, @selector(commit)); (int)0'),
    ]
    for nm, e in steps:
        r = ev(PRE + e)
        print("P4 шаг", nm, "ok", r.GetValue())
    m = ev('(unsigned long)((id(*)(id, SEL))objc_msgSend)((id)0x%x, @selector(mask))' % H).GetValueAsUnsigned()
    print("P4 маска поставлена 0x%x (%.0f x %.0f)" % (m, w, h))
