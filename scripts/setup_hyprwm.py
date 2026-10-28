#!/usr/bin/env python3
"""Guarded one-command setup; existing native tools retain admission authority."""
import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import pwd
import re
import shlex
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / 'hook/tools'
BUILD = '25G241'
MARKER = 'hyprwm-setup-v1'
SIP_DISABLED = 'System Integrity Protection status: disabled.'
ROOT_PYTHON = Path('/Library/Developer/CommandLineTools/usr/bin/python3')


def need(value, message):
    if not value:
        raise RuntimeError(message)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def output(command, *, check=True, timeout=30):
    result = subprocess.run(list(map(str, command)), capture_output=True, text=True, timeout=timeout,
                            env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
    if check and result.returncode:
        raise RuntimeError(shlex.join(list(map(str, command))) + ': ' + (result.stderr + result.stdout).strip()[-2000:])
    return result


def run(command):
    subprocess.run(list(map(str, command)), check=True, env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})


def run_json(command, **kwargs):
    return json.loads(output(command, **kwargs).stdout)


def sudo(command, purpose, *, json_result=False, isolated=False):
    # Repeat actual admission immediately before every privileged invocation.
    check_host(observe_host(), live=True)
    print('sudo: ' + purpose, flush=True)
    arguments = ['/usr/bin/sudo', '-H', str(ROOT_PYTHON), *(['-I', '-S'] if isolated else ['-E', '-S']), *map(str, command)]
    result = output(arguments, timeout=None)
    if json_result:
        return json.loads(result.stdout)
    if result.stdout.strip():
        print(result.stdout.rstrip(), flush=True)
    return result.stdout


def kickstart_autostart(uid):
    check_host(observe_host(), live=True)
    print('sudo: ask launchd to start the existing native-session service if it is idle (no service is killed)', flush=True)
    run(['/usr/bin/sudo', '/bin/launchctl', 'kickstart', 'system/dev.hyprwm.native-session.' + str(uid)])
    run(['/bin/launchctl', 'kickstart', 'gui/' + str(uid) + '/dev.hyprwm.backend.' + str(uid)])


def observe_host(test=False):
    def query(command):
        try:
            result = output(command, check=False)
            return result.stdout.strip() if result.returncode == 0 else 'unverified'
        except (OSError, subprocess.SubprocessError):
            return 'unverified'
    value = dict(system=platform.system(), arch=platform.machine(),
                 build=query(['/usr/bin/sw_vers', '-buildVersion']),
                 sip=query(['/usr/bin/csrutil', 'status']),
                 clt=Path('/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk').is_dir(),
                 git=bool(shutil.which('git')), python=sys.version.split()[0])
    if test:
        aliases = dict(SYSTEM='system', OS='system', ARCH='arch', BUILD='build', SIP='sip')
        used = {}
        for key, field in aliases.items():
            name = 'HYPRWM_TEST_' + key
            if name in os.environ:
                value[field] = os.environ[name]
                used[name] = os.environ[name]
        if used:
            value['dry_run_test_overrides'] = used
    return value


def check_host(host, live=False):
    need(host['system'] == 'Darwin', 'Native setup requires macOS.')
    need(host['arch'] == 'arm64', 'Native setup requires a native arm64 process on Apple Silicon; Rosetta is refused.')
    need(host['build'] == BUILD, 'Only exact macOS build ' + BUILD + ' is qualified; current build: ' + host['build'])
    need(host['sip'] == SIP_DISABLED, 'Fully disabled SIP is required; enabled, custom/partial and unverified SIP are refused. Setup never changes SIP.')
    if live:
        need(os.geteuid() != 0, 'Run setup as the desktop user, without sudo.')
        need(not sys.flags.optimize and os.environ.get('PYTHONOPTIMIZE', '') in ('', '0'), 'Python optimization must be disabled.')
        need(host['clt'], 'Command Line Tools SDK is unavailable; run ./setup.sh to install it.')
        for tool in ('clang', 'swift', 'lldb'):
            need(output(['/usr/bin/xcrun', '--find', tool], check=False).returncode == 0, 'Command Line Tools are incomplete: ' + tool)
        need(host['git'] and shutil.which('git'), 'Git is unavailable; run ./setup.sh.')
        need(Path(os.environ['HOME']).expanduser().resolve() == Path(pwd.getpwuid(os.getuid()).pw_dir).resolve(),
             'Live setup requires the desktop account HOME; isolated HOME is supported only for dry-run.')
        # No test override can admit a live or privileged operation.
        need(not any(key.startswith('HYPRWM_TEST_') for key in os.environ), 'HYPRWM_TEST_* overrides are accepted only with --dry-run.')
        protected_python()


def protected_python():
    need(ROOT_PYTHON.is_file(), 'Protected Command Line Tools Python is required for root helpers.')
    resolved = ROOT_PYTHON.resolve(strict=True)
    for path in (resolved, *resolved.parents):
        info = path.lstat()
        need(info.st_uid == 0 and not info.st_mode & 0o022, 'Root helper Python path is not protected: ' + str(path))
    return resolved


def locations():
    home = Path(os.environ['HOME']).expanduser().resolve()
    base = home / 'Library/Application Support/HyprWM/setup'
    return dict(home=home, base=base, state=base / 'receipt.json',
                app=home / 'Applications/HyprWM.app',
                autostart=Path('/Library/Application Support/HyprWM') / ('native-session-' + str(os.getuid())))


def private_directory(path):
    if path.exists() or path.is_symlink():
        info = path.lstat()
        need(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o022,
             'Unsafe setup directory was preserved: ' + str(path))
    else:
        private_directory(path.parent)
        path.mkdir(mode=0o700)
    return path


def read_receipt(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return {}
    need(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o022 and
         info.st_nlink == 1 and info.st_size <= 2**20, 'Unsafe setup receipt was preserved: ' + str(path))
    value = json.loads(path.read_bytes())
    need(value.get('installer') == MARKER and value.get('root') == str(ROOT), 'Unrecognized setup receipt was preserved: ' + str(path))
    return value


def save_receipt(paths, value):
    private_directory(paths['base'])
    read_receipt(paths['state'])
    value.update(installer=MARKER, root=str(ROOT), uid=os.getuid(), updated=time.time())
    fd, name = tempfile.mkstemp(prefix='.receipt-', dir=paths['base'])
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, paths['state'])
    finally:
        if os.path.exists(name):
            os.unlink(name)


def toolgraph():
    return run_json([sys.executable, '-B', ROOT / 'scripts/install_autostart.py', 'inspect', '--root', ROOT, '--uid', os.getuid()])


def native_cache(path, *, host=True):
    """Cache reuse proves source identity, frozen artifacts and actual local OS."""
    need(path.is_absolute() and not path.is_symlink() and not path.is_relative_to(ROOT), 'Native cache must be canonical and outside the checkout.')
    info = path.stat()
    need(info.st_uid == os.getuid() and stat.S_ISDIR(info.st_mode) and not info.st_mode & 0o022,
         'Native cache is not privately owned.')
    builder = module('hyprwm_setup_build', TOOLS / 'build_native.py')
    need(json.loads((path / 'source-manifest.json').read_bytes()) == builder.inputs(), 'Native cache source manifest changed.')
    provenance = json.loads((path / 'setup-provenance.json').read_bytes())
    need(provenance.get('schema') == 1 and provenance.get('build') == BUILD and provenance.get('arch') == 'arm64', 'Native cache host receipt differs.')
    artifacts = provenance.get('artifacts', {})
    need(set(artifacts) == {'probe-eh.dylib', 'probe-eh.bin', 'probe-eh-meta.json', 'display-local.S', 'display-local.json', 'source-manifest.json', 'native-channel'},
         'Native cache artifact receipt is incomplete.')
    for name, digest in artifacts.items():
        candidate = path / name
        item = candidate.lstat()
        need(stat.S_ISREG(item.st_mode) and item.st_uid == os.getuid() and not item.st_mode & 0o022 and item.st_nlink == 1,
             'Native cache artifact is unsafe: ' + name)
        need(sha(candidate) == digest, 'Native cache artifact changed: ' + name)
    generated = json.loads((path / 'display-local.json').read_bytes())
    need(provenance.get('os_input') == {key: generated[key] for key in ('build', 'skylight_uuid', 'body_sha256', 'cache', 'file_offset')},
         'Native cache OS provenance differs.')
    if host:
        generator = module('hyprwm_setup_generator', TOOLS / 'generate_display_clone.py')
        _, current = generator.local_body()
        need(current == provenance['os_input'], 'Cached image belongs to another local OS bridge.')
    return provenance


def workspace_cache(path, identity_helper=None, identity_sha256=None):
    installer = module('hyprwm_setup_installer', ROOT / 'scripts/install_autostart.py')
    files = installer.approved_workspaces(path, os.getuid(), ROOT)
    identity, specification = installer.approved_identity(argparse.Namespace(identity_helper=identity_helper, identity_sha256=identity_sha256, workspace_image_dir=path), files, os.getuid())
    return dict(files={name: hashlib.sha256(data).hexdigest() for name, data in files.items()}, identity_helper=specification)



def protected_workspaces(paths):
    """Root-owned receipts authorize reuse of their exact split workspace/helper graph."""
    uid = os.getuid()
    home = Path(paths['home']).expanduser().resolve()
    if home != Path(pwd.getpwuid(uid).pw_dir).resolve():
        return None
    installer = module('hyprwm_setup_protected_workspaces', ROOT / 'scripts/install_autostart.py')
    config = installer.service.load_config(paths['autostart'] / 'config.json')
    need(config['uid'] == uid and config.get('home') == str(home), 'Existing autostart belongs to another desktop owner or HOME.')
    base = Path(config['base'])
    directory = base / 'graph/workspaces'
    helper = base / 'graph/identity' / installer.service.IDENTITY_FILE
    digest = config['identity_helper']['sha256']
    validated = workspace_cache(directory, helper, digest)
    need(validated['files'] == config['workspace_files'] and validated['identity_helper'] == config['identity_helper'],
         'Protected workspace/identity graph differs from its owned receipt.')
    return dict(config=config, directory=directory, identity_helper=helper, identity_sha256=digest, validation=validated)


def retain_protected_workspaces(protected, active, status):
    need(active_runtime_proof(active, status), 'Protected workspace reuse requires the authenticated current manager.')
    config = protected['config']
    need(config['manager'] == active['manager'] and config['hook'] == active['hook'] and
         config['native_sha256'] == active['native_sha256'] and config['manager_sha256'] == sha(active['manager']),
         'Protected workspace graph belongs to a different native image or manager.')
    return protected


def build_native(paths, receipt):
    if receipt.get('native_image_dir'):
        cached = Path(receipt['native_image_dir'])
        try:
            native_cache(cached)
            print('Reusing the native image after source, artifact and local OS validation.', flush=True)
            return cached
        except (OSError, ValueError, RuntimeError) as error:
            print('Previous native cache retained; rebuilding: ' + str(error), flush=True)
    parent = private_directory(paths['base'] / 'images')
    destination = parent / ('native-' + time.strftime('%Y%m%d-%H%M%S') + '-' + os.urandom(4).hex())
    run([sys.executable, '-B', TOOLS / 'build_native.py', '--output-dir', destination])
    generated = json.loads((destination / 'display-local.json').read_bytes())
    names = ('probe-eh.dylib', 'probe-eh.bin', 'probe-eh-meta.json', 'display-local.S', 'display-local.json', 'source-manifest.json', 'native-channel')
    provenance = dict(schema=1, build=BUILD, arch='arm64',
                      os_input={key: generated[key] for key in ('build', 'skylight_uuid', 'body_sha256', 'cache', 'file_offset')},
                      artifacts={name: sha(destination / name) for name in names})
    (destination / 'setup-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    native_cache(destination)
    receipt['native_image_dir'] = str(destination)
    save_receipt(paths, receipt)
    return destination


def build_workspaces(paths, receipt, protected=None):
    if protected is not None:
        directory = protected['directory']
        workspace_cache(directory, protected['identity_helper'], protected['identity_sha256'])
        receipt.update(workspace_image_dir=str(directory),
                       workspace_identity_helper=str(protected['identity_helper']),
                       workspace_identity_sha256=protected['identity_sha256'])
        save_receipt(paths, receipt)
        print('Reusing the exact protected workspace images and reviewed identity helper.', flush=True)
        return directory
    if receipt.get('workspace_image_dir'):
        cached = Path(receipt['workspace_image_dir'])
        try:
            workspace_cache(cached)
            return cached
        except (OSError, ValueError, RuntimeError) as error:
            print('Previous workspace cache retained; rebuilding: ' + str(error), flush=True)
    parent = private_directory(paths['base'] / 'images')
    destination = parent / ('workspaces-' + time.strftime('%Y%m%d-%H%M%S') + '-' + os.urandom(4).hex())
    run([sys.executable, '-B', TOOLS / 'build_workspaces.py', '--output-dir', destination])
    workspace_cache(destination)
    receipt['workspace_image_dir'] = str(destination)
    save_receipt(paths, receipt)
    return destination


def manager_status():
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(3)
            client.connect(os.environ.get('HYPRWM_CTL', '/tmp/hyprwm.ctl'))
            client.sendall(b'status\n')
            data = bytearray()
            while b'\n' not in data:
                chunk = client.recv(65536)
                if not chunk:
                    break
                data.extend(chunk)
                need(len(data) <= 2**20, 'Oversized manager status.')
            return json.loads(data)
    except (FileNotFoundError, ConnectionRefusedError):
        return None


def conflicts(yes=False, dry_run=False):
    found = []
    for process, application in (('yabai', None), ('skhd', None), ('AeroSpace', 'AeroSpace'),
                                 ('Rectangle', 'Rectangle'), ('Amethyst', 'Amethyst')):
        result = output(['/usr/bin/pgrep', '-u', os.getuid(), '-x', process], check=False)
        if result.returncode == 0:
            found.append((process, application))
    if not found:
        return []
    print('Other window managers or hotkey services are running: ' + ', '.join(row[0] for row in found), flush=True)
    if dry_run:
        return [row[0] for row in found]
    accepted = yes
    if not accepted and sys.stdin.isatty():
        accepted = input('Request their graceful shutdown before continuing? [y/N] ').strip().lower() in ('y', 'yes')
    need(accepted, 'Stop the conflicting managers gracefully, then rerun setup (or use --yes).')
    for process, application in found:
        if application:
            run(['/usr/bin/osascript', '-e', 'tell application ' + json.dumps(application) + ' to quit'])
        else:
            brew = shutil.which('brew')
            need(brew, 'Cannot request a managed graceful stop for ' + process + '; stop it using its service owner and rerun.')
            run([brew, 'services', 'stop', process])
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        if all(output(['/usr/bin/pgrep', '-u', os.getuid(), '-x', row[0]], check=False).returncode != 0 for row in found):
            return [row[0] for row in found]
        time.sleep(.5)
    raise RuntimeError('A conflicting manager is still running; no process was forcibly terminated.')


def authenticated_manager(manager, uid):
    """Use the existing kernel/code-signing/status admission for a live manager."""
    sys.path.insert(0, str(TOOLS))
    import prepare_native
    workspace = module('hyprwm_setup_manager_proof', TOOLS / 'bootstrap_workspaces.py')
    workspace.identity = prepare_native.identity
    workspace.bounded_read = prepare_native.bounded_read
    return workspace.manager(Path('/tmp/hyprwm.ctl'), uid, Path(manager), sha(manager))


def active_runtime_proof(active, status):
    return bool(active and active.get('manager_verified') is True and status and
                status.get('enabled') is True and status.get('compatibility', {}).get('verified') is True and
                status.get('daemon', {}).get('pid') == active.get('manager_identity', {}).get('pid'))



def validate_workspace_receipt(directory, uid, active, peer, service, identity):
    workspace = module('hyprwm_setup_workspace_actor', TOOLS / 'bootstrap_workspaces.py')
    context = json.loads(service.read(directory / 'context.json', limit=2**21))
    published = json.loads(service.read(directory / 'published.json', limit=2**21))
    native = json.loads(service.read(directory / 'native.json', limit=2**21))
    user = pwd.getpwuid(uid)
    lease = Path(user.pw_dir) / 'Library/Application Support/HyprWM/native-spaces/lease.json'
    need(active.get('manager') and context.get('manager_path') == active['manager'] and
         context.get('request', {}).get('peer') == workspace.actor(peer),
         'Workspace manager is not the exact current peer')
    need(context.get('uid') == uid and context.get('lease') == str(lease) and published.get('lease') == str(lease),
         'Different workspace lease')
    need(json.loads(service.read(lease, (0, uid), 65536)) == context['request'] and
         native.get('ok') is True and native.get('detached') is True, 'Incomplete workspace publication')
    need(service.same(context['server'], identity) and service.same(context['dock'], identity),
         'Departed workspace generation')
    return str(directory)


def manager_hook(executable, home):
    executable = Path(executable)
    candidates = (ROOT / 'hook', Path(home) / 'Applications/HyprWM.app/Contents/Resources/hook',
                  *executable.parents)
    for hook in candidates:
        release = hook / 'swift/.build/release/hyprwm-swift'
        if release.is_file() and release.resolve(strict=True) == executable:
            return hook.resolve(strict=True)
    return None


def inspect_active(uid):
    """Read-only root inspection, restricted to existing native receipt roots."""
    need(os.geteuid() == 0 and uid > 0 and not sys.flags.optimize, 'Active inspection requires explicit root and a desktop UID.')
    # This entry point never admits native actions, even with forged test values.
    check_host(observe_host())
    service = module('hyprwm_setup_inspection', TOOLS / 'autostart.py')
    sys.path.insert(0, str(TOOLS))
    import prepare_native
    import activate_native
    candidates = []
    for receipt in Path('/private/tmp').glob('hyprwm-native-active-*/activation.json'):
        try:
            row = json.loads(service.read(receipt, limit=2**21))
            need(row.get('phase') == 'published', 'Incomplete native publication')
            prepared = Path(row['prepared'])
            value = json.loads(service.read(prepared, limit=2**21))
            need(value.get('owner_uid') == uid and service.same(value['expected'], prepare_native.identity), 'Different desktop/generation')
            state = row['engine_state']
            need(state.get('published') is True and service.read(Path(state['path']), (0, uid), 4096).hex() == state['new_data'], 'State publication differs')
            pointer = row['pointer']
            need(pointer.get('published') is True and activate_native.snapshot(Path(pointer['path']), uid)['data'] == pointer['new_data'], 'Pointer publication differs')
            candidates.append(dict(activation=str(receipt), prepared=str(prepared), engine_state=state['path'],
                                   native_sha256=sha(prepared.parent / 'probe-eh.dylib')))
        except (OSError, KeyError, ValueError, RuntimeError):
            continue
    need(len(candidates) <= 1, 'Multiple current native receipts match; resolve the ambiguous owned session explicitly.')
    active = candidates[0] if candidates else None
    if active:
        peer = None
        try:
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(3)
                connection.connect('/tmp/hyprwm.ctl')
                peer_pid = struct.unpack('=i', connection.getsockopt(0, 2, 4))[0]
            peer = prepare_native.identity(peer_pid)
            need(peer and peer['uid'] == uid, 'Different manager owner')
            active['manager'] = peer['path']
            user_home = Path(pwd.getpwuid(uid).pw_dir)
            hook = manager_hook(peer['path'], user_home)
            need(hook is not None, 'Current manager has no exact matching lifecycle hook')
            active['hook'] = str(service.canonical(hook, (0, uid), directory=True))
            peer = authenticated_manager(Path(active['manager']), uid)
            active['manager_identity'] = service.actor(peer)
            active['manager_sha256'] = sha(active['manager'])
            active['manager_verified'] = True
        except (FileNotFoundError, ConnectionRefusedError):
            pass
        workspaces = []
        directories = (Path('/private/tmp').glob('hyprwm-workspace-bootstrap-*')
                       if peer is not None and active.get('manager_verified') else ())
        for directory in directories:
            try:
                workspaces.append(validate_workspace_receipt(directory, uid, active, peer, service, prepare_native.identity))
            except (OSError, KeyError, ValueError, RuntimeError):
                continue
        need(len(workspaces) <= 1, 'Multiple current workspace receipts match; resolve explicitly.')
        active['workspace_receipt'] = workspaces[0] if workspaces else None
    print(json.dumps(dict(schema=1, active=active), indent=2))



def prepare_native_json(image, uid):
    """Adapt the approved prepare() return API without changing its pinned source."""
    need(os.geteuid() == 0 and uid > 0 and not sys.flags.optimize,
         'Native preparation adapter requires explicit unoptimized root and a desktop UID.')
    check_host(observe_host())
    sys.stdout.flush()
    saved_stdout = os.dup(1)
    try:
        # Native preparation invokes child tools. Redirect inherited FD1 too,
        # so the machine response remains one JSON value even with progress.
        os.dup2(2, 1)
        with contextlib.redirect_stdout(sys.stderr):
            preparation = module('hyprwm_setup_prepare_adapter', TOOLS / 'prepare_native.py')
            prepared = preparation.prepare(image.expanduser().resolve(strict=True), uid)
            sys.stdout.flush()
    finally:
        os.dup2(saved_stdout, 1)
        os.close(saved_stdout)
    print(json.dumps(dict(prepared=str(prepared / 'prepared.json'))))


def recover_departed(uid, receipt):
    """Reuse the existing departure guard; remove only its exact stale pointer."""
    need(os.geteuid() == 0 and uid > 0 and not sys.flags.optimize, 'Departure inspection requires explicit root and desktop UID.')
    check_host(observe_host())
    service = module('hyprwm_setup_departure', TOOLS / 'autostart.py')
    sys.path.insert(0, str(TOOLS))
    import prepare_native
    import activate_native
    row = json.loads(service.read(receipt, limit=2**21))
    prepared = json.loads(service.read(Path(row['prepared']), limit=2**21))
    need(prepared.get('owner_uid') == uid and row.get('phase') == 'published', 'Exact owned previous activation required.')
    actors = [prepare_native.identity(int(pid)) for pid in output(['/usr/bin/pgrep', '-x', 'WindowServer']).stdout.split()]
    actors = [actor for actor in actors if actor and actor['uid'] == 88 and actor['path'] == service.SERVER and actor['status'] != 4]
    need(len(actors) == 1, 'One canonical running WindowServer is required.')
    previous = dict(activation=str(receipt), windowserver=service.actor(prepared['expected']))
    service.unpublish_departed(dict(uid=uid, base=str(ROOT)), previous, service.actor(actors[0]))
    print(json.dumps(dict(ok=True, previous_activation=str(receipt), departed=True)))


def app_contract(paths):
    app = paths['app']
    receipt = json.loads((app / 'Contents/Resources/InstallReceipt.json').read_bytes())
    need(receipt.get('installer') == 'hyprwm-user-install-v1', 'The app is not an owned HyprWM installation.')
    relative = receipt.get('lifecycle_hook_relative')
    if relative is not None:
        need(isinstance(relative, str) and relative and not Path(relative).is_absolute(), 'Invalid bundled lifecycle hook receipt.')
        hook = (app / relative).resolve(strict=True)
        need(hook.is_relative_to(app.resolve(strict=True)), 'Bundled lifecycle hook escapes the installed app.')
    else:
        hook = (ROOT / 'hook').resolve(strict=True)
    manager = (hook / 'swift/.build/release/hyprwm-swift').resolve(strict=True)
    return hook, manager, app / 'Contents/MacOS/hyprwm-swift'


def permissions(binary):
    value = run_json([binary, '--permissions-json'])
    return value.get('accessibility') is True or value.get('accessibility_trusted') is True


def wait_permissions(binary, no_open):
    if permissions(binary):
        return
    need(not no_open, 'Accessibility is not granted to HyprWM. Open Privacy & Security → Accessibility, grant HyprWM access and rerun setup.')
    run_json([binary, '--request-permissions-json'])
    print('Enable HyprWM in Privacy & Security → Accessibility. Waiting for the app’s actual permission state…', flush=True)
    run(['/usr/bin/open', 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'])
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        if permissions(binary):
            return
        time.sleep(1)
    raise RuntimeError('Accessibility is still disabled. Existing receipts were retained; grant HyprWM access and rerun setup.')


def install_keyboard(active=None, status=None):
    command = [sys.executable, '-B', ROOT / 'scripts/install_keyboard.py', 'install']
    if active_runtime_proof(active, status):
        command += ['--legacy-hook', active['hook']]
    run(command)
    return wait_keyboard()


def wait_keyboard():
    deadline = time.monotonic() + 20
    last = {}
    while time.monotonic() < deadline:
        last = run_json([sys.executable, '-B', ROOT / 'scripts/install_keyboard.py', 'status'])
        if last.get('loaded') is True and last.get('health', {}).get('ready') is True:
            return last
        time.sleep(.5)
    raise RuntimeError('Keyboard LaunchAgent has not confirmed actual Carbon registration; inspect ' + str(last.get('log', 'its status/log')))


def wait_manager(timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = manager_status()
        if value and value.get('enabled') is True and value.get('compatibility', {}).get('verified') is True:
            return value
        time.sleep(.5)
    raise RuntimeError('HyprWM did not publish a live control status; run scripts/hyprwm-up to inspect the retained installation.')


def wait_autostart(uid, timeout=60):
    deadline = time.monotonic() + timeout
    last = {}
    while time.monotonic() < deadline:
        last = run_json([sys.executable, '-B', ROOT / 'scripts/install_autostart.py', 'status', '--uid', uid])
        status = last.get('status', {})
        if status.get('phase') == 'workspaces-ready' and status.get('ready') is True:
            return last
        need(status.get('phase') not in ('quarantined', 'workspace-quarantined', 'removed'),
             'Autostart requires receipt-based recovery: ' + json.dumps(status, sort_keys=True))
        time.sleep(.5)
    raise RuntimeError('Autostart has not confirmed a complete current workspace session: ' + json.dumps(last.get('status', {}), sort_keys=True))


def completion_summary(args, manager):
    status = wait_manager()
    peer = authenticated_manager(manager, os.getuid())
    need(status.get('daemon', {}).get('pid') == peer['pid'], 'Manager changed during final readiness observation.')
    wait_keyboard()
    if not args.no_autostart:
        wait_autostart(os.getuid())
        for domain in ('system/dev.hyprwm.native-session.' + str(os.getuid()),
                       'gui/' + str(os.getuid()) + '/dev.hyprwm.backend.' + str(os.getuid())):
            need(output(['/bin/launchctl', 'print', domain], check=False).returncode == 0,
                 'Autostart LaunchDaemon/LaunchAgent is not loaded: ' + domain)
    print('Tiling:ON, hotkeys:ON, autostart:' + ('OFF' if args.no_autostart else 'ON'), flush=True)


def dry_run(args):
    paths = locations()
    actual = observe_host()
    observed = observe_host(test=True)
    errors = []
    try:
        check_host(observed)
    except RuntimeError as error:
        errors.append(str(error))
    report = dict(schema=1, dry_run=True, mutations=False, host=actual, preflight=observed,
                  qualified=not errors, errors=errors,
                  paths={key: str(value) for key, value in paths.items()},
                  default_autostart=not args.no_autostart, open_app=not args.no_open,
                  plan=['[1/7] Actual arm64 / exact 25G241 / fully disabled SIP; install missing CLT, Git/Python only during live setup',
                        '[2/7] Build release app; preserve existing configuration and owned installation',
                        '[3/7] Revalidate cached native sources/artifacts/local OS; build native and approved workspace images as user',
                        '[4/7] Inspect active receipts; adopt current native publication or sudo prepare then sudo activate a fresh session',
                        '[5/7] Install user Carbon keyboard LaunchAgent before app or backend starts',
                        '[6/7] Poll actual app Accessibility permission; open Settings and app unless --no-open',
                        '[7/7] Install root native-session LaunchDaemon + user backend LaunchAgent with reviewed hashes and active receipt adoption' if not args.no_autostart else '[7/7] Skip native-session autostart; retain scripts/hyprwm-up manual fallback'])
    report['artifacts'] = {}
    try:
        state = read_receipt(paths['state'])
        report['setup_receipt'] = state
        for key in ('native_image_dir', 'workspace_image_dir'):
            if state.get(key):
                directory = Path(state[key])
                protected = None
                if key == 'workspace_image_dir' and state.get('workspace_identity_helper'):
                    protected = protected_workspaces(paths)
                    if protected is None:
                        report['artifacts'][key] = dict(path=str(directory), available=False,
                                                       detail='Protected workspace cache is unavailable for an isolated HOME.')
                        continue
                entries = {}
                if directory.is_dir() and not directory.is_symlink():
                    for file in directory.iterdir():
                        if file.is_file() and not file.is_symlink():
                            entries[file.name] = sha(file)
                report['artifacts'][key] = dict(path=str(directory), sha256=entries)
                try:
                    if key == 'native_image_dir':
                        validation = native_cache(directory, host=actual['system'] == 'Darwin' and actual['build'] == BUILD)
                    elif state.get('workspace_identity_helper'):
                        need(protected is not None, 'Protected workspace cache is unavailable for this HOME.')
                        need(directory == protected['directory'] and state['workspace_identity_helper'] == str(protected['identity_helper']) and
                             state.get('workspace_identity_sha256') == protected['identity_sha256'], 'Saved workspace identity does not match the protected installation.')
                        validation = protected['validation']
                    else:
                        validation = workspace_cache(directory)
                    report['artifacts'][key]['validation'] = validation
                    report['artifacts'][key]['host_verified'] = key != 'native_image_dir' or (actual['system'] == 'Darwin' and actual['build'] == BUILD)
                except (OSError, ValueError, RuntimeError, KeyError) as error:
                    report['artifacts'][key]['validation_error'] = str(error)
    except (OSError, ValueError, RuntimeError) as error:
        report['receipt_error'] = str(error)
    for path in (paths['app'] / 'Contents/Resources/InstallReceipt.json', paths['app'] / 'Contents/MacOS/hyprwm-swift',
                 paths['autostart'] / 'config.json', paths['autostart'] / 'status.json'):
        try:
            if path.is_file() and not path.is_symlink():
                report['artifacts'][str(path)] = dict(sha256=sha(path))
        except OSError as error:
            report['artifacts'][str(path)] = dict(read_error=str(error))
    try:
        report['toolgraph'] = toolgraph()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report['toolgraph_error'] = str(error)
    print(json.dumps(report, indent=2))
    return 0 if not errors else 1


def setup(args):
    print('[1/7] Verifying actual host, account and conflicting managers.', flush=True)
    check_host(observe_host(), live=True)
    need(os.environ.get('HYPRWM_CTL', '/tmp/hyprwm.ctl') == '/tmp/hyprwm.ctl', 'One-command setup uses the canonical /tmp/hyprwm.ctl control endpoint.')
    paths = locations()
    receipt = read_receipt(paths['state'])
    existing_service = paths['autostart'] / 'config.json'
    protected = protected_workspaces(paths) if existing_service.exists() else None
    conflicts(args.yes)
    if args.up and receipt.get('autostart') is False:
        args.no_autostart = True
    # Inspect before rebuilding: a running native session must be adopted.
    active = sudo([__file__, '--inspect-active', '--uid', os.getuid()], 'inspect existing native/workspace publications without attaching', json_result=True)['active']
    running = manager_status()
    if protected is not None and active_runtime_proof(active, running):
        protected = retain_protected_workspaces(protected, active, running)
    elif protected is not None:
        need(args.up, 'Existing autostart is not currently ready; use scripts/hyprwm-up to recover its owned services without a competing native attachment.')
    if args.up and existing_service.exists():
        status = run_json([sys.executable, '-B', ROOT / 'scripts/install_autostart.py', 'status', '--uid', os.getuid()])
        print('Autostart status: ' + json.dumps(status.get('status', {}), sort_keys=True), flush=True)
        phase = status.get('status', {}).get('phase', '')
        need(phase not in ('prepare-attempt', 'activation-attempt', 'quarantined', 'workspace-attempt', 'workspace-quarantined'),
             'Autostart retained an unconfirmed native attempt; manual recovery requires its receipts. No second attachment was attempted.')
        if active_runtime_proof(active, running):
            install_keyboard(active, running)
            wait_autostart(os.getuid())
            print('HyprWM is already running; current native activation was retained.', flush=True)
            completion_summary(args, Path(active['manager']))
            return
        print('Requesting a safe restart of idle launchd services using their frozen cached image.', flush=True)
        install_keyboard()
        kickstart_autostart(os.getuid())
        wait_manager()
        wait_autostart(os.getuid())
        wait_keyboard()
        print('HyprWM recovered through its existing autostart service and frozen native cache.', flush=True)
        config = json.loads(existing_service.read_bytes())
        completion_summary(args, Path(config['manager']))
        return
    print('[2/7] Building and installing the user app; existing configuration is preserved.', flush=True)
    if running:
        need(active_runtime_proof(active, running), 'A running manager lacks authenticated current native/runtime proof; the owner session was preserved.')
        print('Live HyprWM retained; app replacement is deferred until its next explicit update.', flush=True)
    elif args.up:
        need(paths['app'].is_dir() and receipt.get('native_image_dir'), 'No completed setup cache exists; run ./setup.sh first.')
    else:
        run(['/usr/bin/swift', 'build', '-c', 'release', '--package-path', ROOT / 'hook/swift'])
    print('[3/7] Validating/building the local native and approved workspace images.', flush=True)
    native = build_native(paths, receipt)
    workspaces = build_workspaces(paths, receipt, protected)
    image_sha = sha(native / 'probe-eh.dylib')
    if active:
        need(active['native_sha256'] == image_sha,
             'Native adoption SHA mismatch; current activation was preserved. Active image SHA-256: ' + active['native_sha256'] +
             '; active prepared receipt: ' + active['prepared'] + '; rebuilt image SHA-256: ' + image_sha +
             '; rebuilt image: ' + str(native / 'probe-eh.dylib') +
             '. Review the original qualified image and source/provenance before migration; no activation was attempted.')
        engine_state = Path(active['engine_state'])
        receipt.update(activation=active['activation'], engine_state=str(engine_state))
        if active.get('workspace_receipt'):
            receipt['workspace_receipt'] = active['workspace_receipt']
    else:
        need(not running, 'A running manager has no matching current activation receipt; current session was preserved.')
        sessions = private_directory(paths['base'] / 'sessions')
        session = sessions / ('session-' + time.strftime('%Y%m%d-%H%M%S') + '-' + os.urandom(4).hex())
        private_directory(session)
        engine_state = session / 'engine.state'
    print('[4/7] Retaining the active native session or preparing/publishing a fresh qualified session.', flush=True)
    if not active:
        # A WindowServer replacement may retain the old pointer in /tmp. Only
        # the existing exact-birth departure guard may clear that publication.
        if Path('/private/tmp/hyprwm/chan_path').exists():
            need(receipt.get('activation'), 'An unrecognized native publication exists; no replacement was attempted.')
            sudo([__file__, '--recover-departed', '--uid', os.getuid(), '--previous-activation', receipt['activation']],
                 'verify the previous WindowServer birth departed and remove only its exact stale filesystem publication', json_result=True)
        # Journal first: an interrupted attempt is never repeated blindly.
        need(receipt.get('phase') not in ('prepare-attempt', 'activation-attempt'),
             'An earlier native attempt is unconfirmed; retain its receipt and inspect before retrying.')
        receipt.update(phase='prepare-attempt', engine_state=str(engine_state))
        save_receipt(paths, receipt)
        prepared = sudo([__file__, '--prepare-native-json', '--image-dir', native, '--uid', os.getuid()],
                        'prepare a fresh disabled native engine; independently verify the image and current WindowServer', json_result=True)
        prepared_path = Path(prepared['prepared'])
        if prepared_path.name != 'prepared.json':
            prepared_path = prepared_path / 'prepared.json'
        receipt.update(phase='activation-attempt', prepared=str(prepared_path))
        save_receipt(paths, receipt)
        text = sudo([TOOLS / 'activate_native.py', 'activate', '--prepared', prepared_path, '--engine-state', engine_state, '--owner-uid', os.getuid()],
                    'publish the exact prepared native graph and its user engine-state receipt')
        matches = re.findall(r'^Native graph published: (/.+/activation\.json)$', text, re.M)
        need(len(matches) == 1, 'Activation did not publish exactly one durable receipt; retained session requires inspection.')
        receipt.update(activation=matches[0], phase='native-ready')
        active = dict(activation=matches[0], engine_state=str(engine_state), workspace_receipt=None)
        save_receipt(paths, receipt)
    if not running:
        run([sys.executable, '-B', ROOT / 'scripts/install_app.py', 'install', '--root', ROOT, '--engine-state', engine_state])
    if active.get('manager_verified'):
        hook, manager = Path(active['hook']), Path(active['manager'])
        app_binary = paths['app'] / 'Contents/MacOS/hyprwm-swift'
        print('Adopting the current manager and its exact lifecycle hook: ' + str(manager), flush=True)
    else:
        hook, manager, app_binary = app_contract(paths)
    # Existing autostart admission requires this helper even with LaunchAgent ownership.
    if not (hook / 'keys/hyprkeys').is_file():
        run(['/usr/bin/xcrun', 'clang', '-fobjc-arc', '-framework', 'Carbon', '-framework', 'AppKit',
             '-o', hook / 'keys/hyprkeys', ROOT / 'hook/keys/hyprkeys.m'])
    print('[5/7] Installing the user Carbon keyboard LaunchAgent before starting HyprWM.', flush=True)
    install_keyboard(active, running)
    print('[6/7] Verifying HyprWM Accessibility permission.', flush=True)
    if active_runtime_proof(active, manager_status()):
        authenticated_manager(manager, os.getuid())
        print('The authenticated current manager reports enabled, verified tiling; retaining its working Accessibility identity.', flush=True)
    else:
        wait_permissions(app_binary, args.no_open)
    print('[7/7] Installing login autostart and adopting the exact current native session.' if not args.no_autostart else '[7/7] Starting the session without native login autostart.', flush=True)
    if not args.no_autostart:
        graph = toolgraph()
        action = 'install'
        if existing_service.exists():
            config = json.loads(existing_service.read_bytes())
            matching = (config.get('uid') == os.getuid() and config.get('manager_sha256') == sha(manager) and
                        config.get('native_sha256') == image_sha and config.get('graph_sha256') == graph['toolgraph_sha256'])
            if matching:
                status = run_json([sys.executable, '-B', ROOT / 'scripts/install_autostart.py', 'status', '--uid', os.getuid()])
                need(status.get('installed') is True, 'Removed autostart retains recovery evidence; inspect it before reinstalling.')
                print('Matching autostart installation retained: ' + json.dumps(status.get('status', {}), sort_keys=True), flush=True)
                action = None
            else:
                need(active_runtime_proof(active, manager_status()) and active.get('workspace_receipt'),
                     'An owned autostart upgrade requires authenticated current native, manager and complete workspace adoption receipts.')
                action = 'upgrade'
        if action:
            arguments = [ROOT / 'scripts/install_autostart.py', action, '--uid', os.getuid(), '--root', ROOT,
                         '--hook', hook, '--manager-executable', manager, '--manager-sha256', sha(manager),
                         '--toolgraph-sha256', graph['toolgraph_sha256'], '--native-image', native / 'probe-eh.dylib',
                         '--native-sha256', image_sha, '--workspace-image-dir', workspaces, '--python', protected_python(),
                         '--adopt-activation', active['activation']]
            if active.get('workspace_receipt'):
                arguments += ['--adopt-workspaces', active['workspace_receipt']]
            if protected is not None:
                arguments += ['--identity-helper', protected['identity_helper'], '--identity-sha256', protected['identity_sha256']]
            sudo(arguments, ('upgrade the owned frozen graph and ONLY its two supervisors; preserve the current native engine, manager, menus and keyboard' if action == 'upgrade' else
                             'freeze the reviewed graph and install the root native-session LaunchDaemon plus user backend LaunchAgent; adopt existing publications'))
    elif not args.no_open and not running:
        run(['/usr/bin/open', paths['app']])
    if not args.no_open:
        if not args.no_autostart:
            # The user service owns daemon startup; opening the app only happens
            # once the shared lifecycle has started or adopted that daemon.
            wait_manager()
            wait_autostart(os.getuid())
            if not running and app_binary.is_file() and app_binary.resolve() == manager:
                run(['/usr/bin/open', paths['app']])
            elif running:
                print('Retaining the current manager and its existing menu companions; the unused app bundle is not opened.', flush=True)
        else:
            wait_manager()
            if not active.get('workspace_receipt'):
                receipt['phase'] = 'workspace-attempt'
                save_receipt(paths, receipt)
                text = sudo([TOOLS / 'bootstrap_workspaces.py', '--image-dir', workspaces, '--owner-uid', os.getuid(),
                             '--manager-executable', manager, '--manager-sha256', sha(manager), '--replace-stale'],
                            'publish the approved workspace bridge for the exact current manager and Dock; preserve live unrelated sessions', isolated=True)
                matches = re.findall(r'^Retain bridge images and root bootstrap receipt: (/.+)$', text, re.M)
                need(len(matches) == 1, 'Workspace bootstrap receipt is unconfirmed; inspect retained evidence before retrying.')
                receipt['workspace_receipt'] = matches[0]
    elif not args.no_autostart:
        # --no-open suppresses explicit app/UI opening; requested login services
        # still own their backend startup and must prove readiness.
        wait_manager()
        wait_autostart(os.getuid())
    receipt.update(phase='complete', native_image_dir=str(native), workspace_image_dir=str(workspaces),
                   engine_state=str(engine_state), autostart=not args.no_autostart)
    save_receipt(paths, receipt)
    print('Manual fallback: ' + str(ROOT / 'scripts/hyprwm-up'), flush=True)
    if args.no_open and args.no_autostart and not running:
        wait_keyboard()
        print('Tiling:OFF, hotkeys:ON, autostart:OFF (app start skipped by --no-open)', flush=True)
    else:
        completion_summary(args, manager)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--yes', action='store_true')
    parser.add_argument('--no-open', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--no-autostart', action='store_true')
    parser.add_argument('--up', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--inspect-active', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--prepare-native-json', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--image-dir', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--uid', type=int, help=argparse.SUPPRESS)
    parser.add_argument('--recover-departed', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--previous-activation', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.prepare_native_json:
            need(not args.dry_run and args.uid is not None and args.image_dir is not None, 'Explicit native image directory and desktop UID required.')
            prepare_native_json(args.image_dir, args.uid)
            return 0
        if args.recover_departed:
            need(not args.dry_run and args.uid is not None and args.previous_activation is not None, 'Explicit previous activation and desktop UID required.')
            recover_departed(args.uid, args.previous_activation)
            return 0
        if args.inspect_active:
            need(not args.dry_run and args.uid is not None, 'Explicit desktop UID required for root inspection.')
            inspect_active(args.uid)
            return 0
        if args.dry_run:
            return dry_run(args)
        setup(args)
        return 0
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print('HyprWM setup: ' + str(error), file=sys.stderr)
        print('Existing code, configuration and native receipts were retained. Manual status/fallback: scripts/hyprwm-up', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
