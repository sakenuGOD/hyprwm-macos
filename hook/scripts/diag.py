import lldb
t=lldb.debugger.GetSelectedTarget()
path="/Users/Shared/rehook/counter.dylib"
r=t.EvaluateExpression('(void*)dlopen("%s", 2)'%path)
print("dlopen =", hex(r.GetValueAsUnsigned()))
e=t.EvaluateExpression('(char*)dlerror()')
# прочитать C-строку
addr=e.GetValueAsUnsigned()
if addr:
    err=lldb.SBError(); s=t.GetProcess().ReadCStringFromMemory(addr,512,err)
    print("dlerror =", s)
else:
    print("dlerror = (null)")
