#!/bin/zsh
# Остановить hyprwm и горячие клавиши (окна остаются, где стоят; скрытые возвращаются).
H=${0:A:h}
python3 -c "
import socket
try:
    s=socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect('/tmp/hyprwm.ctl'); s.sendall(b'unhide all\n'); print(s.recv(512).decode().strip())
except Exception as e: print('демон не ответил:', e)" 2>/dev/null
pkill -f "$H/keys/hyprkeys"; pkill -f "$H/hyprwm.py"; echo остановлено
