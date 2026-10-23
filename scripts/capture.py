import lldb, time, struct
dbg=lldb.debugger; t=dbg.GetSelectedTarget(); p=t.GetProcess()
log=open("/tmp/capture.log","w")
def resolve(name):
    syms=t.FindSymbols(name)
    if syms.GetSize(): return syms.GetContextAtIndex(0).GetSymbol().GetStartAddress().GetLoadAddress(t)
    return 0
def f(frame,n):
    r=frame.FindRegister(n);
    try: return struct.unpack("<f",struct.pack("<I",r.GetValueAsUnsigned()&0xffffffff))[0]
    except: return 0.0
def cb(frame, loc, d):
    import lldb
    g=lambda n: frame.FindRegister(n).GetValueAsUnsigned()
    err=lldb.SBError()
    x0=g("x0"); x1=g("x1"); x2=g("x2"); x3=g("x3")
    wid=p.ReadUnsignedFromMemory(x1,4,err) if x1 else 0
    log.write("CGXMoveWindowList x0=%x arr=%x cnt=%d wid=%d x3=%x | s0=%.2f s1=%.2f s2=%.2f s3=%.2f d0=%.2f d1=%.2f\n"%(
        x0,x1,x2,wid,x3, f(frame,"s0"),f(frame,"s1"),f(frame,"s2"),f(frame,"s3"),
        frame.FindRegister("d0").GetValueAsUnsigned() and 0 or 0, 0)); log.flush()
    return False
addr=resolve("CGXMoveWindowList") or resolve("_CGXMoveWindowList")
log.write("resolved CGXMoveWindowList @ %x\n"%addr); log.flush()
bp=t.BreakpointCreateByAddress(addr) if addr else None
if bp: bp.SetScriptCallbackFunction("capture.cb"); log.write("bp locs=%d\n"%bp.GetNumLocations()); log.flush()
dbg.SetAsync(True); p.Continue(); time.sleep(20); p.Stop()
log.write("end\n"); log.close(); p.Detach()
