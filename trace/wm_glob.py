import lldb, struct
t = lldb.debugger.GetSelectedTarget(); p = t.GetProcess(); err = lldb.SBError()
TARGET = 0x93ac32d80
mod = [m for m in t.module_iter() if m.GetFileSpec().GetFilename() == "WindowManager"][0]
hits = []
for seg in mod.section_iter():
    if not seg.GetName().startswith("__DATA"): continue
    for sec in seg:
        a = sec.GetLoadAddress(t); n = sec.GetByteSize()
        data = p.ReadMemory(a, n, err) if n else b""
        if not data: continue
        for off in range(0, len(data) - 7, 8):
            v = struct.unpack_from("<Q", data, off)[0] & 0x0000ffffffffffff
            if v == TARGET:
                hits.append((seg.GetName(), sec.GetName(), a + off, sec.GetFileAddress() + off))
for h in hits: print("GLOB %s,%s runtime=0x%x static=0x%x" % h)
print("GLOB всего:", len(hits))
