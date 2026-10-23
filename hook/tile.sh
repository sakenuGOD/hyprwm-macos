#!/bin/zsh
# Тайлинг dwindle с нативным resize (через WindowManager.app) + действия с раскладкой.
# usage: tile.sh [tile|togglesplit|balance|reset|dry|focus <dir>|move <dir>]
set -eu
H=${0:A:h}; T=$H/../trace; CMD=${1:-tile}
exec 2>>/tmp/tile.err
$H/scripts/wlist_json > /tmp/before_tile.json
python3 $H/scripts/tile.py "$@"
[[ "$CMD" == "dry" || "$CMD" == "focus" ]] && exit 0      # focus ничего не двигает
python3 -c "import json; print(' '.join(sorted({str(i['pid']) for i in json.load(open('/tmp/tile_plan.json'))})))" > /tmp/wmlookup.args
$T/run_lldb_wm_long.sh $T/wm_lookup.py | grep -E '^WMMAP manager|rror' || true
python3 $H/scripts/tile_jobs.py
$T/run_lldb_wm.sh $T/wm_resize_batch.py | grep -E 'WMBATCH|rror' || true
[[ "$CMD" == "tile" || "$CMD" == "reset" ]] || exit 0
sleep 1.2
if ! python3 $H/scripts/tile.py learn; then
  python3 $H/scripts/tile.py tile >/dev/null
  python3 $H/scripts/tile_jobs.py
  $T/run_lldb_wm.sh $T/wm_resize_batch.py | grep -E 'WMBATCH|rror' || true
fi
