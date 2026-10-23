#!/bin/zsh
# Собирает библиотеки демона (не движок: тот — build_anim4.sh). Демон подхватывает их при перезапуске.
set -eu
H=${0:A:h}; cd $H
mkdir -p build
W=(-O2 -Wall -Wno-deprecated-declarations)
clang $W -dynamiclib -framework ApplicationServices -F/System/Library/PrivateFrameworks -framework SkyLight \
      src/axlib.c -o build/libax.dylib
clang $W -fobjc-arc -dynamiclib -framework AppKit -framework ApplicationServices \
      -F/System/Library/PrivateFrameworks -framework SkyLight src/winsnap.m -o build/libwinsnap.dylib
clang $W -dynamiclib src/chanlib.c -o build/libhyprchan.dylib
echo "библиотеки собраны"
