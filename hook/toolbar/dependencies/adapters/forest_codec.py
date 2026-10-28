"""Bounded saved-forest display evidence. No WM commands or action authority."""
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import sys
import time

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT))
from lib.model import integer, native_catalog, native_windows, tree_windows

MAX_BYTES = 1024 * 1024
MAX_SAVED_SPACES = 4096


class EpochError(ValueError):
    def __init__(self, diagnostics):
        super().__init__("WM sample/exclusion epoch changed")
        self.diagnostics = diagnostics


def _stat_key(info):
    return (info.st_dev, info.st_ino, info.st_uid, info.st_mode,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


@dataclass(frozen=True)
class ForestRead:
    data: bytes
    sha256: str
    identity: tuple
    started_ns: int
    ended_ns: int

    @property
    def mtime_ns(self):
        return self.identity[5]


def _read_once(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid()
                or before.st_mode & 0o022 or before.st_size > MAX_BYTES):
            raise ValueError("owned bounded regular forest file required")
        parts = []
        size = 0
        while True:
            value = os.read(fd, min(65536, MAX_BYTES + 1 - size))
            if not value:
                break
            parts.append(value)
            size += len(value)
            if size > MAX_BYTES:
                raise ValueError("forest file overflow")
        after = os.fstat(fd)
        named = os.lstat(path)
        if _stat_key(before) != _stat_key(after) or _stat_key(after) != _stat_key(named):
            raise ValueError("forest changed while reading")
        return b"".join(parts), _stat_key(after)
    finally:
        os.close(fd)


def read_forest(path):
    """Two immediate stable reads; no sleeps, writes, sockets or polling."""
    path = Path(path)
    if not path.is_absolute() or path != path.resolve():
        raise ValueError("canonical absolute forest path required")
    parent = path.parent.stat()
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o022:
        raise ValueError("owned non-writable forest parent required")
    started = time.monotonic_ns()
    first, before = _read_once(path)
    second, after = _read_once(path)
    if first != second or before != after:
        raise ValueError("forest double-read epoch changed")
    return ForestRead(second, hashlib.sha256(second).hexdigest(), after,
                      started, time.monotonic_ns())


def decode_forest(data, spaces):
    """Project actual catalog first; historical rows are not live Spaces."""
    if not isinstance(data, bytes) or len(data) > MAX_BYTES:
        raise ValueError("bounded forest bytes required")
    try:
        raw = json.loads(data)
    except (ValueError, UnicodeDecodeError, RecursionError) as error:
        raise ValueError("invalid bounded forest JSON") from error
    if not isinstance(raw, dict) or not isinstance(raw.get("spaces"), dict) or len(raw["spaces"]) > MAX_SAVED_SPACES:
        raise ValueError("bounded saved forest required")
    if len(spaces) > 64 or len({row["id"] for row in spaces}) != len(spaces):
        raise ValueError("bounded unique native catalog required")
    # Do not decode old trees for deleted native Spaces. Their count is bounded
    # by the file/row caps, not by the64 currently supported native Space cap.
    selected = {}
    leaves = 0
    for space in spaces:
        sid = space["id"]
        if not integer(sid, 1):
            raise ValueError("invalid current native Space")
        row = raw["spaces"].get(str(sid))
        if row is None:
            selected[sid] = None
            continue
        if not isinstance(row, dict) or "tree" not in row:
            raise ValueError("invalid current saved Space")
        wids = tree_windows(row["tree"])
        leaves += len(wids)
        if leaves > 512:
            raise ValueError("bounded current saved leaves required")
        selected[sid] = wids
    def ids(value, label, records=False):
        if not isinstance(value, list) or len(value) > 512:
            raise ValueError("bounded " + label + " required")
        found = set()
        for row in value:
            wid = row.get("wid") if records and isinstance(row, dict) else row
            if not integer(wid, 1) or wid in found:
                raise ValueError("invalid " + label)
            found.add(wid)
        return found
    excluded = ids(raw.get("floating"), "saved floating") | ids(raw.get("hidden"), "saved hidden", True)
    return selected, excluded, len(raw["spaces"])


def _owner(value):
    if (not isinstance(value, dict) or not integer(value.get("pid"), 1)
            or value.get("uid") != os.getuid() or not integer(value.get("uid"))):
        raise ValueError("authenticated kernel owner required")
    birth = value.get("birth")
    if (not isinstance(birth, list) or len(birth) != 4 or not all(integer(n) for n in birth)
            or birth[:2] != [value["pid"], value["uid"]] or birth[2] < 1 or birth[3] >= 1000000
            or not isinstance(value.get("executable"), str) or not value["executable"].startswith("/")):
        raise ValueError("invalid authenticated owner generation")
    return (value["pid"], value["uid"], tuple(birth), value["executable"])


def _status(value, owner, sid):
    if (not isinstance(value, dict) or not integer(value.get("space"), 1) or value["space"] != sid
            or value.get("enabled") is not True or value.get("runtime") != "swift"
            or value.get("mode", "engine") != "engine" or not isinstance(value.get("daemon"), dict)
            or value["daemon"].get("pid") != owner[0]):
        raise ValueError("fresh native Engine status required")
    excluded = set()
    for field in ("hidden", "floating"):
        rows = value.get(field)
        if not isinstance(rows, list) or len(rows) > 512 or not all(integer(wid, 1) for wid in rows) or len(set(rows)) != len(rows):
            raise ValueError("bounded live " + field + " required")
        excluded.update(rows)
    witness = value.get("workspace_manager")
    if (not isinstance(witness, dict) or not (witness.get("stable") is True or type(witness.get("stable")) is int and witness["stable"] == 1)
            or not integer(witness.get("space"), 1) or witness["space"] != sid):
        raise ValueError("stable native WM sample required")
    sequence, stamp = witness.get("sample_sequence"), witness.get("sampled_at")
    if not integer(sequence, 1) or type(stamp) not in (int, float) or not math.isfinite(stamp) or stamp < 0:
        raise ValueError("native WM sample epoch required")
    return excluded, sequence, stamp


def _metadata(raw):
    if (not isinstance(raw, dict) or raw.get("source") != "CoreGraphics+NSRunningApplication+SkyLight.read-only"
            or raw.get("census_scope") != "all-spaces" or raw.get("census_complete") is not True):
        raise ValueError("complete actual all-Space native census required")
    spaces = native_catalog(raw.get("catalog"))
    windows = native_windows(raw)
    result = {}
    for row in windows:
        birth = row.get("process_birth")
        bounds = row.get("bounds")
        if (not isinstance(birth, list) or len(birth) != 4 or not all(integer(n) for n in birth)
                or birth[0] != row["pid"] or birth[2] < 1 or birth[3] >= 1000000
                or birth[1] != os.getuid()
                or type(row.get("app_hidden")) is not bool or type(row.get("alpha")) not in (int, float)
                or not math.isfinite(row["alpha"]) or not 0 <= row["alpha"] <= 1
                or type(row.get("layer")) is not int or row["layer"] != 0
                or type(row.get("app_terminated")) is not bool
                or not isinstance(bounds, list) or len(bounds) != 4
                or any(type(n) not in (int, float) or not math.isfinite(n) or abs(n) > 10**7 for n in bounds)
                or "minimized" in row and type(row["minimized"]) is not bool):
            raise ValueError("actual native ownership/visibility fields required")
        if bounds[2] <= 0 or bounds[3] <= 0:
            # Root's actual diagnostic row65: an ordered-out0×0 CG object with
            # no Space membership. Its valid identity is not tiling evidence.
            # Only that exact noncandidate shape is dropped; malformed or
            # nonpositive real-member/onscreen geometry still refuses.
            if row["onscreen"] is False and not row["spaces"] and bounds[2:] == [0, 0]:
                continue
            raise ValueError("positive native candidate geometry required")
        result[row["wid"]] = row
    return spaces, result


def display_evidence(forest, native_before, native_after, status_before, status_after,
                     owner_before, owner_after, *, now_ns=None, now_wall_ns=None):
    """Icons only: callers supply kernel-authenticated control-peer identities.

    No returned row may authorize focus, move, close, layout or WM mutation.
    Status PID alone is not authentication. Root's existing lifecycle Control
    authenticates peer PID+birth/executable before and after the status request.
    """
    owner = _owner(owner_before)
    if owner != _owner(owner_after):
        raise ValueError("daemon generation changed")
    now = time.monotonic_ns() if now_ns is None else now_ns
    wall = time.time_ns() if now_wall_ns is None else now_wall_ns
    if (not isinstance(forest, ForestRead) or now < forest.ended_ns
            or now - forest.started_ns > 1000000000
            or forest.mtime_ns < (owner[2][2] * 1000000000 + owner[2][3] * 1000)
            or forest.mtime_ns > wall + 1000000000):
        raise ValueError("forest/read daemon epoch unavailable")
    before_spaces, before_windows = _metadata(native_before)
    spaces, windows = _metadata(native_after)
    if before_spaces != spaces:
        raise ValueError("native catalog changed")
    active = next(row["id"] for row in spaces if row["active"])
    before_excluded, before_sequence, before_stamp = _status(status_before, owner, active)
    excluded, sequence, stamp = _status(status_after, owner, active)
    if (before_excluded != excluded or sequence < before_sequence
            or status_before.get("tree") != status_after.get("tree")
            or status_before.get("rects") != status_after.get("rects")
            or stamp < before_stamp or now / 1e9 - before_stamp > 1 or stamp > now / 1e9 + .05):
        raise EpochError({"before_sequence": before_sequence, "after_sequence": sequence,
                          "sequence_delta": sequence - before_sequence,
                          "before_sampled_at": before_stamp, "after_sampled_at": stamp,
                          "python_monotonic": now / 1e9,
                          "before_age_seconds": now / 1e9 - before_stamp,
                          "after_age_seconds": now / 1e9 - stamp,
                          "exclusions_equal": before_excluded == excluded,
                          "current_tree_equal": status_before.get("tree") == status_after.get("tree"),
                          "current_rects_equal": status_before.get("rects") == status_after.get("rects"),
                          "before_excluded_count": len(before_excluded), "after_excluded_count": len(excluded),
                          "exclusion_symmetric_difference_count": len(before_excluded ^ excluded)})
    trees, saved_excluded, historical_count = decode_forest(forest.data, spaces)
    excluded |= saved_excluded
    memberships = {}
    for sid, leaves in trees.items():
        for wid in leaves or []:
            memberships.setdefault(wid, set()).add(sid)
    excluded |= {wid for wid, sids in memberships.items() if len(sids) != 1}
    result = {}
    for space in spaces:
        sid = space["id"]
        row = {"source": "WM.saved-forest+native-membership", "display_only": True,
               "action_authority": False, "saved_owner_generation_verified": False,
               "native_minimized_verified": False, "windows": [], "apps": [],
               "reason": "current-tree-remains-authoritative" if space["active"] else "saved-display-intersection"}
        result[sid] = row
        if space["active"] or space["type"] != 0 or trees[sid] is None:
            continue
        seen = set()
        for wid in trees[sid]:
            current, previous = windows.get(wid), before_windows.get(wid)
            if not current or not previous or wid in excluded:
                continue
            # A native membership/owner change over the bounded envelope drops
            # this item. Current titles/order are irrelevant to assignment.
            if any(current.get(key) != previous.get(key) for key in ("pid", "process_birth", "spaces", "app_hidden", "app_terminated", "layer")):
                continue
            if (sid not in current["spaces"] or current["app_hidden"] or current["app_terminated"] or current["alpha"] <= .05
                    or previous["alpha"] <= .05 or current.get("minimized") is True):
                continue
            row["windows"].append(current)
            key = current["bundle"] or "pid:" + str(current["pid"])
            if key not in seen:
                seen.add(key)
                row["apps"].append({"key": key, "bundle": current["bundle"], "name": current["app"] or "Окно"})
        row["display_verified"] = True
    return {"schema": 1, "spaces": result, "forest_sha256": forest.sha256,
            "forest_identity": list(forest.identity), "historical_space_rows": historical_count,
            "daemon_birth": list(owner[2]), "wm_sample_sequence": sequence,
            "saved_wid_reuse_guard": "current-native-PID+birth-only; no saved per-leaf owner",
            "display_only": True, "action_authority": False}
