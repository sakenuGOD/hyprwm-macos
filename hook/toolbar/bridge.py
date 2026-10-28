#!/usr/bin/env python3
"""Event-driven, read-only JSON bridge for the native menu-bar companion.

Run with --settings /absolute/settings.json. stdout is newline-delimited schema1
JSON; stdin accepts newline-delimited action objects. No bar module is imported.
Workspace actions remain disabled until a backend is separately qualified.

Window icons use the complete native census. IPC events trigger fresh reads;
explicit authenticated WM hidden exclusions remain, without forest dependency.
"""
import argparse
import json
import math
import os
from pathlib import Path
import selectors
import signal
import socket
import stat
import struct
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
DEPENDENCIES = HERE / "dependencies"
sys.path.insert(0, str(DEPENDENCIES))
sys.path.insert(0, str(DEPENDENCIES / "adapters"))
from lib.model import EventDecoder, integer, native_catalog, native_windows, tiling_snapshot, tree_windows
from forest_runtime import status as authenticated_status
from forest_codec import _metadata as validated_native_metadata
from forest_watch import ForestWatch
from native_popup import native_identity, peer_uid

MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_INPUT_BYTES = 16384
COALESCE_SECONDS = .030
RETRY_SECONDS = .150
REFRESH_RETRIES = 3


def settings_from_file(path):
    path = Path(path).expanduser()
    if not path.is_absolute() or path.stat().st_size > 65536:
        raise ValueError("absolute bounded settings file required")
    value = json.loads(path.read_bytes())
    if not isinstance(value, dict) or value.get("schema") != 1:
        raise ValueError("settings schema1 required")
    for name in ("events_socket", "control_socket", "metadata_helper", "forest_path", "wm_executable"):
        item = value.get(name)
        if not isinstance(item, str) or not item or not Path(item).is_absolute():
            raise ValueError("absolute configured " + name + " required")
    for name in ("events_socket", "control_socket"):
        if len(os.fsencode(value[name])) >= 104:
            raise ValueError("bounded Unix socket path required")
    if "workspace_clicks_enabled" in value and type(value["workspace_clicks_enabled"]) is not bool:
        raise ValueError("workspace_clicks_enabled must be boolean")
    # stdout is sufficient for the UI. A status artifact is optional and may
    # only be created within this companion's separate, explicit namespace.
    if value.get("status_path") is not None:
        status_path = Path(value["status_path"])
        if (not status_path.is_absolute() or status_path.name != "status.json"
                or status_path.parent.name != "hyprwm-native-companion"
                or status_path.parent != status_path.parent.resolve()):
            raise ValueError("status_path must use hyprwm-native-companion/status.json")
    return value


def run_json(arguments, *, timeout):
    """Only invoke the configured read-only metadata helper, with a deadline."""
    result = subprocess.run(arguments, check=True, timeout=timeout,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if len(result.stdout) > MAX_JSON_BYTES:
        raise ValueError("metadata response overflow")
    return json.loads(result.stdout)


def collect(settings, control_path, metadata, run_json, *, status_reader=authenticated_status):
    """Event-triggered bounded native census + authenticated hidden exclusions.

    No forest read, tiling/tree requirement, native action or idle WM polling.
    Both native catalogs and every current member's identity must stay stable.
    """
    before, owner_before = status_reader(control_path, settings["wm_executable"])
    native_before = run_json([metadata, "snapshot"], timeout=1)
    native_after = run_json([metadata, "snapshot"], timeout=1)
    after, owner_after = status_reader(control_path, settings["wm_executable"])
    if owner_before != owner_after:
        raise ValueError("authenticated WM generation changed")
    def hidden(value):
        rows = value.get("hidden") if isinstance(value, dict) else None
        if (not isinstance(rows, list) or len(rows) > 512 or not all(integer(wid, 1) for wid in rows)
                or len(set(rows)) != len(rows)):
            raise ValueError("bounded authenticated hidden exclusions required")
        return set(rows)
    excluded = hidden(after)
    if hidden(before) != excluded:
        raise ValueError("hidden exclusion epoch changed")
    before_spaces, before_windows = validated_native_metadata(native_before)
    after_spaces, after_windows = validated_native_metadata(native_after)
    if before_spaces != after_spaces:
        raise ValueError("native catalog epoch changed")
    def member_identity(windows):
        return {wid: tuple((key, tuple(row[key]) if isinstance(row[key], list) else row[key])
                           for key in ("pid", "process_birth", "spaces", "bundle", "app_hidden", "app_terminated", "layer"))
                for wid, row in windows.items() if row["spaces"]}
    if member_identity(before_windows) != member_identity(after_windows):
        raise ValueError("native window ownership or membership epoch changed")
    # Validate census scope/revision and strict display rules before publication.
    build_spaces(native_before, {"hidden": sorted(excluded)})
    build_spaces(native_after, {"hidden": sorted(excluded)})
    projection = {"hidden": sorted(excluded)}
    selection = after.get("toolbar_windows_by_space")
    if before.get("toolbar_windows_by_space") != selection:
        raise ValueError("WM selected-window epoch changed")
    if isinstance(selection, dict) and len(selection) <= 256:
        projection["toolbar_windows_by_space"] = selection
    # Every Space has its own stable rank. A changed layout is a torn sample,
    # so keep the previously published row while the event-triggered retry runs.
    ordering = after.get("tiling_order_by_space")
    if before.get("tiling_order_by_space") != ordering:
        raise ValueError("WM tiling-order epoch changed")
    if ordering is not None and after.get("enabled") is True:
        validate_tiling_order(ordering)
        projection["tiling_order_by_space"] = ordering
    # Compatibility with an older daemon; rank still never admits a member.
    if (before.get("enabled") is True and after.get("enabled") is True
            and all(before.get(key) == after.get(key) for key in ("space", "tree"))
            and integer(after.get("space"), 1)):
        try:
            projection.update(order_space=after["space"], order_wids=tree_windows(after.get("tree")))
        except ValueError:
            pass
    # A torn viewport must not suppress workspaces or the original app menus.
    if (after.get("enabled") is True and "viewport" in after
            and before.get("viewport") == after["viewport"]):
        projection["viewport"] = after["viewport"]
    return native_after, projection, None


def validate_tiling_order(value):
    if not isinstance(value, dict) or len(value) > 256:
        raise ValueError("bounded per-Space tiling order required")
    total = 0
    for sid, rows in value.items():
        if (not isinstance(sid, str) or not sid.isascii() or not sid.isdigit()
                or not integer(int(sid), 1) or str(int(sid)) != sid
                or not isinstance(rows, list) or len(rows) > 512):
            raise ValueError("invalid per-Space tiling order")
        seen = set(); total += len(rows)
        if total > 8192:
            raise ValueError("tiling order overflow")
        for row in rows:
            if (not isinstance(row, dict) or not integer(row.get("wid"), 1, 2**32-1)
                    or not integer(row.get("pid"), 1, 2**31-1)
                    or row["wid"] in seen or not isinstance(row.get("birth"), str)
                    or len(row["birth"]) > 128):
                raise ValueError("invalid tiling rank identity")
            seen.add(row["wid"])


def build_spaces(snapshot, status=None, evidence=None):
    """Display qualified native app windows; ignore WM tiling/floating/forest.

    metadata revision2+ already restricts its census to native regular-policy
    applications. Positive current-catalog membership excludes non-Space CG
    objects without guessing from PID, application name or window dimensions.
    A member of the active Space must actually be onscreen. Inactive-Space
    windows remain eligible: CoreGraphics marks them offscreen by definition.
    """
    if (not isinstance(snapshot, dict) or type(snapshot.get("schema")) is not int
            or snapshot["schema"] != 1 or snapshot.get("available") is not True
            or snapshot.get("source") != "CoreGraphics+NSRunningApplication+SkyLight.read-only"
            or snapshot.get("census_scope") != "all-spaces"
            or snapshot.get("census_complete") is not True
            or not integer(snapshot.get("metadata_revision"), 2)):
        raise ValueError("complete reviewed revision2+ native census required")
    catalog = snapshot.get("catalog")
    if not isinstance(catalog, dict) or type(catalog.get("schema")) is not int:
        raise ValueError("strict native catalog schema required")
    spaces = native_catalog(catalog)
    windows = native_windows(snapshot)
    if status is not None and not isinstance(status, dict):
        raise ValueError("WM hidden-exclusion object required")
    hidden_rows = status.get("hidden", []) if status is not None else []
    if (not isinstance(hidden_rows, list) or len(hidden_rows) > 512
            or not all(integer(wid, 1) for wid in hidden_rows)
            or len(set(hidden_rows)) != len(hidden_rows)):
        raise ValueError("bounded unique WM hidden-exclusion WIDs required")
    hidden = set(hidden_rows)
    members = {row["id"]: [] for row in spaces}
    active_sids = {row["id"] for row in spaces if row["active"]}
    for native in windows:
        if snapshot["metadata_revision"]>=3:
            if type(native.get("ordered_in")) is not bool:raise ValueError("native ordered-in witness required")
            if not native["ordered_in"]:continue
        sids = set(native["spaces"])
        if native["wid"] in hidden or not sids or not sids.issubset(members):
            continue
        if sids & active_sids and native.get("onscreen") is not True:
            continue
        birth = native.get("process_birth")
        alpha, bounds = native.get("alpha"), native.get("bounds")
        if (not isinstance(birth, list) or len(birth) != 4
                or not all(integer(value) for value in birth)
                or birth[:2] != [native["pid"], os.getuid()]
                or birth[2] < 1 or birth[3] >= 1000000
                or native.get("app_hidden") is not False
                or native.get("app_terminated") is not False
                or type(native.get("layer")) is not int or native["layer"] != 0
                or type(alpha) not in (int, float) or not math.isfinite(alpha) or not .05 < alpha <= 1
                or not isinstance(bounds, list) or len(bounds) != 4
                or any(type(value) not in (int, float) or not math.isfinite(value)
                       or abs(value) > 10**7 for value in bounds)
                or bounds[2] <= 0 or bounds[3] <= 0):
            continue
        descriptor = {"key": "wid:" + str(native["wid"]), "wid": native["wid"], "pid": native["pid"],
                      "bundle": native["bundle"], "name": native["app"], "process_birth": birth}
        for sid in sids:
            members[sid].append(descriptor)
    ordering = status.get("tiling_order_by_space") if status else None
    if ordering is not None:
        validate_tiling_order(ordering)
    # An unranked floating/native member has a stable identity-based tail;
    # native census enumeration is z-order and must never rank the bar.
    for sid, apps in members.items():
        rank = {}
        for index, row in enumerate((ordering or {}).get(str(sid), [])):
            for app in apps:
                birth = app["process_birth"]
                if (row["wid"] == app["wid"] and row["pid"] == app["pid"]
                        and row["birth"] == f"{birth[0]}:{birth[2]}:{birth[3]}"):
                    rank[app["wid"]] = index
        apps.sort(key=lambda app: (rank.get(app["wid"], 8192), app["wid"], app["pid"]))
    order_space = status.get("order_space") if status and ordering is None else None
    order_wids = status.get("order_wids", []) if status else []
    if (integer(order_space, 1) and isinstance(order_wids, list) and len(order_wids) <= 512
            and all(integer(wid, 1) for wid in order_wids) and len(set(order_wids)) == len(order_wids)):
        rank = {wid: index for index, wid in enumerate(order_wids)}
        members.get(order_space, []).sort(key=lambda app: (rank.get(app["wid"], len(rank)), app["wid"]))
    ordinal = 0
    result = []
    for space in spaces:
        sid = space["id"]
        if space["type"] == 0:
            ordinal += 1
        qualified = members[sid]
        selected = {"available": False, "app": "", "title": ""}
        selections = status.get("toolbar_windows_by_space", {}) if status else {}
        choice = selections.get(str(sid)) if isinstance(selections, dict) else None
        if (isinstance(choice, dict) and integer(choice.get("wid"), 1)
                and integer(choice.get("pid"), 1)
                and choice.get("source") in ("native-focus-history", "wm-space-selection")):
            app = next((app for app in qualified if app["wid"] == choice["wid"] and app["pid"] == choice["pid"]), None)
            if app is not None and app["name"]:
                birth = app["process_birth"]
                if choice.get("birth") == f"{birth[0]}:{birth[2]}:{birth[3]}":
                    native = next(row for row in windows if row["wid"] == app["wid"])
                    title = native.get("title", "") if snapshot.get("titles_permission") is True else ""
                    if not isinstance(title, str):
                        title = ""
                    title = "".join(char if char.isprintable() else " " for char in title)[:512]
                    selected = {"available": True, "app": app["name"], "title": title,
                                "wid": app["wid"], "pid": app["pid"], "process_birth": birth,
                                "source": choice["source"]}
        result.append({"sid": sid, "ordinal": ordinal if space["type"] == 0 else None,
                       "active": space["active"], "type": space["type"], "apps": qualified,
                       "apps_source": "complete-native-window-census", "apps_verified": True,
                       "window_count": len(qualified), "windows_truncated": False,
                       "selected_window": selected})
    return result


def unavailable_wm_tiled_window():
    return {"available": False, "app": "", "title": "", "source": "WM.status.current-tiled-window"}


def build_wm_tiled_window(snapshot, status):
    """Resolve the WM-reported tiled candidate through the current census.

    status.focus is the first onscreen tiled WID, not actual native app/window
    focus. This display field makes no claim about focused floating windows.
    This pure projection uses the already collected catalog/windows/status
    envelope and performs no native reads, status requests or WM polling.
    """
    if not isinstance(status, dict) or not integer(status.get("focus"), 1):
        return unavailable_wm_tiled_window()
    spaces = native_catalog(snapshot.get("catalog"))
    windows = native_windows(snapshot)
    active = next(row for row in spaces if row["active"])
    selected = tiling_snapshot(spaces, windows, status)[active["id"]]
    candidate = next((row for row in selected["windows"] if row["wid"] == status["focus"]), None)
    if candidate is None:
        return unavailable_wm_tiled_window()
    birth = candidate.get("process_birth")
    if (not isinstance(birth, list) or len(birth) != 4
            or not all(integer(value) for value in birth)
            or birth[:2] != [candidate["pid"], os.getuid()]
            or birth[2] < 1 or birth[3] >= 1000000
            or candidate.get("app_hidden") is not False
            or candidate.get("app_terminated") is not False):
        return unavailable_wm_tiled_window()
    return {"available": True, "app": candidate["app"], "title": candidate["title"],
            "source": "WM.status.current-tiled-window"}


def build_viewport(snapshot, status, spaces):
    """Optional crop control, bound to a current selected native member."""
    value = status.get("viewport") if isinstance(status, dict) else None
    unavailable = {"supported": False}
    if not isinstance(value, dict) or type(value.get("supported")) is not bool:
        return unavailable
    if value["supported"] is not True:
        return unavailable
    window = value.get("window")
    if window is None:
        return {"supported": True}
    if (not isinstance(window, dict) or not integer(window.get("wid"), 1, 2**32-1)
            or not integer(window.get("pid"), 1, 2**31-1)
            or not integer(window.get("space"), 1) or type(window.get("pending")) is not bool):
        return unavailable
    for key in ("x", "y", "max_x", "max_y"):
        number = window.get(key)
        if type(number) not in (int, float) or not 0 <= number <= 65536 or not math.isfinite(number):
            return unavailable
    if window["x"] > window["max_x"] or window["y"] > window["max_y"]:
        return unavailable
    active = next((row for row in spaces if row["active"] and row["type"] == 0), None)
    if not active or active["sid"] != window["space"]:
        return unavailable
    selected = active["selected_window"]
    birth = selected.get("process_birth")
    if (selected.get("available") is not True or not isinstance(birth, list) or len(birth) != 4
            or selected.get("wid") != window["wid"] or selected.get("pid") != window["pid"]
            or window.get("birth") != f"{birth[0]}:{birth[2]}:{birth[3]}"):
        return unavailable
    return {"supported": True, "window": {key: window[key] for key in
            ("wid", "pid", "birth", "space", "x", "y", "max_x", "max_y", "pending")}}


def viewport_selector(window):
    return {key: window[key] for key in ("wid", "pid", "birth", "space")}


def diagnostic_state(value):
    """Never persist private tiled-candidate app/title from owned UI IPC."""
    result = dict(value)
    candidate = value.get("wm_tiled_window", {})
    result["wm_tiled_window"] = {"available": candidate.get("available") is True,
                                  "app": "", "title": "", "redacted": True,
                                  "source": "WM.status.current-tiled-window"}
    result["spaces"] = [dict(row, selected_window=dict(row.get("selected_window", {}), app="", title="", redacted=True))
                        for row in value.get("spaces", [])]
    return result


def command_request(settings, arguments):
    """Send explicit selection to the authenticated WM; its worker owns native actions."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(1)
        client.connect(settings["control_socket"])
        pid = struct.unpack("=i", client.getsockopt(0, 2, 4))[0]
        identity = native_identity(pid)
        birth = identity.get("birth")
        if (peer_uid(client) != os.getuid() or identity.get("executable") != str(Path(settings["wm_executable"]).resolve())
                or not isinstance(birth, list) or len(birth) != 4 or birth[:2] != [pid, os.getuid()]):
            raise ValueError("authenticated WM command peer required")
        client.sendall((json.dumps(arguments) + "\n").encode())
        response = bytearray()
        while b"\n" not in response:
            chunk = client.recv(min(4096, 16385-len(response)))
            if not chunk:raise ValueError("incomplete workspace reply")
            response.extend(chunk)
            if len(response)>16384:raise ValueError("workspace reply overflow")
        if native_identity(pid) != identity:raise ValueError("WM generation changed")
        return response.split(b"\n",1)[0].decode()


def workspace_request(settings, ordinal):
    if not integer(ordinal, 1, 10):
        raise ValueError("ordinary ordinal1..10 required")
    return command_request(settings, ["workspace", str(ordinal)])


class Bridge:
    def __init__(self, settings, *, emitter=None, collector=collect, clock=time.monotonic,
                 selector=None):
        self.settings = settings
        self.emit = emitter or self.stdout_emit
        self.collector = collector
        self.clock = clock
        self.selector = selector or selectors.DefaultSelector()
        self.event_socket = None
        self.decoder = EventDecoder()
        self.transport_connected = False
        self.forest_watch = None
        self.forest_watching = False
        self.forest_retry_at = None
        self.forest_retries = 3
        self.event_retry_at = None
        self.event_header_deadline = None
        self.backoff = .5
        self.refresh_at = None
        self.refresh_retries = 0
        self.spaces = []
        self.wm_tiled_window = unavailable_wm_tiled_window()
        self.has_snapshot = False
        self.snapshot_at = None
        self.revision = 0
        self.error = "bootstrap-pending"
        self.input_buffer = b""
        self.running = True
        self.viewport = None
        self.pan_action = None
        self.pan_refresh_at = None

    @staticmethod
    def stdout_emit(value):
        print(json.dumps(value, ensure_ascii=False, separators=(",", ":")), flush=True)

    def state(self):
        available = (self.has_snapshot and not self.error and self.transport_connected)
        value = {"schema": 1, "kind": "state", "revision": self.revision,
                "spaces": self.spaces,
                "wm_tiled_window": dict(self.wm_tiled_window) if available else unavailable_wm_tiled_window(),
                "click_enabled": bool(available and self.clicks_qualified()),
                "click_reason": "" if available and self.clicks_qualified() else "backend-not-qualified" if self.settings.get("workspace_clicks_enabled") is True else "disabled-by-settings",
                "available": bool(available), "retained": self.has_snapshot and not available,
                "status": "available" if available else "retained" if self.has_snapshot else "unavailable",
                "reason": self.error or ("event-transport-unavailable" if not self.transport_connected else ""),
                "event_socket_connected": self.transport_connected,
                "forest_watching": self.forest_watching, "wm_state_polling": False,
                "last_snapshot_monotonic": self.snapshot_at, "display_only": True,
                "action_authority": False}
        if self.viewport is not None:
            value["viewport"] = dict(self.viewport) if available else {"supported": False}
        return value

    def clicks_qualified(self):
        return (self.settings.get("workspace_clicks_enabled") is True
                and self.settings.get("workspace_backend") in ("wm-verified-public-v1", "wm-native-dock-v1"))

    def publish(self):
        self.revision += 1
        value = self.state()
        self.emit(value)
        if self.settings.get("status_path"):
            self.write_status(value)

    def write_status(self, value):
        path = Path(self.settings["status_path"])
        path.parent.mkdir(mode=0o700, parents=False, exist_ok=True)
        info = path.parent.lstat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o700):
            raise ValueError("owned private companion status directory required")
        temporary = path.with_name(".status-" + str(os.getpid()) + ".tmp")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(diagnostic_state(value), stream, ensure_ascii=False)
                stream.write("\n")
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)

    def schedule_refresh(self):
        if self.refresh_at is None:
            self.refresh_at = self.clock() + COALESCE_SECONDS
        self.refresh_retries = REFRESH_RETRIES

    def refresh(self):
        self.refresh_at = None
        try:
            snapshot, status, evidence = self.collector(
                self.settings, self.settings["control_socket"],
                self.settings["metadata_helper"], run_json)
            spaces = build_spaces(snapshot, status, evidence)
            wm_tiled_window = unavailable_wm_tiled_window()
            viewport = build_viewport(snapshot, status, spaces) if isinstance(status, dict) and "viewport" in status else None
        except (OSError, ValueError, TypeError, KeyError, StopIteration, subprocess.SubprocessError):
            self.error = "sample-unavailable"
            if self.refresh_retries:
                self.refresh_retries -= 1
                self.refresh_at = self.clock() + RETRY_SECONDS
        else:
            self.spaces = spaces
            self.viewport = viewport
            self.wm_tiled_window = wm_tiled_window
            self.has_snapshot = True
            self.snapshot_at = self.clock()
            self.error = ""
            self.refresh_retries = 0
        self.publish()
        self.observe_pan()

    def ingest_events(self, data):
        for action, event in self.decoder.feed(data):
            if event["event"] == "connected":
                self.transport_connected = True
                self.event_header_deadline = None
                self.backoff = .5
            # EventDecoder turns reconnect, sequence gaps and unknown Space0
            # membership into resyncs. Never use events as membership evidence.
            self.schedule_refresh()

    def disconnect(self, reason="event-transport-eof"):
        if self.event_socket is not None:
            self.selector.unregister(self.event_socket)
            self.event_socket.close()
            self.event_socket = None
        self.decoder = EventDecoder()
        self.transport_connected = False
        self.event_header_deadline = None
        self.refresh_at = None
        self.refresh_retries = 0
        self.error = reason
        self.event_retry_at = self.clock() + self.backoff
        self.backoff = min(30, self.backoff * 2)
        if self.pan_action is not None:
            self.finish_pan(False, "pan-transport-disconnected")
        self.publish()

    def connect(self):
        self.event_retry_at = None
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            client.settimeout(.5)
            client.connect(self.settings["events_socket"])
            pid = struct.unpack("=i", client.getsockopt(0, 2, 4))[0]
            identity = native_identity(pid)
            birth = identity.get("birth")
            if (pid <= 0 or peer_uid(client) != os.getuid()
                    or identity.get("executable") != str(Path(self.settings["wm_executable"]).resolve())
                    or not isinstance(birth, list) or len(birth) != 4
                    or birth[:2] != [pid, os.getuid()]):
                raise ValueError("authenticated event peer required")
            client.setblocking(False)
            self.selector.register(client, selectors.EVENT_READ, "events")
            self.event_socket = client
            self.decoder = EventDecoder()
            self.event_header_deadline = self.clock() + 1
        except (OSError, ValueError):
            client.close()
            self.disconnect("event-transport-unavailable")

    def open_forest_watch(self):
        self.forest_retry_at = None
        watch = None
        try:
            watch = ForestWatch(self.settings["forest_path"])
            self.selector.register(watch, selectors.EVENT_READ, "forest")
            self.forest_watch = watch
            self.forest_watching = True
            self.schedule_refresh()
        except (OSError, ValueError):
            if watch is not None:
                watch.close()
            self.forest_watching = False
            if self.forest_retries:
                self.forest_retries -= 1
                self.forest_retry_at = self.clock() + RETRY_SECONDS
            # Forest notifications are optional hints, never native display authority.
            self.publish()

    def forest_ready(self):
        try:
            if self.forest_watch.drain():
                self.schedule_refresh()
        except (OSError, ValueError):
            self.selector.unregister(self.forest_watch)
            self.forest_watch.close()
            self.forest_watch = None
            self.forest_watching = False
            self.forest_retries = 3
            self.forest_retry_at = self.clock() + RETRY_SECONDS
            # Forest notifications are optional hints, never native display authority.
            self.publish()

    def finish_pan(self, acknowledged, reason):
        action = self.pan_action
        self.pan_action = None
        self.pan_refresh_at = None
        self.emit({"schema": 1, "kind": "action", "action": "pan", "ok": acknowledged,
                   "queued": True, "acknowledged": acknowledged, "retry_allowed": False,
                   "reason": reason, "window": action["window"], "request_id": action["request_id"]})

    def observe_pan(self):
        action = self.pan_action
        if action is None:
            return
        current = (self.viewport or {}).get("window")
        available = self.state()["available"]
        if (available and current and viewport_selector(current) == action["window"]
                and current["pending"] is False
                and abs(current["x"] - action["x"]) < .01
                and abs(current["y"] - action["y"]) < .01):
            self.finish_pan(True, "native-offset-acknowledged")
        elif self.clock() >= action["deadline"] or not available or (current and viewport_selector(current) != action["window"]):
            self.finish_pan(False, "pan-unconfirmed-or-selection-changed")
        else:
            self.pan_refresh_at = self.clock() + RETRY_SECONDS

    def request_pan(self, value):
        reply = {"schema": 1, "kind": "action", "action": "pan", "ok": False,
                 "queued": False, "acknowledged": False, "retry_allowed": False,
                 "reason": "pan-unavailable"}
        request_id = value.get("request_id")
        if (not isinstance(request_id, str) or not 1 <= len(request_id) <= 64
                or any(not (c.isascii() and (c.isalnum() or c == "-")) for c in request_id)):
            self.emit(reply)
            return
        reply["request_id"] = request_id
        direction = value.get("direction")
        if self.pan_action is not None or direction not in ("left", "right", "up", "down", "reset"):
            self.emit(reply)
            return
        try:
            if not self.state()["available"]:
                raise ValueError("unavailable")
            # Fresh status/census after AppKit mouse-up; never reuse the drawn selector.
            snapshot, status, evidence = self.collector(self.settings, self.settings["control_socket"],
                                                       self.settings["metadata_helper"], run_json)
            current = build_viewport(snapshot, status, build_spaces(snapshot, status, evidence)).get("window")
            if not current or current["pending"] or value.get("window") != viewport_selector(current):
                raise ValueError("stale or pending crop selection")
            x, y = current["x"], current["y"]
            if direction == "reset": x, y = 0, 0
            elif direction == "left": x = max(0, x-64)
            elif direction == "right": x = min(current["max_x"], x+64)
            elif direction == "up": y = max(0, y-64)
            else: y = min(current["max_y"], y+64)
            selector = viewport_selector(current)
            reply["window"] = selector
            response = command_request(self.settings, ["pan", direction, str(current["wid"]),
                                       str(current["pid"]), current["birth"], str(current["space"])])
            if response != f"content pan queued: {current['wid']} → {int(x)}, {int(y)}":
                raise ValueError("WM refused pan")
            self.pan_action = {"window": selector, "x": x, "y": y, "deadline": self.clock()+1.2, "request_id": request_id}
            self.pan_refresh_at = self.clock()+COALESCE_SECONDS
            reply.update(queued=True, reason="queued")
        except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
            reply["reason"] = "pan-target-or-peer-unavailable"
        self.emit(reply)

    def ingest_commands(self, data):
        self.input_buffer += data
        if len(self.input_buffer) > MAX_INPUT_BYTES:
            raise ValueError("command buffer overflow")
        while b"\n" in self.input_buffer:
            line, self.input_buffer = self.input_buffer.split(b"\n", 1)
            try:
                value = json.loads(line)
                if isinstance(value, dict) and value.get("action") == "pan":
                    self.request_pan(value)
                    continue
                valid = (isinstance(value, dict) and value.get("action") == "workspace"
                         and integer(value.get("sid"), 1))
            except (ValueError, UnicodeDecodeError):
                valid = False
            reply = {"schema": 1, "kind": "action", "ok": False, "queued": False,
                     "acknowledged": False, "retry_allowed": False,
                     "reason": "workspace-clicks-disabled" if valid else "invalid-command"}
            if valid and self.clicks_qualified() and self.state()["click_enabled"]:
                try:
                    snapshot=run_json([self.settings["metadata_helper"],"snapshot"],timeout=1)
                    ordinary=[row for row in native_catalog(snapshot["catalog"]) if row["type"]==0]
                    targets=[i+1 for i,row in enumerate(ordinary) if row["id"]==value["sid"]]
                    if len(targets)!=1 or targets[0]>10:raise ValueError("stale ordinary target")
                    response=workspace_request(self.settings,targets[0])
                    reply["queued"]=response==f"workspace request queued: {targets[0]}; acknowledgement pending"
                    reply["ok"]=reply["queued"] or response==f"workspace{targets[0]} already active"
                    reply["reason"]="queued" if reply["queued"] else "already-active" if reply["ok"] else "wm-refused"
                    self.schedule_refresh()
                except (OSError,ValueError,KeyError,subprocess.SubprocessError):
                    reply["reason"]="workspace-target-or-peer-unavailable"
            self.emit(reply)

    def advance(self):
        now = self.clock()
        if self.event_header_deadline is not None and self.event_header_deadline <= now:
            self.disconnect("event-header-unavailable")
        if self.event_retry_at is not None and self.event_retry_at <= now:
            self.connect()
        if self.forest_retry_at is not None and self.forest_retry_at <= now:
            self.open_forest_watch()
        if self.pan_refresh_at is not None and self.pan_refresh_at <= now:
            self.pan_refresh_at = None
            self.refresh()
        elif self.refresh_at is not None and self.refresh_at <= now:
            self.refresh()

    def next_timeout(self):
        deadlines = [value for value in (self.refresh_at, self.event_retry_at, self.forest_retry_at,
                                        self.event_header_deadline, self.pan_refresh_at)
                     if value is not None]
        return max(0, min(deadlines) - self.clock()) if deadlines else None

    def close(self):
        for resource in (self.event_socket, self.forest_watch):
            if resource is not None:
                try:
                    self.selector.unregister(resource)
                finally:
                    resource.close()
        self.event_socket = self.forest_watch = None
        self.selector.close()

    def serve(self, input_fd=0):
        # A private pipe wakes an indefinitely blocked selector on termination.
        # Only this bridge and its own bounded metadata child are ever stopped.
        wake_read, wake_write = os.pipe()
        os.set_blocking(wake_read, False)
        os.set_blocking(wake_write, False)
        previous = {}
        def stop(_signum, _frame):
            self.running = False
            try:
                os.write(wake_write, b"x")
            except OSError:
                pass
        try:
            self.selector.register(wake_read, selectors.EVENT_READ, "wake")
            self.selector.register(input_fd, selectors.EVENT_READ, "stdin")
            for signum in (signal.SIGTERM, signal.SIGINT):
                previous[signum] = signal.signal(signum, stop)
            self.publish()
            self.open_forest_watch()
            self.connect()
            self.schedule_refresh()  # one bootstrap envelope, then events only
            while self.running:
                self.advance()
                for key, _mask in self.selector.select(self.next_timeout()):
                    if key.data == "wake":
                        os.read(wake_read, 4096)
                    elif key.data == "stdin":
                        data = os.read(input_fd, 4096)
                        if not data:
                            self.running = False
                            break
                        try:
                            self.ingest_commands(data)
                        except ValueError:
                            self.running = False
                            break
                    elif key.data == "forest":
                        self.forest_ready()
                    elif key.data == "events":
                        try:
                            data = self.event_socket.recv(32768)
                            if data:
                                self.ingest_events(data)
                            else:
                                self.disconnect()
                        except BlockingIOError:
                            pass
                        except (OSError, ValueError):
                            self.disconnect("event-transport-invalid")
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)
            self.close()
            os.close(wake_read)
            os.close(wake_write)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--settings", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        Bridge(settings_from_file(arguments.settings)).serve()
    except BrokenPipeError:
        return 0
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        print("native-companion bridge unavailable", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
