import lldb
ci = lldb.debugger.GetCommandInterpreter()
def cmd(c):
    r = lldb.SBCommandReturnObject(); ci.HandleCommand(c, r); return (r.GetOutput() or "") + (r.GetError() or "")
print(cmd("command script import lldb.macosx.heap")[:300])
for c in ("WMWindowPropertySnapshot", "BSServiceListenerConnection"):
    s = cmd("objc_refs -o %s" % c)
    print("RAW", c, len(s)); print(s[:1500])
