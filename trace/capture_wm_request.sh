#!/bin/zsh
# Поймать живой resize-запрос WindowManager.app: объект клиента, соединение и поля запроса.
# Точки останова с автопродолжением (-G true), lldb снимается через 25 с.
P=$(pgrep -f 'WindowManager.app/Contents/MacOS/WindowManager$' | head -1)
BASE=$(vmmap $P 2>/dev/null | awk '/__TEXT/ && /MacOS\/WindowManager$/ {split($2,a,"-"); print "0x"a[1]; exit}')
SLIDE=$(( BASE - 0x100000000 ))
SEND=$(printf '0x%x' $(( 0x1000aa6ec + SLIDE )))      # отправитель: x20 = клиент
IVAR=$(printf '0x%x' $(( 0x10045ffe0 + SLIDE )))      # глобал со смещением ivar соединения
LOG=/tmp/wm_req.log; : > $LOG
echo "WindowManager pid=$P base=$BASE send=$SEND ivar=$IVAR"
sudo -n lldb --batch -p $P \
  -o "breakpoint set -a $SEND -G true -C 'register read x0 x20' -C 'p/x *(long*)(\$x20 + *(long*)$IVAR)' -C 'po (id)*(long*)(\$x20 + *(long*)$IVAR)'" \
  -o "breakpoint set -n '-[_WMClientResizeWindowRequest encodeWithCoder:]' -G true -C 'po \$x0'" \
  -o "breakpoint set -n '+[_WMResizeTargetGeometry targetGeometryWithFrame:contentsGravity:]' -G true -C 'register read d0 d1 d2 d3' -C 'po \$x2'" \
  -o continue > $LOG 2>&1 &
L=$!
sleep 2; echo ">>> ЗАПИСЬ 25 с: окно Терминала → Окно → «Переместить и изменить размер» → «Левая половина»"
sleep 25
for q in $(pgrep -f "lldb --batch -p $P"); do sudo -n dtrace -w -n "BEGIN{system(\"/bin/kill -9 $q\");exit(0)}" >/dev/null 2>&1; done
sleep 1; ps -o stat= -p $P | sed 's/^/WindowManager stat: /'
grep -vE 'using dumb|No entry for' $LOG | grep -A12 -E 'x20 =|_WMClientResizeWindowRequest|d0 =' | head -80
