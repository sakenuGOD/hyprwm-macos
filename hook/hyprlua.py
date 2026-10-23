"""Живой Lua-рантайм дотфайлов (config/hypr_runtime.lua): бинды-функции из binds.lua исполняются
как есть, их вызовы hl.* обслуживает демон через handler(op, args)."""
import json
import os
import subprocess

HOOK = os.path.dirname(os.path.abspath(__file__))
sys_path_cfg = os.path.join(HOOK, "config")


class LuaRuntime:
    def __init__(self, home):
        self.home = home
        self.p = None
        self.binds = []
        self.start()

    def start(self):
        self.p = subprocess.Popen(["lua", os.path.join(sys_path_cfg, "hypr_runtime.lua"), self.home],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        for line in self.p.stdout:
            if line.startswith("@@BINDS "):
                self.binds = json.loads(line[8:])
                return
        raise RuntimeError("Lua-рантайм не выдал бинды")

    def call(self, i, handler):
        if self.p.poll() is not None:
            self.start()
        self.p.stdin.write(json.dumps({"op": "call", "i": i}) + "\n")
        self.p.stdin.flush()
        for line in self.p.stdout:
            if line.startswith("@@RPC "):
                req = json.loads(line[6:])
                try:
                    res = handler(req["op"], req.get("args") or [])
                except Exception as e:      # ошибка демона не должна вешать рантайм
                    res = None
                    handler("log", ["rpc %s упал: %r" % (req["op"], e)])
                self.p.stdin.write(json.dumps(res, ensure_ascii=False) + "\n")
                self.p.stdin.flush()
            elif line.startswith("@@DONE "):
                return json.loads(line[7:])
        raise RuntimeError("Lua-рантайм завершился")


def tiling_binds(binds):
    """Какие бинды конфига берёт мак-демон: блок [OmniWM] (тайлинг/окна) + полный экран.
    ALT-бинды (это Cmd на маке: ⌘H, ⌘M, ⌘Tab) не перехватываем — там родное поведение macOS."""
    out = []
    for b in binds:
        if b["mouse"] or "ALT" in b["keys"].split(" + ") and "CTRL" not in b["keys"]:
            continue
        if b["desc"].startswith("[OmniWM]") or b["desc"] == "Полный экран":
            out.append(b)
    return out
