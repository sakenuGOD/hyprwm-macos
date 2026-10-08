#!/bin/zsh
# usage: ghidra_decomp.sh <program> <addr> <outname>  -> notes/decomp/<outname>.c (через HTTP GhidraMCP :8089)
P=$1; A=$2; O=$3
curl -s --max-time 180 "http://127.0.0.1:8089/decompile_function?address=$A&program=$P&timeout=150" > /tmp/_dec.json
python3 - "$O" <<'PY'
import json,sys
raw=open('/tmp/_dec.json').read()
try:
    j=json.loads(raw)
    if isinstance(j,dict) and 'result' in j and isinstance(j['result'],str):
        try: j=json.loads(j['result'])
        except Exception: pass
    out=j.get('decompiled') if isinstance(j,dict) else None
    if out is None: out=raw
except Exception: out=raw
p='/Users/fsociety/Developer/re-tools/notes/decomp/'+sys.argv[1]+'.c'
open(p,'w').write(out); print(p, len(out.splitlines()),'lines')
PY
