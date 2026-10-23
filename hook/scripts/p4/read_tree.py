# П4 шаг 1: только чтение CA-дерева окна внутри WS (compositor.md §1б). Запуск: run_lldb.sh этот_файл
# Окно — из /tmp/hyprwm/p4_wid.
import lldb
t = lldb.debugger.GetSelectedTarget(); proc = t.GetProcess(); err = lldb.SBError()
opt = lldb.SBExpressionOptions(); opt.SetIgnoreBreakpoints(True); opt.SetTimeoutInMicroSeconds(3000000)
def ev(e):
    r = t.EvaluateExpression(e, opt)
    if r.GetError().Fail() and "unknown error" not in (r.GetError().GetCString() or ""):
        return "ERR " + (r.GetError().GetCString() or "")
    return r
def r64(a): return int.from_bytes(proc.ReadMemory(a, 8, err), "little")
wid = int(open("/tmp/hyprwm/p4_wid").read())
win = ev("(unsigned long)CGXWindowByID(%d)" % wid).GetValueAsUnsigned()
print("P4 win 0x%x" % win)
cwc = r64(win + 0x18); print("P4 cwc 0x%x" % cwc)
ctx = r64(cwc + 0x38); print("P4 ctx 0x%x" % ctx)
for off in (0x80, 0x88, 0x98, 0x90, 0x60, 0x68, 0xa8):
    L = r64(cwc + off)
    if not L:
        print("P4 +0x%x NULL" % off); continue
    name = ev('(char*)[[(id)0x%x name] UTF8String]' % L)
    cls = ev('(char*)object_getClassName((id)0x%x)' % L)
    cr = ev('(double)[(id)0x%x cornerRadius]' % L)
    mtb = ev('(int)[(id)0x%x masksToBounds]' % L)
    gf = ev('(int)[(id)0x%x isGeometryFlipped]' % L)
    mask = ev('(unsigned long)[(id)0x%x mask]' % L)
    b = ev('(CGRect)[(id)0x%x bounds]' % L)
    def s(v):
        return v if isinstance(v, str) else (v.GetSummary() or v.GetValue() or str(v.GetValueAsUnsigned()))
    print("P4 +0x%x %s cls=%s name=%s cr=%s mtb=%s flip=%s mask=%s bounds=%s" % (
        off, hex(L), s(cls), s(name), s(cr), s(mtb), s(gf), s(mask),
        "" if isinstance(b, str) else " ".join(str(b.GetChildAtIndex(i).GetChildAtIndex(j).GetValue()) for i in range(2) for j in range(2))))
