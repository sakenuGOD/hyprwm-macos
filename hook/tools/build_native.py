#!/usr/bin/env python3
"""Build the complete qualified native image using this Mac's OS bridge.

Output is private and local. This command never attaches to WindowServer.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parents[1]
if sys.flags.optimize or os.environ.get('PYTHONOPTIMIZE', '') not in ('', '0'):
    raise RuntimeError('Native qualification requires Python optimization disabled')


def inputs():
    pending = [ROOT / 'hook/src/anim4.c', ROOT / 'hook/src/presentation_normal.cpp',
               ROOT / 'hook/src/presentation_normal_entry.S',
               ROOT / 'hook/src/display_unwind_check.h', *TOOLS.glob('*.py'),
               TOOLS / 'display_unwind_check_at.h', TOOLS / 'native_channel.c',
               TOOLS / 'native_layout.c', TOOLS / 'native_raw_check.cpp']
    found = set()
    while pending:
        path = pending.pop().resolve()
        if path in found:
            continue
        if not path.is_relative_to(ROOT):
            raise RuntimeError('Build source escapes repository')
        found.add(path)
        for name in re.findall(r'^\s*#include\s+"([^"]+)"', path.read_text(), re.M):
            if path == (TOOLS / 'native_raw_check.cpp').resolve() and name == 'normal-layout.h':
                # qualify_raw derives this header from native_layout.c and the
                # linked image in its private output, not the source checkout.
                continue
            pending.append(path.parent / name)
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(found)}


def build(output):
    before = inputs()
    def run(arguments, **kwargs):
        subprocess.run(arguments, cwd=ROOT, check=True, **kwargs)
    python = sys.executable
    run([python, str(TOOLS / 'generate_display_clone.py'), '--output', str(output / 'display-local.S')])
    flags = ['xcrun', 'clang', '-arch', 'arm64e', '-O2', '-ffreestanding',
             '-fno-builtin', '-fno-math-errno', '-fno-stack-protector', '-fno-stack-check',
             '-funwind-tables', '-fasynchronous-unwind-tables', '-fexceptions',
             '-Wall', '-Wno-unused-function', '-include', str(TOOLS / 'display_unwind_check_at.h')]
    run([*flags, '-S', '-include', str(ROOT / 'hook/src/display_unwind_check.h'),
         str(ROOT / 'hook/src/anim4.c'), '-o', str(output / 'probe-eh.s')])
    run(['xcrun', 'clang++', '-arch', 'arm64e', '-O2', '-ffreestanding', '-fno-builtin',
         '-fno-stack-protector', '-fno-stack-check', '-fexceptions', '-funwind-tables',
         '-fasynchronous-unwind-tables', '-S', str(ROOT / 'hook/src/presentation_normal.cpp'),
         '-o', str(output / 'normal-cxx.s')])
    cxx = (output / 'normal-cxx.s').read_text()
    cxx = re.sub(r'\bL[A-Za-z0-9_]+', lambda m: 'Lncxx_' + m[0][1:], cxx)
    cxx = cxx.replace('155, ___gxx_personality_v0', '155, _rgba_normal_personality')
    assembly = (output / 'probe-eh.s').read_text().replace(
        '155, ___gcc_personality_v0', '155, _rgba_normal_personality') + '\n' + cxx
    parts = re.split(r'(\t\.cfi_startproc\n.*?\t\.cfi_endproc)', assembly, flags=re.S)
    for index, part in enumerate(parts):
        if '.cfi_startproc' not in part:
            continue
        if re.search(r'^\s*pacibsp\s*$', part, re.M):
            part = part.replace('\t.cfi_startproc\n', '\t.cfi_startproc\n\t.cfi_b_key_frame\n', 1)
        prefix = ''.join(parts[:index])[-200:]
        if re.search(r'_(?:anim_rgba_display_entry|anim_display_probe_entry):[^\n]*\n$', prefix):
            part = part.replace('\t.cfi_startproc\n', '\t.cfi_startproc\n\tbti c\n', 1)
        parts[index] = part
    combined = '\n'.join([''.join(parts), (output / 'display-local.S').read_text(),
                          (ROOT / 'hook/src/presentation_normal_entry.S').read_text()])
    if '.cfi_negate_ra_state' in combined:
        raise RuntimeError('Unsupported unwind return-address state')
    (output / 'probe-eh-combined.s').write_text(combined)
    run(['xcrun', 'clang', '-arch', 'arm64e', '-femit-dwarf-unwind=always', '-c',
         str(output / 'probe-eh-combined.s'), '-o', str(output / 'probe-eh-combined.o')])
    image = output / 'probe-eh.dylib'
    run(['xcrun', 'clang', '-arch', 'arm64e', '-dynamiclib', '-nostdlib', '-lSystem',
         '-Wl,-no_adhoc_codesign', '-Wl,-no_compact_unwind', '-Wl,-install_name,hyprwm-native-local',
         str(output / 'probe-eh-combined.o'), '-o', str(image)])
    run([python, str(TOOLS / 'normalize_runtime.py'), str(image)])
    run([python, str(TOOLS / 'extract_native.py'), str(output)])
    run([python, str(TOOLS / 'qualify_raw.py'), str(output)])
    run(['xcrun', 'clang', '-arch', 'arm64', '-O2', str(TOOLS / 'native_channel.c'),
         '-o', str(output / 'native-channel')])
    if inputs() != before:
        raise RuntimeError('Native source changed during build; image is not publishable')
    (output / 'source-manifest.json').write_text(json.dumps(before, indent=2) + '\n')
    print('Native image built and structurally qualified in ' + str(output), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, help='New private directory outside the source checkout')
    args = parser.parse_args()
    os.umask(0o077)
    if args.output_dir:
        requested = args.output_dir.expanduser().absolute()
        if requested.is_symlink():
            parser.error('Output symlinks are refused')
        output = requested.parent.resolve() / requested.name
        if output.is_relative_to(ROOT):
            parser.error('OS-derived output must stay outside the source checkout')
        parent = output.parent.stat()
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid() or parent.st_mode & 0o022:
            parser.error('Output parent must be owned and private')
        output.mkdir(mode=0o700)
    else:
        output = Path(tempfile.mkdtemp(prefix='hyprwm-native-'))
    build(output)


if __name__ == '__main__':
    main()
