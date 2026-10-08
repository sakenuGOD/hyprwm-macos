#!/usr/bin/env python3
"""Бинды из дотфайлов Hyprland -> /tmp/hyprkeys.json для keys/hyprkeys.

Раскладка клавиш как на его Линуксе: SUPER = Option, CTRL = Control, ALT = Command
(на Линуксе keyd уже переставляет их так же — см. комментарий в nebula/binds.lua).
Берём только те действия, которые наш WM умеет; остальное печатаем как пропущенное.
"""
import json
import os
import sys

HOOK = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(HOOK, "config"))
import hyprcfg  # noqa: E402

MOD = {"SUPER": 0x0800, "CTRL": 0x1000, "SHIFT": 0x0200, "ALT": 0x0100}   # Carbon
KEY = {
    "left": 123, "right": 124, "down": 125, "up": 126, "return": 36, "escape": 53,
    "space": 49, "grave": 50, "tab": 48, "delete": 51,
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38,
    "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1,
    "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
    "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
}


# Линуксовые программы из exec_cmd -> приложения на маке (нет на маке — бинд пропускается).
APPS = {"kitty": "Ghostty", "zen-browser": "Zen", "dolphin": "Finder", "vesktop": "Discord",
        "code": "Visual Studio Code", "obsidian": "Obsidian", "keepassxc": "KeePassXC"}
# Lua-бинды без dsp: что они делают по описанию в дотфайле
LUA = {"Скрыть окно": ["hide"], "Вернуть скрытое": ["unhide"], "Равные пропорции": ["balance"],
       "Завершить приложение": ["quit"], "Spotify": ["exec", "Spotify"], "Telegram": ["exec", "Telegram"]}


def installed(app):
    return any(os.path.exists(os.path.join(d, app + ".app"))
               for d in ("/Applications", "/System/Applications", "/System/Library/CoreServices",
                         os.path.expanduser("~/Applications")))


def exec_to_cmd(line):
    w = line.split()
    if "--" in w:
        w = w[w.index("--") + 1:]
    if not w:
        return None
    if w[0] == "openrunner":                   # на маке это OpenRunner.app (Линукс-скрипт — его копия)
        return ["exec", "OpenRunner"] if installed("OpenRunner") else None
    app = APPS.get(w[0])
    if not app or not installed(app):
        return None
    rest = w[1:]
    if w[0] == "kitty":
        if "-e" in rest:                       # kitty --class X -e prog -> Ghostty с программой
            return ["exec", app, "-e"] + rest[rest.index("-e") + 1:]
        return ["exec", app, "--new"]
    return ["exec", app]


def action_to_cmd(a, desc=""):
    """Действие Hyprland -> команда демона hyprwm. None, если наш WM этого пока не умеет."""
    if isinstance(a, dict) and a.get("lua"):
        for k, v in LUA.items():
            if k in desc:
                if v[0] == "exec" and not installed(v[1]):
                    return None
                return v
        return None
    if not isinstance(a, dict) or "dsp" not in a:
        return None
    dsp, args = a["dsp"], (a.get("args") or [{}])
    arg = args[0] if isinstance(args[0], dict) else {}
    if dsp == "focus" and "direction" in arg:
        return ["focus", arg["direction"]]
    if dsp == "window.move" and "direction" in arg:
        return ["move", arg["direction"]]
    if dsp == "layout" and isinstance(args[0], str):
        if args[0] == "togglesplit":
            return ["togglesplit"]
        if args[0].startswith("preselect "):
            return ["preselect", args[0].split()[1]]
    if dsp == "window.float":
        return ["float"]
    if dsp == "window.fullscreen":
        return ["fullscreen", arg.get("mode", "fullscreen")]
    if dsp == "window.close":
        return ["close"]
    if dsp == "window.resize" and arg.get("relative"):
        return ["resize", str(arg.get("x", 0)), str(arg.get("y", 0))]
    if dsp == "exec_cmd" and isinstance(args[0], str):
        return exec_to_cmd(args[0])
    return None


def main():
    out, skipped = [], []
    seen = set()
    for b in hyprcfg.load()["binds"]:
        desc = b.get("opts", {}).get("description") or b["keys"]
        cmd = action_to_cmd(b["action"], desc)
        # ALT = Command: ⌘H/⌘M/⌘Tab/⌘Space на маке уже делают то же самое — не перехватываем
        ks = [p.strip().upper() for p in b["keys"].split("+")]
        if "ALT" in ks and "SUPER" not in ks:
            cmd = None
        if cmd is None:
            skipped.append(desc)
            continue
        parts = [p.strip() for p in b["keys"].split("+")]
        mods, key = 0, None
        for p in parts:
            if p.upper() in MOD:
                mods |= MOD[p.upper()]
            else:
                key = KEY.get(p.lower())
        if key is None or (mods, key) in seen:
            skipped.append(desc)
            continue
        seen.add((mods, key))
        out.append({"keycode": key, "mods": mods, "cmd": cmd, "desc": desc, "keys": b["keys"],
                    "repeat": bool(b.get("opts", {}).get("repeating"))})

    # своё: переложить принудительно (в Hyprland такого бинда нет — раскладка там сама, как и у нас)
    out.append({"keycode": KEY["t"], "mods": MOD["CTRL"] | MOD["SUPER"] | MOD["SHIFT"], "cmd": ["retile"],
                "desc": "[наше] Разложить окна", "keys": "CTRL + SUPER + SHIFT + T"})

    json.dump(out, open("/tmp/hyprkeys.json", "w"), ensure_ascii=False, indent=1)
    for b in out:
        print("+ %-28s %s" % (b["keys"], b["desc"]))
    print("\nвсего: %d; пока не умеем: %d" % (len(out), len(skipped)))


if __name__ == "__main__":
    main()
