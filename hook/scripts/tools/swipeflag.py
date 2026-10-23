import lldb, os
def __lldb_init_module(d, _):
    t = d.GetSelectedTarget(); p = t.GetProcess(); e = lldb.SBError()
    want = int(open("/tmp/swipe.val").read())
    for n in ("_ZN7cgdebugL28allow_unflatten_during_swipeE", "_ZN7cgdebugL25allow_unflatten_during_mcE"):
        for sc in t.FindSymbols(n):
            a = sc.symbol.GetStartAddress().GetLoadAddress(t)
            old = p.ReadUnsignedFromMemory(a, 1, e)
            if want >= 0 and "swipe" in n:
                p.WriteMemory(a, bytes([want]), e)
            print("FLAG", n, hex(a), "было", old, "стало", p.ReadUnsignedFromMemory(a, 1, e))
