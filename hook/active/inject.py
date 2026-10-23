#!/usr/bin/env python3
"""Загрузить hyprforce.dylib (активный вид всех окон, П3) в запущенное приложение: lldb attach → dlopen → detach.

Песочница приложения (Telegram, TextEdit, …) не даёт открыть файл вне контейнера — для таких модуль кладётся
в его контейнер ~/Library/Containers/<bundle id>/Data. Приложение стоит на паузе, пока lldb подключён (замер —
в логе демона). Повторная загрузка безопасна: модуль один раз на процесс.
Запуск руками: python3 hook/active/inject.py <pid>
"""
import os
import plistlib
import shutil
import subprocess
import sys
import time
import ctypes

HERE = os.path.dirname(os.path.abspath(__file__))
DYLIB = os.path.join(HERE, "hyprforce.dylib")
# Версия = CFG_CAP в hyprforce.m. dlopen того же пути вернёт уже загруженный старый образ, поэтому новая
# версия грузится под своим именем файла; процесс со старой версией (без cap) получает новую.
CAP = 5
NAME = "hyprforce.v%d.dylib" % CAP

_libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
_libc.notify_register_check.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int)]
_libc.notify_get_state.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint64)]


def cap(pid):
    """Версия модуля в процессе (0 — нет модуля с configure). Регистрацию имени держит сам модуль."""
    t, v = ctypes.c_int(), ctypes.c_uint64()
    if _libc.notify_register_check(("hyprwm.cap.%d" % pid).encode(), ctypes.byref(t)) != 0:
        return 0
    _libc.notify_get_state(t, ctypes.byref(v))
    _libc.notify_cancel(t)
    return v.value


def app_path(pid):
    exe = subprocess.run(["/bin/ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    i = exe.find(".app/")
    return exe[:i + 4] if i > 0 else None


def bundle_id(app):
    try:
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
            return plistlib.load(f).get("CFBundleIdentifier")
    except OSError:
        return None


def dylib_for(pid):
    """Путь, который процесс сможет открыть: контейнер песочницы, если он есть, иначе сам модуль."""
    app = app_path(pid)
    bid = bundle_id(app) if app else None
    box = os.path.expanduser("~/Library/Containers/%s/Data" % bid) if bid else None
    dst = os.path.join(box if box and os.path.isdir(box) else HERE, NAME)
    if not os.path.exists(dst) or os.path.getmtime(dst) < os.path.getmtime(DYLIB):
        shutil.copy2(DYLIB, dst)
    return dst


def loaded(pid):
    """Модуль этой версии уже в процессе (после перезапуска демона не грузить второй раз — пауза ~2 с)."""
    return cap(pid) >= CAP


def inject(pid, timeout=15):
    """-> (ок, сообщение, секунд под lldb)."""
    if loaded(pid):
        return True, "уже загружен", 0.0
    path = dylib_for(pid)
    t = time.time()
    try:
        out = subprocess.run(["sudo", "-n", "lldb", "--batch", "-p", str(pid),
                              "-o", 'expr (void*)dlopen("%s", 2)' % path, "-o", "expr (char*)dlerror()",
                              "-o", "detach", "-o", "quit"], capture_output=True, text=True, timeout=timeout).stdout
    except subprocess.TimeoutExpired:
        return False, "lldb не ответил за %d с" % timeout, time.time() - t
    dt = time.time() - t
    ok = "(void *) $0 = 0x0000000000000000" not in out and "(void *) $0 = 0x" in out
    err = next((l for l in out.splitlines() if l.startswith("(char *) $1") and "0x0000000000000000" not in l), "")
    return ok, (path if ok else (err or out[-300:])), dt


if __name__ == "__main__":
    print(inject(int(sys.argv[1])))
