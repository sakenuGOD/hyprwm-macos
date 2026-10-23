import lldb, struct, time
t=lldb.debugger.GetSelectedTarget(); p=t.GetProcess(); err=lldb.SBError()
A=0x11a23c000
v=p.ReadUnsignedFromMemory(A,8,err)
print("COUNTER=%d"%v if err.Success() else "read err: "+err.GetCString())
