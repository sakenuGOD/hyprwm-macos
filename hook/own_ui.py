"""Exact local HyprWM menu-bundle identity, independent of window names.

Imports and construction are inert. Root can compose this with system_ui.Resolver
to exclude the app's settings/onboarding windows without excluding a WM daemon.
"""
import json
import os
from pathlib import Path
import plistlib
import stat

BUNDLE_ID = 'dev.hyprwm.HyprWM'


def _read(path, limit):
    before = path.lstat()
    if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or
            before.st_mode & 0o022 or before.st_nlink != 1 or not 0 < before.st_size <= limit):
        raise ValueError('owned regular bundle metadata required')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(fd)
        data = os.read(fd, limit + 1)
        after = os.fstat(fd)
        stamp = lambda row: (row.st_dev, row.st_ino, row.st_size, row.st_mtime_ns)
        if stamp(before) != stamp(opened) or stamp(opened) != stamp(after) or stamp(after) != stamp(path.lstat()):
            raise ValueError('bundle metadata changed')
        if len(data) != after.st_size:
            raise ValueError('incomplete bundle metadata')
        return data
    finally:
        os.close(fd)


def menu_role(identity, hook):
    """A standalone Swift executable or an explicit native daemon never matches."""
    if not isinstance(identity, dict):
        return False
    binary = Path(hook).resolve().parent / 'dist/HyprWM.app/Contents/MacOS/hyprwm-swift'
    if identity.get('executable') != str(binary):
        return False
    argv = identity.get('argv')
    if (not isinstance(argv, list) or not argv or not isinstance(argv[0], str) or
            Path(argv[0]).resolve() != binary or
            argv[1:] not in ([], ['--menu-only'], ['--menu-only', '--show-settings'])):
        return False
    try:
        if binary.resolve() != binary or not binary.is_file():
            return False
        contents = binary.parents[1]
        info = plistlib.loads(_read(contents / 'Info.plist', 65536))
        manifest = json.loads(_read(contents / 'Resources/BuildManifest.json', 262144))
        return bool(isinstance(info, dict) and info.get('CFBundleIdentifier') == BUNDLE_ID and
                    info.get('CFBundleExecutable') == binary.name and info.get('HyprWMLaunchRole') == 'menu-only' and
                    info.get('LSUIElement') is True and isinstance(manifest, dict) and manifest.get('schema') == 1 and
                    manifest.get('bundle_id') == BUNDLE_ID and manifest.get('launch_role') == 'menu-only' and
                    manifest.get('source_root') == str(Path(hook).resolve().parent))
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException):
        return False


class Resolver:
    def __init__(self, hook, processes=None):
        self.hook, self.processes = hook, processes

    def __call__(self, pid):
        if type(pid) is not int or pid <= 0:
            return False
        try:
            if self.processes is None:
                try:
                    from .lifecycle import DarwinProcesses
                except ImportError:
                    from lifecycle import DarwinProcesses
                self.processes = DarwinProcesses()
            # Other applications need only a cheap native birth/path check.
            # Fetch argv solely for the exact bundle executable candidate.
            try:
                first = self.processes.identity(pid, read_argv=False)
            except TypeError:  # Small offline fixtures keep the one-argument interface.
                first = self.processes.identity(pid)
            expected = str(Path(self.hook).resolve().parent / 'dist/HyprWM.app/Contents/MacOS/hyprwm-swift')
            if not isinstance(first, dict) or first.get('executable') != expected:
                return False
            if first.get('argv') is None:
                full = self.processes.identity(pid)
                if not full or full.get('birth') != first.get('birth') or full.get('executable') != expected:
                    return False
                first = full
            birth = first.get('birth') if isinstance(first, dict) else None
            if (not isinstance(birth, (tuple, list)) or len(birth) != 4 or
                    any(type(value) is not int for value in birth) or birth[0] != pid or
                    birth[1] != os.getuid() or birth[2] <= 0 or not 0 <= birth[3] < 1000000 or
                    not menu_role(first, self.hook)):
                return False
            return first == self.processes.identity(pid)
        except (OSError, ValueError, TypeError, AttributeError):
            return False
