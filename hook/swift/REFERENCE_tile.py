#!/usr/bin/env python3
# Python reference model used to generate Swift test fixtures. Not used at runtime.
"""Dwindle layout model for macOS windows.

Compute target rectangles while preserving the split tree between steps.
New windows split an existing leaf instead of rebuilding the whole layout.
Read gaps, split ratios and other layout values from the configuration.
The fixture generator runs this saved model with fake system adapters.
"""
import json
import os
import subprocess
import sys

HOOK = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = os.path.join(HOOK, "tile.state.json")
MINSIZE = os.path.join(HOOK, "minsize.json")   # Learned window minimum sizes: {wid: [width, height]}
sys.path.insert(0, os.path.join(HOOK, "config"))
import hyprcfg                  # Values from the Hyprland configuration

GAPS_IN, GAPS_OUT = hyprcfg.gaps()
SPLIT_WIDTH_MULT = float(hyprcfg.dwindle().get("split_width_multiplier", 1.0))
DEFAULT_RATIO = float(hyprcfg.dwindle().get("default_split_ratio", 1.0)) / 2.0   # Hyprland ratio 1.0 means a 50/50 split.
MIN_W, MIN_H = 200, 150

# Utility or floating windows that layout should leave alone.
SKIP_OWNERS = set()


# Split tree
def leaf(wid):
    return {"wid": wid}


def leaves(node):
    if node is None:
        return []
    if "wid" in node:
        return [node]
    return leaves(node["a"]) + leaves(node["b"])


def remove(node, wid):
    """Remove a leaf and replace its parent with the other child."""
    if node is None:
        return None
    if "wid" in node:
        return None if node["wid"] == wid else node
    a, b = remove(node["a"], wid), remove(node["b"], wid)
    if a is None:
        return b
    if b is None:
        return a
    node["a"], node["b"] = a, b
    return node


def insert(node, wid, target, box):
    """Split the target leaf, placing the new window in the second child."""
    if node is None:
        return leaf(wid)
    if "wid" in node:
        if target is not None and node["wid"] != target:
            return node
        split = "v" if box[2] > box[3] * SPLIT_WIDTH_MULT else "h"
        return {"split": split, "ratio": DEFAULT_RATIO, "a": node, "b": leaf(wid)}
    ba, bb = split_box(box, node)
    before = json.dumps(node)
    node["a"] = insert(node["a"], wid, target, ba)
    if json.dumps(node) == before:
        node["b"] = insert(node["b"], wid, target, bb)
    return node


MINS = {}


def load_mins():
    global MINS
    MINS = {int(k): v for k, v in json.load(open(MINSIZE)).items()} if os.path.exists(MINSIZE) else {}


def need(node):
    """Return the subtree minimum tile size, including gaps around windows."""
    if "wid" in node:
        mw, mh = MINS.get(node["wid"], (MIN_W, MIN_H))
        mw, mh = max(mw, MIN_W), max(mh, MIN_H)        # A learned zero on an axis must not reduce the default minimum.
        pad = 2 * max(GAPS_IN, *GAPS_OUT.values())     # Use the screen edge as the worst case.
        return mw + pad, mh + pad
    (aw, ah), (bw, bh) = need(node["a"]), need(node["b"])
    if node["split"] == "v":
        return aw + bw, max(ah, bh)
    return max(aw, bw), ah + bh


def split_box(box, node):
    """Split by ratio while allowing both subtree minimum sizes to fit."""
    x, y, w, h = box
    r = node.get("ratio", 0.5)
    (aw, ah), (bw, bh) = need(node["a"]), need(node["b"])
    if node["split"] == "v":
        wa = min(max(w * r, aw), max(w - bw, 0)) if aw + bw <= w else w * aw / (aw + bw)
        return (x, y, wa, h), (x + wa, y, w - wa, h)
    ha = min(max(h * r, ah), max(h - bh, 0)) if ah + bh <= h else h * ah / (ah + bh)
    return (x, y, w, ha), (x, y + ha, w, h - ha)


def boxes(node, box, out):
    if node is None:
        return out
    if "wid" in node:
        out[node["wid"]] = box
        return out
    ba, bb = split_box(box, node)
    boxes(node["a"], ba, out)
    boxes(node["b"], bb, out)
    return out


def with_gaps(box, area):
    """Apply gaps_out at screen edges and gaps_in on each interior side."""
    x, y, w, h = box
    ax, ay, aw, ah = area
    eps = 1.0
    l = GAPS_OUT["left"] if abs(x - ax) < eps else GAPS_IN
    t = GAPS_OUT["top"] if abs(y - ay) < eps else GAPS_IN
    r = GAPS_OUT["right"] if abs((x + w) - (ax + aw)) < eps else GAPS_IN
    b = GAPS_OUT["bottom"] if abs((y + h) - (ay + ah)) < eps else GAPS_IN
    return (x + l, y + t, max(MIN_W, w - l - r), max(MIN_H, h - t - b))


# System adapters
def snapshot():
    out = subprocess.check_output([os.path.join(HOOK, "scripts", "wlist_json")], text=True)
    d = json.loads(out)
    wins = [w for w in d["windows"] if w["owner"] not in SKIP_OWNERS]
    return d, wins


def load():
    if os.path.exists(STATE):
        return json.load(open(STATE))
    return {"tree": None, "focus": None}


def save(st):
    json.dump(st, open(STATE, "w"), indent=1)


def sync(st, wins, area):
    """Sync the tree with the current set of windows."""
    live = [w["wid"] for w in wins]
    for n in leaves(st["tree"]):
        if n["wid"] not in live:
            st["tree"] = remove(st["tree"], n["wid"])
    have = {n["wid"] for n in leaves(st["tree"])}
    for wid in live:
        if wid not in have:
            target = st.get("focus") if st.get("focus") in have else None
            st["tree"] = insert(st["tree"], wid, target, area)
            have.add(wid)
            st["focus"] = wid
    if st.get("focus") not in have:
        st["focus"] = live[0] if live else None
    return st


def plan(area, st, wins):
    cur = {w["wid"]: w for w in wins}
    raw = boxes(st["tree"], area, {})
    out = []
    for wid, box in raw.items():
        x, y, w, h = with_gaps(box, area)
        c = cur[wid]
        out.append({"wid": wid, "pid": c["pid"], "owner": c["owner"],
                    "from": (c["x"], c["y"], c["w"], c["h"]),
                    "to": (round(x), round(y), round(w), round(h)),
                    "dx": round(x - c["x"]), "dy": round(y - c["y"])})
    return out


def find_parent(node, wid, par=None):
    if node is None or "wid" in node:
        return par if node and node.get("wid") == wid else None
    return find_parent(node["a"], wid, node) or find_parent(node["b"], wid, node)


def neighbour(rects, wid, direction):
    """Find the nearest window in a direction using tile centers."""
    if wid not in rects:
        return None
    x, y, w, h = rects[wid]
    cx, cy = x + w / 2, y + h / 2
    best, bestd = None, None
    for other, (ox, oy, ow, oh) in rects.items():
        if other == wid:
            continue
        dx, dy = ox + ow / 2 - cx, oy + oh / 2 - cy
        ok = {"left": dx < -1 and abs(dy) < max(h, oh) / 2 + 1,
              "right": dx > 1 and abs(dy) < max(h, oh) / 2 + 1,
              "up": dy < -1 and abs(dx) < max(w, ow) / 2 + 1,
              "down": dy > 1 and abs(dx) < max(w, ow) / 2 + 1}[direction]
        if not ok:
            continue
        d = abs(dx) + abs(dy)
        if bestd is None or d < bestd:
            best, bestd = other, d
    return best


def swap(node, a, b):
    if node is None or "wid" in node:
        return
    for side in ("a", "b"):
        ch = node[side]
        if "wid" in ch and ch["wid"] in (a, b):
            ch["wid"] = b if ch["wid"] == a else a
        else:
            swap(ch, a, b)


def focused_wid(wins):
    """Find the active application window in front-to-back CGWindowList order."""
    front = subprocess.run(
        ["osascript", "-e", 'tell application "System Events" to get unix id of first process whose frontmost is true'],
        capture_output=True, text=True)
    try:
        pid = int(front.stdout.strip())
    except ValueError:
        return wins[0]["wid"] if wins else None
    for w in wins:
        if w["pid"] == pid:
            return w["wid"]
    return wins[0]["wid"] if wins else None


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "tile"
    d, wins = snapshot()
    v = d["visible"]
    area = (v["x"], v["y"], v["w"], v["h"])
    st = load()
    load_mins()

    if cmd == "learn":
        # Compare actual sizes with the last plan to learn window minimums.
        plan_prev = {i["wid"]: i for i in json.load(open("/tmp/tile_plan.json"))}
        mins = {int(k): v for k, v in json.load(open(MINSIZE)).items()} if os.path.exists(MINSIZE) else {}
        new = 0
        for w in wins:
            it = plan_prev.get(w["wid"])
            if not it:
                continue
            tw, th = it["to"][2], it["to"][3]
            mw, mh = mins.get(w["wid"], (0, 0))
            if w["w"] > tw + 6 and w["w"] > mw:
                mw = w["w"]; new += 1
            if w["h"] > th + 6 and w["h"] > mh:
                mh = w["h"]; new += 1
            if (mw, mh) != (0, 0):
                mins[w["wid"]] = (max(mw, MIN_W), max(mh, MIN_H))
        json.dump({str(k): v for k, v in mins.items()}, open(MINSIZE, "w"))
        print("новых минимумов:", new, mins)
        sys.exit(1 if new else 0)

    if cmd == "reset":
        st = {"tree": None, "focus": None}
    st = sync(st, wins, area)

    rects = {wid: with_gaps(b, area) for wid, b in boxes(st["tree"], area, {}).items()}

    if cmd in ("focus", "move"):
        direction = sys.argv[2]
        cur = focused_wid(wins)
        tgt = neighbour(rects, cur, direction)
        if tgt is None:
            print("нет окна в стороне", direction); return
        if cmd == "focus":
            st["focus"] = tgt
            save(st)
            pid = next(w["pid"] for w in wins if w["wid"] == tgt)
            subprocess.run(["osascript", "-e",
                            'tell application "System Events" to set frontmost of (first process whose unix id is %d) to true' % pid])
            print("фокус ->", tgt)
            return
        swap(st["tree"], cur, tgt)
        st["focus"] = cur
        print("поменял местами", cur, "и", tgt)

    if cmd == "balance":
        def rebal(n):
            if n is None or "wid" in n:
                return
            n["ratio"] = 0.5
            rebal(n["a"]); rebal(n["b"])
        rebal(st["tree"])

    if cmd == "togglesplit":
        # Toggle the split direction of the focused window parent.
        par = find_parent(st["tree"], focused_wid(wins))
        if par:
            par["split"] = "h" if par["split"] == "v" else "v"

    p = plan(area, st, wins)
    save(st)

    for it in p:
        print("%-10s wid=%-5d %4d,%-4d %4dx%-4d -> %4d,%-4d %4dx%-4d  сдвиг (%+d,%+d)" % (
            it["owner"], it["wid"], it["from"][0], it["from"][1], it["from"][2], it["from"][3],
            it["to"][0], it["to"][1], it["to"][2], it["to"][3], it["dx"], it["dy"]))

    json.dump(p, open("/tmp/tile_plan.json", "w"), indent=1)
    if cmd != "dry":
        with open("/tmp/anim.args", "w") as f:
            for it in p:
                if it["dx"] or it["dy"]:
                    f.write("WID=%d DX=%d DY=%d\n" % (it["wid"], it["dx"], it["dy"]))
        print("задания записаны в /tmp/anim.args")


if __name__ == "__main__":
    main()
