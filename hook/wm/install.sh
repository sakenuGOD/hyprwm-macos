#!/bin/zsh
# Поставить модуль в живой WindowManager (один раз на процесс WindowManager).
set -u
H=${0:A:h}; P=$(pgrep -f 'WindowManager.app/Contents/MacOS/WindowManager$' | head -1)
if [[ "$(python3 $H/wmctl.py ping 2>/dev/null)" == *"\"pid\": $P,"* ]]; then
  echo "модуль уже в WindowManager $P"; python3 $H/wmctl.py setmgr; exit $?
fi
DYLIB=$($H/build.sh) || exit 1
LOG=/tmp/hyprwm_install.log; : > $LOG
sudo -n lldb --batch -p $P -o "expr -- (void*)dlopen(\"$DYLIB\", 2)" \
  -o "command script import $H/findmgr.py" -o detach -o quit > $LOG 2>&1 &
W=$!
for i in $(seq 1 120); do kill -0 $W 2>/dev/null || break; sleep 0.5
  if [ $i -eq 120 ]; then echo "!!! lldb завис -> снимаю"; for q in $(pgrep -f "lldb --batch -p $P"); do sudo -n dtrace -w -n "BEGIN{system(\"/bin/kill -9 $q\");exit(0)}" >/dev/null 2>&1; done; fi
done
grep -E 'dlopen|\(void \*\)|FINDMGR|rror' $LOG
sleep 0.3
python3 $H/wmctl.py setmgr
