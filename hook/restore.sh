#!/bin/zsh
# Вернуть окна в рамки до tile.sh (снимок /tmp/before_tile.json) тем же нативным resize.
set -eu
H=${0:A:h}; T=$H/../trace
python3 - <<'PY'
import json
b = json.load(open("/tmp/before_tile.json"))["windows"]
json.dump([{"wid": w["wid"], "pid": w["pid"], "owner": w["owner"], "to": [w["x"], w["y"], w["w"], w["h"]]} for w in b],
          open("/tmp/tile_plan.json", "w"))
PY
python3 -c "import json; print(' '.join(sorted({str(i['pid']) for i in json.load(open('/tmp/tile_plan.json'))})))" > /tmp/wmlookup.args
$T/run_lldb_wm_long.sh $T/wm_lookup.py | grep -E 'rror' || true
python3 $H/scripts/tile_jobs.py
$T/run_lldb_wm.sh $T/wm_resize_batch.py | grep -E 'WMBATCH|rror' || true
