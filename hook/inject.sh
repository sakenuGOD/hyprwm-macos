#!/bin/zsh
# Разовая загрузка dylib в живой WindowServer через lldb, со сторожем.
set -u
DYLIB="$1"
P=$(pgrep -x WindowServer)
echo "WindowServer pid=$P  dylib=$DYLIB"
LOG=/tmp/inject_lldb.log
: > "$LOG"
sudo -n lldb --batch -p "$P" \
  -o "expr -- (void*)dlopen(\"$DYLIB\", 2)" \
  -o "detach" -o "quit" >"$LOG" 2>&1 &
WRAP=$!
# сторож: ждём до 20с, иначе убиваем lldb через dtrace (sudo kill нам не разрешён)
for i in $(seq 1 40); do
  if ! kill -0 $WRAP 2>/dev/null; then echo "lldb завершился за ~$((i/2))s"; break; fi
  sleep 0.5
  if [ $i -eq 40 ]; then
    echo "!!! lldb завис — освобождаю WindowServer через dtrace-kill"
    PIDS=$(pgrep -f "lldb --batch -p $P" | tr '\n' ' ')
    sudo -n dtrace -w -n "BEGIN { $(for q in $(echo $PIDS); do echo -n "system(\"/bin/kill -9 $q\"); "; done) exit(0); }" 2>/dev/null
  fi
done
echo "=== lldb output ==="; cat "$LOG" | grep -vE 'using dumb|No entry for'
