#!/usr/bin/env python3
"""Build the existing, constructor-free native workspace bridge as the user."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess

ROOT = Path(__file__).resolve().parents[2]
IDENTITY_SOURCE = 'hook/src/managed_process_identity.c'
IDENTITY_SOURCE_SHA256 = '33ceec7761918eca50287f3af18217f5164b8d934644f8f6c3661bc57e81834c'
RECOVERY_INSTALL_NAME = 'hyprwm-workspaces-owned-recovery-20261028'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', required=True, type=Path)
    parser.add_argument('--recovery-instance', action='store_true',
                        help='Link a separate instance for explicit owned-bridge retirement')
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error('Build as the desktop user; bootstrap is a separate root operation')
    output = args.output_dir.expanduser().absolute()
    if output.is_symlink() or output.exists():
        parser.error('Output must be a new private directory')
    output = output.parent.resolve(strict=True) / output.name
    parent = output.parent.stat()
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o022:
        parser.error('Output parent must be owned without shared write access')
    if output.is_relative_to(ROOT):
        parser.error('Build outside the source checkout')
    sources = [ROOT / 'hook/native-space/DockSpacesBridge.m', ROOT / 'hook/src/managed_process_identity.c']
    before = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    if before[IDENTITY_SOURCE] != IDENTITY_SOURCE_SHA256:
        raise RuntimeError('The independently approved public process-identity source changed')
    os.umask(0o077)
    output.mkdir(mode=0o700)
    profiles = {}
    install_name = RECOVERY_INSTALL_NAME if args.recovery_instance else 'hyprwm-workspaces-local'
    for arch in ('arm64', 'arm64e'):
        image = output / ('DockSpacesBridge.' + arch + '.dylib')
        subprocess.run(['xcrun', 'clang', '-O2', '-Wall', '-Wextra', '-Werror', '-fobjc-arc',
                        '-dynamiclib', '-arch', arch, '-framework', 'Foundation',
                        '-framework', 'ApplicationServices', '-install_name', install_name,
                        str(sources[0]), '-o', str(image)], check=True)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(image)], check=True)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(image)], check=True)
        text = subprocess.check_output(['/usr/bin/dwarfdump', '--uuid', str(image)], text=True)
        rows = re.findall(r'UUID: ([0-9A-F-]+) \(([^)]+)\)', text)
        if len(rows) != 1 or rows[0][1] != arch:
            raise RuntimeError('Unexpected workspace image architecture/UUID')
        profiles[arch] = dict(file=image.name, uuid=rows[0][0].replace('-', '').lower(),
                              sha256=hashlib.sha256(image.read_bytes()).hexdigest())
    identity = output / 'ProcessIdentity.dylib'
    subprocess.run(['xcrun', 'clang', '-O2', '-Wall', '-Wextra', '-Werror', '-dynamiclib', '-arch', 'arm64',
                    '-install_name', 'hyprwm-process-identity', str(ROOT / IDENTITY_SOURCE), '-o', str(identity)], check=True)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(identity)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(identity)], check=True)
    helper = dict(file=identity.name, sha256=hashlib.sha256(identity.read_bytes()).hexdigest(),
                  source=IDENTITY_SOURCE, source_sha256=IDENTITY_SOURCE_SHA256)
    after = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    if before != after:
        raise RuntimeError('Workspace source changed while building')
    (output / 'workspace-images.json').write_text(json.dumps(dict(schema=1, profiles=profiles, sources=before,
                                                               install_name=install_name, identity_helper=helper), indent=2) + '\n')
    print('Workspace bridge built: ' + str(output))


if __name__ == '__main__':
    main()
