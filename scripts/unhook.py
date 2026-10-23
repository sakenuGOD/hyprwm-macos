import lldb, struct
t=lldb.debugger.GetSelectedTarget(); p=t.GetProcess(); err=lldb.SBError()
head=t.FindSymbols("metalCallbacks").GetContextAtIndex(0).GetSymbol().GetStartAddress().GetLoadAddress(t)
cur=p.ReadPointerFromMemory(head, err)
p.WriteMemory(head, struct.pack("<Q",0), err)
print("metalCallbacks head: %x -> 0 (our nodes removed), err:%s"%(cur, err.GetCString() or "OK"))
