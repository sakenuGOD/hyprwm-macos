#!/usr/bin/env python3
"""Prepare a fresh, disabled native engine without replacing the running one."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import stat
import signal
import subprocess
import sys
import tempfile
import time

if sys.flags.optimize:
    raise RuntimeError('Native preparation requires Python optimization disabled')

TOOLS = Path(__file__).resolve().parent
WS = Path('/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer')


def identity(pid):
    class Info(ctypes.Structure):
        _fields_ = [('header', ctypes.c_uint32 * 12), ('comm', ctypes.c_char * 16),
                    ('name', ctypes.c_char * 32), ('tail', ctypes.c_uint32 * 6),
                    ('sec', ctypes.c_uint64), ('usec', ctypes.c_uint64)]
    lib = ctypes.CDLL('/usr/lib/libproc.dylib')
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    def sample():
        row, path = Info(), ctypes.create_string_buffer(4096)
        if (lib.proc_pidinfo(pid, 3, 0, ctypes.byref(row), ctypes.sizeof(row)) != ctypes.sizeof(row)
                or lib.proc_pidpath(pid, path, len(path)) <= 0):
            return None
        return dict(pid=int(row.header[3]), uid=int(row.header[5]), seconds=int(row.sec),
                    micros=int(row.usec), path=os.path.realpath(os.fsdecode(path.value)),
                    status=int(row.header[1]), flags=int(row.header[0]), stop_signal=int(row.header[2]))
    first, second = sample(), sample()
    keys = ['pid', 'uid', 'seconds', 'micros', 'path']
    return first if first and second and all(first[k] == second[k] for k in keys) else None


def running_after_detach(expected):
    """Resolve only an untraced SIGSTOP left after our successful detach."""
    keys = ['pid', 'uid', 'seconds', 'micros', 'path']
    current = identity(expected['pid'])
    if not current or any(current[k] != expected[k] for k in keys):
        return None
    if current['status'] == 4:
        if (expected['uid'] != 88 or expected['path'] != str(WS.resolve())
                or current['stop_signal'] != signal.SIGSTOP or current['flags'] & 0x800):
            return None
        os.kill(expected['pid'], signal.SIGCONT)
        end = time.monotonic() + 1
        while current and current['status'] == 4 and time.monotonic() < end:
            time.sleep(.01)
            current = identity(expected['pid'])
    return current if current and current['status'] in (2, 3) and all(current[k] == expected[k] for k in keys) else None


def protected_tool(name):
    path = Path('/Library/Developer/CommandLineTools/usr/bin') / name
    resolved = path.resolve(strict=True)
    for part in [path, *path.parents, resolved, *resolved.parents]:
        item = part.stat()
        if item.st_uid != 0 or item.st_mode & 0o022:
            raise RuntimeError('Unprotected native tool: ' + str(part))
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise RuntimeError('Native developer tool is unavailable')
    return str(path)


def bounded_read(path, owner, limit=2**21):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid not in (0, owner)
                or before.st_mode & 0o022 or before.st_nlink != 1 or not 0 < before.st_size <= limit):
            raise RuntimeError('Untrusted native input: ' + str(path))
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(fd, min(65536, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        after = os.fstat(fd)
        if ((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) !=
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
                or len(data) != before.st_size):
            raise RuntimeError('Native input changed while freezing')
        return bytes(data)
    finally:
        os.close(fd)


def prepare(image, owner):
    if os.geteuid() != 0 or not 0 < owner < 2**32:
        raise RuntimeError('Explicit root preparation and a positive desktop owner UID are required')
    if subprocess.check_output(['/usr/bin/sw_vers', '-buildVersion'], text=True).strip() != '25G241':
        raise RuntimeError('This macOS build is not qualified')
    ids = subprocess.check_output(['/usr/bin/pgrep', '-x', 'WindowServer'], text=True).split()
    actors = [identity(int(pid)) for pid in ids]
    actors = [row for row in actors if row and row['uid'] == 88 and row['path'] == str(WS.resolve())]
    if len(actors) != 1 or actors[0]['status'] == 4:
        raise RuntimeError('One running, canonical WindowServer generation is required')
    expected = actors[0]
    # CoreGraphics can synchronously contact WindowServer. Complete all host
    # display queries before attaching; doing this in the stopped body deadlocks.
    graphics = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    graphics.CGMainDisplayID.restype = ctypes.c_uint32
    graphics.CGDisplayIsActive.argtypes = [ctypes.c_uint32]
    graphics.CGDisplayIsOnline.argtypes = [ctypes.c_uint32]
    display = graphics.CGMainDisplayID()
    if not display or not graphics.CGDisplayIsActive(display) or not graphics.CGDisplayIsOnline(display):
        raise RuntimeError('A verified active main display is required before native preparation')
    timebase = (ctypes.c_uint32 * 2)()
    if (ctypes.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(ctypes.byref(timebase)) != 0
            or not timebase[1]):
        raise RuntimeError('Mach timebase unavailable')
    output = Path(tempfile.mkdtemp(prefix='hyprwm-native-prepared-', dir='/private/tmp'))
    os.chmod(output, 0o700)
    names = ['prepare_native.py', 'native_lldb.py', 'native_state.py', 'qualify_native.py',
             'extract_native.py', 'generate_display_clone.py', 'native_symbols.py']
    for name in names:
        (output / name).write_bytes(bounded_read(TOOLS / name, owner))
    (output / 'probe-eh.dylib').write_bytes(bounded_read(image / 'probe-eh.dylib', owner))
    # Re-derive raw bytes, symbols and every FDE from the frozen linked image.
    subprocess.run([protected_tool('python3'), str(output / 'extract_native.py'), str(output)], check=True)
    sys.path.insert(0, str(output))
    from generate_display_clone import local_body
    body, local = local_body()
    (output / 'os-display-body.bin').write_bytes(body)
    (output / 'os-input.json').write_text(json.dumps(local, indent=2) + '\n')
    from native_symbols import profile
    (output / 'native-symbols.json').write_text(json.dumps(profile(), indent=2) + '\n')
    source = bounded_read(TOOLS / 'native_channel.c', owner).decode().replace('"../src/chan.h"', '"chan.h"')
    (output / 'native_channel.c').write_text(source)
    (output / 'chan.h').write_bytes(bounded_read(TOOLS.parent / 'src/chan.h', owner))
    sdk = Path('/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk').resolve(strict=True)
    for part in [sdk, *sdk.parents]:
        info = part.stat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise RuntimeError('Unprotected native SDK: ' + str(part))
    subprocess.run([protected_tool('clang'), '-isysroot', str(sdk), '-arch', 'arm64', '-O2', str(output / 'native_channel.c'),
                    '-o', str(output / 'native-channel')], check=True)
    resources = Path(tempfile.mkdtemp(prefix='hyprwm-native-resources-', dir='/private/tmp'))
    os.chown(resources, 88, -1)
    os.chmod(resources, 0o700)
    files = {}
    for name, size in [('channel', 196608), ('control', 65536)]:
        path = resources / name
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.ftruncate(fd, size)
            os.fchown(fd, 88, -1)
            os.fchmod(fd, 0o600)
            if name == 'channel':
                result = subprocess.run([str(output / 'native-channel'), str(fd)], pass_fds=(fd,),
                                        check=True, capture_output=True, text=True)
                if json.loads(result.stdout) != {'abi': 6, 'size': 183528, 'extent': 196608}:
                    raise RuntimeError('Native channel ABI differs from supported contract')
            info = os.fstat(fd)
            files[name] = dict(path=str(path), inode=[info.st_dev, info.st_ino], size=size)
        finally:
            os.close(fd)
    names += ['probe-eh.dylib', 'probe-eh.bin', 'probe-eh-meta.json', 'os-display-body.bin',
              'os-input.json', 'native-symbols.json']
    frozen = {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in names}
    config = dict(mode='prepare', run=str(output), expected=expected, owner_uid=owner,
                  display=display, mach_us=timebase[0] / timebase[1] / 1000,
                  files=files, frozen=frozen, parent_deadline=time.monotonic() + 20)
    wrapper = output / 'entry.py'
    wrapper.write_text(
        'import lldb,os,traceback\nCONFIG=' + repr(config) + '\n'
        'ok=False\ntry:\n    exec(compile(open(' + repr(str(output / 'native_lldb.py')) +
        ').read(),"native_loader","exec"),globals())\n    ok=True\n'
        'except BaseException:\n    os.write(2,traceback.format_exc().encode())\n'
        'finally:\n    error=lldb.debugger.GetSelectedTarget().GetProcess().Detach()\n'
        '    os.write(1,("NATIVE_DETACH "+str(error.Success())+" PREPARED "+str(ok)+"\\n").encode())\n'
        '    if error.Success():os._exit(0 if ok else 1)\n')
    current = identity(expected['pid'])
    keys = ['pid', 'uid', 'seconds', 'micros', 'path']
    if not current or any(current[k] != expected[k] for k in keys):
        raise RuntimeError('WindowServer generation changed before attach')
    log_path = output / 'prepare.log'
    with log_path.open('w') as log:
        child = subprocess.Popen([
            '/usr/bin/arch', '-arm64', protected_tool('lldb'), '--no-lldbinit',
            '-O', 'plugin disable symbol-file',
            '-O', 'plugin disable instrumentation-runtime', '-O', 'plugin disable language-runtime.swift',
            '-O', 'settings set target.detach-on-error true', '-O', 'settings set target.preload-symbols false',
            '-O', 'settings set symbols.enable-external-lookup false',
            '-O', 'settings set target.load-script-from-symbol-file false', '-p', str(expected['pid']),
            '-o', 'script exec(compile(open(' + repr(str(wrapper)) + ').read(),"native_entry","exec"))'],
            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        try:
            code = child.wait(timeout=max(.1, config['parent_deadline'] - time.monotonic()))
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=3)
            raise RuntimeError('Owned native debugger timed out and disconnected; inspect ' + str(log_path))
    text = log_path.read_text()
    current = (running_after_detach(expected) if code == 0 and 'NATIVE_DETACH True PREPARED True' in text
               else identity(expected['pid']))
    if (code or 'NATIVE_DETACH True PREPARED True' not in text or not current or current['status'] == 4
            or any(current[k] != expected[k] for k in keys)):
        raise RuntimeError('Native preparation refused; inspect ' + str(log_path))
    print('Prepared disabled fresh engine: ' + str(output / 'prepared.json'))
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image-dir', required=True, type=Path)
    parser.add_argument('--owner-uid', required=True, type=int)
    args = parser.parse_args()
    os.umask(0o077)
    prepare(args.image_dir.expanduser().resolve(), args.owner_uid)


if __name__ == '__main__':
    main()
