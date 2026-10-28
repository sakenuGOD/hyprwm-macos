#!/usr/bin/env python3
"""Install/remove the explicitly qualified native-session launchd services.

inspect is read-only. install requires root, explicit reviewed hashes and local
qualified images; it never builds code or changes system security policy.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('hyprwm_autostart', ROOT / 'hook/tools/autostart.py')
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)


def need(value, message):
    service.need(value, message)


def root_only():
    need(sys.platform == 'darwin' and os.geteuid() == 0, 'Run this action explicitly as root on macOS')
    need(not sys.flags.optimize, 'Python optimization must be disabled')


def digest(value):
    need(re.fullmatch('[0-9a-f]{64}', value or ''), 'An explicit reviewed SHA-256 is required')
    return value


def mkdir_root(path, mode=0o755):
    if not path.exists():
        mkdir_root(path.parent)
        path.mkdir(mode=mode)
    service.canonical(path, (0,), directory=True)
    return path


def user_directory(path, user):
    previous_uid, previous_gid = os.geteuid(), os.getegid()
    try:
        os.setegid(user.pw_gid); os.seteuid(user.pw_uid)
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    finally:
        os.seteuid(previous_uid); os.setegid(previous_gid)
    return service.canonical(path, (0, user.pw_uid), directory=True)


def write_exclusive(path, data, uid=0, gid=0, mode=0o644):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, mode)
    try:
        os.fchown(descriptor, uid, gid); os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, 'wb', closefd=False) as output:
            output.write(data); output.flush(); os.fsync(descriptor)
    finally:
        os.close(descriptor)


def labels(uid):
    return 'dev.hyprwm.native-session.' + str(uid), 'dev.hyprwm.backend.' + str(uid)


def plist_paths(uid, home):
    native, backend = labels(uid)
    return (Path('/Library/LaunchDaemons') / (native + '.plist'),
            Path(home) / 'Library/LaunchAgents' / (backend + '.plist'))


def launch_plists(config):
    native, backend = labels(config['uid'])
    script = str(Path(config['base']) / 'graph/hook/tools/autostart.py')
    common = dict(RunAtLoad=True, KeepAlive={'SuccessfulExit': False}, ThrottleInterval=30,
                  ProcessType='Background', AbandonProcessGroup=True,
                  EnvironmentVariables={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'PYTHONDONTWRITEBYTECODE': '1'})
    arguments = [config['python'], '-S', script]
    config_args = ['--config', str(Path(config['base']) / 'config.json')]
    root = dict(common, Label=native, ProgramArguments=arguments + ['native-service'] + config_args,
                StandardOutPath=str(Path(config['base']) / 'runtime/native-service.log'),
                StandardErrorPath=str(Path(config['base']) / 'runtime/native-service.log'))
    user = dict(common, Label=backend, ProgramArguments=arguments + ['user-service'] + config_args,
                LimitLoadToSessionType='Aqua',
                EnvironmentVariables={'HOME': config['home'], 'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
                                      'PYTHONDONTWRITEBYTECODE': '1'})
    return [plistlib.dumps(value, sort_keys=True) for value in (root, user)]


def launchctl(*arguments, missing_ok=False):
    result = subprocess.run(['/bin/launchctl', *map(str, arguments)], capture_output=True, text=True, timeout=12)
    if result.returncode:
        text = (result.stderr + result.stdout).strip()
        if missing_ok and ('No such process' in text or 'Could not find service' in text or result.returncode == 3):
            return False
        raise RuntimeError('launchctl ' + ' '.join(map(str, arguments[:2])) + ': ' + text[-1000:])
    return True


def inspect(root, uid):
    blobs = service.source_graph(root, uid)
    files = {name: service.sha(data) for name, data in blobs.items()}
    print(json.dumps(dict(schema=1, files=files, toolgraph_sha256=service.graph_digest(files)), indent=2))


def approved_workspaces(path, uid, root):
    names = ('workspace-images.json', 'DockSpacesBridge.arm64.dylib', 'DockSpacesBridge.arm64e.dylib')
    files = {name: service.read(path / name, (0, uid), 2**27) for name in names}
    manifest = json.loads(files['workspace-images.json'])
    # Read constants from this reviewed source without executing user code as root.
    import ast
    tree = ast.parse(service.read(root / 'hook/tools/bootstrap_workspaces.py', (0, uid)).decode())
    constants = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            if node.targets[0].id in ('APPROVED_IMAGES', 'APPROVED_SOURCES', 'APPROVED_HELPERS'):
                constants[node.targets[0].id] = ast.literal_eval(node.value)
    need(manifest.get('schema') == 1 and manifest.get('sources') == constants['APPROVED_SOURCES'] and
         set(manifest.get('profiles', {})) == {'arm64', 'arm64e'}, 'Independently approved workspace sources required')
    for arch in ('arm64', 'arm64e'):
        profile = manifest['profiles'][arch]
        name = 'DockSpacesBridge.' + arch + '.dylib'
        need(profile.get('file') == name and (profile.get('uuid'), profile.get('sha256')) == constants['APPROVED_IMAGES'][arch] and
             service.sha(files[name]) == profile['sha256'], 'Workspace artifact is not independently approved: ' + arch)
    for name, expected in constants['APPROVED_HELPERS'].items():
        need(service.sha(service.read(root / 'hook/tools' / name, (0, uid))) == expected, 'Workspace helper is not approved: ' + name)
    return files


def approved_identity(args, workspace_files, uid):
    need(bool(args.identity_helper) == bool(args.identity_sha256),
         '--identity-helper and --identity-sha256 must be supplied together')
    if args.identity_helper:
        path = args.identity_helper
        specification = dict(file=service.IDENTITY_FILE, sha256=digest(args.identity_sha256),
                             source=service.IDENTITY_SOURCE, source_sha256=service.IDENTITY_SOURCE_SHA256)
    else:
        specification = service.identity_spec(json.loads(workspace_files['workspace-images.json']).get('identity_helper'))
        path = args.workspace_image_dir / specification['file']
    data = service.read(path, (0, uid))
    need(service.sha(data) == specification['sha256'], 'Public identity helper differs from its approved artifact hash')
    service.identity_image(data)
    return data, specification


def install(args):
    root_only()
    uid = args.uid
    need(uid > 0, 'Positive desktop owner UID required')
    user = pwd.getpwuid(uid)
    need(Path(user.pw_dir).is_absolute(), 'Canonical account home required')
    root = service.canonical(args.root, (0, uid), directory=True)
    hook = service.canonical(args.hook, (0, uid), directory=True)
    manager = service.canonical(args.manager_executable, (0, uid))
    need(service.sha(service.read(manager, (0, uid))) == digest(args.manager_sha256), 'Manager differs from the reviewed executable')
    need((hook / 'swift/.build/release/hyprwm-swift').resolve(strict=True) == manager,
         'Manager must be the exact release executable of the configured lifecycle hook')
    need((hook / 'keys/hyprkeys').is_file(), 'Build the existing hotkey helper before installing autostart')
    python = service.canonical(Path(args.python).resolve(strict=True), (0,))
    need(os.access(python, os.X_OK), 'Protected Python executable required')
    blobs = service.source_graph(root, uid)
    files = {name: service.sha(data) for name, data in blobs.items()}
    need(service.graph_digest(files) == digest(args.toolgraph_sha256), 'Tool graph differs from the explicitly reviewed digest')
    image = service.read(args.native_image, (0, uid))
    need(service.sha(image) == digest(args.native_sha256), 'Native image differs from the explicitly reviewed image')
    workspace_files = approved_workspaces(args.workspace_image_dir, uid, root)
    identity_bytes, identity_helper = approved_identity(args, workspace_files, uid)
    need({name: service.sha(data) for name, data in service.source_graph(root, uid).items()} == files,
         'Reviewed source changed while freezing the installation graph')
    need(not args.adopt_workspaces or args.adopt_activation,
         '--adopt-workspaces requires its matching --adopt-activation receipt')
    base = service.BASE / ('native-session-' + str(uid))
    need(not base.exists() and not base.is_symlink(), 'An autostart receipt already exists; inspect/remove it before replacing it')
    daemon, agent = plist_paths(uid, user.pw_dir)
    need(not any(path.exists() or path.is_symlink() for path in (daemon, agent)), 'Existing service files were preserved')
    mkdir_root(service.BASE)
    mkdir_root(daemon.parent)
    user_directory(agent.parent, user)
    with tempfile.TemporaryDirectory(prefix='.native-session-' + str(uid) + '-', dir=service.BASE) as temporary:
        staged = Path(temporary)
        staged.chmod(0o755)
        graph = staged / 'graph'
        graph.mkdir(mode=0o755)
        (staged / 'runtime').mkdir(mode=0o700)
        for name, data in blobs.items():
            path = graph / name
            path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            write_exclusive(path, data)
        for directory, data in (('native', {'probe-eh.dylib': image}), ('workspaces', workspace_files),
                                ('identity', {service.IDENTITY_FILE: identity_bytes})):
            (graph / directory).mkdir(mode=0o755)
            for name, contents in data.items():
                write_exclusive(graph / directory / name, contents)
        frozen_identity = graph / 'identity' / service.IDENTITY_FILE
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(frozen_identity)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        signing = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(frozen_identity)],
                                 check=True, capture_output=True, text=True)
        need('Signature=adhoc' in signing.stderr.splitlines(), 'Public identity helper must have an ad-hoc signature')
        config = dict(schema=1, installer=service.MARKER, uid=uid, home=user.pw_dir, base=str(base),
                      hook=str(hook), manager=str(manager), manager_sha256=args.manager_sha256,
                      python=str(python), python_sha256=service.sha(service.read(python)),
                      files=files, graph_sha256=args.toolgraph_sha256, native_sha256=args.native_sha256,
                      identity_helper=identity_helper,
                      workspace_files={name: service.sha(data) for name, data in workspace_files.items()}, installed=time.time())
        write_exclusive(staged / 'config.json', (json.dumps(config, indent=2) + '\n').encode())
        # Rename a complete immutable graph before writing any launchd entry.
        staged.rename(base)
        # TemporaryDirectory must find its old pathname for cleanup.
        staged.mkdir(mode=0o700)
    service.load_config(base / 'config.json')
    if args.adopt_activation:
        row = service.activation(config, args.adopt_activation)
        if args.adopt_workspaces:
            row = service.adopted_workspaces(config, args.adopt_workspaces, row)
        service.save(base / 'runtime/current.json', row)
        service.publish(config, row, ready=True)
    else:
        preparation, active = service.native_modules(config)
        active.no_manager('/tmp/hyprwm.ctl')
        service.publish(config, {'phase': 'pending'}, detail='Fresh native preparation is scheduled at the configured GUI session')
    plist_data = launch_plists(config)
    config['plists'] = {str(path): service.sha(data) for path, data in zip((daemon, agent), plist_data)}
    service.save(base / 'config.json', config, 0o644)
    # User-owned LaunchAgent creation must happen with the desktop user's UID.
    write_exclusive(daemon, plist_data[0])
    previous_uid, previous_gid = os.geteuid(), os.getegid()
    try:
        os.setegid(user.pw_gid); os.seteuid(uid)
        write_exclusive(agent, plist_data[1], uid, user.pw_gid)
    finally:
        os.seteuid(previous_uid); os.setegid(previous_gid)
    launchctl('enable', 'system/' + labels(uid)[0])
    launchctl('bootstrap', 'system', daemon)
    # A missing GUI domain is a normal pre-login installation. RunAtLoad handles
    # the agent at the next login; an existing GUI domain must accept bootstrap.
    gui = subprocess.run(['/bin/launchctl', 'print', 'gui/' + str(uid)], capture_output=True, timeout=12)
    if gui.returncode == 0:
        launchctl('enable', 'gui/' + str(uid) + '/' + labels(uid)[1])
        launchctl('bootstrap', 'gui/' + str(uid), agent)
    print(json.dumps(dict(ok=True, installed=True, base=str(base), status=str(base / 'status.json'),
                          adopted=bool(args.adopt_activation)), indent=2))


def configuration(uid):
    need(uid > 0, 'Positive desktop owner UID required')
    return service.load_config(service.BASE / ('native-session-' + str(uid)) / 'config.json')


def status(uid):
    config = configuration(uid)
    base = Path(config['base'])
    value = dict(installed=True, base=str(base), uid=uid)
    try:
        value['status'] = json.loads(service.read(base / 'status.json', limit=65536))
    except FileNotFoundError:
        value['status'] = {'phase': 'pending'}
    value['installed'] = value['status'].get('phase') != 'removed'
    print(json.dumps(value, indent=2))


def remove(uid):
    root_only()
    config = configuration(uid)
    with service.effect_lock(config, removing=True):
        remove_owned(config)


def remove_owned(config):
    uid = config['uid']
    user = pwd.getpwuid(uid)
    daemon, agent = plist_paths(uid, config['home'])
    expected = config.get('plists', {})
    # Verify both owned files before making the first change.
    for path in (daemon, agent):
        if path.exists() or path.is_symlink():
            need(service.sha(service.read(path, (0, uid), 65536)) == expected.get(str(path)), 'Service file changed; installation preserved: ' + str(path))
    service.save(Path(config['base']) / 'runtime/removing.json', dict(schema=1, uid=uid, requested=time.time()))
    native, backend = labels(uid)
    for domain in ('system/' + native, 'gui/' + str(uid) + '/' + backend):
        launchctl('disable', domain, missing_ok=True)
        launchctl('bootout', domain, missing_ok=True)
    command = [config['python'], '-S', str(Path(config['base']) / 'graph/hook/tools/autostart.py'),
               'user-stop', '--config', str(Path(config['base']) / 'config.json')]
    def desktop_identity():
        os.initgroups(user.pw_name, user.pw_gid)
        os.setgid(user.pw_gid); os.setuid(uid)
    result = subprocess.run(command, preexec_fn=desktop_identity, capture_output=True, text=True,
                            env={'HOME': user.pw_dir, 'PATH': '/opt/homebrew/bin:/usr/bin:/bin', 'PYTHONDONTWRITEBYTECODE': '1'})
    need(result.returncode == 0, 'Restoration/drain is pending; disabled services, code and receipts were preserved: ' + result.stderr[-1000:])
    base = Path(config['base'])
    journal = base / 'runtime/current.json'
    row = json.loads(service.read(journal, limit=2**21)) if journal.exists() else {}
    preparation, active = service.native_modules(config)
    if row.get('windowserver') and service.same(row['windowserver'], preparation.identity):
        need(row.get('phase') not in ('prepare-attempt', 'activation-attempt', 'quarantined', 'workspace-attempt', 'workspace-quarantined'),
             'Unconfirmed native outcome requires explicit recovery; all code and receipts were preserved')
        if row.get('activation'):
            receipt = Path(row['activation'])
            service.canonical(receipt, (0,))
            active.retire(receipt.parent)
        elif row.get('prepared'):
            raise RuntimeError('Prepared native mappings retained without an activation inverse; installation preserved until this WindowServer departs')
    row['phase'] = 'removed'; service.save(journal, row); service.publish(config, row)
    for path in (agent, daemon):
        try:
            data = service.read(path, (0, uid), 65536)
        except FileNotFoundError:
            continue
        need(service.sha(data) == expected.get(str(path)), 'Service file changed before removal; file preserved')
        if path == agent:
            previous_uid, previous_gid = os.geteuid(), os.getegid()
            try:
                os.setegid(user.pw_gid); os.seteuid(uid); path.unlink()
            finally:
                os.seteuid(previous_uid); os.setegid(previous_gid)
        else:
            path.unlink()
    print(json.dumps(dict(ok=True, removed=True, drained=True, retained_receipts=str(base),
                          detail='Root graph and native/workspace evidence retained; toolbar keeps its separate existing service'), indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest='action', required=True)
    scan = actions.add_parser('inspect', help='Read-only reviewed tool-graph identity')
    scan.add_argument('--root', type=Path, default=ROOT)
    scan.add_argument('--uid', type=int, default=os.getuid())
    install_parser = actions.add_parser('install')
    install_parser.add_argument('--uid', type=int, required=True)
    install_parser.add_argument('--root', type=Path, default=ROOT)
    install_parser.add_argument('--hook', type=Path, required=True)
    install_parser.add_argument('--manager-executable', type=Path, required=True)
    install_parser.add_argument('--manager-sha256', required=True)
    install_parser.add_argument('--toolgraph-sha256', required=True)
    install_parser.add_argument('--native-image', type=Path, required=True)
    install_parser.add_argument('--native-sha256', required=True)
    install_parser.add_argument('--workspace-image-dir', type=Path, required=True)
    install_parser.add_argument('--identity-helper', type=Path, help='Explicit reviewed public-C identity dylib; otherwise use the workspace manifest helper')
    install_parser.add_argument('--identity-sha256', help='Explicit reviewed identity-helper SHA-256, paired with --identity-helper')
    install_parser.add_argument('--python', type=Path, default=Path('/Library/Developer/CommandLineTools/usr/bin/python3'))
    install_parser.add_argument('--adopt-activation', type=Path)
    install_parser.add_argument('--adopt-workspaces', type=Path, help='Completed root bootstrap directory for the same current native session')
    for action in ('status', 'remove'):
        command = actions.add_parser(action)
        command.add_argument('--uid', type=int, required=True)
    args = parser.parse_args()
    os.umask(0o022)
    try:
        if args.action == 'inspect':
            inspect(args.root, args.uid)
        elif args.action == 'install':
            install(args)
        elif args.action == 'status':
            status(args.uid)
        else:
            remove(args.uid)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, 'HyprWM autostart installer: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
