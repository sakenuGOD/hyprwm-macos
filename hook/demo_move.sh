#!/bin/zsh
# Демо плавного переезда: окно WID (по умолчанию — первое окно Ghostty на экране) едет на DY и обратно.
# usage: demo_move.sh [WID] [DX] [DY]
H=${0:A:h}
WID=${1:-$($H/scripts/wlist.bin 2>/dev/null | awk '/Ghostty/{sub("wid=","",$1); print $1; exit}')}
DX=${2:-0}; DY=${3:-200}
echo "WID=$WID DX=$DX DY=$DY" > /tmp/anim.args; $H/run_lldb.sh $H/scripts/anim.py | grep ANIM
sleep 1.5
echo "WID=$WID DX=$((-DX)) DY=$((-DY))" > /tmp/anim.args; $H/run_lldb.sh $H/scripts/anim.py | grep ANIM
