#!/usr/bin/env python3
"""User-local app installation and fail-closed window restoration."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import uuid


MARKER = 'hyprwm-user-install-v1'
TOOLBAR_MANAGER = Path('toolbar/HyprWM Spaces.app/Contents/Resources/hook/toolbar/manage.py')


def paths():
    # Use the explicit install HOME, including isolated packaging checks.
    home = Path(os.environ['HOME']).expanduser().resolve()
    return home / 'Applications/HyprWM.app', home / '.local/bin'


def request(command):
    path = os.environ.get('HYPRWM_CTL', '/tmp/hyprwm.ctl')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(5)
        client.connect(path)
        client.sendall((command + '\n').encode())
        response = bytearray()
        while b'\n' not in response:
            chunk = client.recv(65536)
            if not chunk:
                break
            response.extend(chunk)
            if len(response) > 1024 * 1024:
                raise RuntimeError('Oversized daemon response')
    if not response:
        raise RuntimeError('Daemon returned no response')
    return response.decode().strip()


def status():
    try:
        value = json.loads(request('status'))
        if not isinstance(value, dict):
            raise RuntimeError('Invalid daemon status')
        return value
    except (FileNotFoundError, ConnectionRefusedError):
        return None


def owned_receipt(app):
    receipt = app / 'Contents/Resources/InstallReceipt.json'
    try:
        value = json.loads(receipt.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        raise RuntimeError('The app is not a receipt-owned HyprWM installation; it was preserved')
    if value.get('installer') != MARKER:
        raise RuntimeError('Unrecognized installation receipt; app was preserved')
    return value


def external_engine_state(path):
    if path is None:return None
    path=Path(os.path.abspath(path.expanduser()))
    descriptor=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK|os.O_CLOEXEC)
    try:
        before=os.fstat(descriptor)
        if not (stat.S_ISREG(before.st_mode) and before.st_uid in (os.getuid(),0) and
                not before.st_mode&0o022 and before.st_nlink==1 and 0<before.st_size<=4096):
            raise RuntimeError('Engine state must be a bounded owned regular file without shared write access')
        data=os.read(descriptor,4097);after=os.fstat(descriptor)
        if len(data)!=before.st_size or (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns):
            raise RuntimeError('Engine state changed during read')
        fields=data.decode('utf-8').split()
        if not fields or not fields[0].isascii() or not fields[0].isdigit() or not 1<int(fields[0])<=2147483647:
            raise RuntimeError('Engine state does not name a native process')
    finally:os.close(descriptor)
    return path


def toolbar_restore(app,offline=False):
    receipt=owned_receipt(app)
    if 'toolbar' not in receipt:return
    runtime=Path(os.environ['HOME']).expanduser().resolve()/'.config/hyprwm-style'
    settings=runtime/'native-toolbar-session/settings.json'
    if not settings.exists():return
    info=settings.lstat()
    if settings.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077 or info.st_size>65536:
        raise RuntimeError('Toolbar configuration is unreadable; installation preserved')
    configuration=json.loads(settings.read_bytes())
    manager=Path(configuration['manager'])
    if manager.is_symlink() or manager.resolve()!=manager:raise RuntimeError('Toolbar recovery manager is not canonical; code preserved')
    info=manager.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o022 or hashlib.sha256(manager.read_bytes()).hexdigest()!=configuration['manager_sha256']:
        raise RuntimeError('Toolbar recovery manager changed; retained code and receipts are required before removal')
    arguments=[str(Path(sys.executable).resolve()),str(manager),'--runtime',str(runtime),'remove-service']
    if offline:arguments+=['--offline']
    result=subprocess.run(arguments,capture_output=True,text=True,timeout=55,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'})
    if result.returncode:raise RuntimeError('Toolbar restoration is pending; installation preserved: '+result.stderr[-500:])
    value=json.loads(result.stdout)
    if value.get('drained') is not True:raise RuntimeError('Toolbar restoration is pending; installation preserved')


def toolbar_update_preflight(app):
    if 'toolbar' not in owned_receipt(app):return
    runtime=Path(os.environ['HOME']).expanduser().resolve()/'.config/hyprwm-style/native-toolbar-session'
    if (runtime/'settings.json').exists():
        raise RuntimeError('The configured toolbar retains an installation graph; restore it and explicitly migrate its qualification before updating. Current app preserved.')


def stage_bundle(root,staged,engine_state_path=None):
    if staged.exists() or staged.is_symlink():raise RuntimeError('Bundle destination already exists; preserved')
    macos = staged / 'Contents/MacOS'
    resources = staged / 'Contents/Resources'
    config = resources / 'hook/config'
    macos.mkdir(parents=True)
    config.mkdir(parents=True)
    binary = macos / 'hyprwm-swift'
    shutil.copy2(root / 'hook/swift/.build/release/hyprwm-swift', binary)
    binary.chmod(0o755)
    shutil.copy2(root / 'hook/config/portable-defaults.json', config / 'hypr_cfg.json')
    for name in ('portable-defaults.json', 'runtime.schema.json', 'hypr_shim.lua'):
        shutil.copy2(root / 'hook/config' / name, config / name)
    shutil.copytree(root / 'hook/config/defaults', config / 'defaults')
    runtime_hook = resources / 'hook'
    for name in ('lifecycle.py', 'own_ui.py'):
        shutil.copy2(root / 'hook' / name, runtime_hook / name)
    keys = runtime_hook / 'keys'
    keys.mkdir()
    shutil.copy2(root / 'hook/keys/binds.py', keys / 'binds.py')
    shutil.copy2(root / 'hook/keys/hyprkeys.m', keys / 'hyprkeys.m')
    shutil.copy2(root / 'hook/keys/hotkey_rules.h', keys / 'hotkey_rules.h')
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Carbon', '-framework', 'AppKit',
                    '-o', str(keys / 'hyprkeys'), str(keys / 'hyprkeys.m')], check=True)
    release = runtime_hook / 'swift/.build/release'
    release.mkdir(parents=True)
    (release / 'hyprwm-swift').symlink_to('../../../../../MacOS/hyprwm-swift')
    toolbar=resources/'toolbar'
    subprocess.run([str(Path(sys.executable).resolve()),str(root/'hook/toolbar/build.py'),'--output',str(toolbar)],check=True,
                   env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'})
    version = os.environ.get('HYPRWM_APP_VERSION', '0.1.1')
    info = dict(CFBundleIdentifier='dev.hyprwm.HyprWM', CFBundleName='HyprWM',
                CFBundleDisplayName='HyprWM', CFBundleExecutable='hyprwm-swift',
                CFBundlePackageType='APPL', CFBundleShortVersionString=version,
                CFBundleVersion='1', LSMinimumSystemVersion='14.0', LSUIElement=True,
                NSHighResolutionCapable=True, HyprWMLaunchRole='daemon',
                NSScreenCaptureUsageDescription='HyprWM captures managed windows in memory to animate layout changes. Images are not saved.')
    iconset = staged.parent / 'AppIcon.iconset'
    subprocess.run(['swift', str(root / 'hook/swift/tools/AppIcon.swift'), str(iconset)], check=True)
    subprocess.run(['iconutil', '--convert', 'icns', str(iconset), '--output', str(resources / 'AppIcon.icns')], check=True)
    info['CFBundleIconFile'] = 'AppIcon'
    (staged / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    receipt = dict(installer=MARKER, compiled_binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                   version=version, mode='auto', engine_installed=False)
    receipt['lifecycle_hook_relative'] = 'Contents/Resources/hook'
    receipt['state_directory'] = str(Path(os.environ['HOME']) / 'Library/Application Support/HyprWM/runtime')
    receipt['toolbar']={'manager':str(TOOLBAR_MANAGER),'build_receipt_sha256':hashlib.sha256((toolbar/'build-receipt.json').read_bytes()).hexdigest(),
                        'default_enabled':False,'live_qualified':False}
    if engine_state_path is not None:receipt['engine_state_path']=str(engine_state_path)
    (resources / 'InstallReceipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', 'dev.hyprwm.HyprWM', str(staged)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(staged)], check=True)
    return binary


def package(root,output,engine_state_path=None):
    engine_state_path=external_engine_state(engine_state_path)
    output=Path(os.path.abspath(output.expanduser()))
    if output.exists() or output.is_symlink():raise RuntimeError('Package destination already exists; preserved')
    output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.hyprwm-package-',dir=output.parent) as temporary:
        staged=Path(temporary)/'HyprWM.app'
        stage_bundle(root,staged,engine_state_path)
        if output.exists() or output.is_symlink():raise RuntimeError('Package destination appeared; preserved')
        staged.rename(output)
    print(f'Packaged {output}; no app launched, configuration initialized or running daemon changed.')


def install(root,engine_state_path=None):
    app, bin_dir = paths()
    if app.is_symlink():
        raise RuntimeError('Refusing to replace a symlink at the app destination')
    if app.exists():
        previous=owned_receipt(app)
        toolbar_update_preflight(app)
        if engine_state_path is None and 'engine_state_path' in previous:
            value=previous['engine_state_path']
            if not isinstance(value,str) or not value.startswith('/'):
                raise RuntimeError('Saved Engine state path is invalid; installation preserved')
            engine_state_path=Path(value)
    engine_state_path=external_engine_state(engine_state_path)
    for name in ('hyprwm', 'hyprwmctl'):
        destination = bin_dir / name
        if destination.is_symlink() or destination.exists():
            if destination.is_symlink() or MARKER not in destination.read_text(errors='replace')[:256]:
                raise RuntimeError(f'Existing CLI was preserved: {destination}')
    if status() is not None:
        raise RuntimeError('Quit the running HyprWM before installing an update; windows and the current installation were preserved')
    app.parent.mkdir(parents=True, exist_ok=True)
    bin_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.hyprwm-install-', dir=app.parent) as temporary:
        staged = Path(temporary) / 'HyprWM.app'
        binary=stage_bundle(root,staged,engine_state_path)
        resources=staged/'Contents/Resources'
        # Explicit destination keeps a temporary HOME isolated even on macOS where
        # Foundation's NSHomeDirectory resolves the account database instead.
        config_path = Path(os.environ.get('HYPRWM_CONFIG', str(Path(os.environ['HOME']) / '.config/hyprwm/hyprwm.conf')))
        environment = dict(os.environ, HYPRWM_HOOK=str(resources / 'hook'), HYPRWM_CONFIG=str(config_path))
        subprocess.run([str(binary), '--init-config'], env=environment, check=True)
        if app.exists():
            backup = app.with_name('HyprWM.backup-' + time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6] + '.app')
            app.rename(backup)
            print(f'Previous app preserved: {backup}')
        staged.rename(app)
    executable = app / 'Contents/MacOS/hyprwm-swift'
    resources = app / 'Contents/Resources'
    hook = resources / 'hook'
    for name in ('hyprwm', 'hyprwmctl'):
        if name == 'hyprwmctl':
            body = (root / 'scripts/hyprwmctl').read_text()
            body = body.replace('# A dependency-free', '# ' + MARKER + '\n# A dependency-free', 1)
        else:
            body = '#!/bin/sh\n# ' + MARKER + '\nset -eu\n'
            body += 'export HYPRWM_HOOK=${HYPRWM_HOOK:-' + shlex.quote(str(hook)) + '}\n'
            body += 'export HYPRWM_STATE_DIR=${HYPRWM_STATE_DIR:-' + shlex.quote(str(Path(os.environ['HOME']) / 'Library/Application Support/HyprWM/runtime')) + '}\n'
            body += 'case "${1:-}" in\n'
            body += '  toolbar) shift; exec '+shlex.quote(str(Path(sys.executable).resolve()))+' '+shlex.quote(str(resources/TOOLBAR_MANAGER))+' "$@" ;;\n'
            body += '  restore-all) if [ -S "${HYPRWM_CTL:-/tmp/hyprwm.ctl}" ]; then exec ' + shlex.quote(str(bin_dir / 'hyprwmctl')) + ' "$@"; fi ;;\n'
            body += '  status|pause|resume|reload) exec ' + shlex.quote(str(bin_dir / 'hyprwmctl')) + ' "$@" ;;\n'
            body += 'esac\nexec ' + shlex.quote(str(executable)) + ' "$@"\n'
        destination = bin_dir / name
        temporary = bin_dir / ('.' + name + '-' + uuid.uuid4().hex)
        temporary.write_text(body)
        temporary.chmod(0o755)
        os.replace(temporary, destination)
    print(f'Installed {app}')
    print(f'CLI: {bin_dir}/hyprwm (add {bin_dir} to PATH)')
    print('Open ~/Applications/HyprWM.app to start Engine mode. An existing qualified Engine installation and its external state receipt are required.')
    if engine_state_path is not None:print(f'External Engine receipt: {engine_state_path}; startup still performs native qualification.')
    else:print('Select the existing receipt with install --engine-state FILE or HYPRWM_ENGINE_STATE; no native engine was installed.')
    print('System Settings → Privacy & Security → Accessibility: enable HyprWM for tiling and focus.')
    print('System Settings → Privacy & Security → Screen & System Audio Recording: enable HyprWM for optional capture features.')
    print('Control–Option–P uses Carbon. Other Engine shortcuts require the separate native watcher; some watcher builds also need Input Monitoring permission. Automation → System Events is needed only for scripted desktop verification.')
    print('Run hyprwm doctor after granting permissions. No SIP, boot-args, injection or root changes were made.')


def restore_all():
    deadline = time.monotonic() + 4
    while True:
        response = request('restore-all')
        if not response.startswith(('error: Lite restoration pending:', 'error: Engine restoration pending:')) or time.monotonic() >= deadline:
            return response
        time.sleep(0.1)


def uninstall(offline):
    app, bin_dir = paths()
    if not app.exists():
        print('No installed HyprWM app found; configuration was preserved')
        return
    if app.is_symlink():
        raise RuntimeError('Refusing a symlink at the app destination')
    owned_receipt(app)
    toolbar_restore(app,offline)
    # Stop the owned login services first so launchd cannot undo a clean Quit.
    # A temporary HOME must never remove the real account's services.
    if offline:
        native_config = Path('/Library/Application Support/HyprWM') / ('native-session-' + str(os.getuid())) / 'config.json'
        if native_config.exists():
            value = json.loads(native_config.read_bytes())
            if Path(value.get('home', '')).resolve() == Path(os.environ['HOME']).resolve():
                status_path = native_config.parent / 'status.json'
                phase = json.loads(status_path.read_bytes()).get('phase') if status_path.exists() else 'pending'
                if phase != 'removed':
                    raise RuntimeError('--offline cannot remove an app retained by installed login services; use normal uninstall')
    else:
        installer = Path(__file__).resolve().with_name('install_autostart.py')
        spec = importlib.util.spec_from_file_location('hyprwm_uninstall_services', installer)
        services = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(services)
        try:
            configuration = services.configuration(os.getuid())
        except FileNotFoundError:
            configuration = None
        if configuration is not None:
            if Path(configuration['home']).resolve() != Path(os.environ['HOME']).resolve():
                raise RuntimeError('The login services belong to another home; they and the app were preserved')
            state = services.service.read(Path(configuration['base']) / 'status.json', limit=65536)
            if json.loads(state).get('phase') != 'removed':
                print('sudo: restore HyprWM windows and remove its owned native and user login services.', flush=True)
                subprocess.run(['/usr/bin/sudo', '/Library/Developer/CommandLineTools/usr/bin/python3',
                                '-I', '-S', str(installer), 'remove', '--uid', str(os.getuid())], check=True)
    current = status()
    if current is not None:
        if offline:
            raise RuntimeError('--offline refuses a responding daemon; no files were removed')
        pid = current.get('daemon', {}).get('pid')
        if not isinstance(pid, int) or pid <= 1:
            raise RuntimeError('Cannot verify the daemon PID; quit HyprWM and retry')
        executable = subprocess.check_output(['ps', '-p', str(pid), '-o', 'comm='], text=True).strip()
        expected = str(app / 'Contents/MacOS/hyprwm-swift')
        if executable != expected:
            raise RuntimeError('The running daemon belongs to another installation; it and all files were preserved')
        response = restore_all()
        if not (response.startswith('restored ') or response in ('no hidden windows', 'restored all windows')):
            raise RuntimeError('Window restoration was not accepted: ' + response)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            current = status()
            if current is None:
                raise RuntimeError('Daemon disconnected before restoration was confirmed; installation preserved')
            if current.get('hidden') == [] and current.get('engine', {}).get('holding', 0) == 0 and current.get('visibility', {}).get('engine_recovery_active') is not True:
                break
            time.sleep(0.05)
        else:
            raise RuntimeError('Windows are still restoring; installation preserved')
        # SIGTERM invokes the app's bounded, identity-checked shutdown coordinator.
        if subprocess.check_output(['ps', '-p', str(pid), '-o', 'comm='], text=True).strip() != expected:
            raise RuntimeError('Daemon identity changed; installation preserved')
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            raise RuntimeError('Safe shutdown is still pending; installation preserved')
    else:
        # A stopped daemon is safe only if no matching installed process remains.
        processes = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
        if str(app / 'Contents/MacOS/hyprwm-swift') in processes:
            raise RuntimeError('An installed process is not responding; quit it safely before uninstalling')
    state_dir = Path(os.environ.get('HYPRWM_STATE_DIR',
                                  owned_receipt(app).get('state_directory', '/tmp/hyprwm-swift')))
    def ledger(name):
        path = state_dir / name
        if not path.exists():
            return None
        if path.stat().st_size > 1024 * 1024:
            raise RuntimeError('Recovery ledger is oversized; installation preserved')
        return json.loads(path.read_text())
    engine = ledger('hyprwm.state.json')
    if engine is not None and not isinstance(engine, dict):
        raise RuntimeError('Unrecognized Engine recovery ledger; installation preserved')
    if isinstance(engine, dict) and engine.get('hidden'):
        raise RuntimeError('Engine hidden windows remain; start HyprWM in Engine mode and run restore-all before uninstalling')
    recovery = ledger('lite-recovery.json')
    if recovery is not None and not isinstance(recovery, list):
        raise RuntimeError('Unrecognized Lite recovery ledger; installation preserved')
    if recovery:
        if offline:
            raise RuntimeError('--offline refuses an outstanding recovery ledger; installation preserved')
        environment = dict(os.environ, HYPRWM_HOOK=str(app / 'Contents/Resources/hook'))
        subprocess.run([str(app / 'Contents/MacOS/hyprwm-swift'), 'restore-all'],env=environment,check=True)
        if ledger('lite-recovery.json'):
            raise RuntimeError('Lite recovery remains incomplete; installation preserved')
    keyboard_spec = importlib.util.spec_from_file_location('hyprwm_uninstall_keyboard',
                                                         Path(__file__).with_name('install_keyboard.py'))
    keyboard = importlib.util.module_from_spec(keyboard_spec)
    keyboard_spec.loader.exec_module(keyboard)
    keyboard.remove(offline=offline)
    for name in ('hyprwm', 'hyprwmctl'):
        path = bin_dir / name
        if path.is_file() and not path.is_symlink() and MARKER in path.read_text(errors='replace')[:256]:
            path.unlink()
    shutil.rmtree(app)
    print('Uninstalled HyprWM. Configuration, state and app backups were preserved.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest='action', required=True)
    install_parser = subparsers.add_parser('install')
    install_parser.add_argument('--root', required=True, type=Path)
    install_parser.add_argument('--engine-state',type=Path)
    package_parser=subparsers.add_parser('package',help='Create a signed bundle without installing or launching it')
    package_parser.add_argument('--root',required=True,type=Path)
    package_parser.add_argument('--output',required=True,type=Path)
    package_parser.add_argument('--engine-state',type=Path)
    uninstall_parser = subparsers.add_parser('uninstall')
    uninstall_parser.add_argument('--offline', action='store_true')
    arguments = parser.parse_args()
    try:
        if arguments.action == 'install':
            install(arguments.root.resolve(),arguments.engine_state)
        elif arguments.action=='package':
            package(arguments.root.resolve(),arguments.output,arguments.engine_state)
        else:
            uninstall(arguments.offline)
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(f'hyprwm install: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
