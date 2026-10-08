import lldb
t=lldb.debugger.GetSelectedTarget(); p=t.GetProcess()
WID=65
code=('unsigned int w=%d;'
      '((void(*)(void*,unsigned int*,int,long,float,float))CGXMoveWindowList)'
      '((void*)0, &w, 1, (long)0, (float)200, (float)300);'
      '(int)0') % WID
r=t.EvaluateExpression(code)
print("MOVE err:", r.GetError().GetCString() or "OK")
