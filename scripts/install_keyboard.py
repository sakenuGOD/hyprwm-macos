#!/usr/bin/env python3
"""Install the Carbon hotkey watcher as a user LaunchAgent, without sudo."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import time

LABEL = 'org.hyprwm.keyboard'
MARKER = 'hyprwm-keyboard-install-v1'
FILES = ('hyprkeys', 'binds.py', 'portable-defaults.json', 'manage.py')


def locations():
    home = Path(os.environ['HOME']).expanduser().resolve()
    return (home / 'Library/Application Support/HyprWM/keyboard',
            home / 'Library/LaunchAgents' / (LABEL + '.plist'),
            home / 'Library/Logs/HyprWM/keyboard.log')


def read_owned(path, limit=4 * 1024 * 1024):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                info.st_mode & 0o022 or info.st_nlink != 1 or info.st_size > limit):
            raise RuntimeError('Unsafe keyboard file was preserved: ' + str(path))
        data = os.read(fd, limit + 1)
        if len(data) > limit:
            raise RuntimeError('Oversized keyboard file: ' + str(path))
        return data
    finally:
        os.close(fd)


def private_directory(path):
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise RuntimeError('Unsafe keyboard directory was preserved: ' + str(path))
    else:
        path.mkdir(parents=True, mode=0o700)


def atomic_write(path, data, mode=0o600):
    if path.exists() or path.is_symlink():
        read_owned(path)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def launchctl(*arguments, check=True):
    result = subprocess.run(['/bin/launchctl', *map(str, arguments)], capture_output=True,
                            text=True, timeout=15)
    if check and result.returncode:
        raise RuntimeError('launchctl ' + arguments[0] + ' failed: ' + result.stderr.strip()[-600:])
    return result


def loaded():
    return launchctl('print', 'gui/' + str(os.getuid()) + '/' + LABEL, check=False).returncode == 0


def receipt():
    base, agent, _ = locations()
    for directory in (base.parent, base, agent.parent):
        if directory.exists() or directory.is_symlink():
            info = directory.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
                raise RuntimeError('Unsafe keyboard directory was preserved: ' + str(directory))
    try:
        value = json.loads(read_owned(base / 'receipt.json', 65536))
    except FileNotFoundError:
        if base.exists() and any(base.iterdir()):
            if set(p.name for p in base.iterdir()) != {'status.json'}:
                raise RuntimeError('Unrecognized keyboard state was preserved')
        if agent.exists() or agent.is_symlink():
            raise RuntimeError('Unrecognized keyboard LaunchAgent was preserved')
        return None
    if value.get('installer') != MARKER or set(value.get('files', {})) != set(FILES):
        raise RuntimeError('Unrecognized keyboard receipt was preserved')
    if str(base) != value.get('base'):
        raise RuntimeError('Keyboard installation path changed; preserved')
    if agent.exists() or agent.is_symlink():
        if digest(read_owned(agent, 65536)) != value.get('plist_sha256'):
            raise RuntimeError('Changed keyboard LaunchAgent was preserved')
    for name in FILES:
        if digest(read_owned(base / name)) != value['files'][name]:
            raise RuntimeError('Changed keyboard installation file was preserved: ' + name)
    return value


def health():
    base, _, _ = locations()
    try:
        value = json.loads(read_owned(base / 'status.json', 65536))
        fresh = isinstance(value.get('updated'), (int, float)) and 0 <= time.time() - value['updated'] <= 6
        expected, registered = value.get('expected'), value.get('registered')
        valid = (value.get('schema') == 1 and value.get('backend') == 'carbon' and
                 type(expected) is int and type(registered) is int and 0 <= registered <= expected)
        value['fresh'] = fresh and valid
        value['ready'] = value['fresh'] and registered == expected and not value.get('reload_rejected')
        return value
    except (FileNotFoundError, ValueError, RuntimeError):
        return {'fresh': False, 'ready': False}


def status(offline=False):
    base, agent, log = locations()
    owned = receipt()
    snapshot = health()
    return dict(ok=True, installed=owned is not None, loaded=None if offline else loaded(),
                state=str(base), launch_agent=str(agent), log=str(log),
                permission='not_required', backend='carbon', health=snapshot,
                running=snapshot['fresh'], ready=snapshot['ready'], registered=snapshot.get('registered'))


def converter(path):
    specification = importlib.util.spec_from_file_location('hyprwm_keyboard_binds', path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def ensure_bindings(base, bindings):
    module = converter(base / 'binds.py')
    rows, _ = module.convert(module.source_bindings(base / 'portable-defaults.json'))
    module.publish(bindings, rows, missing_only=True)


def migrate_legacy(legacy_hook, *, processes=None, clock=time.monotonic, sleep=time.sleep):
    """Stop only a positively identified helper from an explicitly supplied hook."""
    hook = Path(legacy_hook)
    if not hook.is_absolute() or hook != hook.resolve(strict=True):
        raise RuntimeError('Legacy hook must be an existing absolute canonical directory')
    binary = hook / 'keys/hyprkeys'
    for path in (hook, binary.parent, binary):
        info = path.lstat()
        regular = stat.S_ISREG(info.st_mode) if path == binary else stat.S_ISDIR(info.st_mode)
        if not regular or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise RuntimeError('Unsafe legacy helper path was preserved: ' + str(path))
    if not os.access(binary, os.X_OK):
        raise RuntimeError('Legacy helper is not executable; preserved')
    if processes is None:
        # Load this installer's lifecycle implementation, never legacy hook code.
        source = Path(__file__).resolve().parent.parent / 'hook/lifecycle.py'
        specification = importlib.util.spec_from_file_location('hyprwm_keyboard_lifecycle', source)
        lifecycle = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(lifecycle)
        processes = lifecycle.DarwinProcesses()
    rows = [row for row in processes.all() if row.get('executable') == str(binary)]
    if len(rows) > 1:
        raise RuntimeError('Multiple exact legacy helper processes were preserved; migration is ambiguous')
    if not rows:
        return dict(stopped=[], hook=str(hook))
    observed = rows[0]
    identity = processes.identity(observed.get('pid'))
    birth = identity.get('birth') if isinstance(identity, dict) else None
    if (identity is None or identity.get('executable') != str(binary) or
            not isinstance(birth, list) or len(birth) != 4 or
            birth[:2] != [identity.get('pid'), os.getuid()] or birth != observed.get('birth') or
            identity.get('argv') != [str(binary)]):
        raise RuntimeError('Legacy helper kernel identity or argv is unconfirmed; no signal sent')
    # DarwinProcesses.terminate re-reads the complete identity immediately before
    # SIGTERM. Keep that existing generation guard; never signal a PID alone.
    processes.terminate(identity)
    deadline = clock() + 3
    while clock() < deadline:
        current = processes.identity(identity['pid'])
        if current is None or current.get('birth') != birth:
            return dict(stopped=[identity['pid']], hook=str(hook))
        sleep(.05)
    raise RuntimeError('Legacy helper did not exit after scoped SIGTERM; no SIGKILL sent')


def install(bindings=Path('/tmp/hyprkeys.json'), offline=False, dry_run=False, legacy_hook=None):
    if os.getuid() == 0:
        raise RuntimeError('Run keyboard setup as your desktop user, without sudo')
    base, agent, log = locations()
    previous = receipt()
    root = Path(__file__).resolve().parent.parent
    sources = {'hyprkeys.m': root / 'hook/keys/hyprkeys.m',
               'hotkey_rules.h': root / 'hook/keys/hotkey_rules.h',
               'binds.py': root / 'hook/keys/binds.py',
               'portable-defaults.json': root / 'hook/config/portable-defaults.json',
               'manage.py': Path(__file__).resolve()}
    source_hashes = {name: digest(path.read_bytes()) for name, path in sources.items()}
    python = str(Path(sys.executable).resolve())
    environment = dict(HOME=str(Path(os.environ['HOME']).expanduser().resolve()),
                       HYPRWM_KEYBOARD_STATE=str(base), HYPRWM_KEYS_BINDINGS=str(bindings),
                       PYTHONDONTWRITEBYTECODE='1')
    if os.environ.get('HYPRWM_CTL'):
        environment['HYPRWM_CTL'] = os.environ['HYPRWM_CTL']
    value = dict(Label=LABEL, ProgramArguments=[python, str(base / 'manage.py'), 'run'],
                 EnvironmentVariables=environment, RunAtLoad=True,
                 KeepAlive={'SuccessfulExit': False}, ThrottleInterval=10,
                 ProcessType='Interactive', StandardOutPath=str(log), StandardErrorPath=str(log))
    plist = plistlib.dumps(value, sort_keys=True)
    if dry_run:
        return dict(ok=True, dry_run=True, action='install', state=str(base), launch_agent=str(agent),
                    bindings=str(bindings), legacy_hook=str(legacy_hook) if legacy_hook else None,
                    command=['clang', '-fobjc-arc', '-framework', 'Carbon',
                    '-framework', 'AppKit', '-o', str(base / 'hyprkeys'), str(sources['hyprkeys.m'])])
    private_directory(base.parent)
    private_directory(agent.parent)
    private_directory(log.parent)
    current = (previous is not None and previous.get('sources') == source_hashes and
               previous.get('plist_sha256') == digest(plist) and agent.exists())
    if not current:
        with tempfile.TemporaryDirectory(prefix='.keyboard-stage-', dir=base.parent) as temporary:
            stage = Path(temporary)
            subprocess.run(['clang', '-fobjc-arc', '-framework', 'Carbon', '-framework', 'AppKit',
                            '-o', str(stage / 'hyprkeys'), str(sources['hyprkeys.m'])], check=True)
            for name in FILES[1:]:
                shutil.copyfile(sources[name], stage / name)
            if previous and not offline and loaded():
                launchctl('bootout', 'gui/' + str(os.getuid()) + '/' + LABEL)
            private_directory(base)
            base.chmod(0o700)
            for name in FILES:
                atomic_write(base / name, (stage / name).read_bytes(), 0o700 if name == 'hyprkeys' else 0o600)
            installed = dict(installer=MARKER, base=str(base), sources=source_hashes,
                             files={name: digest((base / name).read_bytes()) for name in FILES},
                             plist_sha256=digest(plist), bindings=str(bindings))
            atomic_write(agent, plist)
            atomic_write(base / 'receipt.json', (json.dumps(installed, indent=2) + '\n').encode())
    ensure_bindings(base, bindings)
    migration = dict(stopped=[])
    if legacy_hook:
        if offline:
            migration['skipped'] = 'offline'
        else:
            migration = migrate_legacy(legacy_hook)
            # A prior partial registration cannot acquire released chords until
            # its own exact LaunchAgent is restarted. Its plist was validated.
            if migration['stopped'] and loaded():
                launchctl('bootout', 'gui/' + str(os.getuid()) + '/' + LABEL)
    if not offline and not loaded():
        launchctl('enable', 'gui/' + str(os.getuid()) + '/' + LABEL)
        launchctl('bootstrap', 'gui/' + str(os.getuid()), agent)
    result = status(offline=offline)
    result['changed'] = not current
    result['legacy_migration'] = migration
    return result


def remove(offline=False, dry_run=False):
    base, agent, log = locations()
    previous = receipt()
    if previous is None:
        return dict(ok=True, installed=False, changed=False)
    if dry_run:
        return dict(ok=True, dry_run=True, action='remove', state=str(base), launch_agent=str(agent))
    extra = set(p.name for p in base.iterdir()) - set(FILES) - {'receipt.json', 'status.json', '__pycache__'}
    if extra:
        raise RuntimeError('Unexpected keyboard state retained: ' + ', '.join(sorted(extra)))
    if not offline and loaded():
        launchctl('bootout', 'gui/' + str(os.getuid()) + '/' + LABEL)
    if agent.exists():
        agent.unlink()
    shutil.rmtree(base)
    return dict(ok=True, installed=False, changed=True, log_retained=str(log), bindings_retained=previous['bindings'])


def run():
    base, _, _ = locations()
    value = receipt()
    if value is None:
        raise RuntimeError('Keyboard installation receipt is missing')
    bindings = Path(value['bindings'])
    ensure_bindings(base, bindings)
    os.environ['HYPRWM_KEYBOARD_STATE'] = str(base)
    os.environ['HYPRWM_KEYS_BINDINGS'] = str(bindings)
    os.execv(str(base / 'hyprkeys'), [str(base / 'hyprkeys')])


def prepare():
    """Create a missing reboot baseline before the daemon applies text overrides."""
    base, _, _ = locations()
    value = receipt()
    if value is None:
        raise RuntimeError('Keyboard installation receipt is missing')
    ensure_bindings(base, Path(value['bindings']))
    return dict(ok=True, installed=True, prepared=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('install', 'status', 'remove', 'run', 'prepare'))
    parser.add_argument('--bindings', type=Path, default=Path('/tmp/hyprkeys.json'))
    parser.add_argument('--offline', action='store_true', help='Only stage files; do not contact launchctl')
    parser.add_argument('--dry-run', action='store_true', help='Describe changes without writing files or launching')
    parser.add_argument('--json', action='store_true', help='Print machine-readable JSON (the default)')
    parser.add_argument('--legacy-hook', type=Path, help='Migrate only the exact helper of a verified legacy hook')
    args = parser.parse_args()
    if args.legacy_hook and args.action != 'install':
        parser.error('--legacy-hook is only supported by install')
    try:
        if args.action == 'install':
            result = install(args.bindings.absolute(), args.offline, args.dry_run, args.legacy_hook)
        elif args.action == 'remove':
            result = remove(args.offline, args.dry_run)
        elif args.action == 'status':
            result = status(args.offline)
        elif args.action == 'prepare':
            if args.dry_run:
                raise RuntimeError('prepare cannot be combined with --dry-run')
            result = prepare()
        else:
            if args.offline or args.dry_run:
                raise RuntimeError('run cannot be combined with --offline or --dry-run')
            run()
            return
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(json.dumps(dict(ok=False, error=str(error))), file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
