#!/bin/zsh
# Запустить/перезапустить hyprwm (демон тайлинга) и горячие клавиши.
H=${0:A:h}
pkill -f "$H/hyprwm.py" 2>/dev/null; pkill -f "$H/keys/hyprkeys" 2>/dev/null; sleep 0.5
HYPRWM_DEBUG=${HYPRWM_DEBUG:-} nohup python3 -u $H/hyprwm.py >> /tmp/hyprwm.log 2>&1 &
python3 $H/keys/binds.py > /dev/null && nohup $H/keys/hyprkeys > /tmp/hyprkeys.log 2>&1 &
sleep 3; tail -5 /tmp/hyprwm.log
