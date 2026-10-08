#!/bin/bash
# WindowServer RE stand — helper. Usage: ./re.sh <command>
set -euo pipefail

ROOT="$HOME/Developer/re-tools"
GHIDRA="/opt/homebrew/Cellar/ghidra/12.1.4/libexec"
PROJ="$ROOT/ghidra_proj"
PROJNAME="WS_RE"
MCP="http://127.0.0.1:8089"
export JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
export GHIDRA_HEADLESS_MAXMEM="${GHIDRA_HEADLESS_MAXMEM:-10G}"  # default 2G is too small for QuartzCore

cmd="${1:-help}"

case "$cmd" in
  status)
    echo "== MCP server =="
    if curl -s --max-time 4 "$MCP/check_connection" 2>/dev/null; then echo; else echo "DOWN — open Ghidra, load a program, enable GhidraMCP plugin (File->Configure)"; fi
    echo "== Ghidra project =="
    [ -f "$PROJ/$PROJNAME.lock" ] && echo "OPEN (GUI holds lock)" || echo "closed"
    echo "== function count =="
    curl -s --max-time 6 "$MCP/list_functions?offset=0&limit=100000" 2>/dev/null | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('functions',[])),'functions')" 2>/dev/null || echo "(unknown)"
    ;;
  gui)
    open -a Ghidra 2>/dev/null || "$GHIDRA/ghidraRun" &
    echo "launching Ghidra — open project $PROJNAME, double-click a program, File->Configure enable GhidraMCP"
    ;;
  import-extra)
    # Import QuartzCore + WindowServer into the project. Ghidra MUST be closed (project lock).
    [ -f "$PROJ/$PROJNAME.lock" ] && { echo "ERROR: Ghidra is open (project locked). Quit Ghidra first."; exit 1; }
    for bin in QuartzCore WindowServer; do
      echo "== importing $bin =="
      "$GHIDRA/support/analyzeHeadless" "$PROJ" "$PROJNAME" \
        -import "$ROOT/extracted/$bin" \
        -processor AARCH64:LE:64:AppleSilicon
    done
    echo "done — reopen Ghidra"
    ;;
  functions)
    # ./re.sh functions <pattern>   search function names via MCP
    pat="${2:-}"
    curl -s "$MCP/list_functions?offset=0&limit=100000" | python3 -c "
import json,sys,re
pat=sys.argv[1] if len(sys.argv)>1 else ''
d=json.load(sys.stdin).get('functions',[])
for f in d:
    if not pat or re.search(pat, f['name'], re.I):
        print(f['address'], f['name'])
" "$pat"
    ;;
  decompile)
    # ./re.sh decompile <funcname>
    curl -s "$MCP/decompile" -X POST -H 'Content-Type: text/plain' --data "${2:?need function name}"
    ;;
  help|*)
    echo "re.sh commands:"
    echo "  status        server + project + imported programs"
    echo "  gui           launch Ghidra"
    echo "  import-extra  add QuartzCore+WindowServer to project (Ghidra must be CLOSED)"
    echo "  functions [p] list/grep function names via MCP"
    echo "  decompile <f> decompile one function via MCP"
    ;;
esac
