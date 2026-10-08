#!/usr/bin/env python3
"""Клиент модуля hyprwm внутри WindowManager.app (сокет в его $TMPDIR)."""
import json, os, socket, subprocess, sys

# своя временная папка WindowManager: песочница пускает его только туда
WMTMP = subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip() + "com.apple.WindowManager/"
SOCK = WMTMP + "hyprwm.sock"
STATE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "wm.state")


class WM:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(3)
        self.s.connect(SOCK)
        self.f = self.s.makefile("rwb")

    def call(self, **req):
        self.f.write(json.dumps(req).encode() + b"\n"); self.f.flush()
        return json.loads(self.f.readline())


if __name__ == "__main__":
    op = sys.argv[1]
    wm = WM()
    if op == "setmgr":
        pid, addr = open(STATE).read().split()
        r = wm.call(op="ping")
        if str(r["pid"]) != pid:
            sys.exit("wm.state от другого WindowManager (%s, живой %s)" % (pid, r["pid"]))
        print(wm.call(op="mgr", addr="0x" + addr))
    elif op == "ping":
        print(json.dumps(wm.call(op="ping")))
    elif op == "map":
        print(json.dumps(wm.call(op="map", pids=[int(x) for x in sys.argv[2:]]), indent=1, ensure_ascii=False))
    elif op == "probe":
        print(json.dumps(wm.call(op="probe", cls=sys.argv[2]), indent=1))
