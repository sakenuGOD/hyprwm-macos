#!/usr/bin/env python3
"""User-local, relocatable Lite installation and fail-closed window restoration."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid


MARKER = 'hyprwm-user-install-v1'


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


def install(root):
    app, bin_dir = paths()
    if app.is_symlink():
        raise RuntimeError('Refusing to replace a symlink at the app destination')
    if app.exists():
        owned_receipt(app)
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
        macos = staged / 'Contents/MacOS'
        resources = staged / 'Contents/Resources'
        config = resources / 'hook/config'
        macos.mkdir(parents=True)
        config.mkdir(parents=True)
        binary = macos / 'hyprwm-swift'
        shutil.copy2(root / 'hook/swift/.build/release/hyprwm-swift', binary)
        binary.chmod(0o755)
        shutil.copy2(root / 'hook/config/portable-defaults.json', config / 'hypr_cfg.json')
        for name in ('runtime.schema.json', 'hypr_shim.lua'):
            shutil.copy2(root / 'hook/config' / name, config / name)
        version = os.environ.get('HYPRWM_APP_VERSION', '0.1.0')
        info = dict(CFBundleIdentifier='dev.hyprwm.HyprWM', CFBundleName='HyprWM',
                    CFBundleDisplayName='HyprWM', CFBundleExecutable='hyprwm-swift',
                    CFBundlePackageType='APPL', CFBundleShortVersionString=version,
                    CFBundleVersion='1', LSMinimumSystemVersion='14.0', LSUIElement=True,
                    NSHighResolutionCapable=True, HyprWMLaunchRole='daemon',
                    NSScreenCaptureUsageDescription='HyprWM captures managed windows in memory to animate layout changes. Images are not saved.')
        iconset = Path(temporary) / 'AppIcon.iconset'
        subprocess.run(['swift', str(root / 'hook/swift/tools/AppIcon.swift'), str(iconset)], check=True)
        subprocess.run(['iconutil', '--convert', 'icns', str(iconset), '--output', str(resources / 'AppIcon.icns')], check=True)
        info['CFBundleIconFile'] = 'AppIcon'
        (staged / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        receipt = dict(installer=MARKER, binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                       version=version, mode='auto', engine_installed=False)
        (resources / 'InstallReceipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', 'dev.hyprwm.HyprWM', str(staged)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', str(staged)], check=True)
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
    hook = app / 'Contents/Resources/hook'
    for name in ('hyprwm', 'hyprwmctl'):
        if name == 'hyprwmctl':
            body = (root / 'scripts/hyprwmctl').read_text()
            body = body.replace('# A dependency-free', '# ' + MARKER + '\n# A dependency-free', 1)
        else:
            body = '#!/bin/sh\n# ' + MARKER + '\nset -eu\n'
            body += 'export HYPRWM_HOOK=${HYPRWM_HOOK:-' + shlex.quote(str(hook)) + '}\n'
            body += 'case "${1:-}" in\n'
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
    print('Open ~/Applications/HyprWM.app to start. Lite is selected when the Engine is unavailable.')
    print('System Settings → Privacy & Security → Accessibility: enable HyprWM for tiling and focus.')
    print('System Settings → Privacy & Security → Screen & System Audio Recording: enable HyprWM for capture animations.')
    print('Carbon hotkeys need no Input Monitoring. Automation → System Events is only needed for scripted desktop verification.')
    print('Run hyprwm doctor after granting permissions. No SIP, boot-args, injection or root changes were made.')


def uninstall(offline):
    app, bin_dir = paths()
    if not app.exists():
        print('No installed HyprWM app found; configuration was preserved')
        return
    if app.is_symlink():
        raise RuntimeError('Refusing a symlink at the app destination')
    owned_receipt(app)
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
        response = request('restore-all')
        if not (response.startswith('restored ') or response in ('no hidden windows', 'restored all windows')):
            raise RuntimeError('Window restoration was not accepted: ' + response)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            current = status()
            if current is None:
                raise RuntimeError('Daemon disconnected before restoration was confirmed; installation preserved')
            if current.get('hidden') == [] and current.get('engine', {}).get('holding', 0) == 0:
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
    state_dir = Path(os.environ.get('HYPRWM_STATE_DIR', '/tmp/hyprwm-swift'))
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
    uninstall_parser = subparsers.add_parser('uninstall')
    uninstall_parser.add_argument('--offline', action='store_true')
    arguments = parser.parse_args()
    try:
        if arguments.action == 'install':
            install(arguments.root.resolve())
        else:
            uninstall(arguments.offline)
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(f'hyprwm install: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
