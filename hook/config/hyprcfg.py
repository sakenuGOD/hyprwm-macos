"""Read Hyprland settings for HyprWM.

Run Lua files through hypr_shim.lua and cache the result in hypr_cfg.json.
Rebuild when a source Lua file is newer. HYPR_HOME overrides config/defaults.
"""
import json
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.environ.get("HYPR_HOME", os.path.join(HERE, "defaults"))
HYPR = os.path.join(HOME, ".config", "hypr")
CACHE = os.path.join(HERE, "hypr_cfg.json")

# Hyprland animation tree (leaf -> parent) for inherited settings
PARENT = {
    "windows": "global", "windowsIn": "windows", "windowsOut": "windows", "windowsMove": "windows",
    "layers": "global", "layersIn": "layers", "layersOut": "layers",
    "fade": "global", "fadeIn": "fade", "fadeOut": "fade", "fadeSwitch": "fade", "fadeShadow": "fade",
    "fadeGlow": "fade", "fadeDim": "fade", "fadeDpms": "fade",
    "fadeLayers": "fade", "fadeLayersIn": "fadeLayers", "fadeLayersOut": "fadeLayers",
    "fadePopups": "fade", "fadePopupsIn": "fadePopups", "fadePopupsOut": "fadePopups",
    "border": "global", "borderangle": "global", "shadowangle": "global", "glowangle": "global",
    "zoomFactor": "global", "monitorAdded": "global",
    "workspaces": "global", "workspacesIn": "workspaces", "workspacesOut": "workspaces",
    "specialWorkspace": "workspaces", "specialWorkspaceIn": "specialWorkspace",
    "specialWorkspaceOut": "specialWorkspace",
}
# hyprutils/Hyprland defaults (AnimationTree.cpp): global = (1, 8, "default"); *angle disabled
DEFAULTS = {
    "global": {"enabled": True, "speed": 8, "bezier": "default"},
    "borderangle": {"enabled": False, "speed": 1, "bezier": "default"},
    "shadowangle": {"enabled": False, "speed": 1, "bezier": "default"},
    "glowangle": {"enabled": False, "speed": 1, "bezier": "default"},
}
# Built-in Hyprland "default" curve
BUILTIN_CURVES = {"default": {"type": "bezier", "points": [[0, 0.75], [0.15, 1.0]]}}

_cfg = None


def _newest_lua():
    t = 0
    for root, _, files in os.walk(HYPR):
        for f in files:
            if f.endswith(".lua"):
                t = max(t, os.path.getmtime(os.path.join(root, f)))
    return t


def load(force=False):
    global _cfg
    if _cfg is not None and not force:
        return _cfg
    if force or not os.path.exists(CACHE) or os.path.getmtime(CACHE) < _newest_lua():
        subprocess.run(["lua", os.path.join(HERE, "hypr_shim.lua"), HOME, CACHE],
                       check=True, capture_output=True)
    _cfg = json.load(open(CACHE))
    if not _cfg.get("load_ok"):
        raise RuntimeError("Hyprland config failed to load: %s" % _cfg.get("load_error"))
    return _cfg


def general():
    return load()["config"].get("general", {})


def gaps():
    g = general()
    gi = g.get("gaps_in", 5)
    go = g.get("gaps_out", 20)
    if isinstance(go, (int, float)):
        go = {"top": go, "right": go, "bottom": go, "left": go}
    gi = gi if isinstance(gi, (int, float)) else gi.get("top", 5)
    return gi, {k: go.get(k, 20) for k in ("top", "right", "bottom", "left")}


def dwindle():
    return load()["config"].get("dwindle", {})


def animation(leaf):
    """Resolve a leaf as in Hyprland: a configured node overrides all settings
    (enabled, speed, curve, style); otherwise use the nearest configured ancestor.
    -> {enabled, speed, kind: spring|bezier, curve, style, node}"""
    anims = {a.get("leaf"): a for a in load()["animations"]}
    node = leaf
    while node:
        a = anims.get(node) or (DEFAULTS.get(node) if node not in PARENT or node in DEFAULTS else None)
        if a:
            break
        node = PARENT.get(node)
    else:
        node, a = "global", DEFAULTS["global"]
    kind, curve = ("spring", a["spring"]) if "spring" in a else ("bezier", a.get("bezier", "default"))
    return {"enabled": bool(a.get("enabled", True)), "speed": float(a.get("speed", 8)), "kind": kind,
            "curve": curve, "style": a.get("style", ""), "node": node}


def curves():
    """All curves: {name: {type, points | mass/stiffness/damping}}, including default."""
    out = dict(BUILTIN_CURVES)
    for name, c in load()["curves"].items():
        if c.get("type") == "spring":
            out[name] = {"type": "spring", "mass": float(c.get("mass", 1)), "stiffness": float(c.get("stiffness", 250)),
                         "damping": float(c.get("damping", c.get("dampening", 25)))}
        else:
            out[name] = {"type": "bezier", "points": c.get("points", [[0, 0], [1, 1]])}
    return out


def spring(leaf):
    """Return (mass, stiffness, damping) for a spring leaf, or None."""
    a = animation(leaf)
    if a["kind"] != "spring":
        return None
    c = load()["curves"].get(a["curve"], {})
    damping = c.get("damping", c.get("dampening", 25))
    return float(c.get("mass", 1)), float(c.get("stiffness", 250)), float(damping)


if __name__ == "__main__":
    load(force=True)
    print("gaps:", gaps())
    print("dwindle:", dwindle())
    for leaf in ("windowsMove", "windowsIn", "windowsOut", "border", "workspaces"):
        print("%-12s %s spring=%s" % (leaf, animation(leaf), spring(leaf)))


def _rgba(s):
    """'rgba(ffb4a4ee)' / 'rgb(1a1110)' / '0xeeffb4a4' -> (r, g, b, a) 0..1."""
    s = str(s).strip()
    if s.startswith("rgba(") or s.startswith("rgb("):
        h = s[s.index("(") + 1:s.index(")")]
        if len(h) == 6:
            h += "ff"
        return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4, 6))
    if s.startswith("0x"):                              # 0xAARRGGBB
        v = int(s, 16)
        return ((v >> 16 & 255) / 255, (v >> 8 & 255) / 255, (v & 255) / 255, (v >> 24 & 255) / 255)
    raise ValueError("color: " + s)


def border():
    """Border width, window radius, active gradient (colors, angle), inactive color."""
    g = general()
    col = g.get("col", {})
    act = col.get("active_border", "rgba(33ccffee)")
    if isinstance(act, dict):
        colors, angle = act.get("colors", []), act.get("angle", 0)
    else:
        colors, angle = [act], 0
    dec = load()["config"].get("decoration", {})
    return {"size": g.get("border_size", 1), "rounding": dec.get("rounding", 0),
            "active": [_rgba(x) for x in colors] or [_rgba("rgba(33ccffee)")], "angle": angle,
            "inactive": _rgba(col.get("inactive_border", "rgba(595959aa)"))}


def shadow():
    """decoration.shadow: (enabled, active alpha, inactive alpha, range, offset y, render_power)."""
    sh = load()["config"].get("decoration", {}).get("shadow", {})
    ca = _rgba(sh.get("color", "rgba(1a1a1aee)"))
    ci = _rgba(sh.get("color_inactive", sh.get("color", "rgba(1a1a1aee)")))
    off = sh.get("offset", [0, 0])
    return {"on": sh.get("enabled", True), "act": ca[3], "inact": ci[3], "range": sh.get("range", 4),
            "offset": off[1] if isinstance(off, (list, tuple)) else 0, "power": sh.get("render_power", 3)}
