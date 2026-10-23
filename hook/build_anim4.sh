#!/bin/zsh
# Собирает src/anim4.c в плоский образ для инъекции в WindowServer (anim4.bin + anim4.syms).
# Линкуем в dylib и берём ВЕСЬ __TEXT: внутренние adrp на константы резолвятся сами.
# Проверка: никаких внешних вызовов (stubs) и обращений к __DATA — их в образе нет.
set -eu
H=${0:A:h}; cd $H
clang -arch arm64e -O2 -ffreestanding -fno-builtin -fno-math-errno -fno-stack-protector -fno-stack-check \
      -fno-unwind-tables -fno-asynchronous-unwind-tables -Wall -Wno-unused-function -c src/anim4.c -o /tmp/anim4.o
clang -arch arm64e -dynamiclib -nostdlib -lSystem -Wl,-no_adhoc_codesign /tmp/anim4.o -o /tmp/anim4.dylib
if otool -l /tmp/anim4.dylib | grep -qE 'sectname (__stubs|__auth_stubs|__got|__auth_got|__data|__bss|__common)'; then
  echo "ОШИБКА: в образе есть stubs/got/__DATA:"; otool -l /tmp/anim4.dylib | grep sectname; exit 1
fi
python3 - <<'PY'
import subprocess, json, re
lc = subprocess.check_output(["otool","-l","/tmp/anim4.dylib"], text=True)
seg = re.search(r"segname __TEXT\n\s+vmaddr (0x[0-9a-f]+)\n\s+vmsize (0x[0-9a-f]+)\n\s+fileoff (\d+)\n\s+filesize (\d+)", lc)
vmaddr, vmsize, fileoff, filesize = int(seg[1],16), int(seg[2],16), int(seg[3]), int(seg[4])
assert vmaddr % 0x4000 == 0 and fileoff == 0
blob = open("/tmp/anim4.dylib","rb").read()[:filesize]
open("anim4.bin","wb").write(blob)
syms = {}
for l in subprocess.check_output(["nm","-g","/tmp/anim4.dylib"], text=True).splitlines():
    p = l.split()
    if len(p) == 3 and p[1] == "T": syms[p[2].lstrip("_")] = int(p[0],16) - vmaddr
json.dump({"size": filesize, "vmsize": vmsize, "syms": syms}, open("anim4.syms","w"), indent=1)
print("anim4.bin %d байт, vmsize 0x%x, %s" % (filesize, vmsize, syms))
PY
