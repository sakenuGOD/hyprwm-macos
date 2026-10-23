import lldb, time, struct
dbg=lldb.debugger; t=dbg.GetSelectedTarget(); p=t.GetProcess()
log=open("/tmp/movetrace.log","w")
def f32(u):
    return struct.unpack("<f",struct.pack("<I",u&0xffffffff))[0]
def cb(frame, loc, d):
    import lldb
    g=frame.FindRegister
    x0=g("x0").GetValueAsUnsigned(); x1=g("x1").GetValueAsUnsigned()
    x2=g("x2").GetValueAsUnsigned(); x3=g("x3").GetValueAsUnsigned()
    s0=g("s0").GetValueAsUnsigned(); s1=g("s1").GetValueAsUnsigned()
    err=lldb.SBError()
    wid=p.ReadUnsignedFromMemory(x1,4,err) if x1 else 0
    log.write("CGXMoveWindowList x0=%x arr=%x count=%d wid=%d s0=%.2f s1=%.2f x3=%x\n"%(
        x0,x1,x2,wid,f32(s0),f32(s1),x3)); log.flush()
    return False  # auto-continue, не останавливаемся
bp=t.BreakpointCreateByName("_CGXMoveWindowList","SkyLight")
bp.SetScriptCallbackFunction("tracer.cb")
log.write("armed bp on _CGXMoveWindowList, resolved=%d loc\n"%bp.GetNumLocations()); log.flush()
dbg.SetAsync(True); p.Continue()
time.sleep(25)
p.Stop(); log.write("window closed\n"); log.flush(); log.close()
p.Detach()
