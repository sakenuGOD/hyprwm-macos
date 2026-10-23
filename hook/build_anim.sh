#!/bin/zsh
# Собирает anim.c в плоский образ для инъекции в WindowServer.
# Линкуем в dylib и копируем ВЕСЬ __TEXT-сегмент целиком: тогда внутренние adrp/ldr
# (константы в __literal16) резолвятся сами — сегмент кладётся на страницу mmap как есть.
set -eu
H=${0:A:h}; cd $H
clang -arch arm64e -O2 -ffreestanding -fno-builtin -fno-stack-protector -fno-stack-check \
      -fno-unwind-tables -fno-asynchronous-unwind-tables -c src/anim.c -o /tmp/anim.o
clang -arch arm64e -dynamiclib -nostdlib -lSystem -Wl,-no_adhoc_codesign \
      /tmp/anim.o -o /tmp/anim.dylib
python3 - <<'PY'
import subprocess, json, re
lc = subprocess.check_output(["otool","-l","/tmp/anim.dylib"], text=True)
seg = re.search(r"segname __TEXT\n\s+vmaddr (0x[0-9a-f]+)\n\s+vmsize (0x[0-9a-f]+)\n\s+fileoff (\d+)\n\s+filesize (\d+)", lc)
vmaddr, vmsize, fileoff, filesize = int(seg[1],16), int(seg[2],16), int(seg[3]), int(seg[4])
assert vmaddr % 0x4000 == 0 and fileoff == 0, (hex(vmaddr), fileoff)
blob = open("/tmp/anim.dylib","rb").read()[:filesize]
open("anim.bin","wb").write(blob)
syms = {}
for l in subprocess.check_output(["nm","-g","/tmp/anim.dylib"], text=True).splitlines():
    p = l.split()
    if len(p) == 3 and p[1] == "T": syms[p[2].lstrip("_")] = int(p[0],16) - vmaddr
json.dump({"size": filesize, "vmsize": vmsize, "syms": syms}, open("anim.syms","w"), indent=1)
print("anim.bin %d байт, vmsize 0x%x, %s" % (filesize, vmsize, syms))
PY
