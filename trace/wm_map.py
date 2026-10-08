# Таблица WindowManager: CGS wid -> windowIdentifier (UUID) и pid -> соединение (BSServiceListenerConnection).
# Сканирует кучу WindowManager (lldb.macosx.heap: objc_refs). Пишет /tmp/wm_map.json
import lldb, re, json
dbg = lldb.debugger; t = dbg.GetSelectedTarget(); ci = dbg.GetCommandInterpreter()
o = lldb.SBExpressionOptions(); o.SetLanguage(lldb.eLanguageTypeObjC_plus_plus); o.SetUnwindOnError(True); o.SetTimeoutInMicroSeconds(3000000)
def cmd(c):
    r = lldb.SBCommandReturnObject(); ci.HandleCommand(c, r); return (r.GetOutput() or "") + (r.GetError() or "")
def ev(e): return t.EvaluateExpression(e, o)
cmd("command script import lldb.macosx.heap")
out = {"windows": {}, "conns": {}}
for cls in ("WMWindowPropertySnapshot", "_WMWindow"):
    txt = cmd("objc_refs -o %s" % cls)
    addrs = sorted(set(re.findall(r"(0x[0-9a-f]{9,})\s*:\s*\S*\s*malloc\(", txt)) | set(re.findall(r"^(0x[0-9a-f]{9,}):", txt, re.M)))
    print("MAP", cls, "найдено", len(addrs))
    for a in addrs:
        wid = ev("(unsigned int)[(id)%s cgWindowID]" % a).GetValueAsUnsigned()
        uid = ev("(id)[(id)%s windowIdentifier]" % a).GetObjectDescription()
        if wid and uid and re.match(r"^[0-9A-F-]{36}$", uid or ""):
            out["windows"].setdefault(str(wid), uid)
txt = cmd("objc_refs -o BSServiceListenerConnection")
for a in sorted(set(re.findall(r"(0x[0-9a-f]{9,})", txt))):
    d = ev("(id)%s" % a).GetObjectDescription() or ""
    m = re.search(r"-from\((\d+):.*-as\(com\.apple\.windowmanager\.app-service\)", d)
    if m: out["conns"][m.group(1)] = a
json.dump(out, open("/tmp/wm_map.json", "w"), indent=1)
print("MAP окон:", len(out["windows"]), "соединений:", len(out["conns"]))
print("MAP", json.dumps(out)[:900])
