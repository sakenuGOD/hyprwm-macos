#!/bin/zsh
# Демо переезда + замер каденции: сколько шагов анимации пришлось на каждый кадр панели.
H=${0:A:h}; P=$(pgrep -x WindowServer); OUT=/tmp/cad.txt
sudo -n dtrace -q -p $P -s $H/../trace/anim_cadence.d -o $OUT 2>/dev/null &
D=$!; sleep 1.5
$H/demo_move.sh "$@"
wait $D
python3 - "$OUT" <<'PY'
import sys
ev=[(l.split()[0],int(l.split()[1])) for l in open(sys.argv[1]) if l[:1] in "XS"]
xs=[t for k,t in ev if k=="X"]
if not xs: print("нет шагов анимации"); sys.exit()
lo,hi=xs[0]-20000,xs[-1]+20000
fr=[t for k,t in ev if k=="S" and lo<=t<=hi]
from collections import Counter
# считаем только кадры внутри анимации: между первым и последним шагом каждой серии
runs=[]; st=xs[0]; prev=xs[0]
for x in xs[1:]:
    if x-prev>300000: runs.append((st,prev)); st=x
    prev=x
runs.append((st,prev))
per=[]; dfr=[]
for a,b in runs:
    f=[t for t in fr if a-20000<=t<=b+20000]
    per+= [sum(1 for x in xs if u<=x<v) for u,v in zip(f,f[1:])]
    dfr+= [v-u for u,v in zip(f,f[1:])]
print("серий:",len(runs),"шагов:",len(xs),"кадров внутри анимации:",len(per)+len(runs))
print("шагов на кадр:",dict(sorted(Counter(per).items())))
if dfr: print("интервал кадров, мс: min %.1f med %.1f max %.1f"%(min(dfr)/1e3,sorted(dfr)[len(dfr)//2]/1e3,max(dfr)/1e3))
PY
