"""Pure event/native catalog validation. Testable without WM or a desktop."""
import json
import math

KNOWN = {"window_opened", "window_closed", "window_focused", "space_changed", "layout_changed", "session_changed", "viewport_changed"}

def integer(value, minimum=0, maximum=2**53-1):
    return type(value) is int and minimum <= value <= maximum

class EventDecoder:
    def __init__(self):
        self.sequence = None
        self.connected = False
        self.buffer = b""

    def feed(self, data):
        self.buffer += data
        if len(self.buffer)>65536:
            raise ValueError("event buffer overflow")
        result=[]
        while b"\n" in self.buffer:
            line,self.buffer=self.buffer.split(b"\n",1)
            if len(line)>32768:
                raise ValueError("event line overflow")
            try: event=json.loads(line)
            except (ValueError, UnicodeDecodeError): raise ValueError("malformed event JSON")
            if not isinstance(event,dict) or not isinstance(event.get("event"),str):
                raise ValueError("invalid event envelope")
            name=event["event"]
            if name=="connected":
                if type(event.get("version")) is not int or event["version"]!=1: raise ValueError("unsupported WM event version")
                self.connected=True;self.sequence=None;result.append(("resync",event));continue
            if not self.connected: raise ValueError("event before connected header")
            seq=event.get("sequence")
            if not integer(seq,1): raise ValueError("invalid event sequence")
            gap=self.sequence is not None and seq!=self.sequence+1
            self.sequence=seq
            if gap: result.append(("resync",event))
            if name in KNOWN:
                if not integer(event.get("space"),1): raise ValueError("invalid native Space ID")
                window=event.get("window")
                if window is not None:
                    if not isinstance(window,dict) or any(not integer(window.get(key),1) for key in ("wid","pid")):
                        raise ValueError("invalid event window identity")
                    if not integer(window.get("space"),0):raise ValueError("invalid event window Space")
                    if window["space"]==0:
                        # EcosystemAPI caches census.window.space verbatim; it
                        # only filters positive WID/PID. Zero is unknown native
                        # membership, never a workspace assignment. Resync from
                        # strict current status/catalog while keeping transport.
                        result.append(("resync",event));continue
                result.append((name,event))
        return result

def native_catalog(raw):
    if not isinstance(raw,dict) or raw.get("schema")!=1 or raw.get("mode")!="native-readonly" or raw.get("source")!="SkyLight.read-only" or raw.get("setter_called") is not False:
        raise ValueError("native read-only catalog unavailable")
    if raw.get("consistent") is not True or raw.get("locked") is not False:
        raise ValueError("native catalog inconsistent or session locked")
    active=raw.get("active_after")
    if not integer(active,1) or raw.get("active_before")!=active:
        raise ValueError("active Space changed while reading catalog")
    displays=raw.get("displays")
    if not isinstance(displays,list) or len(displays)!=1:
        raise ValueError("current verified runtime supports one display")
    display=displays[0]
    if display.get("current_catalog")!=active or display.get("current_getter")!=active:
        raise ValueError("native current Space witnesses disagree")
    spaces=display.get("spaces")
    if not isinstance(spaces,list) or not 1<=len(spaces)<=64: raise ValueError("bounded native Space catalog required")
    seen=set();result=[]
    for row in spaces:
        if not isinstance(row,dict) or not integer(row.get("sid"),1) or row["sid"] in seen or not integer(row.get("type")) or not isinstance(row.get("uuid"),str) or len(row["uuid"])>128:
            raise ValueError("invalid native Space row")
        seen.add(row["sid"])
        result.append({"id":row["sid"],"type":row["type"],"uuid":row["uuid"],"active":row["sid"]==active})
    if active not in seen: raise ValueError("active Space absent from catalog")
    return result

def native_windows(raw):
    if not isinstance(raw,dict) or raw.get("schema")!=1 or raw.get("available") is not True:
        raise ValueError("native window membership unavailable")
    rows=raw.get("windows")
    if not isinstance(rows,list) or len(rows)>512: raise ValueError("bounded windows required")
    result=[];seen=set()
    for row in rows:
        if not isinstance(row,dict) or not integer(row.get("wid"),1) or not integer(row.get("pid"),1) or row["wid"] in seen:
            raise ValueError("invalid window identity")
        members=row.get("spaces")
        if not isinstance(members,list) or len(members)>64 or not all(integer(s,1) for s in members): raise ValueError("invalid native membership")
        if not all(isinstance(row.get(key),str) and len(row[key])<=512 for key in ("app","bundle","title")): raise ValueError("bounded app metadata required")
        if type(row.get("onscreen")) is not bool: raise ValueError("native onscreen boolean required")
        seen.add(row["wid"]);result.append(row)
    return result

def tree_windows(tree):
    """Decode the actual HyprCore Node.json shape, with bounded work.

    A leaf is a WM assignment, not native visibility or application identity.
    Do not infer leaves from census/opened events or a native Space membership.
    """
    pending=[(tree,0)];seen=set();result=[];nodes=0
    while pending:
        node,depth=pending.pop();nodes+=1
        if nodes>1023 or depth>64: raise ValueError("bounded tiling tree required")
        if node is None:
            if nodes!=1: raise ValueError("missing tiling branch")
            continue
        if not isinstance(node,dict): raise ValueError("invalid tiling node")
        if "wid" in node:
            wid=node["wid"]
            if not integer(wid,1) or wid in seen or any(key in node for key in ("a","b","split")):
                raise ValueError("invalid or duplicate tiling leaf")
            seen.add(wid);result.append(wid)
            if len(result)>512: raise ValueError("bounded tiling leaves required")
        else:
            if node.get("split") not in ("v","h") or "a" not in node or "b" not in node:
                raise ValueError("invalid tiling split")
            ratio=node.get("ratio",.5)
            if type(ratio) not in (int,float) or not math.isfinite(ratio) or not 0<ratio<1:
                raise ValueError("invalid tiling ratio")
            pending.extend(((node["b"],depth+1),(node["a"],depth+1)))
    return result

def _window_ids(value,name):
    if not isinstance(value,list) or len(value)>512 or not all(integer(wid,1) for wid in value) or len(set(value))!=len(value):
        raise ValueError("bounded "+name+" window IDs required")
    return set(value)

def _rect_windows(rects):
    if not isinstance(rects,dict) or len(rects)>512: raise ValueError("bounded WM rectangles required")
    result=set()
    for key,rect in rects.items():
        if not isinstance(key,str) or not key.isascii() or not key.isdigit() or str(int(key))!=key or not integer(int(key),1):
            raise ValueError("invalid WM rectangle identity")
        if not isinstance(rect,list) or len(rect)!=4 or any(type(value) not in (int,float) or not math.isfinite(value) or abs(value)>10**7 for value in rect) or rect[2]<=0 or rect[3]<=0:
            raise ValueError("invalid WM rectangle")
        result.add(int(key))
    return result

def _covered_windows(status):
    """Existing SnapshotHandoff.status witnesses for retained native sources.

    A source can be order-out during a legitimate displayed snapshot handoff.
    A positive, still-covered acquire/configure receipt avoids treating that as
    an app hide. An unqualified offscreen census row is still excluded.
    """
    snapshots=status.get("snapshots")
    if snapshots is None:return set()
    if not isinstance(snapshots,dict) or type(snapshots.get("enabled")) is not bool:
        raise ValueError("invalid snapshot handoff status")
    sources=_window_ids(snapshots.get("covered_sources"),"covered source")
    if not snapshots["enabled"] or not sources:return set()
    receipts=snapshots.get("receipts")
    if not isinstance(receipts,dict) or len(receipts)>64: raise ValueError("bounded snapshot receipts required")
    covered=set()
    for wid in sources:
        receipt=receipts.get(str(wid))
        if not isinstance(receipt,dict):continue
        stamp=receipt.get("time")
        if (integer(receipt.get("epoch"),1) and integer(receipt.get("clone"),1) and
            type(receipt.get("mode")) is int and receipt["mode"]==3 and
            type(receipt.get("result")) is int and receipt["result"] in (1,2,5) and
            type(stamp) in (int,float) and math.isfinite(stamp) and stamp>=0):covered.add(wid)
    return covered

def tiling_snapshot(spaces,windows,status=None):
    """Join current WM assignments with its projected layout and native census.

    Existing status publishes only the current Space tree. Inactive Space apps
    remain unknown/empty; a remembered tree or native membership is insufficient
    proof. This function does no I/O, polling, cache promotion or UI mutation.
    `selected` means this snapshot's three witnesses agree, not an atomic native
    transaction or future validity. Event gaps must trigger a new status read.
    """
    result={row["id"]:{"selected":False,"source":"unavailable","reason":"inactive-tree-unpublished","windows":[]} for row in spaces}
    active=[row for row in spaces if row.get("active") is True]
    if len(active)!=1 or len(result)!=len(spaces): raise ValueError("one native active Space required")
    current=active[0];sid=current["id"]
    result[sid]["reason"]="wm-status-required"
    if status is None:return result
    if not isinstance(status,dict) or not integer(status.get("space"),1) or status["space"]!=sid:
        raise ValueError("WM/native active Space disagree")
    if status.get("mode","engine")!="engine" or status.get("runtime","swift")!="swift":
        raise ValueError("native Engine tiling status required")
    if type(status.get("enabled")) is not bool: raise ValueError("WM enabled boolean required")
    if not status["enabled"]:
        result[sid]["reason"]="tiling-paused";return result
    if current["type"]!=0:
        result[sid]["reason"]="native-nonordinary-space";return result
    if "tree" not in status: raise ValueError("current WM tiling tree required")
    leaves=tree_windows(status["tree"])
    hidden=_window_ids(status.get("hidden"),"hidden")
    floating=_window_ids(status.get("floating"),"floating")
    projected=_rect_windows(status.get("rects"))
    covered=_covered_windows(status)
    allowed=set(leaves).intersection(projected).difference(hidden|floating)
    native={window["wid"]:window for window in windows}
    selected=[native[wid] for wid in leaves if wid in allowed and wid in native and
              sid in native[wid]["spaces"] and (native[wid].get("onscreen") is True or wid in covered) and
              native[wid].get("app_hidden",False) is False]
    result[sid]={"selected":True,"source":"WM.current-tree+rects+native-membership",
                 "reason":"current-snapshot-intersection","windows":selected}
    return result

def workspace_apps(spaces,windows,status=None):
    """Only apps with selected tiling windows; absent status fails closed.

    Controller integration must pass fresh status as the third argument. Kept
    optional so old callers cannot accidentally keep showing all native windows.
    """
    selected=tiling_snapshot(spaces,windows,status)
    result={sid:[] for sid in selected}
    for sid,row in selected.items():
        seen=set()
        for window in row["windows"]:
            key=window["bundle"] or "pid:"+str(window["pid"])
            if key in seen:continue
            seen.add(key)
            result[sid].append({"key":key,"bundle":window["bundle"],"name":window["app"] or "Окно"})
    return result

def committed_trees(raw):
    """Parse existing saved state as candidates only, never live proof.

    WM.stateJSON has all saved trees but no daemon birth/revision/leaf PID.
    Kept distinct so the renderer cannot promote persisted data to selected.
    """
    if not isinstance(raw,dict) or not isinstance(raw.get("spaces"),dict) or len(raw["spaces"])>64:
        raise ValueError("bounded committed WM spaces required")
    floating=_window_ids(raw.get("floating"),"floating")
    hidden=raw.get("hidden")
    if not isinstance(hidden,list) or len(hidden)>512 or any(not isinstance(row,dict) or not integer(row.get("wid"),1) for row in hidden):
        raise ValueError("bounded committed hidden records required")
    excluded=floating|{row["wid"] for row in hidden};result={}
    for key,row in raw["spaces"].items():
        if not isinstance(key,str) or not key.isascii() or not key.isdigit() or str(int(key))!=key or not integer(int(key),1) or not isinstance(row,dict) or "tree" not in row:
            raise ValueError("invalid committed Space state")
        result[int(key)]={"source":"WM.saved-state","selected":False,"reason":"no-live-revision-or-owner-witness",
                          "candidate_wids":[wid for wid in tree_windows(row["tree"]) if wid not in excluded]}
    return result

def clean_text(value,limit=36):
    # SketchyBar receives a single argument, with no shell expansion. Remove only
    # controls/newlines; preserve readable Unicode including Cyrillic.
    value=" ".join("".join(c if c.isprintable() else " " for c in str(value)).split())
    return value if len(value)<=limit else value[:limit-1]+"…"
