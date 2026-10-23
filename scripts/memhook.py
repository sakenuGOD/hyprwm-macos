import lldb, struct
t=lldb.debugger.GetSelectedTarget(); p=t.GetProcess(); err=lldb.SBError()
def ev(e):
    r=t.EvaluateExpression(e); return r.GetValueAsUnsigned(), (r.GetError().GetCString() or "OK")
head=t.FindSymbols("metalCallbacks").GetContextAtIndex(0).GetSymbol().GetStartAddress().GetLoadAddress(t)
print("metalCallbacks head @", hex(head))
# РЕГИОН A: код (станет R+X)
code,e = ev("(void*)mmap(0, 16384, 3, 0x1002, -1, 0)"); print("code mmap =", hex(code), "|", e)
# РЕГИОН B: данные счётчик+узел (остаётся R+W)
data,e = ev("(void*)mmap(0, 16384, 3, 0x1002, -1, 0)"); print("data mmap =", hex(data), "|", e)
if code in (0,0xffffffffffffffff) or data in (0,0xffffffffffffffff): print("mmap FAILED"); raise SystemExit
cb=bytes([0x68,0x00,0x40,0xF9, 0x08,0x05,0x00,0x91, 0x68,0x00,0x00,0xF9, 0xC0,0x03,0x5F,0xD6]) # ldr x8,[x3];add;str;ret
p.WriteMemory(code, cb, err)                            # код в A
p.WriteMemory(data, struct.pack("<Q",0), err)           # счётчик в B (RW!)
rc,e = ev("(int)mprotect((void*)%d, 16384, 5)"%code); print("mprotect code R+X rc=",rc,"|",e)  # ТОЛЬКО код
if rc!=0: print("mprotect FAILED"); raise SystemExit
signed,e = ev("(void*)__builtin_ptrauth_sign_unauthenticated((void*)%d, 0, 0)"%code)
print("signed fn =", hex(signed), "|", e)
if not signed or signed==code: print("sign FAILED/no-op"); raise SystemExit
cur=p.ReadPointerFromMemory(head, err); node=data+0x200   # узел в B (RW)
p.WriteMemory(node, struct.pack("<QQQ", cur, signed, data), err)  # {next, signed_fn, ctx=counter@data}
p.WriteMemory(head, struct.pack("<Q", node), err)
print("INSTALLED node@%x counter@%x prevhead=%x"%(node, data, cur))
print("COUNTER_ADDR=%x"%data)
