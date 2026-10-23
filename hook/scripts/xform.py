# CGXSetWindowTransform3DList(conn, &wid, &key, &CATransform3D) — env: WID TX TY SX(scale) KEY
import lldb, os
t=lldb.debugger.GetSelectedTarget()
P=dict(l.split("=",1) for l in open("/tmp/xform.args").read().split()); g=lambda k,d: P.get(k,d)
WID=int(g("WID","65")); TX=float(g("TX","0")); TY=float(g("TY","0"))
SX=float(g("SX","1")); KEY=int(g("KEY","0x30000000"),0)
code=('unsigned int w=%d; unsigned int k=%u; double m[16]={%r,0,0,0, 0,%r,0,0, 0,0,1,0, %r,%r,0,1};'
      '((void(*)(void*,unsigned int*,unsigned int*,double*))CGXSetWindowTransform3DList)((void*)0,&w,&k,m);'
      '(int)0') % (WID,KEY,SX,SX,TX,TY)
r=t.EvaluateExpression(code)
print("XFORM", WID, TX, TY, SX, hex(KEY), "err:", r.GetError().GetCString() or "OK")
