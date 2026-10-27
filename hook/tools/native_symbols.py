"""Resolve required native names from the installed, owned dyld cache.

Only metadata is returned. Executable bytes remain local runtime guards and are
never part of the source distribution. No process attachment is performed.
"""
from collections import OrderedDict
import hashlib
from pathlib import Path
import struct
import uuid
from generate_display_clone import LocalCache, BUILD
from native_state import CONTEXT_FUNCTIONS

MODULES = {'SkyLight', 'QuartzCore', 'CoreGraphics', 'CoreFoundation', 'libobjc.A.dylib',
           'libc++abi.dylib', 'libsystem_kernel.dylib', 'libsystem_pthread.dylib',
           'libsystem_platform.dylib', 'libsystem_c.dylib', 'libsystem_m.dylib',
           'libunwind.dylib', 'libsystem_malloc.dylib'}
DATA = {'gMainThreadQueue', '__sessionControlRef'}
WANTED = set(CONTEXT_FUNCTIONS.values()) | DATA | {
    'mmap', 'mprotect', 'open', 'fstat', 'close', 'sys_icache_invalidate', '__register_frame',
    '__gxx_personality_v0', '__cxa_begin_catch', '__cxa_end_catch', '__cxa_rethrow',
    '_ZSt9terminatev', '_Unwind_Resume', 'abort', 'unw_getcontext', 'unw_init_local',
    'unw_get_reg', 'unw_set_reg', 'unw_get_proc_info', 'pthread_main_np', 'pthread_self',
    'pthread_get_stackaddr_np', 'pthread_get_stacksize_np', 'objc_retain', 'objc_release',
    'CARenderUpdateSetGreedy', 'CARenderUpdateSetIgnoreFlattenCache',
    'CARenderUpdateSetFlattenBackdrops', 'CARenderUpdateSetCanCreateFlattenSurface',
    'CFStringCreateWithCString', 'CFStringGetTypeID', 'CFStringGetCString'}


def need(value, message):
    if not value:
        raise RuntimeError(message)


class MetadataCache(LocalCache):
    def __init__(self):
        super().__init__()
        self.pages = OrderedDict()

    def metadata(self, address, size):
        matches = [row for row in self.mappings if row[0] <= address and address + size <= row[0] + row[1]]
        need(len(matches) == 1, 'Metadata range has no unique cache mapping')
        base, extent, offset, initial, maximum, descriptor, path, info = matches[0]
        need(initial & 1 and maximum & 1, 'Cache metadata is not readable')
        return self.read(descriptor, offset + address - base, size, info.st_size)

    def string(self, address, size):
        matches = [row for row in self.mappings if row[0] <= address and address + size <= row[0] + row[1]]
        need(len(matches) == 1, 'String range has no unique cache mapping')
        base, _, offset, initial, maximum, descriptor, _, info = matches[0]
        need(initial & 1 and maximum & 1, 'Symbol strings are unreadable')
        address = offset + address - base
        result = bytearray()
        while size:
            page = address & ~65535
            key = descriptor, page
            if key not in self.pages:
                self.pages[key] = self.read(descriptor, page, min(65536, info.st_size - page), info.st_size)
                if len(self.pages) > 128:
                    self.pages.popitem(last=False)
            self.pages.move_to_end(key)
            count = min(size, page + 65536 - address)
            result.extend(self.pages[key][address - page:address - page + count])
            address += count
            size -= count
        return bytes(result)


def images(cache):
    mains = [(fd, info) for fd, path, info in cache.files if path.name == 'dyld_shared_cache_arm64e']
    need(len(mains) == 1, 'Main native cache is ambiguous')
    descriptor, info = mains[0]
    offset, count = struct.unpack('<QQ', cache.read(descriptor, 136, 16, info.st_size))
    need(0 < count <= 16384, 'Cache image count is invalid')
    table = cache.read(descriptor, offset, count * 32, info.st_size)
    result = {}
    for index in range(count):
        identifier, base, size, path_offset = struct.unpack_from('<16sQII', table, index * 32)
        raw = cache.read(descriptor, path_offset, min(4096, info.st_size - path_offset), info.st_size)
        end = raw.find(b'\0')
        need(end >= 0, 'Cache image path is unterminated')
        name = Path(raw[:end].decode()).name
        if name in MODULES:
            row = dict(header=base, uuid=str(uuid.UUID(bytes=identifier)).upper())
            need(name not in result or result[name] == row, 'Ambiguous cache image: ' + name)
            result[name] = row
    need(result.keys() == MODULES, 'Required native cache images are missing')
    return result


def image_symbols(cache, base, expected_uuid):
    magic, cpu, subtype, kind, count, size, _, _ = struct.unpack('<8I', cache.metadata(base, 32))
    need(magic == 0xfeedfacf and cpu == 0x100000c and subtype & 0xffffff == 2 and kind == 6
         and 0 < count <= 2048 and 0 < size <= 1048576, 'Unsupported native image header')
    commands = cache.metadata(base + 32, size)
    position, sections, identifiers = 0, [], []
    linkedit = symtab = None
    for _ in range(count):
        need(position + 8 <= size, 'Truncated native load command')
        command, length = struct.unpack_from('<II', commands, position)
        need(length >= 8 and length % 8 == 0 and position + length <= size, 'Invalid load command extent')
        if command == 0x1b:
            need(length == 24, 'Invalid native UUID command')
            identifiers.append(str(uuid.UUID(bytes=commands[position + 8:position + 24])).upper())
        elif command == 2:
            need(length == 24 and symtab is None, 'Invalid native symbol command')
            symtab = struct.unpack_from('<4I', commands, position + 8)
        elif command == 0x19:
            need(length >= 72, 'Truncated native segment')
            segment = commands[position + 8:position + 24].rstrip(b'\0')
            vm, extent, fileoff, filesize = struct.unpack_from('<4Q', commands, position + 24)
            protection, nsections = struct.unpack_from('<II', commands, position + 60)
            need(72 + nsections * 80 <= length, 'Truncated native sections')
            if segment == b'__LINKEDIT':
                need(linkedit is None, 'Duplicate native LINKEDIT')
                linkedit = vm, extent, fileoff, filesize
            for index in range(nsections):
                section = position + 72 + index * 80
                address, extent = struct.unpack_from('<QQ', commands, section + 32)
                flags = struct.unpack_from('<I', commands, section + 64)[0]
                sections.append((address, extent, protection, flags))
        position += length
    need(position == size and identifiers == [expected_uuid] and linkedit and symtab,
         'Native image identity differs')
    vm, extent, fileoff, filesize = linkedit
    symoff, nsyms, stroff, strsize = symtab
    need(0 < nsyms <= 1000000 and 0 < strsize <= 2**30, 'Native symbol bounds exceeded')
    def linked(offset, length):
        need(fileoff <= offset and offset + length <= fileoff + filesize, 'Symbol table outside LINKEDIT')
        return vm + offset - fileoff
    entries = cache.metadata(linked(symoff, nsyms * 16), nsyms * 16)
    strings = linked(stroff, strsize)
    selected = {name.encode(): name for name in WANTED}
    maximum = max(map(len, selected)) + 2
    result = {}
    for offset in range(0, len(entries), 16):
        index, kind, section, _, value = struct.unpack_from('<IBBHQ', entries, offset)
        if kind & 0xe0 or kind & 0x0e != 0x0e or not index:
            continue
        need(index < strsize and 1 <= section <= len(sections), 'Invalid native nlist')
        raw = cache.string(strings + index, min(maximum, strsize - index))
        end = raw.find(b'\0')
        if end < 0:
            continue  # Longer names cannot equal any requested native symbol.
        raw = raw[:end]
        if raw.startswith(b'_'):
            raw = raw[1:]
        if raw not in selected:
            continue
        name = selected[raw]
        address, extent, protection, flags = sections[section - 1]
        need(address <= value < address + extent, 'Symbol outside its native section')
        if name in DATA:
            need(protection & 1, 'Native data is unreadable')
            prefix = None
        else:
            need(protection & 5 == 5 and not protection & 2 and flags & 0x80000400,
                 'Native function is not executable code')
            prefix = cache.read_vm(value, 16)[0].hex()
        row = dict(address=value, prefix=prefix)
        need(name not in result or result[name] == row, 'Ambiguous native symbol: ' + name)
        result[name] = row
    return result


def profile():
    cache = MetadataCache()
    try:
        modules = images(cache)
        for name, row in modules.items():
            row['symbols'] = image_symbols(cache, row['header'], row['uuid'])
        missing = WANTED - {name for row in modules.values() for name in row['symbols']}
        need(not missing, 'Required native names missing: ' + ', '.join(sorted(missing)))
        # Current qualified SkyLight synchronous ORDER callback seams and the
        # direct dictionary getter, not the public IPC-fallback API. Freeze local
        # bytes only in the private runtime profile, never in distributed source.
        close={name:dict(address=address,prefix=cache.read_vm(address,16)[0].hex()) for name,address in {
            'callback_pc':0x186e72c8c,'notification_pc':0x186e7260c,
            'order_pc':0x18705bbdc,'get_property':0x187071b5c}.items()}
        cache.verify_unchanged()
        return dict(build=BUILD, modules=modules, close=close)
    finally:
        cache.close()
