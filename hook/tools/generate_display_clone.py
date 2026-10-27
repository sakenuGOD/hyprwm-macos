#!/usr/bin/env python3
"""Generate the qualified display bridge from this Mac's OS into private output.

No native body bytes are distributed with this tool. Generation neither attaches
to WindowServer nor qualifies a new image for execution.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import uuid

BUILD = '25G241'
SKYLIGHT_UUID = 'CD5F2362-8462-38D4-8C57-0BCD4E04F962'
HEADER_ADDRESS = 0x186CF4000
BODY_ADDRESS = 0x186E0F158
BODY_SIZE = 156
BODY_SHA = '656b8e9a0966559c8e23db5cc2f0b1ad40ba21396d33bc396c29a868e1fda58c'
CACHE_ROOT = Path('/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld')

# Own relocations and unwind facts; instruction bytes come only from the OS.
RELOCATIONS = {0x20:'ldr x9,Lguard_page', 0x4c:'bl Linit', 0x5c:'bl Lupdate',
               0x68:'bl Ldestroy', 0x70:'ldr x9,Lguard_page', 0x98:'bl Lfail'}
CFI = {
    0x08:['.cfi_def_cfa_offset 64'],
    0x0c:['.cfi_offset w20,-32','.cfi_offset w19,-24'],
    0x10:['.cfi_offset w29,-16','.cfi_offset w30,-8'],
    0x14:['.cfi_def_cfa w29,16'],
    0x88:['.cfi_remember_state'],
    0x8c:['.cfi_def_cfa wsp,64','.cfi_restore w29','.cfi_restore w30'],
    0x90:['.cfi_restore w20','.cfi_restore w19'],
    0x94:['.cfi_def_cfa_offset 0'],
    0x98:['Lfailed:','.cfi_restore_state'],
}
SUFFIX = '''.cfi_endproc
.globl _display_native_clone_end
_display_native_clone_end:
.cfi_startproc
.cfi_b_key_frame
.cfi_def_cfa w29,16
.cfi_offset w29,-16
.cfi_offset w30,-8
.cfi_offset w20,-32
.cfi_offset w19,-24
Linit:
    ldr x16,Linit_slot
    braaz x16
Lupdate:
    ldr x16,Lupdate_slot
    braaz x16
Ldestroy:
    ldr x16,Ldestroy_slot
    braaz x16
Lfail:
    ldr x17,Lfail_slot
    ldr x16,[x17]
    braa x16,x17
.cfi_endproc
.p2align 3
.globl _display_native_clone_slots
_display_native_clone_slots:
Lguard_page: .quad 0
Linit_slot: .quad 0
Lupdate_slot: .quad 0
Ldestroy_slot: .quad 0
Lfail_slot: .quad 0
'''


class LocalCache:
    def __init__(self):
        self.files = []
        self.mappings = []
        paths = sorted(CACHE_ROOT.glob('dyld_shared_cache_arm64e*'))
        if not 1 <= len(paths) <= 128:
            raise RuntimeError('Supported local arm64e cache is unavailable')
        try:
            for path in paths:
                descriptor = os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
                info = os.fstat(descriptor)
                if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
                    os.close(descriptor)
                    raise RuntimeError('Untrusted OS cache file')
                self.files.append((descriptor,path,info))
                header = self.read(descriptor,0,min(32,info.st_size),info.st_size)
                if not header.startswith(b'dyld_v1 ') or b'arm64e' not in header[:16]:
                    continue
                if len(header) != 32:
                    raise RuntimeError('Truncated cache header')
                offset,count = struct.unpack_from('<II',header,16)
                if not 0 < count <= 128 or offset < 32:
                    raise RuntimeError('Invalid cache mapping table')
                table = self.read(descriptor,offset,count*32,info.st_size)
                for index in range(count):
                    address,size,file_offset,maximum,initial = struct.unpack_from('<QQQII',table,index*32)
                    if not size or address+size > 2**64 or file_offset+size > info.st_size:
                        raise RuntimeError('Invalid cache mapping bounds')
                    self.mappings.append((address,size,file_offset,initial,maximum,descriptor,path,info))
        except BaseException:
            self.close()
            raise

    @staticmethod
    def read(descriptor,offset,size,file_size):
        if offset < 0 or size < 0 or offset+size > file_size:
            raise RuntimeError('OS input range is outside its file')
        data = os.pread(descriptor,size,offset)
        if len(data) != size:
            raise RuntimeError('Short OS input read')
        return data

    def read_vm(self,address,size):
        matches = [row for row in self.mappings if row[0] <= address and address+size <= row[0]+row[1]]
        if len(matches) != 1:
            raise RuntimeError('OS virtual range has no unique cache mapping')
        base,_,offset,initial,maximum,descriptor,path,info = matches[0]
        if initial & 5 != 5 or maximum & 5 != 5 or initial & 2 or maximum & 2:
            raise RuntimeError('Display code is not in a readable executable mapping')
        return self.read(descriptor,offset+address-base,size,info.st_size),path,offset+address-base

    def verify_unchanged(self):
        for descriptor,_,before in self.files:
            after = os.fstat(descriptor)
            if (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns) != (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns):
                raise RuntimeError('OS cache changed during generation')

    def close(self):
        for descriptor,_,_ in self.files:os.close(descriptor)
        self.files.clear()


def local_body():
    build = subprocess.check_output(['/usr/bin/sw_vers','-buildVersion'],text=True).strip()
    if build != BUILD:raise RuntimeError('Unqualified macOS build: '+build)
    cache = LocalCache()
    try:
        header,_,_ = cache.read_vm(HEADER_ADDRESS,32)
        magic,cpu,subtype,kind,count,size,_,_ = struct.unpack('<8I',header)
        if magic != 0xfeedfacf or cpu != 0x100000c or subtype & 0xffffff != 2 or kind != 6 or not 0<count<2048 or not 0<size<1048576:
            raise RuntimeError('Unqualified SkyLight Mach-O header')
        commands,_,_ = cache.read_vm(HEADER_ADDRESS+32,size)
        position = 0
        identifiers = []
        text_range = None
        for _ in range(count):
            if position+8 > size:raise RuntimeError('Truncated Mach-O command')
            command,length = struct.unpack_from('<II',commands,position)
            if length < 8 or length % 8 or position+length > size:raise RuntimeError('Invalid Mach-O command')
            if command == 0x1b:
                if length != 24:raise RuntimeError('Invalid UUID command')
                identifiers.append(str(uuid.UUID(bytes=commands[position+8:position+24])).upper())
            if command == 0x19 and commands[position+8:position+24].rstrip(b'\0') == b'__TEXT':
                if length < 72 or text_range is not None:raise RuntimeError('Invalid text segment')
                text_range = struct.unpack_from('<QQ',commands,position+24)
            position += length
        if position != size or identifiers != [SKYLIGHT_UUID] or not text_range or not text_range[0] <= BODY_ADDRESS < BODY_ADDRESS+BODY_SIZE <= text_range[0]+text_range[1]:
            raise RuntimeError('SkyLight identity or code extent is unqualified')
        body,path,offset = cache.read_vm(BODY_ADDRESS,BODY_SIZE)
        if hashlib.sha256(body).hexdigest() != BODY_SHA:raise RuntimeError('Native display body differs from the qualified profile')
        cache.verify_unchanged()
        return body,dict(cache=str(path),file_offset=offset,build=build,skylight_uuid=SKYLIGHT_UUID,body_sha256=BODY_SHA)
    finally:cache.close()


def assembly(body):
    lines=['// Generated from the local OS; do not distribute or commit.', '.text','.p2align 3',
           '.globl _display_native_clone','_display_native_clone:','.cfi_startproc','.cfi_b_key_frame']
    for offset in range(0,BODY_SIZE,4):
        lines.extend(CFI.get(offset,[]))
        lines.append('    '+RELOCATIONS.get(offset,'.inst 0x%08x'%struct.unpack_from('<I',body,offset)[0]))
    return ('\n'.join(lines)+'\n'+SUFFIX).encode()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args()
    requested=Path(os.path.abspath(args.output.expanduser()))
    if requested.is_symlink() or requested.with_suffix('.json').is_symlink():
        parser.error('Output symlinks are refused; existing paths preserved')
    output=requested.parent.resolve()/requested.name
    if output.is_relative_to(Path(__file__).resolve().parents[2]):
        parser.error('Generated native inputs must stay outside the source tree')
    manifest=output.with_suffix('.json')
    if output.exists() or manifest.exists():parser.error('Output already exists; preserved')
    body,receipt=local_body()
    data=assembly(body)
    receipt.update(generator_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                   assembly_sha256=hashlib.sha256(data).hexdigest(),body_size=BODY_SIZE,
                   update_return_offset=0x60,relocation_offsets=sorted(RELOCATIONS),
                   runtime_qualification_performed=False)
    output.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    created=[]
    try:
        for path,content in [(output,data),(manifest,(json.dumps(receipt,indent=2)+'\n').encode())]:
            fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
            created.append(path)
            with os.fdopen(fd,'wb') as stream:stream.write(content);stream.flush();os.fsync(stream.fileno())
    except BaseException:
        for path in created:path.unlink()
        raise
    print(json.dumps(dict(output=str(output),manifest=str(manifest),body_sha256=BODY_SHA)))


if __name__=='__main__':main()
