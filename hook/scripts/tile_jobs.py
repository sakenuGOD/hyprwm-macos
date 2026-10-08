#!/usr/bin/env python3
"""План раскладки (/tmp/tile_plan.json) + таблица WindowManager (/tmp/wm_map.json)
-> задания нативного resize (/tmp/wmresize_jobs.json). Только окна типа primary."""
import json, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "config"))
import hyprcfg
sp = hyprcfg.spring("windowsMove")           # пружина листа windowsMove из конфига
SPRING = [sp[0], sp[1], sp[2], 0.001] if sp else [1.0, 210.0, 24.0, 0.001]
plan = json.load(open("/tmp/tile_plan.json")); wm = json.load(open("/tmp/wm_map.json"))
jobs, skipped = [], []
for it in plan:
    app = wm.get(str(it["pid"]), {}); w = app.get("windows", {}).get(str(it["wid"]))
    if not w or w.get("type") != "primary":
        skipped.append("%s/%d" % (it["owner"], it["wid"])); continue
    x, y, ww, hh = it["to"]
    jobs.append({"conn": app["conn"], "uuid": w["uuid"], "wid": it["wid"], "x": x, "y": y, "w": ww, "h": hh, "spring": SPRING})
json.dump(jobs, open("/tmp/wmresize_jobs.json", "w"), indent=1)
print("заданий: %d, пропущено: %s, пружина windowsMove: %s" % (len(jobs), ", ".join(skipped) or "нет", SPRING))
