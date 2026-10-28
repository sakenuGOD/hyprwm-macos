#!/usr/bin/env python3
"""Build the toolbar and menu modules without launching or installing them."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
HOOK = HERE.parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(argv):
    result = subprocess.run(argv, capture_output=True, timeout=90)
    if result.returncode:
        raise ValueError((result.stdout + result.stderr).decode(errors='replace')[-6000:])
    return result.stdout.decode(errors='replace').strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--settings-source', type=Path)
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('this native toolbar build supports Apple Silicon macOS')
    output = args.output.expanduser()
    if not output.is_absolute() or output.resolve() != output or output.exists() or HERE in output.parents:
        raise ValueError('new canonical output outside the source tree required')
    entries = sorted(HERE.rglob('*'))
    if any(p.is_symlink() or p.resolve() != p for p in entries):
        raise ValueError('canonical source files required')
    if (HOOK / 'lifecycle.py').is_symlink() or (HOOK / 'lifecycle.py').resolve() != HOOK / 'lifecycle.py':
        raise ValueError('canonical lifecycle source required')
    inputs = [p for p in entries if p.is_file() and '__pycache__' not in p.parts]
    graph = {'schema': 1, 'sha256': {str(p.relative_to(HOOK)): sha(p) for p in inputs}}
    graph['sha256']['lifecycle.py'] = sha(HOOK / 'lifecycle.py')
    output.mkdir(parents=True, mode=0o700)
    manifest_path = output / 'source-manifest.json'
    manifest_path.write_text(json.dumps(graph, indent=2, sort_keys=True) + '\n')
    app = output / 'HyprWM Spaces.app'
    contents = app / 'Contents'
    macos = contents / 'MacOS'
    resources = contents / 'Resources'
    macos.mkdir(parents=True)
    resources.mkdir()
    for name in ('bridge.py', 'dependency-pins.json'):
        shutil.copy2(HERE / name, resources / name)
    shutil.copytree(HERE / 'dependencies', resources / 'dependencies', ignore=shutil.ignore_patterns('__pycache__'))
    shutil.copytree(HERE / 'assets', resources / 'brand-provenance', ignore=shutil.ignore_patterns('__pycache__'))
    shutil.copytree(HERE / 'assets/app-glyphs', resources / 'app-glyphs', ignore=shutil.ignore_patterns('__pycache__'))
    portable_hook = resources / 'hook'
    portable_toolbar = portable_hook / 'toolbar'
    portable_toolbar.mkdir(parents=True)
    shutil.copy2(HOOK / 'lifecycle.py', portable_hook / 'lifecycle.py')
    shutil.copytree(HERE / 'loader', portable_toolbar / 'loader', ignore=shutil.ignore_patterns('__pycache__'))
    for name in ('native_companion.py', 'session.py', 'manage.py'):
        shutil.copy2(HERE / name, portable_toolbar / name)
    shutil.copytree(HERE / 'dependencies', portable_toolbar / 'dependencies', ignore=shutil.ignore_patterns('__pycache__'))
    for path in resources.rglob('*.py'):
        path.chmod(0o600)
    compile_base = ['/usr/bin/xcrun', 'clang', '-arch', 'arm64', '-O2', '-fobjc-arc', '-Wall', '-Wextra', '-Wno-unused-parameter']
    binary = macos / 'HyprWMSpaces'
    run(compile_base + ['-framework', 'AppKit', '-framework', 'ApplicationServices', '-framework', 'CoreText', str(HERE / 'native/NativeWorkspaceCompanion.m'), '-lproc', '-o', str(binary)])
    frameworks = [part for name in ('AppKit', 'ApplicationServices', 'CoreWLAN', 'SystemConfiguration', 'IOKit', 'CoreAudio') for part in ('-framework', name)]
    run(compile_base + ['-Wno-deprecated-declarations', *frameworks, str(HERE / 'native/metadata.m'), '-lproc', '-o', str(resources / 'metadata')])
    run(['/usr/bin/xcrun', 'swiftc', str(HERE / 'session_events.swift'), '-o', str(resources / 'session-events')])
    profile_directory = resources / 'menu-profiles'
    profile_directory.mkdir()
    profiles = {}
    for arch in ('arm64', 'arm64e'):
        module = profile_directory / f'AppMenusRepresentationV7.{arch}.dylib'
        run(['/usr/bin/xcrun', 'clang', '-arch', arch, '-dynamiclib', '-fobjc-arc', '-fvisibility=hidden', '-Wall', '-Wextra', '-Werror', '-framework', 'Cocoa', '-DHYPR_FIRST_MAP', '-I', str(HERE / 'menu/frozen-admission'), str(HERE / 'menu/HyprAppMenusRepresentationV7.m'), *[str(HERE / 'menu/frozen-admission' / name) for name in ('admission.m', 'client.m', 'grant.m')], '-Wl,-install_name,@rpath/' + module.name, '-o', str(module)])
        run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'dev.hyprwm.style.appmenus-representation-v7', str(module)])
        run(['/usr/bin/codesign', '--verify', '--strict', str(module)])
        match = re.search(r'UUID: ([A-Fa-f0-9-]{36}) ', run(['/usr/bin/dwarfdump', '--uuid', str(module)]))
        if not match:
            raise ValueError('built module UUID unavailable')
        profiles[arch] = {'path': str(module.relative_to(output)), 'sha256': sha(module), 'uuid': match[1], 'qualified': False, 'external_v3_stage': True}
    (resources / 'menu-profiles.json').write_text(json.dumps({'schema': 1, 'profiles': profiles, 'qualification': 'build provenance only; no live qualification'}, indent=2) + '\n')
    info = {'CFBundleIdentifier': 'dev.hyprwm.style.native-bar', 'CFBundleName': 'HyprWM Spaces', 'CFBundleExecutable': 'HyprWMSpaces', 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1', 'LSUIElement': True, 'NSHighResolutionCapable': True, 'LSMinimumSystemVersion': '12.0'}
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'dev.hyprwm.style.native-bar', str(app)])
    run(['/usr/bin/codesign', '--verify', '--strict', str(app)])
    supplied = {}
    if args.settings_source:
        if not args.settings_source.is_absolute() or args.settings_source.stat().st_size > 65536:
            raise ValueError('bounded absolute settings source required')
        supplied = json.loads(args.settings_source.read_bytes())
    status_directory = output / 'hyprwm-native-companion'
    status_directory.mkdir(mode=0o700)
    settings = {'schema': 1, 'status_path': str(status_directory / 'status.json'), 'native_ui_status_path': str(status_directory / 'ui-status.json'), 'presentation': 'left-inline', 'own_space_panels_enabled': False, 'anchor_after_app_menus': True, 'python_executable': str(Path(sys.executable).resolve()), 'bridge_script': str(resources / 'bridge.py'), 'events_socket': '/tmp/hyprwm.ctl.events', 'control_socket': '/tmp/hyprwm.ctl', 'metadata_helper': str(resources / 'metadata'), 'forest_path': supplied.get('forest_path', str(HOOK / 'hyprwm.state.json')), 'wm_executable': supplied.get('wm_executable', str(HOOK / 'swift/.build/release/hyprwm-swift')), 'workspace_clicks_enabled': False, 'b15_menu_enabled': False, 'maximum_left_width': 480}
    settings_path = output / 'settings.json'
    settings_path.write_text(json.dumps(settings, indent=2) + '\n')
    settings_path.chmod(0o600)
    for rel, digest in graph['sha256'].items():
        if sha(HOOK / rel) != digest:
            raise ValueError('source changed during build: ' + rel)
    receipt = {'schema': 1, 'source_manifest_sha256': sha(manifest_path), 'architecture': 'arm64', 'compiler': run(['/usr/bin/xcrun', 'clang', '--version']), 'sdk': run(['/usr/bin/xcrun', '--show-sdk-version']), 'runtime': {str(p.relative_to(output)): sha(p) for p in sorted(output.rglob('*')) if p.is_file() and p != manifest_path}, 'profiles': profiles, 'GUI_started': False, 'services_changed': False, 'live_visual_qualified': False, 'workspace_clicks_enabled': False, 'wm_state_polling': False}
    (output / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'ok': True, 'app': str(app), 'build_receipt': str(output / 'build-receipt.json'), 'live_qualified': False}))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
