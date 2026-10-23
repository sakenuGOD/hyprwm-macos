#!/usr/bin/env python3
"""Scoped service lifecycle. No WindowServer loading or broad process signals.

Darwin process and socket contracts come from the local SDK libproc.h,
sys/proc_info.h, sys/sysctl.h and sys/un.h (SOL_LOCAL/LOCAL_PEERPID).
Imports perform no native calls. Tests inject process/control/store adapters.
"""
import argparse
import contextlib
import ctypes
import errno
import fcntl
import json
import os
import re
from pathlib import Path
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time

MAX_REPLY = 256 * 1024


class LifecycleError(RuntimeError):
    pass


def python_executable(path):
    if not isinstance(path, str):
        return False
    return bool(re.fullmatch(r'python3(?:\.\d+)?', Path(path).name) or
                ('/Python.framework/Versions/' in path and
                 path.endswith('/Resources/Python.app/Contents/MacOS/Python')))


def open_log(path):
    """Append to an owned regular log, never through an attacker-created link."""
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        os.close(fd)
        raise LifecycleError('unsafe service log: ' + str(path))
    os.fchmod(fd, 0o600)
    return os.fdopen(fd, 'ab')


class DarwinProcesses:
    class BSDInfo(ctypes.Structure):
        _fields_ = [('header', ctypes.c_uint32 * 12), ('comm', ctypes.c_char * 16),
                    ('name', ctypes.c_char * 32), ('tail', ctypes.c_uint32 * 6),
                    ('sec', ctypes.c_uint64), ('usec', ctypes.c_uint64)]

    def __init__(self):
        if sys.platform != 'darwin':
            raise LifecycleError('native service lifecycle requires macOS')
        self.lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.lib.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.libc.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
                                    ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]

    def argv(self, pid):
        mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2.
        size = ctypes.c_size_t()
        if self.libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) or not 4 < size.value <= 1024 * 1024:
            return None
        buffer = ctypes.create_string_buffer(size.value)
        if self.libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0):
            return None
        data = buffer.raw[:size.value]
        count = struct.unpack_from('=i', data)[0]
        if not 1 <= count <= 256:
            return None
        cursor = data.find(b'\0', 4)
        if cursor < 0:
            return None
        cursor += 1
        while cursor < len(data) and data[cursor] == 0:
            cursor += 1
        result = []
        for _ in range(count):
            end = data.find(b'\0', cursor)
            if end < 0:
                return None
            result.append(os.fsdecode(data[cursor:end]))
            cursor = end + 1
        return result  # Never parse, retain or print the environment tail.

    def identity(self, pid, *, read_argv=True):
        if type(pid) is not int or pid <= 0:
            return None
        value = self.BSDInfo()
        expected = ctypes.sizeof(value)
        if self.lib.proc_pidinfo(pid, 3, 0, ctypes.byref(value), expected) != expected:
            return None
        if value.header[3] != pid or value.header[5] != os.getuid() or not value.sec:
            return None
        executable = ctypes.create_string_buffer(4096)
        length = self.lib.proc_pidpath(pid, executable, len(executable))
        if not 0 < length < len(executable):
            return None
        argv = self.argv(pid) if read_argv else None
        after = self.BSDInfo()
        if self.lib.proc_pidinfo(pid, 3, 0, ctypes.byref(after), expected) != expected:
            return None
        birth = [pid, int(value.header[5]), int(value.sec), int(value.usec)]
        if birth != [int(after.header[3]), int(after.header[5]), int(after.sec), int(after.usec)]:
            return None
        fresh_path = ctypes.create_string_buffer(4096)
        if self.lib.proc_pidpath(pid, fresh_path, len(fresh_path)) <= 0 or fresh_path.value != executable.value:
            return None
        return {'pid': pid, 'birth': birth, 'executable': os.path.realpath(os.fsdecode(executable.value)), 'argv': argv}

    def all(self):
        needed = self.lib.proc_listpids(1, 0, None, 0)
        if not 0 < needed < 256 * 1024:
            raise LifecycleError('cannot obtain a bounded process census')
        size = min(256 * 1024, needed + 4096)
        buffer = (ctypes.c_int * (size // 4))()
        written = self.lib.proc_listpids(1, 0, buffer, ctypes.sizeof(buffer))
        if not 0 < written < ctypes.sizeof(buffer) or written % 4:
            raise LifecycleError('incomplete process census; refusing duplicate service launch')
        return [identity for pid in buffer[:written // 4] if pid > 0 and
                (identity := self.identity(pid, read_argv=False))]

    def terminate(self, identity):
        if self.identity(identity['pid']) != identity:
            raise LifecycleError('process generation changed; no signal sent')
        os.kill(identity['pid'], signal.SIGTERM)


class Control:
    def __init__(self, path, processes):
        self.path, self.processes = str(path), processes

    def request(self, command, expected=None):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(3)
            connection.connect(self.path)
            peer_pid = struct.unpack('=i', connection.getsockopt(0, 2, 4))[0]
            identity = self.processes.identity(peer_pid)
            if identity is None or (expected is not None and identity != expected):
                expected_owner = 'unbound' if expected is None else f"pid={expected.get('pid')},birth={expected.get('birth')}"
                observed_owner = 'unavailable' if identity is None else f"pid={identity.get('pid')},birth={identity.get('birth')}"
                raise LifecycleError('control peer process generation changed '
                                     f'(kernel_peer_pid={peer_pid}; expected={expected_owner}; observed={observed_owner})')
            connection.sendall((command + '\n').encode('utf-8'))
            result = bytearray()
            deadline = time.monotonic() + 3
            while b'\n' not in result:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise LifecycleError('control reply timed out')
                connection.settimeout(remaining)
                block = connection.recv(min(8192, MAX_REPLY + 1 - len(result)))
                if not block:
                    raise LifecycleError('incomplete control reply')
                result.extend(block)
                if len(result) > MAX_REPLY:
                    raise LifecycleError('control reply exceeds 256 KiB')
            after = self.processes.identity(peer_pid)
            if after != identity:
                observed_owner = 'unavailable' if after is None else f"pid={after.get('pid')},birth={after.get('birth')}"
                raise LifecycleError('control peer changed during request '
                                     f"(kernel_peer_pid={peer_pid}; authenticated_pid={identity.get('pid')},birth={identity.get('birth')}; observed={observed_owner})")
            return result.split(b'\n', 1)[0].decode('utf-8'), identity


class RecordStore:
    def __init__(self, directory, hook):
        self.directory, self.hook = Path(directory), str(hook)
        self.path = self.directory / 'lifecycle.json'

    def prepare(self):
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise LifecycleError('lifecycle directory must be owned by current user with mode 0700')

    @contextlib.contextmanager
    def lock(self):
        self.prepare()
        fd = os.open(self.directory / 'lifecycle.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise LifecycleError('unsafe lifecycle lock')
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise LifecycleError('another lifecycle action is in progress') from error
            yield
        finally:
            os.close(fd)

    def load(self):
        try:
            fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            return {'version': 1, 'hook': self.hook, 'owned': {}}
        with os.fdopen(fd, encoding='utf-8') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 65536 or info.st_mode & 0o077:
                raise LifecycleError('unsafe lifecycle record')
            value = json.load(stream)
        if not isinstance(value, dict) or value.get('version') != 1 or value.get('hook') != self.hook or not isinstance(value.get('owned'), dict):
            raise LifecycleError('lifecycle record belongs to another checkout or is invalid')
        for role, identity in value['owned'].items():
            if (role not in ('daemon', 'hotkeys', 'menu') or not isinstance(identity, dict) or
                    type(identity.get('pid')) is not int or identity['pid'] <= 0 or
                    not isinstance(identity.get('birth'), list) or len(identity['birth']) != 4 or
                    any(type(part) is not int for part in identity['birth']) or
                    identity['birth'][0] != identity['pid'] or identity['birth'][1] != os.getuid() or
                    not isinstance(identity.get('executable'), str) or
                    (identity.get('argv') is not None and not isinstance(identity.get('argv'), list))):
                raise LifecycleError('invalid lifecycle process identity')
        return value

    def save(self, value):
        fd, staged = tempfile.mkstemp(prefix='lifecycle-', dir=self.directory)
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as stream:
                json.dump(value, stream, ensure_ascii=False, indent=2)
                stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
            os.replace(staged, self.path)
        finally:
            if os.path.exists(staged):
                os.unlink(staged)


class Lifecycle:
    def __init__(self, hook, processes, control, store, *, spawn=None, clock=time.monotonic, sleep=time.sleep):
        self.hook = Path(hook).resolve()
        self.processes, self.control, self.store = processes, control, store
        self.spawn = spawn or self._spawn
        self.clock, self.sleep = clock, sleep

    def swift(self):
        available = [path.resolve() for mode in ('release', 'debug')
                     if (path := self.hook / 'swift/.build' / mode / 'hyprwm-swift').is_file()]
        return available # Release first; debug is an optional developer/menu build.

    def daemon_command(self, runtime):
        if runtime == 'python':
            return [sys.executable, '-u', str(self.hook / 'hyprwm.py')]
        if runtime != 'swift':
            raise LifecycleError('runtime must be swift or explicit developer python')
        binary = self.hook / 'swift/.build/release/hyprwm-swift'
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise LifecycleError('Swift release daemon is not built; run swift build -c release in hook/swift')
        return [str(binary.resolve())]

    def role(self, identity):
        if not isinstance(identity, dict):
            return None
        try:
            from .own_ui import menu_role
        except ImportError:
            from own_ui import menu_role
        if menu_role(identity, self.hook):
            return 'menu'
        path, argv = identity.get('executable'), identity.get('argv', [])
        if path == str((self.hook / 'keys/hyprkeys').resolve()):
            return 'hotkeys'
        if not isinstance(argv, list):
            return None
        if path in {str(path) for path in self.swift()}:
            return 'menu' if '--menu-only' in argv else ('daemon' if len(argv) == 1 else None)
        if (python_executable(path) and
                len(argv) >= 2 and isinstance(argv[-1], str) and os.path.isabs(argv[-1]) and
                str(Path(argv[-1]).resolve()) == str(self.hook / 'hyprwm.py') and
                all(arg in ('-u', '-B', '-I') for arg in argv[1:-1])):
            return 'daemon'
        return None

    def census(self):
        swift_paths = {str(path) for path in self.swift()}
        menu_bundle = str(self.hook.parent / 'dist/HyprWM.app/Contents/MacOS/hyprwm-swift')
        result = []
        for row in self.processes.all():
            # Only inspect argv for a possible daemon/menu executable; other
            # applications are discovered by kernel metadata without argv reads.
            path = row['executable']
            if path in swift_paths or path == menu_bundle or python_executable(path):
                fresh = self.processes.identity(row['pid'])
                if fresh and fresh['birth'] == row['birth'] and fresh['executable'] == path:
                    row = fresh
                else:
                    continue
            result.append(row)
        return result

    def status(self, expected=None):
        reply, identity = self.control.request('status', expected)
        if self.role(identity) != 'daemon':
            raise LifecycleError('control socket is not served by this checkout daemon')
        try:
            data = json.loads(reply)
        except ValueError as error:
            raise LifecycleError('daemon status is not JSON') from error
        if not isinstance(data, dict) or not isinstance(data.get('hidden'), list):
            raise LifecycleError('daemon status has no hidden-window ledger')
        daemon = data.get('daemon', {})
        if not isinstance(daemon, dict) or daemon.get('pid', identity['pid']) != identity['pid']:
            raise LifecycleError('daemon status PID differs from kernel control peer')
        runtime = 'python' if python_executable(identity['executable']) else 'swift'
        if daemon.get('runtime', data.get('runtime', runtime)) != runtime:
            raise LifecycleError('daemon runtime identity mismatch')
        data['daemon'] = {**daemon, 'pid': identity['pid'], 'runtime': runtime, 'birth': identity['birth']}
        return data, identity

    def optional_status(self):
        try:
            return self.status()
        except (FileNotFoundError, ConnectionRefusedError):
            return None
        except OSError as error:
            if error.errno == errno.ENOTCONN:
                return None
            raise

    def _spawn(self, command, log):
        environment = dict(os.environ, HYPRWM_HOOK=str(self.hook), HYPRWM_STATE_DIR=str(self.hook),
                           HYPRWM_CTL='/tmp/hyprwm.ctl', HYPRWM_ALLOW_LEGACY_INSTALL='0',
                           HYPRWM_ADOPT_ENGINE='1', HYPRWM_MENU_BAR='0',
                           HYPRWM_SNAPSHOT_FRAMES='0')
        with open_log(log) as stream:
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stream, stderr=stream,
                                     start_new_session=True, cwd=self.hook.parent, env=environment)
        return child.pid

    def launch(self, role, command, log, record):
        pid = self.spawn(command, log)
        deadline = self.clock() + 3
        while self.clock() < deadline:
            identity = self.processes.identity(pid)
            if identity and self.role(identity) == role:
                record['owned'][role] = identity
                self.store.save(record)
                return identity
            self.sleep(.05)
        raise LifecycleError(f'{role} did not publish its exact process identity; inspect {log}')

    def start(self, menu=True, runtime='swift'):
        record = self.store.load()
        current = self.optional_status()
        census = self.census()
        if current is None:
            swift_paths = {str(path) for path in self.swift()}
            if any(self.role(row) == 'daemon' or
                   (row['executable'] in swift_paths and row.get('argv') is None) for row in census):
                raise LifecycleError('daemon process already exists but control is unavailable; no second daemon launched')
            identity = self.launch('daemon', self.daemon_command(runtime),
                                   '/tmp/hyprwm.log', record)
            deadline = self.clock() + 10
            while self.clock() < deadline:
                try:
                    current = self.status(identity)
                    break
                except (FileNotFoundError, ConnectionRefusedError):
                    if self.processes.identity(identity['pid']) != identity:
                        raise LifecycleError('daemon exited during startup; inspect /tmp/hyprwm.log')
                    self.sleep(.1)
            if current is None:
                raise LifecycleError('daemon not ready; ownership record retained, no process was killed')
        notes = []
        keys = self.hook / 'keys/hyprkeys'
        if not any(self.role(row) == 'hotkeys' for row in census) and keys.is_file():
            # Existing hotkeys are left alone: rewriting their config is not an idempotent start.
            if self.spawn == self._spawn:
                with open_log('/tmp/hyprkeys.log') as output:
                    subprocess.run([sys.executable, str(self.hook / 'keys/binds.py')], check=True,
                                   cwd=self.hook.parent, stdout=output, stderr=output)
            self.launch('hotkeys', [str(keys)], '/tmp/hyprkeys.log', record)
        elif not keys.is_file():
            notes.append('hotkeys binary is not built')
        if menu and not any(self.role(row) == 'menu' for row in census):
            available = self.swift()
            ambiguous = any(row['executable'] in {str(path) for path in available} and
                            row.get('argv') is None for row in census)
            if ambiguous:
                notes.append('Swift process mode is unavailable; duplicate menu launch refused')
            elif available:
                self.launch('menu', [str(available[0]), '--menu-only'], '/tmp/hyprwm-menu.log', record)
            else:
                notes.append('Swift menu is not built')
        data, _ = current
        return {'ok': True, 'action': 'start', 'daemon': data['daemon'],
                'enabled': data.get('enabled', True), 'notes': notes}

    def start_hotkeys(self):
        record = self.store.load()
        if any(self.role(row) == 'hotkeys' for row in self.census()):
            return {'ok': True, 'action': 'hotkeys', 'already_running': True}
        keys = self.hook / 'keys/hyprkeys'
        if not keys.is_file():
            raise LifecycleError('hotkeys binary is not built')
        if self.spawn == self._spawn:
            with open_log('/tmp/hyprkeys.log') as output:
                subprocess.run([sys.executable, str(self.hook / 'keys/binds.py')], check=True,
                               cwd=self.hook.parent, stdout=output, stderr=output)
        self.launch('hotkeys', [str(keys)], '/tmp/hyprkeys.log', record)
        return {'ok': True, 'action': 'hotkeys', 'already_running': False}

    @staticmethod
    def drained(data):
        engine, visibility = data.get('engine', {}), data.get('visibility', {})
        fields = (engine.get('active'), engine.get('holding'), engine.get('pending_commands'))
        if (any(type(value) is not int or value < 0 for value in fields[:2]) or
                type(fields[2]) not in (int, bool) or fields[2] < 0):
            raise LifecycleError('daemon lacks shutdown drain evidence; update daemon before stopping')
        if not isinstance(visibility, dict) or not isinstance(visibility.get('restore_pending'), list) or not isinstance(visibility.get('restoring'), list):
            raise LifecycleError('daemon lacks restore-completion evidence; no process stopped')
        return (not data['hidden'] and fields == (0, 0, 0) and
                not visibility['restore_pending'] and not visibility['restoring'] and visibility.get('engine_recovery_active', False) is False)

    def stop(self, timeout=12):
        record = self.store.load()
        current = self.optional_status()
        if current is None:
            if any(self.role(row) == 'daemon' for row in self.census()):
                raise LifecycleError('daemon exists without authenticated control; hidden ledger retained, no signal sent')
            identity = None
        else:
            data, identity = current
            # Verify evidence support BEFORE temporarily resuming or restoring anything.
            self.drained(data)
            was_paused = data.get('enabled') is False
            terminated = False
            final_pause = False
            try:
                reply, _ = self.control.request('restore-all', identity)
                if not (reply.startswith(('restored ', 'error: Engine restoration pending:')) or reply == 'no hidden windows'):
                    raise LifecycleError('daemon refused return of hidden windows; no process stopped')
                deadline = self.clock() + timeout
                while self.clock() < deadline:
                    data, _ = self.status(identity)
                    if self.drained(data):
                        break
                    self.sleep(.1)
                else:
                    raise LifecycleError('hidden restore/drain timed out; daemon and ledger retained')
                reply, _ = self.control.request('pause', identity)
                if reply != 'paused':
                    raise LifecycleError('daemon refused final pause; no process stopped')
                final_pause = True
                data, _ = self.status(identity)
                if not self.drained(data):
                    raise LifecycleError('shutdown evidence changed after pause; daemon retained')
                self.processes.terminate(identity)
                terminated = True
                deadline = self.clock() + 3
                while self.processes.identity(identity['pid']) == identity and self.clock() < deadline:
                    self.sleep(.05)
                if self.processes.identity(identity['pid']) == identity:
                    raise LifecycleError('daemon did not exit after scoped SIGTERM; no SIGKILL sent')
                record['owned'].pop('daemon', None)
                self.store.save(record)
            finally:
                if not terminated and (was_paused or final_pause):
                    try:
                        self.control.request('pause' if was_paused else 'resume', identity)
                    except (OSError, LifecycleError):
                        pass
        stopped, retained = [], []
        for role in ('menu', 'hotkeys'):
            owned = record['owned'].get(role)
            if owned is None:
                continue
            if self.processes.identity(owned.get('pid')) != owned or self.role(owned) != role:
                retained.append(role + ': stale ownership record; no signal sent')
                continue
            self.processes.terminate(owned)
            deadline = self.clock() + 3
            while self.processes.identity(owned['pid']) == owned and self.clock() < deadline:
                self.sleep(.05)
            if self.processes.identity(owned['pid']) == owned:
                raise LifecycleError(role + ' did not exit; ownership retained, no SIGKILL sent')
            stopped.append(role)
            record['owned'].pop(role, None)
            self.store.save(record)
        return {'ok': True, 'action': 'stop', 'stopped_owned': stopped, 'notes': retained,
                'daemon_stopped': identity is not None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('start', 'stop', 'status', 'hotkeys'))
    parser.add_argument('--no-menu', action='store_true', help='start without Swift menu companion')
    parser.add_argument('--runtime', choices=('swift', 'python'), default='swift', help='Swift daemon by default; python is explicit developer fallback')
    args = parser.parse_args()
    hook = Path(__file__).resolve().parent
    try:
        processes = DarwinProcesses()
        store = RecordStore(Path.home() / 'Library/Application Support/HyprWM', hook)
        lifecycle = Lifecycle(hook, processes, Control('/tmp/hyprwm.ctl', processes), store)
        if args.action == 'status':
            result, _ = lifecycle.status()
        else:
            with store.lock():
                if args.action == 'start':
                    result = lifecycle.start(menu=not args.no_menu, runtime=args.runtime)
                elif args.action == 'hotkeys':
                    result = lifecycle.start_hotkeys()
                else:
                    result = lifecycle.stop()
        print(json.dumps(result, ensure_ascii=False))
    except (OSError, ValueError, LifecycleError, subprocess.CalledProcessError) as error:
        parser.exit(1, 'HyprWM lifecycle: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
