#!/usr/bin/env python3
"""Keep native application menus hidden while the HyprWM session is active."""
from pathlib import Path
import argparse,ctypes,fcntl,importlib.util,json,os,signal,socket,stat,struct,time

def regular_applications(regular_only=True):
    # Read LaunchServices' actual application policy, excluding agents and helpers.
    ctypes.CDLL('/System/Library/Frameworks/AppKit.framework/AppKit')
    runtime=ctypes.CDLL('/usr/lib/libobjc.A.dylib')
    runtime.objc_getClass.argtypes=[ctypes.c_char_p];runtime.objc_getClass.restype=ctypes.c_void_p
    runtime.sel_registerName.argtypes=[ctypes.c_char_p];runtime.sel_registerName.restype=ctypes.c_void_p
    address=ctypes.cast(runtime.objc_msgSend,ctypes.c_void_p).value
    send=ctypes.CFUNCTYPE(ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p)(address)
    integer=ctypes.CFUNCTYPE(ctypes.c_long,ctypes.c_void_p,ctypes.c_void_p)(address)
    at=ctypes.CFUNCTYPE(ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_ulong)(address)
    selector=lambda name:runtime.sel_registerName(name.encode())
    pool=send(runtime.objc_getClass(b'NSAutoreleasePool'),selector('new'))
    try:
        core=ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        core.CFRunLoopRunInMode.argtypes=[ctypes.c_void_p,ctypes.c_double,ctypes.c_bool]
        core.CFRunLoopRunInMode.restype=ctypes.c_int
        core.CFRunLoopRunInMode(ctypes.c_void_p.in_dll(core,'kCFRunLoopDefaultMode'),.01,False)
        workspace=send(runtime.objc_getClass(b'NSWorkspace'),selector('sharedWorkspace'))
        applications=send(workspace,selector('runningApplications'))
        return [integer(app,selector('processIdentifier'))
                for index in range(integer(applications,selector('count')))
                for app in [at(applications,selector('objectAtIndex:'),index)]
                if not regular_only or integer(app,selector('activationPolicy'))==0]
    finally:send(pool,selector('drain'))

def modifier():
    source=Path(__file__).resolve().with_name('menu-inject.py')
    spec=importlib.util.spec_from_file_location('menu_inject',source)
    loader=importlib.util.module_from_spec(spec);spec.loader.exec_module(loader)
    return loader

def restore_menus(uid):
    assert os.geteuid()==0 and uid>0
    loader=modifier();library=loader.notify()
    for pid in regular_applications(False):
        actor=loader.identity(pid)
        if actor and actor['uid']==uid and loader.capability(library,pid)==1:
            token=loader.request(library,pid,False);library.notify_cancel(token)

def run(uid,control):
    assert os.geteuid()==0 and uid>0
    lock=os.open(f'/var/run/hyprwm-menu-policy-{uid}.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    info=os.fstat(lock);assert stat.S_ISREG(info.st_mode) and info.st_uid==0 and not info.st_mode&0o077
    try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:os.close(lock);return
    loader=modifier()
    library=loader.notify();known={};ready=set();attempted=set();stopping=False
    def stop(*_):
        nonlocal stopping
        stopping=True
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    def active():
        try:
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(1);connection.connect(control)
                pid=struct.unpack('=i',connection.getsockopt(0,2,4))[0];peer=loader.identity(pid)
                if not peer or peer['uid']!=uid:return None
                connection.sendall(b'status\n');data=bytearray()
                while b'\n' not in data and len(data)<=262144:
                    block=connection.recv(8192)
                    if not block:return None
                    data.extend(block)
                status=json.loads(data.split(b'\n',1)[0]);fresh=loader.identity(pid)
                if not fresh or any(fresh[k]!=peer[k] for k in ['pid','uid','seconds','micros','path']) or status.get('daemon',{}).get('pid')!=pid:return None
                return bool(status.get('enabled')) and status.get('compatibility',{}).get('verified') is True
        except (OSError,ValueError,KeyError):return None
    def set_existing(value):
        for pid,actor in list(known.items()):
            fresh=loader.identity(pid)
            if not fresh or any(fresh[k]!=actor[k] for k in ['pid','uid','seconds','micros','path']):known.pop(pid,None);continue
            key=(pid,actor['seconds'],actor['micros'],actor['path'])
            if value and key not in ready:continue
            token=loader.request(library,pid,value);library.notify_cancel(token)
    missing_since=None;was_enabled=None
    try:
        while not stopping:
            enabled=active()
            if enabled is None:
                missing_since=missing_since or time.monotonic()
                if time.monotonic()-missing_since>10:enabled=False
                if time.monotonic()-missing_since>120:break
            else:missing_since=None
            actors=[]
            for pid in regular_applications():
                actor=loader.identity(pid)
                if not actor or actor['uid']!=uid:continue
                path=actor['path']
                if path.count('.app/')!=1 or not path.split('.app/',1)[1].startswith('Contents/MacOS/'):continue
                known[pid]=actor;actors.append(actor)
            if enabled is not None and (enabled!=was_enabled or not enabled):
                set_existing(enabled);was_enabled=enabled
                if not enabled:restore_menus(uid)
            if enabled:
                for actor in actors:
                    if stopping:break
                    pid=actor['pid']
                    key=(pid,actor['seconds'],actor['micros'],actor['path'])
                    if key in ready:continue
                    if key in attempted and loader.capability(library,pid)!=1:continue
                    attempted.add(key)
                    known[pid]=actor
                    try:
                        result=loader.load(pid,uid,actor['seconds'],actor['micros']);ready.add(key)
                        print(json.dumps(result),flush=True)
                    except Exception as error:
                        fresh=loader.identity(pid)
                        if fresh and all(fresh[k]==actor[k] for k in ['pid','uid','seconds','micros','path']):
                            token=loader.request(library,pid,False);library.notify_cancel(token)
                        print(json.dumps(dict(ok=False,pid=pid,error=str(error)[-600:])),flush=True)
            for _ in range(10):
                if stopping:break
                time.sleep(.2)
    finally:set_existing(False);os.close(lock)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--uid',type=int,required=True);parser.add_argument('--control',default='/tmp/hyprwm.ctl');parser.add_argument('--restore',action='store_true');arguments=parser.parse_args()
    if arguments.restore:restore_menus(arguments.uid)
    else:run(arguments.uid,arguments.control)
