import lldb, struct
t=lldb.debugger.GetSelectedTarget(); p=t.GetProcess(); err=lldb.SBError()
def ev(e):
    r=t.EvaluateExpression(e); return r.GetValueAsUnsigned(), (r.GetError().GetCString() or "OK")
MC_STATIC=0x1ea5fb3b8; CLEAR_STATIC=0x186f3dedc
head=t.FindSymbols("metalCallbacks").GetContextAtIndex(0).GetSymbol().GetStartAddress().GetLoadAddress(t)
slide=head-MC_STATIC; clear_rt=CLEAR_STATIC+slide
print("head @%x slide=%x metal_clear_rect @%x"%(head, slide, clear_rt))
# регион кода (R+X) и данных (RW)
code,_=ev("(void*)mmap(0,16384,3,0x1002,-1,0)"); data,_=ev("(void*)mmap(0,16384,3,0x1002,-1,0)")
if code in (0,0xffffffffffffffff) or data in (0,0xffffffffffffffff): print("mmap FAIL"); raise SystemExit
# тело колбэка (6 инстр., little-endian)
cb=struct.pack("<6I",0xF9400061,0x6D408861,0x6D419063,0x3CC28065,0xBD403860,0xD61F083F)
p.WriteMemory(code, cb, err)
rc,e=ev("(int)mprotect((void*)%d,16384,5)"%code); print("mprotect code R+X rc=%d %s"%(rc,e))
if rc!=0: raise SystemExit
sc,e=ev("(void*)__builtin_ptrauth_sign_unauthenticated((void*)%d,0,0)"%clear_rt); print("signed clear=%x %s"%(sc,e))
scode,e=ev("(void*)__builtin_ptrauth_sign_unauthenticated((void*)%d,0,0)"%code);  print("signed code =%x %s"%(scode,e))
if not sc or not scode: print("sign FAIL"); raise SystemExit
# ctx struct: +0 fn(Q) +8 x +0x10 y +0x18 w +0x20 h(dbl) +0x28 rgba(4f) +0x38 scale(f)
ctx=data
buf=bytearray(0x40)
struct.pack_into("<Q", buf, 0x00, sc)
struct.pack_into("<dddd", buf, 0x08, 200.0, 200.0, 600.0, 400.0)   # x,y,w,h
struct.pack_into("<ffff", buf, 0x28, 1.0, 0.0, 0.0, 1.0)            # красный r,g,b,a
struct.pack_into("<f",   buf, 0x38, 1.0)                           # scale
p.WriteMemory(ctx, bytes(buf), err)
# узел: {next=*head, signed_code, ctx}
cur=p.ReadPointerFromMemory(head, err); node=data+0x200
p.WriteMemory(node, struct.pack("<QQQ", cur, scode, ctx), err)
p.WriteMemory(head, struct.pack("<Q", node), err)
print("INSTALLED node@%x ctx@%x code@%x prevhead=%x"%(node,ctx,code,cur))
