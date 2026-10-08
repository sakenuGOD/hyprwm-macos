"""Постоянный мост к WindowManager.app: один lldb на всё время работы демона.

Модуль внутри WindowManager поставить нельзя (песочница не даёт отобразить файл как код),
поэтому держим lldb подключённым: процесс работает свободно, на запрос lldb останавливает
его на ~0.1 с (interrupt -> wmsrv.do -> continue). Подключение и символы — один раз.
Если lldb умирает, ядро отпускает WindowManager; мост переподключается при следующем вызове.
"""
import base64
import json
import os
import select
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = "/tmp/hyprwm_lldb.log"


def wm_pid():
    out = subprocess.run(["pgrep", "-f", "WindowManager.app/Contents/MacOS/WindowManager$"],
                         capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


class Bridge:
    def __init__(self, log=print):
        self.lp = None
        self.pid = None
        self.log = log

    def alive(self):
        return self.lp is not None and self.lp.poll() is None and self.pid == wm_pid()

    def _send(self, line):
        self.lp.stdin.write(line + "\n")
        self.lp.stdin.flush()

    def _reply(self, timeout):
        end = time.time() + timeout
        buf = ""
        while time.time() < end:
            r, _, _ = select.select([self.lp.stdout], [], [], max(0.0, end - time.time()))
            if not r:
                break
            line = self.lp.stdout.readline()
            if not line:
                break
            with open(LOG, "a") as f:
                f.write(line)
            if line.startswith("@@R "):
                return json.loads(line[4:])
            buf += line
        raise TimeoutError("lldb не ответил: " + buf[-300:])

    def start(self):
        self.stop()
        self.pid = wm_pid()
        if not self.pid:
            raise RuntimeError("WindowManager не запущен")
        t0 = time.time()
        open(LOG, "w").close()
        self.lp = subprocess.Popen(["sudo", "-n", "lldb", "--no-use-colors", "-p", str(self.pid)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, bufsize=1)
        self._send("command script import " + os.path.join(HERE, "wmsrv.py"))
        r = self._call_stopped({"op": "setup"}, timeout=120)
        if not r.get("ok"):
            self.stop()
            raise RuntimeError("мост: " + r.get("error", "?"))
        self._send("script lldb.debugger.SetAsync(True)")
        self._send("process continue")
        self.log("мост к WindowManager %d готов за %.1f с (менеджер %s)" % (self.pid, time.time() - t0, r["mgr"]))

    def _call_stopped(self, req, timeout=10):
        b = base64.b64encode(json.dumps(req).encode()).decode()
        self._send("script wmsrv.do('%s')" % b)
        return self._reply(timeout)

    def call(self, req, timeout=10):
        if not self.alive():
            self.start()
        self._send("process interrupt")
        try:
            return self._call_stopped(req, timeout)
        finally:
            self._send("process continue")

    def stop(self):
        if self.lp and self.lp.poll() is None:
            try:
                self._send("process continue")   # на случай, если остановлен
                self._send("detach")
                self._send("quit")
                self.lp.stdin.close()
                self.lp.wait(5)
            except Exception:
                pass
        self.lp = None


if __name__ == "__main__":
    import sys
    b = Bridge()
    t = time.time()
    print(json.dumps(b.call({"op": "map", "pids": [int(x) for x in sys.argv[1:]]}), ensure_ascii=False)[:2000])
    print("map %.2f с" % (time.time() - t))
    t = time.time()
    print(b.call({"op": "map", "pids": [int(x) for x in sys.argv[1:]]})["ok"], "повтор %.2f с" % (time.time() - t))
    b.stop()
    print(subprocess.run(["ps", "-o", "stat=", "-p", str(b.pid)], capture_output=True, text=True).stdout.strip())
