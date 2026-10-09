#!/bin/zsh
# Запустить/перезапустить hyprwm (демон тайлинга) и горячие клавиши.
# Демон и бинды — в своей сессии процессов (setsid): иначе они умирают вместе с терминалом/агентом, который их
# запустил (2026-10-09 16:11: упал Ghostty с сессией агента — демон ушёл вместе с ним).
H=${0:A:h}
pkill -f "$H/hyprwm.py" 2>/dev/null; pkill -f "$H/keys/hyprkeys" 2>/dev/null; sleep 0.5
python3 $H/keys/binds.py > /dev/null
HYPRWM_DEBUG=${HYPRWM_DEBUG:-} python3 - "$H" <<'PY'
import os, subprocess, sys
h = sys.argv[1]
log = open("/tmp/hyprwm.log", "ab")
subprocess.Popen(["python3", "-u", h + "/hyprwm.py"], stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                 start_new_session=True)
subprocess.Popen([h + "/keys/hyprkeys"], stdout=open("/tmp/hyprkeys.log", "wb"), stderr=subprocess.STDOUT,
                 stdin=subprocess.DEVNULL, start_new_session=True)
PY
sleep 3; tail -5 /tmp/hyprwm.log
