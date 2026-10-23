#!/bin/zsh
# Собрать модуль для WindowManager.app. Имя с меткой времени: dlopen того же пути второй раз не перезагружает.
set -eu
setopt nullglob
H=${0:A:h}; OUT=$H/build; mkdir -p $OUT
V=$(date +%s)
clang -arch arm64e -dynamiclib -fobjc-arc -O2 -framework Foundation -o $OUT/wmhook.$V.dylib $H/wmhook.m
# песочница WindowManager читает только свою временную папку
WD=$(getconf DARWIN_USER_TEMP_DIR)com.apple.WindowManager; mkdir -p $WD
rm -f $WD/wmhook.*.dylib; cp $OUT/wmhook.$V.dylib $WD/
echo $WD/wmhook.$V.dylib
