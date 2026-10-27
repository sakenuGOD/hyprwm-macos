#!/usr/bin/env python3
"""Run the existing raw-image ABI/unwind check on one newly built image."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

if sys.flags.optimize:
    raise RuntimeError('Native qualification requires Python optimization disabled')
TOOLS = Path(__file__).resolve().parent


def check(output):
    meta = json.loads((output / 'probe-eh-meta.json').read_text())
    digest = hashlib.sha256((output / 'probe-eh.bin').read_bytes()).hexdigest()
    if digest != meta['sha256']:
        raise RuntimeError('Raw image differs from metadata')
    subprocess.run(['xcrun', 'clang', '-arch', 'arm64e', '-O1', '-fvisibility=hidden',
                    '-Wl,-dead_strip', '-Wl,-undefined,dynamic_lookup',
                    str(TOOLS / 'native_layout.c'), '-o', str(output / 'native-layout')], check=True)
    layout = subprocess.check_output([str(output / 'native-layout')], text=True)
    for name in ['_anim_rgba_normal_prepare', '_anim_rgba_begin_prepare', '_anim_rgba_begin_restore',
                 '_rgba_normal_runtime_slots', '_rgba_normal_personality', '_anim_rgba_scene_prepare',
                 '_anim_rgba_normal_present_dispatch', '_display_native_clone', '_display_native_clone_slots',
                 '_anim_rgba_draw_shape_prepare', '_anim_rgba_draw_ingest_prepare', '_anim_rgba_normal_before_abort',
                 '_rgba_normal_draw_commands', '_rgba_normal_close_gate']:
        layout += '#define SYMBOL' + name + ' ' + str(meta['symbols'][name]) + '\n'
    for name in ['__eh_frame', '__normal_got']:
        layout += '#define SECTION_' + name + ' ' + str(meta['sections'][name][0]) + '\n'
    layout += '#define EH_OFFSET ' + str(meta['sections']['__eh_frame'][0]) + '\n'
    layout += '#define EH_SIZE ' + str(meta['sections']['__eh_frame'][1]) + '\n'
    (output / 'normal-layout.h').write_text(layout)
    checker_source=(TOOLS / 'native_raw_check.cpp').read_bytes()
    checker=output / 'native_raw_check.cpp'
    checker.write_bytes(checker_source)
    subprocess.run(['xcrun', 'clang++', '-arch', 'arm64e', '-O1', '-std=c++17', '-UNDEBUG',
                    '-I', str(output), str(checker),
                    '-o', str(output / 'native-raw-check')], check=True)
    subprocess.run([str(output / 'native-raw-check'), str(output / 'probe-eh.bin')], check=True)
    if hashlib.sha256((output / 'probe-eh.bin').read_bytes()).hexdigest() != digest:
        raise RuntimeError('Raw image changed during qualification')
    (output / 'raw-qualification.json').write_text(json.dumps(
        dict(accepted=True, sha256=digest, checker_sha256=hashlib.sha256(
            checker_source).hexdigest()), indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    check(parser.parse_args().output.resolve())
