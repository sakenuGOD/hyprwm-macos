#!/usr/bin/env python3
"""Explicitly qualify and publish a workspace bridge in the current Dock.

Build with build_workspaces.py as the desktop user first. This command never
restarts Dock, changes security policy, creates a Space or switches desktops.
"""
import argparse
import ctypes
import contextlib
import errno
import fcntl
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import signal
import time
import socket
import stat
import struct
import subprocess
import sys
import tempfile


TOOLS = Path(__file__).resolve().parent
DOCK = '/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock'
SERVER = '/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer'
DOCK_UUID = '073a7e7521bb342781809b9b3b80212b'
SKY_UUID = 'CD5F2362-8462-38D4-8C57-0BCD4E04F962'
# Independently reviewed build/source identities. A manifest cannot authorize new code.
APPROVED_IMAGES = {
    'arm64': ('bc0e57e6f96c3009918d3a62f2069279', '6cc19a738c8b5385b5970bbd51495dcf1a3a82896f68e14a658b62967eab41ae'),
    'arm64e': ('32d9b671cc89350798ae8a97eaa09b1e', '6385ce7c361616e32f24e6816e33600db5b838c08c2d23d71a84082ccfd989bc')}
# A recovery build is authorized only after its independently inspected exact
# identities are added here. The original image/receipt remains authoritative.
APPROVED_RECOVERY_IMAGES = {
    'arm64': ('0342a46aae2838968ca8a4b04073c899', '8239cc114e3899e77ad0dacab15bb16b2947dc18e410e3b7022034c6e5a30b19'),
    'arm64e': ('73a9119ef5cd317e9e8bf7b33c1c1681', '09734d164272084b70e99a45ddcd98450a658f06f885c09917592e4b8b7563c4')}
RECOVERY_INSTALL_NAME = 'hyprwm-workspaces-owned-recovery-20261028'
APPROVED_SOURCES = {
    'hook/native-space/DockSpacesBridge.m': '82173255d7172eadca1cf4aa91be3f4b5e91710a0d9b7f34de6f0c59b4b779a9',
    'hook/src/managed_process_identity.c': '33ceec7761918eca50287f3af18217f5164b8d934644f8f6c3661bc57e81834c'}
APPROVED_HELPERS = {
    'prepare_native.py': 'b0c8700ae1147cc912aa1b34af224df2db4d6d1b2633859542c250c091f80e75',
    'workspace_lldb.py': '424344f2abf5eeab43cb7bb62df11ef66faa2e62b8a73826bbe2c7e99e0d312c'}
LEGACY_APPROVED_HELPERS = {
    'prepare_native.py': 'b0c8700ae1147cc912aa1b34af224df2db4d6d1b2633859542c250c091f80e75',
    'workspace_lldb.py': '1faca9fcdda8a097f1b42b56ec7d27d838340ec196f0e768d1871027c344931c'}


def approved_profile_set(profiles):
    if not isinstance(profiles, dict) or set(profiles) != {'arm64', 'arm64e'}:
        return False
    pairs = {arch: (profile.get('uuid'), profile.get('sha256'))
             for arch, profile in profiles.items() if isinstance(profile, dict)}
    return pairs == APPROVED_IMAGES or (bool(APPROVED_RECOVERY_IMAGES) and pairs == APPROVED_RECOVERY_IMAGES)


def read_file(path, owners, limit=2**21):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        need(stat.S_ISREG(before.st_mode) and before.st_uid in owners and not before.st_mode & 0o022 and
             before.st_nlink == 1 and 0 < before.st_size <= limit, 'Untrusted bounded input: ' + str(path))
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(fd, min(65536, limit+1-len(data)))
            if not chunk:
                break
            data.extend(chunk)
        after = os.fstat(fd)
        need((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) ==
             (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) and len(data) == before.st_size,
             'Input changed: ' + str(path))
        return bytes(data)
    finally:
        os.close(fd)


def save_json(path, value):
    temporary = path.with_suffix('.next')
    with temporary.open('w') as output:
        json.dump(value, output, indent=2)
        output.write('\n');output.flush();os.fsync(output.fileno())
    os.replace(temporary, path)


def freeze_helpers(run, uid, resume, pins=None):
    pins = APPROVED_HELPERS if pins is None else pins
    need(pins in (APPROVED_HELPERS, LEGACY_APPROVED_HELPERS), 'Unapproved workspace helper set')
    for name, expected in pins.items():
        data = read_file((run if resume else TOOLS)/name, (0,) if resume else (0, uid))
        need(hashlib.sha256(data).hexdigest() == expected, 'Unapproved workspace helper: ' + name)
        if not resume:
            (run/name).write_bytes(data)
    spec = importlib.util.spec_from_file_location('workspace_frozen_identity', run/'prepare_native.py')
    module = importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    global identity, protected_tool, bounded_read
    identity, protected_tool, bounded_read = module.identity, module.protected_tool, module.bounded_read


def private_directory(path, uid, gid):
    if not path.exists():
        previous_uid, previous_gid = os.geteuid(), os.getegid()
        try:
            os.setegid(gid);os.seteuid(uid)
            path.mkdir(mode=0o700, parents=True, exist_ok=True)
        finally:
            os.seteuid(previous_uid);os.setegid(previous_gid)
    item = path.lstat()
    need(stat.S_ISDIR(item.st_mode) and item.st_uid == uid and stat.S_IMODE(item.st_mode) == 0o700 and
         path.resolve(strict=True) == path, 'Canonical private user workspace directory required')


@contextlib.contextmanager
def publisher_lock(uid):
    path = Path('/private/var/run')/('hyprwm-workspaces-'+str(uid)+'.lock')
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        item = os.fstat(fd)
        need(stat.S_ISREG(item.st_mode) and item.st_uid == 0 and item.st_nlink == 1 and
             stat.S_IMODE(item.st_mode) == 0o600, 'Protected workspace publication lock required')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def need(value, message):
    if not value:
        raise RuntimeError(message)


def actor(row):
    return dict(pid=row['pid'], uid=row['uid'], sec=row['seconds'], usec=row['micros'], path=row['path'])


def same(row):
    fresh = identity(row['pid'])
    return fresh and actor(fresh) == actor(row) and fresh['status'] != 4


def find_actor(name, executable, uid=None):
    rows = []
    for pid in subprocess.check_output(['/usr/bin/pgrep', '-x', name], text=True).split():
        row = identity(int(pid))
        if row and row['path'] == executable and (uid is None or row['uid'] == uid):
            rows.append(row)
    need(len(rows) == 1 and rows[0]['status'] != 4, 'One current canonical ' + name + ' required')
    return rows[0]


def manager(path, uid, expected_path, expected_sha):
    item = path.lstat()
    need(stat.S_ISSOCK(item.st_mode) and item.st_uid == uid and not item.st_mode & 0o077,
         'Private desktop-owner control socket required')
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(3)
        connection.connect(str(path))
        pid = struct.unpack('=i', connection.getsockopt(0, 2, 4))[0]
        row = identity(pid)
        need(row and row['uid'] == uid and row['path'] == str(expected_path),
             'Exact approved desktop Swift manager path required')
        approved_bytes = bounded_read(expected_path, uid, 2**27)
        need(hashlib.sha256(approved_bytes).hexdigest() == expected_sha, 'Manager executable changed')
        kernel_hash = (ctypes.c_ubyte*20)()
        csops = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True).csops
        csops.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.c_void_p, ctypes.c_size_t]
        csops.restype = ctypes.c_int
        need(csops(pid, 5, kernel_hash, 20) == 0, 'Kernel manager code identity unavailable')
        signing = ctypes.c_uint32()
        need(csops(pid, 0, ctypes.byref(signing), ctypes.sizeof(signing)) == 0 and
             signing.value & 1 and not signing.value & 0x10000000 and not row['flags'] & 0x800,
             'Valid untraced manager code required')
        hashes = set()
        # codesign must inspect the SHA-approved bytes, never reopen the
        # mutable user pathname after the hash check.
        with tempfile.TemporaryDirectory(prefix='hyprwm-workspace-manager-', dir='/private/tmp') as temporary:
            frozen = Path(temporary)/'manager'
            frozen.write_bytes(approved_bytes);os.chmod(frozen, 0o600)
            for arch in ('arm64', 'arm64e'):
                result = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', '--arch', arch, str(frozen)],
                                        capture_output=True, text=True, timeout=5)
                hashes.update(re.findall(r'^CDHash=([0-9a-f]{40})$', result.stderr, re.M) if result.returncode == 0 else [])
        need(bytes(kernel_hash).hex() in hashes, 'Running manager image differs from the approved file')
        connection.sendall(b'status\n')
        data = bytearray()
        while b'\n' not in data:
            chunk = connection.recv(min(8192, 262145-len(data)))
            need(chunk and len(data)+len(chunk) <= 262144, 'Bounded manager status required')
            data.extend(chunk)
    value = json.loads(bytes(data).split(b'\n', 1)[0])
    need(same(row) and value.get('daemon', {}).get('pid') == pid and value.get('enabled') is True and
         value.get('compatibility', {}).get('verified') is True, 'Verified current manager required')
    return row


def snapshot_at(directory, name, uid):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
    except FileNotFoundError:
        return None, None
    try:
        before = os.fstat(fd)
        need(stat.S_ISREG(before.st_mode) and before.st_uid == uid and before.st_nlink == 1 and
             stat.S_IMODE(before.st_mode) == 0o600 and 0 < before.st_size <= 65536,
             'Private bounded user-owned workspace lease required')
        data = bytearray()
        while len(data) <= 65536:
            chunk = os.read(fd, min(65536, 65537-len(data)))
            if not chunk:
                break
            data.extend(chunk)
        after = os.fstat(fd)
        before_key = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        need(before_key == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) and
             before.st_uid == after.st_uid and before.st_mode == after.st_mode and
             after.st_nlink == 1 and len(data) == before.st_size, 'Workspace lease changed during read')
        return bytes(data), before_key
    finally:
        os.close(fd)


def snapshot(path, uid):
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        return snapshot_at(directory, path.name, uid)
    finally:
        os.close(directory)


def exclusive_rename(directory, source, destination):
    # Darwin sys/stdio.h: RENAME_EXCL. No foreign destination is overwritten.
    function = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True).renameatx_np
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    if function(directory, os.fsencode(source), directory, os.fsencode(destination), 4):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def publish(path, uid, gid, data, previous, inode, parent_inode, backup):
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    temporary = '.workspace-lease-' + secrets.token_hex(12)
    def parent_current():
        current = path.parent.lstat();opened = os.fstat(directory)
        need(stat.S_ISDIR(current.st_mode) and current.st_uid == uid and
             stat.S_IMODE(current.st_mode) == 0o700 and
             (current.st_dev, current.st_ino) == (opened.st_dev, opened.st_ino) == parent_inode,
             'Workspace directory changed; files preserved')
    try:
        parent_current()
        current = snapshot_at(directory, path.name, uid)
        if current[0] == data:
            return
        expected = (previous, inode)
        if previous is not None:
            if current == expected:
                exclusive_rename(directory, path.name, backup)
                if snapshot_at(directory, backup, uid) != expected:
                    try:
                        exclusive_rename(directory, backup, path.name)
                    except FileExistsError:
                        pass
                    raise RuntimeError('Concurrent lease preserved at ' + str(path.parent/backup))
            else:
                need(current == (None, None) and snapshot_at(directory, backup, uid) == expected,
                     'Workspace lease changed; no publication performed')
        else:
            need(current == (None, None), 'Concurrent workspace lease preserved')
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
        try:
            with os.fdopen(fd, 'wb', closefd=False) as stream:
                stream.write(data);stream.flush();os.fsync(stream.fileno())
            os.fchown(fd, uid, gid);os.fchmod(fd, 0o600)
        finally:
            os.close(fd)
        parent_current()
        exclusive_rename(directory, temporary, path.name)
        need(snapshot_at(directory, path.name, uid)[0] == data, 'Published lease changed externally')
        parent_current();os.fsync(directory)
    except BaseException:
        # A failed publication restores the previous file only into an empty
        # name. A concurrently installed lease is always preserved.
        if previous is not None:
            try:
                if snapshot_at(directory, path.name, uid) == (None, None) and snapshot_at(directory, backup, uid) == (previous, inode):
                    exclusive_rename(directory, backup, path.name)
            except OSError:
                pass
        raise
    finally:
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass
        os.close(directory)


def root_run(path):
    need(path.is_absolute() and path.resolve(strict=True) == path, 'Canonical root bootstrap receipt required')
    item = path.lstat()
    need(stat.S_ISDIR(item.st_mode) and item.st_uid == 0 and stat.S_IMODE(item.st_mode) == 0o700,
         'Root-private bootstrap receipt required')
    return path


def detached_running(expected, result):
    fresh = identity(expected['pid'])
    need(fresh and actor(fresh) == actor(expected), 'Dock generation changed during debugger cleanup')
    if fresh['status'] == 4 and not fresh['flags'] & 0x800 and fresh['stop_signal'] == signal.SIGSTOP and result.get('detached') is True:
        # Resume only the exact untraced SIGSTOP left by this successful detach.
        os.kill(fresh['pid'], signal.SIGCONT)
        deadline = time.monotonic()+1
        while fresh['status'] == 4 and time.monotonic() < deadline:
            time.sleep(.01);fresh = identity(expected['pid'])
            need(fresh and actor(fresh) == actor(expected), 'Dock changed while resuming own detach')
    need(fresh['status'] in (2, 3) and not fresh['flags'] & 0x800,
         'Dock detach/running state unconfirmed; retain this bootstrap receipt')



def departed_peer(peer):
    fresh = identity(peer['pid'])
    if fresh:
        return (fresh['seconds'], fresh['micros']) != (peer['sec'], peer['usec'])
    try:
        os.kill(peer['pid'], 0)
    except ProcessLookupError:
        return True
    return False


def owned_retirement_context(directory, uid, control, manager_path, dock, server, lease, previous, expected=None):
    directory = root_run(directory)
    files = {name: read_file(directory/name, (0,)) for name in ('context.json', 'native.json', 'published.json')}
    hashes = {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}
    if expected is not None:
        need(hashes == expected['files'], 'Original root workspace receipt changed')
    context, native, published = (json.loads(files[name]) for name in ('context.json', 'native.json', 'published.json'))
    request = context['request'];pins = context.get('source_pins')
    need(context.get('schema') == 1 and context.get('uid') == uid and
         context.get('control') == str(control) and context.get('manager_path') == str(manager_path) and
         pins in (APPROVED_HELPERS, LEGACY_APPROVED_HELPERS), 'Owned compatible workspace receipt required')
    for name, digest in pins.items():
        need(hashlib.sha256(read_file(directory/name, (0,))).hexdigest() == digest, 'Original frozen helper changed')
    need(approved_profile_set(context.get('profiles')), 'Original complete approved workspace profiles required')
    for profile in context['profiles'].values():
        image = Path(profile['artifact'])
        need(image.is_absolute() and image.resolve(strict=True) == image and
             hashlib.sha256(read_file(image, (0,))).hexdigest() == profile['sha256'], 'Original root workspace image changed')
    need(context.get('lease') == str(lease) and json.loads(previous) == request and
         request.get('kind') == 'native-Dock-existing-v1' and request['owner'] == actor(dock) and
         actor(context['dock']) == actor(dock) and actor(context['server']) == actor(server) and
         request['generation'] == dict(build='25G241', sky_uuid=SKY_UUID, window_server=actor(server)) and
         published.get('lease') == str(lease) and published.get('dock') == request['owner'] and
         published.get('peer') == request['peer'], 'Original published lease/generation required')
    profile = context['profiles'].get(native.get('architecture'), {})
    need(native.get('ok') is True and native.get('detached') is True and native.get('native_code') == 0 and
         native.get('native', {}).get('installed') is True and native.get('source_pins') == pins and
         native.get('module_uuid') == profile.get('uuid') and native.get('module_sha256') == profile.get('sha256') and
         native.get('artifact') == profile.get('artifact') and type(native.get('retained_handle')) is int and
         native['retained_handle'] > 0, 'Completed exact retained installation required')
    need(request['peer']['uid'] == uid and request['peer']['path'] == str(manager_path) and
         departed_peer(request['peer']), 'Original manager kernel birth must be gone')
    endpoint = Path(request['socket'])
    need(endpoint.is_absolute() and endpoint.parent == lease.parent and endpoint.name.startswith('dock-') and
         str(endpoint) == str(endpoint.resolve(strict=False)), 'Original canonical private endpoint required')
    if expected is None:
        item = endpoint.lstat()
        need(stat.S_ISSOCK(item.st_mode) and item.st_uid == uid and not item.st_mode & 0o077,
             'Original private workspace endpoint required')
        expected = dict(receipt=str(directory), files=hashes, socket_inode=[item.st_dev, item.st_ino])
    return context, native, expected


def prepare_context(run, image_dir, uid, user, control, replace_stale, manager_path, manager_sha, retire_owned=None):
    dock = find_actor('Dock', DOCK, uid)
    server = find_actor('WindowServer', SERVER, 88)
    peer = manager(control, uid, manager_path, manager_sha)
    uuid_text = subprocess.check_output([protected_tool('dwarfdump'), '--uuid', DOCK], text=True)
    need(DOCK_UUID in uuid_text.replace('-', '').lower(), 'Dock image UUID is not qualified')
    private = Path(user.pw_dir).resolve(strict=True)/'Library/Application Support/HyprWM/native-spaces'
    private_directory(private, uid, user.pw_gid)
    info = private.lstat();parent_inode = (info.st_dev, info.st_ino)
    lease = private/'lease.json';old, old_inode = snapshot(lease, uid)
    retirement = None;retiring_context = None
    if old:
        value = json.loads(old);old_owner = value.get('owner', {})
        need(replace_stale or retire_owned, 'Workspace lease exists; explicit replacement authority required')
        need(value.get('kind') == 'native-Dock-existing-v1' and set(old_owner) == {'pid','uid','sec','usec','path'} and
             old_owner['path'] == DOCK and old_owner['uid'] == uid and type(old_owner['pid']) is int and old_owner['pid'] > 1,
             'Unrecognized lease preserved')
        if retire_owned:
            retiring_context, _, retirement = owned_retirement_context(retire_owned, uid, control, manager_path, dock, server, lease, old)
        else:
            need(old_owner != actor(dock), 'Current Dock lease preserved; use normal manager rebind')
            current_old = identity(old_owner['pid'])
            need(not current_old or actor(current_old) != old_owner, 'Previous Dock is alive; lease preserved')
    need(not retire_owned or retirement, 'Owned current lease required for retirement')
    approved = APPROVED_RECOVERY_IMAGES if retirement else APPROVED_IMAGES
    manifest = json.loads(bounded_read(image_dir/'workspace-images.json', uid))
    need(manifest.get('schema') == 1 and manifest.get('sources') == APPROVED_SOURCES and
         set(manifest.get('profiles', {})) == {'arm64','arm64e'}, 'Reviewed workspace build required')
    need(not retirement or (set(approved) == {'arm64','arm64e'} and manifest.get('install_name') == RECOVERY_INSTALL_NAME and
                           all(approved[arch][0] != retiring_context['profiles'][arch]['uuid'] for arch in approved)),
         'Separately approved independent recovery images required')
    for arch in ('arm64','arm64e'):
        profile = manifest['profiles'][arch]
        need((profile.get('uuid'),profile.get('sha256')) == approved[arch] and
             profile.get('file') == 'DockSpacesBridge.'+arch+'.dylib', 'Workspace image is not independently approved')
    images = Path(tempfile.mkdtemp(prefix='hyprwm-workspace-image-',dir='/private/tmp'));os.chmod(images,0o755)
    profiles = {}
    for arch in ('arm64','arm64e'):
        profile = manifest['profiles'][arch];data = bounded_read(image_dir/profile['file'],uid)
        need(hashlib.sha256(data).hexdigest() == approved[arch][1], 'Workspace image changed')
        image = images/profile['file'];image.write_bytes(data);os.chmod(image,0o644)
        subprocess.run(['/usr/bin/codesign','--verify','--strict',str(image)],check=True,
                       stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        text = subprocess.check_output([protected_tool('dwarfdump'),'--uuid',str(image)],text=True)
        rows = re.findall(r'UUID: ([0-9A-F-]+) \(([^)]+)\)',text)
        need(len(rows)==1 and rows[0][1]==arch and rows[0][0].replace('-','').lower()==approved[arch][0],
             'Workspace image architecture/UUID changed')
        profiles[arch] = dict(profile,artifact=str(image))
    endpoint = private/('dock-'+secrets.token_hex(6)+'.sock')
    need(not endpoint.exists() and len(str(endpoint).encode())<104,'New bounded private endpoint required')
    request = dict(op='install',schema=1,kind='native-Dock-existing-v1',owner=actor(dock),peer=actor(peer),
                   generation=dict(build='25G241',sky_uuid=SKY_UUID,window_server=actor(server)),
                   nonce=secrets.token_hex(32),epoch=secrets.token_hex(16),socket=str(endpoint))
    context = dict(schema=1,uid=uid,control=str(control),manager_path=str(manager_path),
                   request=request,profiles=profiles,dock=dock,server=server,source_pins=APPROVED_HELPERS,
                   lease=str(lease),previous=old.hex() if old is not None else None,
                   previous_inode=old_inode,parent_inode=parent_inode,backup='.lease-before-'+request['epoch'])
    if retirement:
        context['retire_owned_current'] = retirement
    # This root-private context is the authority for every retry, including a
    # debugger interruption before it could write its first native receipt.
    save_json(run/'context.json',context)
    return context


def invoke_native(run, dock, configuration, stem='bootstrap'):
    driver = run/('driver.py' if stem == 'bootstrap' else stem+'-driver.py')
    driver.write_text('import sys\nsys.path.insert(0,'+repr(str(run))+')\n'+
                      '\n'.join(k+'='+repr(v) for k,v in configuration.items())+'\n'+(run/'workspace_lldb.py').read_text())
    os.chmod(driver,0o600)
    log = run/(stem+'.log');environment = {k:v for k,v in os.environ.items() if not k.startswith(('PYTHON','DYLD_','LD_'))}
    arguments = ['/usr/bin/arch','-arm64',protected_tool('lldb'),'--batch','--no-lldbinit',
                 '-O','plugin disable language-runtime.swift','-O','settings set target.detach-on-error true',
                 '-O','settings set target.load-script-from-symbol-file false',
                 '-O','settings set target.auto-import-clang-modules false','-p',str(dock['pid']),'-o',
                 'script exec(compile(open('+repr(str(driver))+').read(),"workspace_bootstrap","exec"))',
                 '-o','script p=lldb.debugger.GetSelectedTarget().GetProcess(); p.Detach(False) if p.IsValid() and p.GetState() not in (lldb.eStateDetached,lldb.eStateExited,lldb.eStateInvalid) else None','-o','quit']
    timed_out = False
    with log.open('w') as output:
        child = subprocess.Popen(arguments,cwd=run,env=environment,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT)
        try:
            code = child.wait(timeout=20)
        except subprocess.TimeoutExpired:
            timed_out = True;child.send_signal(signal.SIGINT)
            try:
                code = child.wait(timeout=4)
            except subprocess.TimeoutExpired:
                child.terminate()
                try:
                    code = child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill();code = child.wait(timeout=3)  # Only our debugger, never Dock.
    path = Path(configuration['OUTPUT'])
    result = json.loads(read_file(path,(0,))) if path.exists() else {}
    detached_running(dock,result)
    need(not timed_out and code==0 and result.get('ok') is True and result.get('detached') is True,
         'Workspace native action incomplete; use --resume '+str(run)+'; inspect '+str(log))
    return result


def retire_owned_current(run, context, uid, control, manager_path, manager_sha):
    authority = context['retire_owned_current'];dock, server = context['dock'], context['server']
    lease = Path(context['lease']);previous = bytes.fromhex(context['previous'])
    old, native, _ = owned_retirement_context(Path(authority['receipt']), uid, control, manager_path,
                                             dock, server, lease, previous, authority)
    endpoint = Path(old['request']['socket'])
    completed = run/'retired.json';output = run/'retirement-native.json'
    if not completed.exists():
        need(snapshot(lease, uid) == (previous, tuple(context['previous_inode'])),
             'Original lease changed before owned retirement')
        prior = json.loads(read_file(output, (0,))) if output.exists() else {}
        # A successful reply/detach is retained even if socket cleanup was delayed.
        if not (prior.get('ok') is True and prior.get('retired') is True and prior.get('detached') is True):
            need(same(dock) and same(server) and
                 actor(manager(control,uid,manager_path,manager_sha)) == context['request']['peer'],
                 'Generation changed before owned retirement')
            expected = dict(pid=dock['pid'],birth=[dock['pid'],dock['uid'],dock['seconds'],dock['micros']],executable=dock['path'],argv=None)
            configuration = dict(IDENTITY=expected,ACTION=2,EXISTING_HANDLE=native['retained_handle'],
                                 SOURCE_PINS=context['source_pins'],PROFILES=old['profiles'],EXPECTED_UUIDS={DOCK_UUID},
                                 OUTPUT=str(output),REQUEST=dict(old['request'],shutdown=True),RESUME=True,
                                 PRIOR_INSTALLED=True,PRIOR_ATTEMPTED=prior.get('mutation_attempted') is True,
                                 ALLOW_SUCCESSOR=True)
            prior = invoke_native(run, dock, configuration, 'retirement-native')
        need(prior.get('retired') is True and prior.get('dlclose_called') is False and prior.get('handle_retained') is True,
             'Original workspace instance retirement unconfirmed')
        detached_running(dock, prior)
        deadline = time.monotonic()+2
        while True:
            try:
                item = endpoint.lstat()
            except FileNotFoundError:
                break
            need(stat.S_ISSOCK(item.st_mode) and item.st_uid == uid and not item.st_mode & 0o077 and
                 [item.st_dev,item.st_ino] == authority['socket_inode'], 'Original endpoint changed; preserve it')
            need(time.monotonic() < deadline, 'Owned endpoint cleanup incomplete; retain recovery receipt')
            time.sleep(.01)
        need(same(dock) and same(server) and departed_peer(old['request']['peer']) and
             actor(manager(control,uid,manager_path,manager_sha)) == context['request']['peer'],
             'Generation changed after owned retirement')
        save_json(completed, dict(schema=1, retired=True, authority=authority, native_result=str(output)))
    proof = json.loads(read_file(completed, (0,)))
    need(proof == dict(schema=1, retired=True, authority=authority, native_result=str(output)) and
         not endpoint.exists(), 'Exact owned retirement proof/endpoint absence required')
    result = json.loads(read_file(output, (0,)))
    need(result.get('ok') is True and result.get('retired') is True and result.get('detached') is True and
         result.get('action') == 2 and result.get('dlclose_called') is False and result.get('handle_retained') is True,
         'Retained successful retirement result required')
    detached_running(dock,result)


def execute_context(run, context, uid, user, control, manager_path, manager_sha, resume):
    need(context.get('schema')==1 and context.get('uid')==uid and context.get('source_pins') in (APPROVED_HELPERS, LEGACY_APPROVED_HELPERS),
         'Incompatible root workspace context')
    need(context.get('control')==str(control) and context.get('manager_path')==str(manager_path),
         'Resume cannot change manager path or control endpoint')
    dock,server = context['dock'],context['server'];request = context['request']
    need(same(dock) and same(server) and actor(dock)==request['owner'] and actor(server)==request['generation']['window_server'],
         'Bootstrap generation departed; old native addresses are never replayed')
    peer = manager(control,uid,manager_path,manager_sha)
    prior = json.loads(read_file(run/'native.json',(0,))) if (run/'native.json').exists() else {}
    installed = prior.get('prior_installed') is True or (prior.get('native',{}).get('installed') is True and prior.get('native_code')==0)
    successor = actor(peer)!=request['peer']
    if successor:
        previous_peer = identity(request['peer']['pid'])
        need(resume and (installed or prior.get('mutation_attempted') is True) and request['peer']['path']==str(manager_path) and
             (not previous_peer or actor(previous_peer)!=request['peer']),
             'Original manager still owns this unpublished workspace installation')
    need(approved_profile_set(context.get('profiles')), 'Unapproved complete retained workspace image set')
    for arch,profile in context['profiles'].items():
        need(hashlib.sha256(read_file(Path(profile['artifact']),(0,))).hexdigest()==profile['sha256'],
             'Retained root-owned workspace image changed')
    lease = Path(context['lease']);old = bytes.fromhex(context['previous']) if context['previous'] is not None else None
    old_inode = tuple(context['previous_inode']) if context['previous_inode'] is not None else None
    parent_inode = tuple(context['parent_inode']);new = (json.dumps(request,indent=2)+'\n').encode()
    if context.get('retire_owned_current'):
        need(actor(peer) == request['peer'] and context['source_pins'] == APPROVED_HELPERS,
             'Recovery is bound to its exact successor and current retirement helper')
        retire_owned_current(run,context,uid,control,manager_path,manager_sha)
    if resume and installed and snapshot(lease,uid)[0]==new:
        print('Workspace lease already published: '+str(lease));return
    expected = dict(pid=dock['pid'],birth=[dock['pid'],dock['uid'],dock['seconds'],dock['micros']],executable=dock['path'],argv=None)
    configuration = dict(IDENTITY=expected,ACTION=1,EXISTING_HANDLE=prior.get('retained_handle',0),
                         SOURCE_PINS=context['source_pins'],PROFILES=context['profiles'],EXPECTED_UUIDS={DOCK_UUID},
                         OUTPUT=str(run/'native.json'),REQUEST=request,RESUME=resume,
                         PRIOR_INSTALLED=installed,PRIOR_ATTEMPTED=prior.get('mutation_attempted') is True,
                         ALLOW_SUCCESSOR=successor)
    need(same(dock) and same(server) and actor(manager(control,uid,manager_path,manager_sha))==actor(peer),
         'Generation changed before attach')
    result = invoke_native(run, dock, configuration)
    need(result.get('native',{}).get('installed') is True, 'Workspace bootstrap installation unconfirmed')
    need(same(dock) and same(server) and actor(manager(control,uid,manager_path,manager_sha))==actor(peer),
         'Generation changed before publication; retain root receipt '+str(run))
    endpoint = Path(request['socket']);item = endpoint.lstat()
    need(stat.S_ISSOCK(item.st_mode) and item.st_uid==uid and not item.st_mode&0o077,
         'Qualified private endpoint missing; retain root receipt '+str(run))
    publish(lease,uid,user.pw_gid,new,old,old_inode,parent_inode,context['backup'])
    save_json(run/'published.json',dict(lease=str(lease),dock=actor(dock),peer=actor(peer),consumer_rebind_required=successor))
    print('Native workspace lease published: '+str(lease))
    print('Retain bridge images and root bootstrap receipt: '+str(run))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--image-dir',type=Path)
    group.add_argument('--resume',type=Path)
    parser.add_argument('--owner-uid',required=True,type=int)
    parser.add_argument('--manager-executable',required=True,type=Path)
    parser.add_argument('--manager-sha256',required=True)
    parser.add_argument('--control-socket',type=Path,default=Path('/tmp/hyprwm.ctl'))
    parser.add_argument('--replace-stale',action='store_true')
    parser.add_argument('--retire-owned-current',type=Path,
                        help='Retire the exact published root receipt before installing a separate approved instance')
    args = parser.parse_args()
    need(not args.retire_owned_current or (args.image_dir and not args.replace_stale),
         '--retire-owned-current requires --image-dir and cannot use --replace-stale')
    need(os.geteuid()==0 and not sys.flags.optimize and sys.flags.isolated and sys.flags.no_site,
         'Run explicit root bootstrap with python3 -I -S')
    need(args.owner_uid>0 and re.fullmatch('[0-9a-f]{64}',args.manager_sha256), 'Desktop UID and approved manager SHA-256 required')
    need(subprocess.check_output(['/usr/bin/sw_vers','-buildVersion'],text=True).strip()=='25G241', 'This build is not qualified')
    os.umask(0o077);user = pwd.getpwuid(args.owner_uid);control = args.control_socket.expanduser().absolute()
    manager_path = args.manager_executable.expanduser().resolve(strict=True)
    with publisher_lock(args.owner_uid):
        if args.resume:
            run = root_run(args.resume.expanduser().absolute())
            context = json.loads(read_file(run/'context.json',(0,)))
            freeze_helpers(run,args.owner_uid,True,context.get('source_pins'))
        else:
            run = Path(tempfile.mkdtemp(prefix='hyprwm-workspace-bootstrap-',dir='/private/tmp'));os.chmod(run,0o700)
            freeze_helpers(run,args.owner_uid,False)
            context = prepare_context(run,args.image_dir.expanduser().resolve(strict=True),args.owner_uid,user,control,
                                      args.replace_stale,manager_path,args.manager_sha256,
                                      args.retire_owned_current.expanduser().absolute() if args.retire_owned_current else None)
        execute_context(run,context,args.owner_uid,user,control,manager_path,args.manager_sha256,bool(args.resume))


if __name__=='__main__':
    main()
