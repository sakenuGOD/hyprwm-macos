# Таблица WindowManager для нужных приложений: pid -> соединение, CGS wid -> windowID(UUID) + тип/теги.
# Вход /tmp/wmlookup.args: pid через пробел. Выход /tmp/wm_map.json.
# Менеджер (AppKitApplicationConnectionManager) ищется один раз на процесс WindowManager
# (ptr_refs на класс: первое слово Swift-объекта — его класс) и кэшируется в hook/wm.state.
import lldb, re, json, os
dbg = lldb.debugger; t = dbg.GetSelectedTarget(); p = t.GetProcess(); ci = dbg.GetCommandInterpreter(); err = lldb.SBError()
o = lldb.SBExpressionOptions(); o.SetLanguage(lldb.eLanguageTypeObjC_plus_plus); o.SetUnwindOnError(True); o.SetTimeoutInMicroSeconds(4000000)
ev = lambda e: t.EvaluateExpression(e, o)
r64 = lambda a: int.from_bytes(p.ReadMemory(a, 8, err), "little") & 0x0000ffffffffffff
r32 = lambda a: int.from_bytes(p.ReadMemory(a, 4, err), "little")
def cmd(c):
    r = lldb.SBCommandReturnObject(); ci.HandleCommand(c, r); return (r.GetOutput() or "") + (r.GetError() or "")
MGR_CLS = "_TtC18WindowManagerAgent34AppKitApplicationConnectionManager"
STATE = "/Users/fsociety/Developer/re-tools/hook/wm.state"
pid = p.GetProcessID()

def is_mgr(a):
    return a and ev('(char*)object_getClassName((id)0x%x)' % a).GetSummary() == '"WindowManagerAgent.AppKitApplicationConnectionManager"'

mgr = None
if os.path.exists(STATE):
    s = open(STATE).read().split()
    if len(s) == 2 and int(s[0]) == pid and is_mgr(int(s[1], 16)): mgr = int(s[1], 16)
if mgr is None:
    cmd("command script import lldb.macosx.heap")
    cls = ev('(unsigned long)objc_getClass("%s")' % MGR_CLS).GetValueAsUnsigned()
    txt = cmd("ptr_refs --max-matches 64 0x%x" % cls)
    for base in re.findall(r"-> (0x[0-9a-f]+) \+ 0\b", txt):
        if is_mgr(int(base, 16)): mgr = int(base, 16); break
    if mgr is None: raise RuntimeError("менеджер не найден")
    open(STATE, "w").write("%d %x\n" % (pid, mgr))
print("WMMAP manager 0x%x" % mgr)

want = set(int(x) for x in open("/tmp/wmlookup.args").read().split())
conns = ev('(id)[(id)0x%x allValues]' % r64(mgr + 0x18)).GetValueAsUnsigned()
n = ev('(long)[(id)0x%x count]' % conns).GetValueAsSigned()
out = {}
for i in range(n):
    c = ev('(unsigned long)[(id)0x%x objectAtIndex:%d]' % (conns, i)).GetValueAsUnsigned()
    cpid = r32(c + 0x30)
    if cpid not in want: continue
    ent = {"conn": "0x%x" % r64(c + 0x8), "client": "0x%x" % c, "windows": {}}
    wd = r64(c + 0x50)
    keys = ev('(id)[(id)0x%x allKeys]' % wd).GetValueAsUnsigned()
    kn = ev('(long)[(id)0x%x count]' % keys).GetValueAsSigned()
    for k in range(kn):
        key = ev('(id)[(id)0x%x objectAtIndex:%d]' % (keys, k)).GetObjectDescription()
        desc = ev('(id)[(id)[(id)0x%x objectForKey:@"%s"] description]' % (wd, key)).GetObjectDescription() or ""
        m = re.search(r"snapshot: <WMWindowPropertySnapshot: (0x[0-9a-f]+)>", desc)
        if not m: continue
        cg = ev('(unsigned int)[(id)%s cgWindowID]' % m.group(1)).GetValueAsUnsigned()
        typ = (re.search(r"modelWindowType: Optional\((\w+)\)", desc) or [None, None])[1]
        tags = (re.search(r"modelTags: \[([^\]]*)\]", desc) or [None, ""])[1]
        ent["windows"][str(cg)] = {"uuid": key, "type": typ, "tags": [x.strip() for x in tags.split(",") if x.strip()]}
    out[str(cpid)] = ent
json.dump(out, open("/tmp/wm_map.json", "w"), indent=1)
print("WMMAP", json.dumps(out, ensure_ascii=False)[:1500])
