#!/bin/zsh
# Перезапустить службу горячих клавиш (бинды пересобираются из дотфайлов).
H=${0:A:h}
pkill -f "$H/hyprkeys" 2>/dev/null
python3 $H/binds.py
nohup $H/hyprkeys > /tmp/hyprkeys.log 2>&1 &
sleep 1.5; tail -2 /tmp/hyprkeys.log | sed 's/^.*hyprkeys\]/[hyprkeys]/'
