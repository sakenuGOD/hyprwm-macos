"""Stopped-process half of prepare_native.py; publishes no timer or detour."""
from pathlib import Path
import ctypes
import hashlib
import json
import os
import stat
import struct
import sys
import tempfile
import time
import lldb

if sys.flags.optimize:
    raise RuntimeError('Native preparation requires Python optimization disabled')
run = Path(CONFIG['run'])
sys.path.insert(0, str(run))
from prepare_native import identity, bounded_read
import native_state as schema


def require(value, reason):
    if not value:
        raise RuntimeError(reason)


require(os.geteuid() == 0 and CONFIG['mode'] == 'prepare', 'Explicit root preparation required')
info = run.lstat()
require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and info.st_mode & 0o777 == 0o700,
        'Preparation directory is not root-only')
for name, digest in CONFIG['frozen'].items():
    require('/' not in name and hashlib.sha256(bounded_read(run / name, 0)).hexdigest() == digest,
            'Frozen loader input changed')
target = lldb.debugger.GetSelectedTarget()
process = target.GetProcess()
expected = CONFIG['expected']
current = identity(expected['pid'])
require(current and all(current[k] == expected[k] for k in ['pid', 'uid', 'seconds', 'micros', 'path']),
        'WindowServer generation changed')
require(process.GetProcessID() == expected['pid'] and process.GetState() == lldb.eStateStopped,
        'Exact stopped WindowServer required')
packet = lldb.SBCommandReturnObject()
lldb.debugger.GetCommandInterpreter().HandleCommand('process plugin packet send QSetDetachOnError:1', packet)
require(packet.Succeeded() and 'response: OK' in packet.GetOutput(), 'Detach-on-error not acknowledged')
main = [thread for thread in process if thread.GetName() == 'ws_main_thread']
require(len(main) == 1, 'Native serialized main thread is unavailable')
process.SetSelectedThread(main[0])
started = time.monotonic()


def deadline():
    require(time.monotonic() - started < 12 and time.monotonic() < CONFIG['parent_deadline'] - 3,
            'Bounded preparation deadline')


def read(address, size):
    deadline()
    error = lldb.SBError()
    result = process.ReadMemory(address, size, error)
    require(error.Success() and len(result) == size, 'Bounded native read failed')
    return result


def write(address, data):
    deadline()
    error = lldb.SBError()
    count = process.WriteMemory(address, data, error)
    require(error.Success() and count == len(data), 'Owned allocation write failed')


def q(address):
    return struct.unpack('<Q', read(address, 8))[0]


options = lldb.SBExpressionOptions()
options.SetIgnoreBreakpoints(True)
options.SetStopOthers(True)
options.SetTryAllThreads(False)
options.SetUnwindOnError(True)
options.SetTimeoutInMicroSeconds(2000000)
options.SetLanguage(lldb.eLanguageTypeC)


def ev(expression):
    deadline()
    value = target.EvaluateExpression(expression, options)
    require(value.IsValid() and value.GetError().Success() and value.GetValue() is not None,
            'Native expression refused: ' + str(value.GetError()))
    return value.GetValueAsUnsigned()


def slide(name, uuid):
    modules = [m for m in target.modules if m.GetFileSpec().GetFilename() == name]
    require(len(modules) == 1 and modules[0].GetUUIDString().upper() == uuid,
            'Unqualified framework image: ' + name)
    header = modules[0].GetObjectFileHeaderAddress()
    return header.GetLoadAddress(target) - header.GetFileAddress()


def symbol(name, module=None):
    rows = [(key, row['symbols'][name]) for key, row in native_profile['modules'].items()
            if (module is None or key == module) and name in row['symbols']]
    values = {row['address'] + module_slides[key] for key, row in rows}
    require(len(values) == 1,
            'Missing or ambiguous native function: ' + name)
    value = values.pop()
    require(all(row['prefix'] and read(value, 16).hex() == row['prefix'] for _, row in rows),
            'Native function code differs: ' + name)
    region = lldb.SBMemoryRegionInfo()
    require(process.GetMemoryRegionInfo(value, region).Success() and region.IsExecutable()
            and not region.IsWritable(), 'Native function is not RX: ' + name)
    return value


def data_symbol(name):
    row = native_profile['modules']['SkyLight']['symbols'].get(name)
    require(row and row['prefix'] is None, 'Native data symbol missing')
    value = row['address'] + module_slides['SkyLight']
    region = lldb.SBMemoryRegionInfo()
    require(process.GetMemoryRegionInfo(value, region).Success() and region.IsReadable(),
            'Native data mapping is unreadable')
    return value


sl = slide('SkyLight', 'CD5F2362-8462-38D4-8C57-0BCD4E04F962')
qc = slide('QuartzCore', 'DF88B985-E9A5-310B-990F-1ECBB86CE4CC')
slide('libunwind.dylib', '201827AE-90B0-38B1-9729-50455B607293')
native_profile = json.loads((run / 'native-symbols.json').read_text())
require(native_profile['build'] == '25G241', 'Native symbol profile build differs')
module_slides = {}
for name, row in native_profile['modules'].items():
    module_slides[name] = slide(name, row['uuid'])
    modules = [m for m in target.modules if m.GetFileSpec().GetFilename() == name]
    require(modules[0].GetObjectFileHeaderAddress().GetFileAddress() == row['header'],
            'Native preferred image header differs')

close_profile={}
for name in ['callback_pc','notification_pc','order_pc','get_property']:
    row=native_profile['close'][name];value=row['address']+sl
    require(row['prefix'] and read(value,16).hex()==row['prefix'],'Accepted-close native seam differs: '+name)
    region=lldb.SBMemoryRegionInfo()
    require(process.GetMemoryRegionInfo(value,region).Success() and region.IsExecutable() and not region.IsWritable(),
            'Accepted-close native seam is not RX: '+name)
    close_profile[name]=value


def system(name, signature):
    return '((%s)__builtin_ptrauth_sign_unauthenticated((void*)0x%x,0,0))' % (
        signature, symbol(name, 'libsystem_kernel.dylib'))
blob = (run / 'probe-eh.bin').read_bytes()
meta = json.loads((run / 'probe-eh-meta.json').read_text())
syms = meta['symbols']
require(0 < len(blob) <= 1048576 and len(blob) % 16384 == 0 and len(blob) == meta['size']
        and hashlib.sha256(blob).hexdigest() == meta['sha256'], 'Raw image changed')
require((run / 'probe-eh.dylib').read_bytes()[:len(blob)] == blob, 'Raw image differs from linked TEXT')
fdes = []
eh, eh_size = meta['sections']['__eh_frame']
require(0 <= eh < eh + eh_size <= len(blob), 'Invalid unwind section')
for row in meta['eh_records']:
    if row['cie'] is None:
        continue
    offset = row['offset']
    require(eh <= row['cie'] < offset < offset + row['size'] <= eh + eh_size,
            'Invalid FDE extent')
    require(blob[offset:offset + row['size']].hex() == row['bytes'], 'FDE bytes changed')
    start = offset + 8 + struct.unpack_from('<q', blob, offset + 8)[0]
    size = struct.unpack_from('<Q', blob, offset + 16)[0]
    require(4 <= size and 0 <= start < start + size <= len(blob), 'Invalid FDE code extent')
    fdes.append(dict(start=start, size=size, fde_offset=offset, probe_pc=start + 4 if size > 4 else start))
# Complete stable-prewarm image (one additional cache guard, preserved legacy
# ABI), qualified by the unchanged raw/unwind checker. Keep its exact FDE set.
require(len(fdes) == 414 and len({r['fde_offset'] for r in fdes}) == len(fdes), 'Complete FDE set required')


def image_function(name):
    offset = syms[name]
    require(any(row['start'] == offset for row in fdes), 'Image function lacks exact FDE: ' + name)
    return code + offset


record = dict(schema=1, expected=expected, owner_uid=CONFIG['owner_uid'], phase='allocating',
              image_sha256=meta['sha256'], allocations=[], maps_retained=True,
              registrations_retained=True, published=False, files=CONFIG['files'])


def save():
    fd, temporary = tempfile.mkstemp(prefix='.prepared-', dir=run)
    with os.fdopen(fd, 'w') as stream:
        json.dump(record, stream, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, run / 'prepared.json')


def allocate(size, name):
    address = ev('(unsigned long)' + system('mmap', 'void*(*)(void*,unsigned long,int,int,int,long long)') +
                 '(0,%d,3,0x1002,-1,0)' % size)
    require(0x100000000 <= address < 0x800000000000 and address % 16384 == 0, 'Allocation failed')
    record[name] = address
    record['allocations'].append(dict(name=name, address=address, size=size))
    save()
    return address


code = allocate(len(blob), 'code')
scratch = allocate(65536, 'scratch')
engine = allocate(16384, 'context')


def map_file(name):
    item = CONFIG['files'][name]
    path = Path(item['path'])
    before, parent = path.lstat(), path.parent.lstat()
    require(stat.S_ISREG(before.st_mode) and before.st_uid == 88 and before.st_nlink == 1
            and before.st_mode & 0o777 == 0o600 and before.st_size == item['size']
            and [before.st_dev, before.st_ino] == item['inode']
            and stat.S_ISDIR(parent.st_mode) and parent.st_uid == 88 and parent.st_mode & 0o777 == 0o700,
            'Private shared allocation changed')
    fd = ev(system('open', 'int(*)(const char*,int,int)') + '(' + json.dumps(str(path)) + ',0x01000102,0)')
    require(fd < 0x7fffffff, 'Native shared file open refused')
    try:
        require(ev(system('fstat', 'int(*)(int,void*)') + '(%d,(void*)0x%x)' % (fd, scratch + 32768)) == 0,
                'Native shared descriptor stat failed')
        native_stat = read(scratch + 32768, 144)
        require(struct.unpack_from('<I', native_stat, 0)[0] == before.st_dev
                and struct.unpack_from('<Q', native_stat, 8)[0] == before.st_ino
                and struct.unpack_from('<I', native_stat, 16)[0] == 88
                and struct.unpack_from('<H', native_stat, 4)[0] == before.st_mode
                and struct.unpack_from('<H', native_stat, 6)[0] == 1
                and struct.unpack_from('<q', native_stat, 96)[0] == item['size'],
                'Native shared descriptor identity differs')
        address = ev('(unsigned long)' + system('mmap', 'void*(*)(void*,unsigned long,int,int,int,long long)') +
                     '(0,%d,3,1,%d,0)' % (item['size'], fd))
        require(0x100000000 <= address < 0x800000000000 and address % 16384 == 0, 'Shared mapping failed')
    finally:
        require(ev(system('close', 'int(*)(int)') + '(%d)' % fd) == 0, 'Native descriptor close failed')
    require(read(address, item['size']) == bounded_read(path, 88), 'Shared allocation bytes differ')
    record[name] = address
    save()
    return address


address = map_file('control')
channel = map_file('channel')
require(read(engine, 16384) == bytes(16384) and read(address, 65536) == bytes(65536),
        'Fresh native allocations are not empty')
require(struct.unpack('<QII', read(channel, 16)) == (0x3531574d52505948, 6, 183528),
        'Channel ABI differs')

entries = {'normal': 0x186e96b40, 'begin': 0x186e26e34, 'scene': 0x186e0f158,
           'content': 0x186f2d3f8, 'frame': 0x186f2d084, 'ingestion': 0x186e23c1c}
native_body = (run / 'os-display-body.bin').read_bytes()
require(len(native_body) == 156 and hashlib.sha256(native_body).hexdigest() ==
        '656b8e9a0966559c8e23db5cc2f0b1ad40ba21396d33bc396c29a868e1fda58c', 'Local OS body changed')
functions = dict(init=0x186d917cc + sl, update=0x186e0f1f4 + sl, destroy=0x186d91848 + sl,
                 cache=symbol('sys_icache_invalidate', 'libsystem_platform.dylib'),
                 register=symbol('__register_frame', 'libunwind.dylib'),
                 check_at=image_function('_display_unwind_check_at'))
for name, actual in [('rgba_size', '_anim_rgba_state_size'), ('view_size', '_anim_rgba_present_size'),
                     ('context_size', '_anim_ctx_size'),('accepted_close_size','_anim_rgba_accepted_close_size'),
                     ('accepted_close_profile_offset','_anim_rgba_accepted_close_profile_offset')]:
    functions[name] = image_function(actual)
for key, name in [('gxx', '__gxx_personality_v0'), ('begin_catch', '__cxa_begin_catch'),
                  ('end_catch', '__cxa_end_catch'), ('rethrow', '__cxa_rethrow'), ('terminate', '_ZSt9terminatev')]:
    functions[key] = symbol(name, 'libc++abi.dylib')
functions['resume'] = symbol('_Unwind_Resume', 'libunwind.dylib')
functions['abort'] = symbol('abort', 'libsystem_c.dylib')
for name in ['unw_getcontext', 'unw_init_local', 'unw_get_reg', 'unw_set_reg', 'unw_get_proc_info']:
    functions[name] = symbol(name, 'libunwind.dylib')
functions['normal_personality'] = image_function('_rgba_normal_personality')
callbacks = {'normal': '_anim_rgba_normal_prepare', 'begin': '_anim_rgba_begin_prepare',
             'scene': '_anim_rgba_scene_prepare', 'content': '_anim_rgba_draw_shape_prepare',
             'frame': '_anim_rgba_draw_shape_prepare', 'ingestion': '_anim_rgba_draw_ingest_prepare'}
prefixes = {}
for kind, native in entries.items():
    prefix = (native_body if kind == 'scene' else
              blob[syms['_rgba_' + kind + '_original']:syms['_rgba_' + kind + '_original_prefix_end']])
    require(len(prefix) == (156 if kind == 'scene' else 48 if kind in ('normal', 'begin') else 16),
            'Native prefix extent differs')
    region = lldb.SBMemoryRegionInfo()
    require(process.GetMemoryRegionInfo(native + sl, region).Success() and region.IsExecutable()
            and not region.IsWritable(), 'Native boundary is not RX')
    prefixes[kind] = prefix
    functions[kind + '_entry'] = image_function('_rgba_' + kind + '_entry')
    functions[kind + '_callback'] = image_function(callbacks[kind])
    functions[kind + '_original'] = code + syms['_display_native_clone' if kind == 'scene' else '_rgba_' + kind + '_original']
    if kind != 'scene':
        functions[kind + '_back'] = native + sl + len(prefix)

write(scratch, struct.pack('<%dQ' % len(functions), *functions.values()))
require(ev('({unsigned long*p=(unsigned long*)0x%x;for(unsigned i=0;i<%d;i++)'
           'p[i]=(unsigned long)__builtin_ptrauth_sign_unauthenticated((void*)p[i],0,0);'
           '(unsigned long)1;})' % (scratch, len(functions))) == 1, 'Function signing failed')
signed = {name: q(scratch + 8 * i) for i, name in enumerate(functions)}
require(all(signed[name] & 0x00007fffffffffff == raw for name, raw in functions.items()),
        'Signed image function readback differs')
published = bytearray(blob)


def slots(offset, values):
    size = 8 * len(values)
    require(0 <= offset < offset + size <= len(published) and published[offset:offset + size] == bytes(size),
            'Image runtime slots are not empty')
    struct.pack_into('<%dQ' % len(values), published, offset, *values)


slots(syms['_display_native_clone_slots'], [0x1e61ce000 + sl, signed['init'], signed['update'],
                                           signed['destroy'], 0x1ee5898b8 + sl])
for kind, partition in [('normal', 12288), ('begin', 57344), ('scene', 10240),
                        ('content', 11264), ('frame', 11264), ('ingestion', 11264)]:
    values = [address + partition, signed[kind + '_original'], signed[kind + '_callback']]
    if kind != 'scene':
        values.append(signed[kind + '_back'])
    slots(syms['_rgba_' + kind + '_slots'], values)
slots(syms['_rgba_normal_runtime_slots'], [signed[name] for name in
      ['gxx', 'begin_catch', 'end_catch', 'rethrow', 'terminate', 'resume', 'abort']])
personality_slot = meta['sections']['__normal_got'][0]
personality = ev('(unsigned long)__builtin_ptrauth_sign_unauthenticated((void*)0x%x,0,0x%x)' %
                 (functions['normal_personality'], code + personality_slot))
slots(personality_slot, [personality])
write(code, published)
require(read(code, len(published)) == published, 'Copied image differs')
require(ev(system('mprotect', 'int(*)(void*,unsigned long,int)') + '((void*)0x%x,%d,5)' % (code, len(blob))) == 0,
        'Image RX transition failed')
require(ev('({((void(*)(void*,unsigned long))0x%x)((void*)0x%x,%d);(unsigned long)1;})' %
           (signed['cache'], code, len(blob))) == 1, 'Image cache flush failed')
region = lldb.SBMemoryRegionInfo()
require(process.GetMemoryRegionInfo(code, region).Success() and region.IsExecutable()
        and not region.IsWritable(), 'Prepared image is not RX')
fde_addresses = [code + row['fde_offset'] for row in fdes]
write(scratch + 512, struct.pack('<%dQ' % len(fdes), *fde_addresses))
record.update(phase='registering', fde_addresses=fde_addresses)
save()
require(ev('({unsigned long*p=(unsigned long*)0x%x;for(unsigned i=0;i<%d;i++)'
           '((void(*)(const void*))0x%x)((const void*)p[i]);(unsigned long)1;})' %
           (scratch + 512, len(fdes), signed['register'])) == 1, 'FDE registration failed')
record.update(phase='registered-before-sdk', registered_fdes=len(fdes))
save()
checks = []
sdk = [signed[name] for name in ['unw_getcontext', 'unw_init_local', 'unw_get_reg', 'unw_set_reg', 'unw_get_proc_info']]
for index in range(0, len(fdes), 2):
    a, b = fdes[index], fdes[min(index + 1, len(fdes) - 1)]
    checks.extend(sdk + [code + a['start'], code + b['start'], code + a['fde_offset'], code + b['fde_offset'],
                         code + a['probe_pc'], code + b['probe_pc']])
require(4096 + len(checks) * 8 <= 32768, 'Unwind checker scratch capacity exceeded')
write(scratch + 4096, struct.pack('<%dQ' % len(checks), *checks))
require(ev('({unsigned long*p=(unsigned long*)0x%x;unsigned failed=0;for(unsigned i=0;i<%d;i++)'
           '{unsigned r=((unsigned(*)(const void*))0x%x)((const void*)(p+11*i));'
           'if(r){failed=1+16*i+r;break;}}(unsigned long)failed;})' %
           (scratch + 4096, (len(fdes) + 1) // 2, signed['check_at'])) == 0,
        'Exact SDK lookup did not cover every FDE')
record.update(phase='sdk-qualified', sdk_lookup_fdes=len(fdes))
save()
for name, size in [('rgba_size', 1888), ('view_size', 496), ('context_size', 0x658),
                   ('accepted_close_size',ctypes.sizeof(schema.AcceptedCloseControl)),
                   ('accepted_close_profile_offset',schema.AcceptedCloseControl.profile.offset)]:
    require(ev('((unsigned(*)(void))0x%x)()' % signed[name]) == size, 'Native layout getter differs')
record.update(phase='layouts-qualified')
save()

# This small immutable CF key belongs to the new disabled context. No callback
# constructs it or performs an IPC lookup. Retain its exact pointer in recovery.
key_text=b'org.hyprwm.lifecycle.accepted-close.v1\0'
write(scratch,key_text)
create=symbol('CFStringCreateWithCString','CoreFoundation')
kind=symbol('CFStringGetTypeID','CoreFoundation')
close_profile['key']=ev('((void*(*)(void*,const char*,unsigned))__builtin_ptrauth_sign_unauthenticated((void*)0x%x,0,0))(0,(const char*)0x%x,0x600)'%(create,scratch))
require(close_profile['key']>0x100000000,'Accepted-close key allocation refused')
record.update(phase='close-key-created',close_key=close_profile['key']);save()
close_profile['string_type']=ev('((unsigned long(*)(void))__builtin_ptrauth_sign_unauthenticated((void*)0x%x,0,0))()'%kind)
require(close_profile['string_type']>0,'Accepted-close string type unavailable')

scene_rows = [row for row in fdes if row['start'] == syms['_anim_rgba_scene_prepare']]
require(len(scene_rows) == 1, 'Scene function extent is ambiguous')
scene_extent = [code + scene_rows[0]['start'], code + scene_rows[0]['start'] + scene_rows[0]['size']]
control_data, control_functions = schema.control_image(engine, address, code, syms, sl, qc, symbol, scene_extent,close_profile)
record.update(phase='control-encoded')
save()
display = CONFIG['display']
session_ref = data_symbol('__sessionControlRef')
record.update(phase='context-resolving')
save()
context_data, context_functions = schema.context_image(
    code=code, symbols=syms, channel=channel, control=address, queue=data_symbol('gMainThreadQueue'),
    session=q(q(session_ref) + 0x20), display=display, mach_us=CONFIG['mach_us'],
    resolve=symbol)
record.update(phase='context-encoded')
save()


def install_payload(destination, data, function_cells):
    write(destination, data)
    locations = [destination + offset for offset in function_cells]
    write(scratch, struct.pack('<%dQ' % len(locations), *locations))
    require(ev('({unsigned long**p=(unsigned long**)0x%x;for(unsigned i=0;i<%d;i++)'
               '*p[i]=(unsigned long)__builtin_ptrauth_sign_unauthenticated((void*)*p[i],0,0);'
               '(unsigned long)1;})' % (scratch, len(locations))) == 1, 'Payload signing failed')
    actual = read(destination, len(data))
    restored = bytearray(actual)
    for offset in function_cells:
        value = struct.unpack_from('<Q', actual, offset)[0]
        raw = struct.unpack_from('<Q', data, offset)[0]
        require(value & 0x00007fffffffffff == raw, 'Payload signed function differs')
        struct.pack_into('<Q', restored, offset, raw)
    require(restored == data, 'Payload write changed a data cell')
    return hashlib.sha256(actual).hexdigest()


control_hash = install_payload(address, control_data, control_functions)
context_hash = install_payload(engine, context_data, context_functions)
require(read(engine + 0x74, 4) == struct.pack('<I', 1) and q(engine + 0x6e0) == address,
        'Fresh engine must remain disabled')
require(q(engine + 0x6e8) & 0x00007fffffffffff == code + syms['_anim_tick']
        and q(engine + 0x380) & 0x00007fffffffffff == code + syms['_anim_will_release'],
        'Fresh graph depends on another image')
record.update(phase='prepared-disabled', registered_fdes=len(fdes), sdk_lookup_fdes=len(fdes),
              context_sha256=context_hash, control_sha256=control_hash,
              runtime_image_sha256=hashlib.sha256(read(code, len(blob))).hexdigest(),
              code_size=len(blob), display=display, framework_slides=dict(skylight=sl, quartzcore=qc),
              boundaries={kind: dict(address=entries[kind] + sl, original=prefixes[kind].hex(),
                                    target=signed[kind + '_entry']) for kind in entries},
              scheduler=q(engine + 8), dispatcher=q(engine + 0x10), queue=q(engine + 0x18),
              session=q(engine + 0x20), functions=signed)
save()
os.write(1, ('NATIVE_PREPARED ' + json.dumps(dict(fdes=len(fdes), context='fresh', disabled=True,
                                               published=False, old_image_dependencies=False)) + '\n').encode())
