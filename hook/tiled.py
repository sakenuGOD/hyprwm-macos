#!/usr/bin/env python3
"""Фоновая раскладка: следит за окнами текущего рабочего стола и дотфайлами Hyprland.

- новое окно / закрытое окно (набор стабилен 2 опроса подряд) -> tile.sh (dwindle: новое окно
  делит текущую плитку, закрытое отдаёт место соседу);
- изменился любой .lua в дотфайлах -> пересборка конфига и перекладка.
Лог: /tmp/tiled.log. Остановить: kill $(cat /tmp/tiled.pid)
"""
import json
import os
import subprocess
import sys
import time

HOOK = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HOOK, "config"))
import hyprcfg  # noqa: E402

POLL = 0.7
LOG = open("/tmp/tiled.log", "a", buffering=1)


def log(*a):
    LOG.write(time.strftime("%H:%M:%S ") + " ".join(str(x) for x in a) + "\n")


def windows():
    out = subprocess.check_output([os.path.join(HOOK, "scripts", "wlist_json")], text=True)
    return frozenset(w["wid"] for w in json.loads(out)["windows"])


def retile(reason):
    log("перекладка:", reason)
    r = subprocess.run([os.path.join(HOOK, "tile.sh"), "tile"], capture_output=True, text=True)
    for line in (r.stdout + r.stderr).splitlines():
        if any(k in line for k in ("WMBATCH", "заданий", "минимум", "rror", "FAIL")):
            log("  ", line)


def main():
    open("/tmp/tiled.pid", "w").write(str(os.getpid()))
    log("старт, pid", os.getpid())
    last = windows()
    cfg_t = hyprcfg._newest_lua()
    retile("старт")
    last = windows()
    pending, seen = None, 0
    while True:
        time.sleep(POLL)
        try:
            cur = windows()
            t = hyprcfg._newest_lua()
            if t != cfg_t:
                cfg_t = t
                hyprcfg.load(force=True)
                retile("изменён конфиг")
                last = windows()
                continue
            if cur != last:
                if cur == pending:
                    seen += 1
                else:
                    pending, seen = cur, 1
                if seen >= 2:
                    added, gone = cur - last, last - cur
                    retile("окна +%s -%s" % (sorted(added), sorted(gone)))
                    last = windows()
                    pending, seen = None, 0
            else:
                pending, seen = None, 0
        except Exception as e:  # демон не должен падать из-за одной ошибки
            log("ошибка:", repr(e))
            time.sleep(2)


if __name__ == "__main__":
    main()
