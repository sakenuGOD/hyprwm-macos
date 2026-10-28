"""Authenticated display-only forest collection, invoked only on event refresh."""
import json
import os
from pathlib import Path
import socket
import struct

from forest_codec import display_evidence, read_forest
from native_popup import native_identity, peer_uid


def status(control_path, expected_executable, *, socket_factory=socket.socket,
           identity_reader=native_identity, uid_reader=peer_uid):
    configured = Path(expected_executable).expanduser()
    if not configured.is_absolute():
        raise ValueError("absolute reviewed WM executable required")
    # The reviewed SwiftPM release directory is a symlink on this actual host.
    # Compare the resolved, exact executable to the kernel path, never a prefix.
    executable = configured.resolve()
    with socket_factory(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(1)
        client.connect(str(control_path))
        pid = struct.unpack("=i", client.getsockopt(0, 2, 4))[0]
        if pid <= 0 or uid_reader(client) != os.getuid():
            raise ValueError("same-user kernel WM peer required")
        identity = identity_reader(pid)
        birth = identity.get("birth")
        if (identity.get("executable") != str(executable) or not isinstance(birth, list)
                or len(birth) != 4 or birth[:2] != [pid, os.getuid()]):
            raise ValueError("reviewed WM process generation required")
        client.sendall(b"status\n")
        payload = bytearray()
        while b"\n" not in payload:
            data = client.recv(min(65536, 1048577 - len(payload)))
            if not data: raise ValueError("WM status closed before record")
            payload.extend(data)
            if len(payload) > 1048576: raise ValueError("WM status overflow")
        if identity_reader(pid) != identity:
            raise ValueError("WM process changed during status")
    value = json.loads(payload)
    if not isinstance(value, dict) or value.get("daemon", {}).get("pid") != pid:
        raise ValueError("WM status peer mismatch")
    return value, {"pid": pid, "uid": os.getuid(), **identity}


def collect(settings, control_path, metadata, run_json, *, status_reader=status):
    """Two native reads + two authenticated status reads; never an idle timer."""
    before, owner_before = status_reader(control_path, settings["wm_executable"])
    native_before = run_json([metadata, "snapshot"], timeout=1)
    forest = read_forest(Path(settings["forest_path"]))
    native_after = run_json([metadata, "snapshot"], timeout=1)
    after, owner_after = status_reader(control_path, settings["wm_executable"])
    evidence = display_evidence(forest, native_before, native_after, before, after,
                                owner_before, owner_after)
    return native_after, after, evidence
