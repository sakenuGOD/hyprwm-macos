#!/bin/zsh
# lldb-скрипт в WindowManager.app со сторожем (25 с): attach -> import -> detach.
set -u
SCRIPT="$1"; P=$(pgrep -f 'WindowManager.app/Contents/MacOS/WindowManager$' | head -1); LOG=/tmp/run_lldb_wm.log; : > "$LOG"
sudo -n lldb --batch -p "$P" -o "command script import $SCRIPT" -o "detach" -o "quit" >"$LOG" 2>&1 &
W=$!
for i in $(seq 1 50); do
  kill -0 $W 2>/dev/null || break
  sleep 0.5
  if [ $i -eq 50 ]; then echo "!!! lldb завис -> снимаю"; for q in $(pgrep -f "lldb --batch -p $P"); do sudo -n dtrace -w -n "BEGIN{system(\"/bin/kill -9 $q\");exit(0)}" >/dev/null 2>&1; done; fi
done
grep -vE 'using dumb|No entry for' "$LOG"
