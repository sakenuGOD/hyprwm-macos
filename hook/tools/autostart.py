#!/usr/bin/env python3
"""Session-bound launchd supervisor. Imports have no native or service effects.

The privileged half executes only a SHA-frozen, root-protected tool graph. A
durable attempt marker precedes each native effect; interrupted attempts are
quarantined for that WindowServer birth. No saved native addresses cross births.
"""
import argparse
import contextlib
import ctypes
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import select
import stat
import struct
import subprocess
import sys
import tempfile
import time
import uuid

MARKER = 'hyprwm-native-autostart-v1'
BASE = Path('/Library/Application Support/HyprWM')
SERVER = '/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer'
NATIVE_TOOLS = ('prepare_native.py', 'activate_native.py', 'native_lldb.py',
                'native_activate_lldb.py', 'native_state.py', 'qualify_native.py',
                'extract_native.py', 'generate_display_clone.py', 'native_symbols.py',
                'native_channel.c', 'bootstrap_workspaces.py', 'workspace_lldb.py')
GRAPH_FILES = ('hook/tools/autostart.py', 'hook/lifecycle.py', 'hook/own_ui.py',
               'hook/src/chan.h', 'hook/src/managed_process_identity.c',
               *('hook/tools/' + name for name in NATIVE_TOOLS))
IDENTITY_KEYS = ('pid', 'uid', 'seconds', 'micros', 'path')
IDENTITY_SOURCE = 'hook/src/managed_process_identity.c'
IDENTITY_SOURCE_SHA256 = '33ceec7761918eca50287f3af18217f5164b8d934644f8f6c3661bc57e81834c'
IDENTITY_FILE = 'ProcessIdentity.dylib'


def need(value, message):
    if not value:
        raise RuntimeError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(path, owners, *, directory=False):
    path = Path(path)
    need(path.is_absolute() and path == Path(os.path.abspath(path)), 'Absolute canonical path required: ' + str(path))
    for item in (path, *path.parents):
        row = item.lstat()
        sticky = item == Path('/private/tmp') and row.st_uid == 0 and stat.S_IMODE(row.st_mode) == 0o1777
        need(not stat.S_ISLNK(row.st_mode) and row.st_uid in owners and (not row.st_mode & 0o022 or sticky),
             'Unprotected or symlink path: ' + str(item))
        if item != path or directory:
            need(stat.S_ISDIR(row.st_mode), 'Directory required: ' + str(item))
    return path


def read(path, owners=(0,), limit=2**27):
    path = canonical(path, owners)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        need(stat.S_ISREG(before.st_mode) and before.st_uid in owners and before.st_nlink == 1 and
             not before.st_mode & 0o022 and 0 < before.st_size <= limit, 'Untrusted bounded input: ' + str(path))
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(fd, min(65536, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        after = os.fstat(fd)
        stamp = lambda row: (row.st_dev, row.st_ino, row.st_size, row.st_mtime_ns)
        need(stamp(before) == stamp(after) and len(data) == before.st_size, 'Input changed: ' + str(path))
        return bytes(data)
    finally:
        os.close(fd)


def save(path, value, mode=0o600):
    canonical(path.parent, (0,), directory=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'w') as stream:
            os.fchmod(stream.fileno(), mode)
            json.dump(value, stream, indent=2); stream.write('\n')
            stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def graph_digest(files):
    return sha(json.dumps(files, sort_keys=True, separators=(',', ':')).encode())


def source_graph(root, uid):
    files = {name: read(Path(root) / name, (0, uid)) for name in GRAPH_FILES}
    need(sha(files[IDENTITY_SOURCE]) == IDENTITY_SOURCE_SHA256, 'The approved public process-identity source changed')
    return files


def identity_image(data):
    """Reject automatic initializers and non-system dependencies before dlopen.

    Mach-O constants/offsets follow the local SDK mach-o/loader.h. The only
    callable ABI remains the unchanged approved C managed_process_identity.
    """
    need(len(data) >= 32, 'Identity helper Mach-O header is missing')
    magic, cpu, subtype, kind, commands, extent, _, _ = struct.unpack_from('<8I', data)
    need(magic == 0xfeedfacf and cpu == 0x0100000c and subtype == 0 and kind == 6 and
         0 < commands <= 256 and 0 < extent <= 65536 and 32 + extent <= len(data),
         'A bounded arm64 identity dylib is required')
    cursor, dependencies, signature = 32, [], False
    for _ in range(commands):
        need(cursor + 8 <= 32 + extent, 'Truncated identity helper load command')
        command, size = struct.unpack_from('<II', data, cursor)
        need(size >= 8 and size % 8 == 0 and cursor + size <= 32 + extent, 'Invalid identity helper load command')
        need(command not in (0x11, 0x1a, 0x8000001c, 0x80000018, 0x8000001f,
                             0x20, 0x80000023, 0x27, 0x80000028, 0x5),
             'Identity helper has initialization or unapproved loading behavior')
        if command == 0x19:  # LC_SEGMENT_64 and section_64.
            need(size >= 72, 'Truncated identity helper segment')
            count = struct.unpack_from('<I', data, cursor + 64)[0]
            need(72 + count * 80 == size, 'Invalid identity helper section table')
            for index in range(count):
                section = cursor + 72 + index * 80
                name = data[section:section + 16].split(b'\0', 1)[0]
                length = struct.unpack_from('<Q', data, section + 40)[0]
                flags = struct.unpack_from('<I', data, section + 64)[0]
                need(not length or (flags & 0xff not in (0x9, 0xa, 0x15, 0x16) and not name.startswith(b'__objc_')),
                     'Identity helper must have no constructors, destructors or Objective-C initialization')
        elif command == 0xc:  # LC_LOAD_DYLIB.
            need(size >= 24, 'Truncated identity helper dependency')
            offset = struct.unpack_from('<I', data, cursor + 8)[0]
            need(24 <= offset < size, 'Invalid identity helper dependency name')
            name = data[cursor + offset:cursor + size].split(b'\0', 1)[0]
            need(name == b'/usr/lib/libSystem.B.dylib', 'Identity helper may depend only on libSystem')
            dependencies.append(name)
        elif command == 0x1d:  # LC_CODE_SIGNATURE.
            need(size == 16, 'Invalid identity helper signature command')
            offset, length = struct.unpack_from('<II', data, cursor + 8)
            need(length > 0 and offset + length <= len(data), 'Identity helper signature is missing')
            signature = True
        cursor += size
    need(cursor == 32 + extent and len(dependencies) == 1 and signature,
         'Complete signed, constructor-free identity helper required')


def identity_spec(specification):
    need(isinstance(specification, dict) and specification.get('file') == IDENTITY_FILE and
         specification.get('source') == IDENTITY_SOURCE and specification.get('source_sha256') == IDENTITY_SOURCE_SHA256 and
         isinstance(specification.get('sha256'), str) and re.fullmatch('[0-9a-f]{64}', specification['sha256']),
         'Explicit approved identity-helper artifact and unchanged C source required')
    return specification


def load_config(path):
    data = json.loads(read(path, limit=2**20))
    need(data.get('installer') == MARKER and data.get('schema') == 1 and type(data.get('uid')) is int and data['uid'] > 0,
         'Unrecognized autostart configuration')
    base = BASE / ('native-session-' + str(data['uid']))
    need(Path(path) == base / 'config.json' and data.get('base') == str(base), 'Unexpected service configuration path')
    need(data.get('home') == pwd.getpwuid(data['uid']).pw_dir, 'Desktop account home changed')
    canonical(base, (0,), directory=True)
    graph = base / 'graph'
    for name, digest in data['files'].items():
        need(name in GRAPH_FILES and sha(read(graph / name)) == digest, 'Frozen service source changed: ' + name)
    need(set(data['files']) == set(GRAPH_FILES) and graph_digest(data['files']) == data['graph_sha256'],
         'Frozen tool graph differs from its reviewed identity')
    need(data['files'][IDENTITY_SOURCE] == IDENTITY_SOURCE_SHA256, 'Frozen public identity C source changed')
    helper = identity_spec(data.get('identity_helper'))
    helper_bytes = read(graph / 'identity' / IDENTITY_FILE)
    need(sha(helper_bytes) == helper['sha256'], 'Frozen public identity helper changed')
    identity_image(helper_bytes)
    need(sha(read(graph / 'native/probe-eh.dylib')) == data['native_sha256'], 'Frozen native image changed')
    for name, digest in data['workspace_files'].items():
        need(name in ('workspace-images.json', 'DockSpacesBridge.arm64.dylib', 'DockSpacesBridge.arm64e.dylib') and
             sha(read(graph / 'workspaces' / name)) == digest, 'Frozen workspace image changed')
    need(set(data['workspace_files']) == {'workspace-images.json', 'DockSpacesBridge.arm64.dylib', 'DockSpacesBridge.arm64e.dylib'},
         'Incomplete workspace image graph')
    python = canonical(Path(data['python']), (0,))
    need(sha(read(python)) == data['python_sha256'], 'Protected service Python changed')
    return data


def native_modules(config):
    tools = Path(config['base']) / 'graph/hook/tools'
    sys.path.insert(0, str(tools))
    import prepare_native
    import activate_native
    return prepare_native, activate_native


def actor(row):
    return {key: row[key] for key in IDENTITY_KEYS}


def same(expected, identity):
    current = identity(expected['pid'])
    return current and actor(current) == actor(expected) and current['status'] in (2, 3)


class UserWindowServerIdentity:
    """Read the public sysctl birth when cross-UID proc_pidinfo is unavailable."""
    def __init__(self, config):
        need(os.getuid() == config['uid'] and os.geteuid() == config['uid'], 'Identity helper is loaded only as its desktop user')
        specification = identity_spec(config.get('identity_helper'))
        path = Path(config['base']) / 'graph/identity' / IDENTITY_FILE
        data = read(path)
        need(sha(data) == specification['sha256'], 'Protected identity helper changed before loading')
        identity_image(data)
        self.library = ctypes.CDLL(str(path))
        self.birth = self.library.managed_process_identity
        self.birth.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint64)]
        self.birth.restype = ctypes.c_int
        self.processes = ctypes.CDLL('/usr/lib/libproc.dylib')
        self.processes.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.processes.proc_pidpath.restype = ctypes.c_int

    def matches(self, expected):
        if (not isinstance(expected, dict) or expected.get('uid') != 88 or expected.get('path') != SERVER or
                any(type(expected.get(key)) is not int for key in ('pid', 'uid', 'seconds', 'micros')) or
                not 1 < expected['pid'] < 2**31 or expected['seconds'] <= 0 or not 0 <= expected['micros'] < 10**6):
            return False
        before, after = (ctypes.c_uint64 * 4)(), (ctypes.c_uint64 * 4)()
        first, second = ctypes.create_string_buffer(4096), ctypes.create_string_buffer(4096)
        if self.birth(expected['pid'], before) != 0:
            return False
        count = self.processes.proc_pidpath(expected['pid'], first, len(first))
        if not 0 < count < len(first) or self.birth(expected['pid'], after) != 0:
            return False
        fresh_count = self.processes.proc_pidpath(expected['pid'], second, len(second))
        birth = [expected[key] for key in ('pid', 'uid', 'seconds', 'micros')]
        return (0 < fresh_count < len(second) and list(before) == list(after) == birth and
                os.fsdecode(first.value) == os.fsdecode(second.value) == SERVER)


def windowserver(identity):
    result = subprocess.run(['/usr/bin/pgrep', '-x', 'WindowServer'], capture_output=True, text=True, timeout=3)
    need(result.returncode in (0, 1), 'WindowServer census unavailable')
    rows = [identity(int(pid)) for pid in result.stdout.split()]
    rows = [row for row in rows if row and row['uid'] == 88 and row['path'] == SERVER and row['status'] in (2, 3)]
    return actor(rows[0]) if len(rows) == 1 else None


def display_ready():
    graphics = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    graphics.CGMainDisplayID.restype = ctypes.c_uint32
    graphics.CGDisplayIsActive.argtypes = [ctypes.c_uint32]
    graphics.CGDisplayIsOnline.argtypes = [ctypes.c_uint32]
    display = graphics.CGMainDisplayID()
    return display and graphics.CGDisplayIsActive(display) and graphics.CGDisplayIsOnline(display)


def await_exit(expected, identity):
    """One kernel process-exit event; no steady-state status polling."""
    with contextlib.closing(select.kqueue()) as queue:
        event = select.kevent(expected['pid'], filter=select.KQ_FILTER_PROC,
                             flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_ONESHOT,
                             fflags=select.KQ_NOTE_EXIT)
        try:
            queue.control([event], 0, 0)
        except ProcessLookupError:
            return
        if not same(expected, identity):
            return
        queue.control(None, 1, None)


def publish(config, row, *, ready=False, detail=None):
    status = dict(schema=1, uid=config['uid'], phase=row.get('phase', 'pending'), ready=ready,
                  windowserver=row.get('windowserver'), engine_state=row.get('engine_state'),
                  activation=row.get('activation'), graph_sha256=config['graph_sha256'], updated=time.time())
    if detail:
        status['detail'] = str(detail)[-1200:]
    save(Path(config['base']) / 'status.json', status, 0o644)


@contextlib.contextmanager
def service_lock(config):
    path = Path(config['base']) / 'runtime/service.lock'
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        row = os.fstat(fd)
        need(stat.S_ISREG(row.st_mode) and row.st_uid == 0 and row.st_nlink == 1 and not row.st_mode & 0o077,
             'Protected service lock required')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


@contextlib.contextmanager
def effect_lock(config, *, removing=False):
    """Serialize removal against a complete native effect and its journal commit."""
    runtime = Path(config['base']) / 'runtime'
    fd = os.open(runtime / 'effect.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        row = os.fstat(fd)
        need(stat.S_ISREG(row.st_mode) and row.st_uid == 0 and row.st_nlink == 1 and not row.st_mode & 0o077,
             'Protected native-effect lock required')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError('A native operation or removal is in progress; services and receipts were preserved') from error
        need(removing or not (runtime / 'removing.json').exists(), 'Removal is pending; no native operation was started')
        yield
    finally:
        os.close(fd)


def activation(config, receipt, *, timer=True):
    preparation, active = native_modules(config)
    receipt = canonical(receipt, (0,))
    need(stat.S_IMODE(receipt.parent.stat().st_mode) == 0o700, 'Private native activation receipt required')
    row = json.loads(read(receipt, limit=2**21))
    need(row.get('phase') == 'published', 'Complete native publication required for adoption')
    prepared = json.loads(read(Path(row['prepared']), limit=2**21))
    need(prepared.get('owner_uid') == config['uid'] and same(prepared['expected'], preparation.identity),
         'Native activation belongs to another desktop or WindowServer birth')
    need(sha(read(Path(row['prepared']).parent / 'probe-eh.dylib')) == config['native_sha256'],
         'Adopted native image differs from the approved image')
    state = row['engine_state']
    need(state.get('published') is True and read(Path(state['path']), (0, config['uid']), 4096).hex() == state['new_data'],
         'Engine publication differs from the durable native activation receipt')
    pointer = row['pointer']
    # Native public files live in an explicitly sticky, root-owned directory.
    need(active.snapshot(Path(pointer['path']), config['uid'])['data'] == pointer['new_data'] and pointer.get('published') is True,
         'Native channel pointer differs from its activation receipt')
    if timer:
        active.wait_ticks(Path(row['channel']))
    return dict(schema=1, phase='native-ready', windowserver=actor(prepared['expected']),
                prepared=row['prepared'], activation=str(receipt), engine_state=state['path'])


def adopted_workspaces(config, directory, row):
    """Validate a completed root bootstrap without attaching or reinstalling it."""
    directory = canonical(directory, (0,), directory=True)
    need(stat.S_IMODE(directory.stat().st_mode) == 0o700, 'Private root workspace receipt directory required')
    context = json.loads(read(directory / 'context.json', limit=2**21))
    published = json.loads(read(directory / 'published.json', limit=2**21))
    native = json.loads(read(directory / 'native.json', limit=2**21))
    preparation, _ = native_modules(config)
    workspace = module('hyprwm_adopt_workspace', Path(config['base']) / 'graph/hook/tools/bootstrap_workspaces.py')
    workspace.identity = preparation.identity
    workspace.bounded_read = preparation.bounded_read
    need(context.get('schema') == 1 and context.get('uid') == config['uid'] and context.get('control') == '/tmp/hyprwm.ctl' and
         context.get('manager_path') == config['manager'] and
         context.get('source_pins') in (workspace.APPROVED_HELPERS, workspace.LEGACY_APPROVED_HELPERS),
         'Workspace receipt belongs to another approved graph or desktop')
    need(actor(context['server']) == row['windowserver'] and same(context['server'], preparation.identity) and
         same(context['dock'], preparation.identity), 'Workspace receipt belongs to a departed Dock or WindowServer')
    peer = workspace.manager(Path('/tmp/hyprwm.ctl'), config['uid'], Path(config['manager']), config['manager_sha256'])
    request = context['request']
    need(workspace.actor(peer) == request['peer'] and workspace.actor(context['dock']) == request['owner'] and
         workspace.actor(context['server']) == request['generation']['window_server'], 'Workspace bootstrap peer identity changed')
    lease = Path(config['home']) / 'Library/Application Support/HyprWM/native-spaces/lease.json'
    need(context.get('lease') == str(lease) and published.get('lease') == str(lease) and
         json.loads(read(lease, (0, config['uid']), 65536)) == request and
         published.get('dock') == workspace.actor(context['dock']) and published.get('peer') == workspace.actor(peer),
         'Published workspace lease differs from its root receipt')
    need(native.get('ok') is True and native.get('detached') is True and native.get('native', {}).get('installed') is True,
         'Completed detached workspace native receipt required')
    need(workspace.approved_profile_set(context['profiles']), 'Complete independently approved workspace profile set required')
    for arch, profile in context['profiles'].items():
        need(sha(read(Path(profile['artifact']))) == profile['sha256'], 'Retained workspace image differs from its approved image')
    need(set(context['profiles']) == {'arm64', 'arm64e'}, 'Complete retained workspace image graph required')
    return {**row, 'phase': 'workspaces-ready', 'workspace_receipt': str(directory)}


def unpublish_departed(config, previous, expected):
    """Retire only owned filesystem publication after its exact server departed."""
    if not previous.get('activation'):
        return
    preparation, active = native_modules(config)
    old = previous.get('windowserver')
    need(old and old != expected and not same(old, preparation.identity), 'Previous WindowServer departure must be proven')
    current = preparation.identity(old['pid'])
    need(current is None or actor(current) != old, 'Previous WindowServer birth still exists')
    active.no_manager('/tmp/hyprwm.ctl')
    # A reboot can remove /private/tmp together with the old receipt. With no
    # public pointer left there is nothing to retire from the departed birth.
    public_pointer = Path('/private/tmp/hyprwm/chan_path')
    try:
        publication = active.snapshot(public_pointer, config['uid'])
    except FileNotFoundError:
        try:
            public_pointer.parent.lstat()
        except FileNotFoundError:
            return
        raise
    if publication['data'] is None:
        return
    receipt = json.loads(read(Path(previous['activation']), limit=2**21))
    prepared = json.loads(read(Path(receipt['prepared']), limit=2**21))
    need(actor(prepared['expected']) == old and prepared.get('owner_uid') == config['uid'], 'Departed native receipt changed')
    pointer = receipt['pointer']
    current = active.snapshot(Path(pointer['path']), config['uid'])
    if current['data'] is None:
        return
    need(pointer.get('published') is True and current['data'] == pointer['new_data'],
         'Unrecognized native publication preserved after WindowServer replacement')
    active.replace_file(pointer, None, pointer['new_data'])


def fresh_state(config, expected):
    user = pwd.getpwuid(config['uid'])
    parent = Path(config['home']) / 'Library/Application Support/HyprWM/native-session'
    # Existing publication helpers create user directories as the user, never by
    # chowning an attacker-replaceable pathname from root.
    _, active = native_modules(config)
    parent = active.publication_directory(parent, config['uid'])
    canonical(parent, (0, config['uid']), directory=True)
    name = '{}-{}-{}-{}'.format(expected['pid'], expected['seconds'], expected['micros'], uuid.uuid4().hex[:12])
    previous_uid, previous_gid = os.geteuid(), os.getegid()
    try:
        os.setegid(user.pw_gid); os.seteuid(user.pw_uid)
        path = parent / name
        path.mkdir(mode=0o700)
    finally:
        os.seteuid(previous_uid); os.setegid(previous_gid)
    canonical(path, (0, user.pw_uid), directory=True)
    return path / 'engine.state'


def run_tool(config, name, arguments, log):
    flags = ['-I', '-S'] if name == 'bootstrap_workspaces.py' else ['-S']
    command = [config['python'], *flags, str(Path(config['base']) / 'graph/hook/tools' / name), *map(str, arguments)]
    environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': '/var/root', 'PYTHONDONTWRITEBYTECODE': '1'}
    with log.open('ab') as output:
        # Each native helper bounds its owned debugger itself. Killing its parent
        # on a second independent timeout could interrupt detach/recovery.
        result = subprocess.run(command, env=environment, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT)
    need(result.returncode == 0, name + ' refused; inspect ' + str(log))
    return log.read_text()


def native_service(config):
    need(os.geteuid() == 0, 'Native service requires root')
    preparation, active = native_modules(config)
    base = Path(config['base'])
    journal = base / 'runtime/current.json'
    with service_lock(config):
        expected = None
        deadline = time.monotonic() + 55
        while time.monotonic() < deadline:
            expected = windowserver(preparation.identity)
            try:
                logged_in = Path('/dev/console').stat().st_uid == config['uid']
            except OSError:
                logged_in = False
            if expected and logged_in and display_ready():
                break
            time.sleep(.5)
        if not expected or not logged_in or not display_ready():
            publish(config, {'phase': 'pending'}, detail='Waiting for the configured console owner and a running WindowServer')
            return 75
        row = json.loads(read(journal, limit=2**21)) if journal.exists() else {}
        if row.get('windowserver') != expected:
            if row:
                save(base / 'runtime' / ('generation-' + str((row.get('windowserver') or {}).get('seconds', 0)) + '-' + uuid.uuid4().hex[:8] + '.json'), row)
                with effect_lock(config):
                    unpublish_departed(config, row, expected)
            row = dict(schema=1, phase='pending', windowserver=expected)
            save(journal, row)
        if row['phase'] in ('prepare-attempt', 'activation-attempt', 'quarantined'):
            row['phase'] = 'quarantined'; save(journal, row)
            publish(config, row, detail='A native attempt is unconfirmed for this WindowServer birth; automatic attachment is quarantined')
            await_exit(expected, preparation.identity)
            return 1
        native_confirmed = False
        try:
            if row['phase'] == 'pending':
                # Refusals before the durable attempt have no native side effects
                # and may retry when the GUI session becomes ready.
                active.no_manager('/tmp/hyprwm.ctl')
                need(subprocess.check_output(['/usr/bin/sw_vers', '-buildVersion'], text=True).strip() == '25G241',
                     'This macOS build is not qualified')
                need(same(expected, preparation.identity), 'WindowServer changed before preparation')
                with effect_lock(config):
                    row['engine_state'] = str(fresh_state(config, expected))
                    row['phase'] = 'prepare-attempt'; save(journal, row); publish(config, row)
                    prepared = preparation.prepare(base / 'graph/native', config['uid'])
                    prepared_row = json.loads(read(prepared / 'prepared.json', limit=2**21))
                    if actor(prepared_row['expected']) != expected:
                        row.update(phase='quarantined', windowserver=actor(prepared_row['expected']), prepared=str(prepared / 'prepared.json'))
                        save(journal, row)
                        raise RuntimeError('WindowServer changed during preparation; the affected birth is quarantined')
                    row.update(phase='prepared', prepared=str(prepared / 'prepared.json')); save(journal, row)
            if row['phase'] == 'prepared':
                need(same(expected, preparation.identity), 'WindowServer changed before activation')
                active.no_manager('/tmp/hyprwm.ctl')
                with effect_lock(config):
                    row['phase'] = 'activation-attempt'; save(journal, row); publish(config, row)
                    log = base / 'runtime' / ('activate-' + str(expected['seconds']) + '.log')
                    text = run_tool(config, 'activate_native.py', ['activate', '--prepared', row['prepared'],
                                    '--engine-state', row['engine_state'], '--owner-uid', config['uid']], log)
                    receipts = re.findall(r'^Native graph published: (/.+/activation\.json)$', text, re.M)
                    need(len(receipts) == 1, 'A single durable native activation receipt is required')
                    row = activation(config, Path(receipts[0])); save(journal, row)
            need(row['phase'] in ('native-ready', 'workspace-attempt', 'workspace-quarantined', 'workspaces-ready'),
                 'Unrecognized native service phase')
            # Revalidate adopted and resumed publications before releasing user startup.
            activation(config, Path(row['activation']))
            native_confirmed = True
            publish(config, row, ready=True)
            if row['phase'] in ('workspace-attempt', 'workspace-quarantined'):
                row['phase'] = 'workspace-quarantined'; save(journal, row); publish(config, row, ready=True,
                    detail='Workspace attachment outcome is unconfirmed; retained receipts require explicit recovery')
            elif row['phase'] == 'native-ready':
                workspace = module('hyprwm_frozen_workspace', base / 'graph/hook/tools/bootstrap_workspaces.py')
                # This only loads the independently pinned identity helper; no attach.
                workspace.identity = preparation.identity
                workspace.bounded_read = preparation.bounded_read
                peer = None
                deadline = time.monotonic() + 55
                while time.monotonic() < deadline and same(expected, preparation.identity):
                    try:
                        peer = workspace.manager(Path('/tmp/hyprwm.ctl'), config['uid'],
                                                 Path(config['manager']), config['manager_sha256'])
                        workspace.find_actor('Dock', workspace.DOCK, config['uid'])
                        break
                    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                        peer = None
                        time.sleep(.5)
                if peer is None:
                    publish(config, row, ready=True, detail='Waiting for the verified approved manager and Dock before workspace bootstrap')
                    return 75
                with effect_lock(config):
                    row['phase'] = 'workspace-attempt'; save(journal, row); publish(config, row, ready=True)
                    log = base / 'runtime' / ('workspaces-' + str(expected['seconds']) + '.log')
                    text = run_tool(config, 'bootstrap_workspaces.py', ['--image-dir', base / 'graph/workspaces',
                        '--owner-uid', config['uid'], '--manager-executable', config['manager'],
                        '--manager-sha256', config['manager_sha256'], '--replace-stale'], log)
                    retained = re.findall(r'^Retain bridge images and root bootstrap receipt: (/.+)$', text, re.M)
                    need(len(retained) == 1, 'Durable workspace bootstrap receipt required')
                    row.update(phase='workspaces-ready', workspace_receipt=retained[0]); save(journal, row)
                publish(config, row, ready=True)
            await_exit(expected, preparation.identity)
            return 1
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            if row.get('phase') in ('prepare-attempt', 'activation-attempt'):
                row['phase'] = 'quarantined'
            elif row.get('phase') == 'workspace-attempt':
                row['phase'] = 'workspace-quarantined'
            save(journal, row)
            ready = native_confirmed and row['phase'] in ('native-ready', 'workspace-quarantined', 'workspaces-ready')
            publish(config, row, ready=ready, detail=error)
            if row['phase'] in ('quarantined', 'workspace-quarantined'):
                await_exit(expected, preparation.identity)
                return 1
            return 75


def user_lifecycle(config):
    need(os.getuid() == config['uid'] and os.geteuid() == config['uid'], 'Exact configured desktop user required')
    hook = canonical(Path(config['hook']), (0, config['uid']), directory=True)
    manager = canonical(Path(config['manager']), (0, config['uid']))
    need(sha(read(manager, (0, config['uid']))) == config['manager_sha256'] and
         (hook / 'swift/.build/release/hyprwm-swift').resolve(strict=True) == manager,
         'Approved manager executable changed')
    graph_hook = Path(config['base']) / 'graph/hook'
    sys.path.insert(0, str(graph_hook))
    lifecycle = module('hyprwm_frozen_lifecycle', graph_hook / 'lifecycle.py')
    processes = lifecycle.DarwinProcesses()
    store = lifecycle.RecordStore(Path(config['home']) / 'Library/Application Support/HyprWM', hook)
    service = lifecycle.Lifecycle(hook, processes, lifecycle.Control('/tmp/hyprwm.ctl', processes), store)
    return lifecycle, service, store


@contextlib.contextmanager
def user_lock(lifecycle, store, timeout=30):
    """Let the existing bounded shutdown finish before interpreting its record."""
    deadline = time.monotonic() + timeout
    with contextlib.ExitStack() as stack:
        while True:
            try:
                stack.enter_context(store.lock())
                break
            except lifecycle.LifecycleError as error:
                if str(error) != 'another lifecycle action is in progress' or time.monotonic() >= deadline:
                    raise
                time.sleep(.1)
        yield


def user_process_exit(processes, identities):
    """Watch both exact process generations without polling a healthy session."""
    with contextlib.closing(select.kqueue()) as queue:
        for role, expected in identities.items():
            event = select.kevent(expected['pid'], filter=select.KQ_FILTER_PROC,
                                 flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_ONESHOT,
                                 fflags=select.KQ_NOTE_EXIT)
            try:
                queue.control([event], 0, 0)
            except ProcessLookupError:
                return role
            if processes.identity(expected['pid']) != expected:
                return role
        events = queue.control(None, len(identities), None)
        # A simultaneous daemon/UI departure belongs to shutdown handling first.
        for role in ('daemon', 'menu'):
            if any(event.ident == identities[role]['pid'] for event in events):
                return role
        raise RuntimeError('Unexpected kernel process event; no service was restarted')


def departed_daemon(lifecycle, store, expected):
    try:
        with user_lock(lifecycle, store):
            recorded = store.load()['owned'].get('daemon')
        # The existing Quit/stop removes this exact record under its lock.
        # A crash leaves it intact. A successor belongs to another action.
        return 1 if recorded == expected else 0
    except (OSError, ValueError, RuntimeError) as error:
        print('HyprWM autostart: daemon departure ownership is unconfirmed; automatic restart stopped: ' + str(error), file=sys.stderr)
        return 0


def user_service(config):
    lifecycle, service, store = user_lifecycle(config)
    server_identity = UserWindowServerIdentity(config)
    deadline = time.monotonic() + 55
    status = None
    while time.monotonic() < deadline:
        try:
            candidate = json.loads(read(Path(config['base']) / 'status.json', limit=65536))
            if (candidate.get('schema') == 1 and candidate.get('uid') == config['uid'] and candidate.get('ready') is True and
                    candidate.get('graph_sha256') == config['graph_sha256'] and candidate.get('windowserver') and
                    server_identity.matches(candidate['windowserver'])):
                status = candidate
                break
        except (OSError, ValueError, RuntimeError):
            pass
        time.sleep(.5)
    if status is None:
        return 75
    read(Path(status['engine_state']), (0, config['uid']), 4096)
    os.environ['HYPRWM_ENGINE_STATE'] = status['engine_state']
    with user_lock(lifecycle, store):
        service.start(menu=True)
        _, identity = service.status()
        need(identity['executable'] == config['manager'], 'Daemon is not the approved manager')
    while True:
        if service.processes.identity(identity['pid']) != identity:
            return departed_daemon(lifecycle, store, identity)
        menus = [row for row in service.census() if service.role(row) == 'menu']
        if not menus:
            try:
                with user_lock(lifecycle, store):
                    if service.processes.identity(identity['pid']) != identity:
                        continue
                    service.start(menu=True)
                menus = [row for row in service.census() if service.role(row) == 'menu']
            except (OSError, ValueError, RuntimeError) as error:
                if service.processes.identity(identity['pid']) != identity:
                    return departed_daemon(lifecycle, store, identity)
                print('HyprWM autostart: controls restart is unconfirmed; existing daemon retained: ' + str(error), file=sys.stderr)
                return 0
        need(len(menus) == 1, 'Exactly one existing Swift controls companion is required; current processes were preserved')
        exited = user_process_exit(service.processes, dict(daemon=identity, menu=menus[0]))
        if exited == 'daemon':
            return departed_daemon(lifecycle, store, identity)
        try:
            os.waitpid(menus[0]['pid'], os.WNOHANG)
        except ChildProcessError:
            pass  # An adopted companion is reaped by its original parent.
        # On an independent controls crash, idempotent lifecycle start restores
        # only the missing companion. A concurrent Quit holds the same lock;
        # after it finishes we observe daemon departure instead of undoing Quit.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('native-service', 'user-service', 'user-stop'))
    parser.add_argument('--config', required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    need(not sys.flags.optimize, 'Autostart requires Python optimization disabled')
    try:
        config = load_config(args.config)
        if args.action == 'native-service':
            code = native_service(config)
        elif args.action == 'user-service':
            code = user_service(config)
        else:
            _, service, store = user_lifecycle(config)
            with store.lock():
                result = service.stop()
            print(json.dumps(result)); code = 0
        return code
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print('HyprWM autostart: ' + str(error), file=sys.stderr)
        return 75


if __name__ == '__main__':
    sys.exit(main())
