#!/bin/zsh
# Команда демону вручную: hook/ctl.sh hide | unhide | resize 60 0 | status ...
python3 -c "
import socket,sys
s=socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect('/tmp/hyprwm.ctl'); s.sendall((' '.join(sys.argv[1:])+'\n').encode()); print(s.recv(65536).decode().strip())" "$@"
