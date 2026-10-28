#!/usr/bin/env python3
"""Bounded client for the explicitly enabled native in-process popup listener."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import socket
import stat
import struct
import sys
import time

TARGETS=('control-center',)
EXECUTABLE='/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter'

def positive(value):
    return type(value) is int and 0<value<2**64-1

def read_config(path):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or stat.S_IMODE(info.st_mode)!=0o600 or not 0<info.st_size<=8192:
            raise ValueError('unsafe native popup client configuration')
        data=os.read(fd,8193)
    finally:os.close(fd)
    value=json.loads(data)
    if not isinstance(value,dict) or set(value)!={'schema','socket','pid','birth','generation','nonce'} or value['schema']!=1:
        raise ValueError('native popup client schema 1 required')
    if not positive(value['pid']) or not positive(value['generation']) or not isinstance(value['nonce'],str) or not re.fullmatch(r'[A-Za-z0-9_-]{16,128}',value['nonce']):
        raise ValueError('invalid native popup instance')
    birth=value['birth']
    if not isinstance(birth,list) or len(birth)!=4 or any(type(v) is not int or v<0 for v in birth) or birth[:2]!=[value['pid'],os.getuid()] or birth[2]<=0 or birth[3]>=1000000:
        raise ValueError('invalid native popup birth')
    path=Path(value['socket']) if isinstance(value['socket'],str) else Path('.')
    if not path.is_absolute() or path.name!='control.sock' or len(os.fsencode(path))>=104 or path.parent.resolve()!=path.parent:
        raise ValueError('invalid canonical native popup socket path')
    parent=path.parent.lstat()
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid!=os.getuid() or stat.S_IMODE(parent.st_mode)!=0o700:
        raise ValueError('unsafe native popup socket directory')
    return value

class BSDInfo(ctypes.Structure):
    _fields_=[('head',ctypes.c_uint32*12),('comm',ctypes.c_char*16),('name',ctypes.c_char*32),
              ('tail',ctypes.c_uint32*6),('seconds',ctypes.c_uint64),('microseconds',ctypes.c_uint64)]

def native_identity(pid):
    # Public SDK proc_bsdinfo: exact136-byte layout, PIDTBSDINFO3. Read-only.
    if sys.platform!='darwin' or ctypes.sizeof(BSDInfo)!=136:raise ValueError('native identity reader unavailable')
    library=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
    library.proc_pidinfo.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
    library.proc_pidinfo.restype=ctypes.c_int
    library.proc_pidpath.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32];library.proc_pidpath.restype=ctypes.c_int
    info=BSDInfo();path=ctypes.create_string_buffer(4096)
    if library.proc_pidinfo(pid,3,0,ctypes.byref(info),ctypes.sizeof(info))!=ctypes.sizeof(info) or library.proc_pidpath(pid,path,len(path))<=0:
        raise ValueError('native process identity unavailable')
    return {'birth':[info.head[3],info.head[5],info.seconds,info.microseconds],'executable':os.fsdecode(path.value)}

def peer_uid(client):
    library=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
    library.getpeereid.argtypes=[ctypes.c_int,ctypes.POINTER(ctypes.c_uint),ctypes.POINTER(ctypes.c_uint)]
    library.getpeereid.restype=ctypes.c_int;uid=ctypes.c_uint();gid=ctypes.c_uint()
    if library.getpeereid(client.fileno(),ctypes.byref(uid),ctypes.byref(gid)):
        raise ValueError('native popup peer credentials unavailable')
    return uid.value

def send_request(config,action,target='control-center',identity_reader=native_identity):
    if action not in ('probe','toggle') or target not in TARGETS:raise ValueError('unsupported native popup request')
    expected={'birth':config['birth'],'executable':EXECUTABLE}
    if identity_reader(config['pid'])!=expected:raise ValueError('native popup process birth changed')
    path=Path(config['socket']);before=path.lstat()
    if not stat.S_ISSOCK(before.st_mode) or before.st_uid!=os.getuid() or stat.S_IMODE(before.st_mode)!=0o600:
        raise ValueError('unsafe native popup socket')
    message={key:config[key] for key in ('generation','nonce')};message.update(action=action,target=target)
    encoded=json.dumps(message,separators=(',',':')).encode()+b'\n'
    if len(encoded)>1024:raise ValueError('native popup request overflow')
    # In-process callers need the same bounded exchange as CLI callers.
    deadline=time.monotonic()+1.5
    def remaining(client):
        duration=deadline-time.monotonic()
        if duration<=0:raise TimeoutError('native popup deadline exceeded; do not retry')
        client.settimeout(duration)
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as client:
        remaining(client);client.connect(str(path))
        if peer_uid(client)!=os.getuid() or struct.unpack('=i',client.getsockopt(0,2,4))[0]!=config['pid']:
            raise ValueError('native popup server identity mismatch')
        after=path.lstat()
        if (before.st_dev,before.st_ino)!=(after.st_dev,after.st_ino) or identity_reader(config['pid'])!=expected:
            raise ValueError('native popup endpoint changed')
        remaining(client);client.sendall(encoded);data=bytearray()
        while b'\n' not in data:
            remaining(client)
            chunk=client.recv(8193-len(data))
            if not chunk:raise ValueError('native popup closed; outcome unknown; do not retry')
            data.extend(chunk)
            if len(data)>8192:raise ValueError('native popup response overflow; do not retry')
    if identity_reader(config['pid'])!=expected:raise ValueError('native popup process changed; outcome unknown; do not retry')
    value=json.loads(data)
    if not isinstance(value,dict) or type(value.get('ok')) is not bool:raise ValueError('native popup response invalid; do not retry')
    return value

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',type=Path,required=True);parser.add_argument('action',choices=('probe','toggle'))
    parser.add_argument('target',choices=TARGETS,nargs='?',default='control-center');args=parser.parse_args()
    try:
        result=send_request(read_config(args.config),args.action,args.target)
        print(json.dumps(result,ensure_ascii=False));return 0 if result['ok'] else 1
    except (OSError,ValueError,TypeError,KeyError) as error:
        print(json.dumps({'schema':1,'ok':False,'reason':str(error),'retry_allowed':False,'invocation_outcome_unknown':args.action=='toggle'},ensure_ascii=False));return 1

if __name__=='__main__':raise SystemExit(main())
