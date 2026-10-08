#!/bin/zsh
# Запись родного resize macOS: dtrace на WindowManager.app и на приложении-цели (25 с).
# usage: resize_capture.sh [имя_приложения]   (по умолчанию Terminal)
H=${0:A:h}; APP=${1:-Terminal}
AP=$(pgrep -x "$APP" | head -1); WM=$(pgrep -f 'WindowManager.app/Contents/MacOS/WindowManager$' | head -1)
[[ -z $AP || -z $WM ]] && { echo "нет процесса: $APP=$AP WindowManager=$WM"; exit 1; }
sudo -n dtrace -q -p $AP -s $H/resize_app.d -o /tmp/rz_app.txt 2>/tmp/rz_app.err &
sudo -n dtrace -q -p $WM -s $H/resize_wm.d  -o /tmp/rz_wm.txt  2>/tmp/rz_wm.err &
sleep 1.5
echo ">>> ЗАПИСЬ ИДЁТ 25 секунд. Сейчас в окне $APP: меню Окно → «Переместить и изменить размер» → «Левая половина»,"
echo ">>> потом ещё раз → «Правая половина» (или наведи на зелёную кнопку и выбери плитку)."
wait
echo "готово: app $(grep -c . /tmp/rz_app.txt 2>/dev/null) строк, wm $(grep -c . /tmp/rz_wm.txt 2>/dev/null) строк"
