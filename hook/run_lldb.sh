#!/bin/zsh
set -u
SCRIPT="$1"; P=$(pgrep -x WindowServer); LOG=/tmp/run_lldb.log; : > "$LOG"
sudo -n lldb --batch -p "$P" -o "command script import $SCRIPT" -o "detach" -o "quit" >"$LOG" 2>&1 &
WRAP=$!
for i in $(seq 1 50); do
  kill -0 $WRAP 2>/dev/null || { echo "lldb done ~$((i/2))s"; break; }
  sleep 0.5
  if [ $i -eq 50 ]; then echo "!!! hang -> dtrace-kill"; PIDS=$(pgrep -f "lldb --batch -p $P"); sudo -n dtrace -w -n "BEGIN { $(for q in ${(f)PIDS}; do print -n "system(\"/bin/kill -9 $q\"); "; done) exit(0); }" 2>/dev/null; fi
done
grep -vE 'using dumb|No entry for' "$LOG"
