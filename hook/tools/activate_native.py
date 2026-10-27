#!/usr/bin/env python3
"""Publish a freshly qualified native graph, or retire it with its guarded inverse.

The manager must already have paused, durably handed over its hidden ledger and
exited. This command never stops a manager, restores a hidden window or restarts
an application. Retained mappings and unwind registrations are never freed.
"""
import argparse
import ctypes
import hashlib
import json
import mmap
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import time

from prepare_native import bounded_read, identity, protected_tool, running_after_detach

def need(value,message):
    if not value: raise RuntimeError(message)
def save(run,row):
    temporary=run/'activation.json.next'
    with temporary.open('w') as stream:
        json.dump(row,stream,indent=2);stream.flush();os.fsync(stream.fileno())
    os.replace(temporary,run/'activation.json')
def root_directory(path):
    item=path.lstat()
    need(stat.S_ISDIR(item.st_mode) and item.st_uid==0 and item.st_mode&0o777==0o700,
         'Native receipt directory must be root-only')
def same_actor(expected):
    row=identity(expected['pid'])
    return row and row['status']!=4 and all(row[k]==expected[k] for k in ('pid','uid','seconds','micros','path'))
def publication_directory(path,owner,mode=0o700):
    path=Path(os.path.abspath(path))
    if path.parent==path:
        return path
    try:parent=path.parent.resolve(strict=True)
    except FileNotFoundError:parent=publication_directory(path.parent,owner)
    path=parent/path.name
    native=path==Path('/private/tmp/hyprwm') and owner==0 and mode==0o1777
    need(mode==0o700 or native,'Unsupported publication directory mode')
    flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW
    directory=os.open('/',flags)
    child=None
    try:
        for component in parent.parts[1:]:
            next_directory=os.open(component,flags,dir_fd=directory)
            os.close(directory);directory=next_directory
        try:child=os.open(path.name,flags,dir_fd=directory)
        except FileNotFoundError:
            anchor=os.fstat(directory)
            trusted=anchor.st_uid==owner and not anchor.st_mode&0o022
            native_anchor=native and parent==Path('/private/tmp') and anchor.st_uid==0 and stat.S_IMODE(anchor.st_mode)==0o1777
            need(trusted or native_anchor,'Missing publication directory requires a trusted owner parent')
            created=False
            previous_uid=os.geteuid()
            try:
                # Create user state as that user. Never chown a pathname that
                # its parent owner could replace between mkdir and open.
                if not native and previous_uid!=owner:os.seteuid(owner)
                try:os.mkdir(path.name,0o700,dir_fd=directory);created=True
                except FileExistsError:pass
                child=os.open(path.name,flags,dir_fd=directory)
            finally:
                if os.geteuid()!=previous_uid:os.seteuid(previous_uid)
            if created:
                item=os.fstat(child)
                need(item.st_uid==owner and stat.S_IMODE(item.st_mode)==0o700,'New publication directory changed')
                # Root's sticky /private/tmp prevents an unprivileged caller
                # from replacing this root-owned native directory.
                if native:os.fchmod(child,mode)
                os.fsync(child);os.fsync(directory)
        item=os.fstat(child)
        sticky=path==Path('/private/tmp/hyprwm') and item.st_uid==0 and stat.S_IMODE(item.st_mode)==0o1777
        need(item.st_uid in (0,owner) and (not item.st_mode&0o022 or sticky),'Unsafe publication directory')
        if native:need(sticky,'Native publication directory must be root-owned and sticky')
        current=path.lstat()
        need(stat.S_ISDIR(current.st_mode) and (current.st_dev,current.st_ino)==(item.st_dev,item.st_ino),
             'Publication directory changed during creation')
        return path
    finally:
        if child is not None:os.close(child)
        os.close(directory)
def snapshot(path,owner):
    path=path.parent.resolve(strict=True)/path.name
    parent=path.parent.lstat()
    sticky_native=path.parent==Path('/private/tmp/hyprwm') and parent.st_uid==0 and stat.S_IMODE(parent.st_mode)==0o1777
    need(stat.S_ISDIR(parent.st_mode) and parent.st_uid in (0,owner) and (not parent.st_mode&0o022 or sticky_native),
         'Unsafe publication directory')
    try:
        data=bounded_read(path,owner,4096);item=path.lstat()
        return dict(path=str(path),data=data.hex(),uid=item.st_uid,gid=item.st_gid,mode=stat.S_IMODE(item.st_mode),
                    inode=[item.st_dev,item.st_ino],parent_inode=[parent.st_dev,parent.st_ino])
    except FileNotFoundError:
        return dict(path=str(path),data=None,uid=owner,gid=-1,mode=0o600,parent_inode=[parent.st_dev,parent.st_ino])
def replace_file(saved,data,expected_data):
    path=Path(saved['path']);directory=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    temporary='.hyprwm-native-'+os.urandom(12).hex()
    try:
        parent=os.fstat(directory)
        need([parent.st_dev,parent.st_ino]==saved['parent_inode'],'Publication directory changed')
        current=snapshot(path,saved['uid'])
        need(current['data']==expected_data,'Publication was changed by another owner')
        if data is None:
            if current['data'] is not None:os.unlink(path.name,dir_fd=directory)
        else:
            fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,saved['mode'],dir_fd=directory)
            try:
                os.fchown(fd,saved['uid'],saved['gid']);os.fchmod(fd,saved['mode'])
                with os.fdopen(fd,'wb',closefd=False) as stream:
                    stream.write(bytes.fromhex(data));stream.flush();os.fsync(fd)
            finally:os.close(fd)
            os.replace(temporary,path.name,src_dir_fd=directory,dst_dir_fd=directory)
        os.fsync(directory)
    finally:
        try:os.unlink(temporary,dir_fd=directory)
        except FileNotFoundError:pass
        os.close(directory)
def no_manager(control_path):
    # Socket absence alone does not prove that a channel writer has exited.
    # Check all UIDs; source and packaged launches use this executable name.
    class Info(ctypes.Structure):
        _fields_=[('header',ctypes.c_uint32*12),('comm',ctypes.c_char*16),
                  ('name',ctypes.c_char*32),('tail',ctypes.c_uint32*6),
                  ('sec',ctypes.c_uint64),('usec',ctypes.c_uint64)]
    lib=ctypes.CDLL('/usr/lib/libproc.dylib')
    lib.proc_listpids.argtypes=[ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_int]
    lib.proc_pidinfo.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
    lib.proc_pidpath.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32]
    needed=lib.proc_listpids(1,0,None,0)
    need(0<needed<256*1024,'Cannot obtain a bounded manager process census')
    size=min(256*1024,needed+4096);pids=(ctypes.c_int*(size//4))()
    written=lib.proc_listpids(1,0,pids,ctypes.sizeof(pids))
    need(0<written<ctypes.sizeof(pids) and written%4==0,'Manager process census is incomplete')
    for pid in pids[:written//4]:
        if pid<=0:continue
        info=Info();length=lib.proc_pidinfo(pid,3,0,ctypes.byref(info),ctypes.sizeof(info))
        if length!=ctypes.sizeof(info):
            try:os.kill(pid,0)
            except ProcessLookupError:continue
            raise RuntimeError('Cannot inspect a live process before native publication')
        executable=ctypes.create_string_buffer(4096)
        count=lib.proc_pidpath(pid,executable,len(executable))
        names=[bytes(info.comm),bytes(info.name)]
        if count>0:names.append(os.path.basename(executable.value))
        if b'hyprwm-swift' in names:
            # Refuse even an unreadable/replaced matching generation. Never
            # turn a failed identity lookup into evidence of departure.
            raise RuntimeError('Complete manager/menu process departure before native publication (pid '+str(pid)+')')
        if count<=0 and info.header[1]!=5:
            try:os.kill(pid,0)
            except ProcessLookupError:continue
            raise RuntimeError('Cannot resolve a live executable before native publication')
    import socket
    need(Path(control_path).is_absolute(),'Control socket path must be absolute')
    for path in dict.fromkeys((str(control_path),'/tmp/hyprwm.ctl')):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(.2)
            try:connection.connect(path)
            except (FileNotFoundError,ConnectionRefusedError):continue
        raise RuntimeError('Complete the authenticated manager handover before native publication')
def attach(run,mode):
    row=json.loads((run/'activation.json').read_text());prepared=Path(row['prepared'])
    no_manager(row.get('control_socket','/tmp/hyprwm.ctl'))
    p=json.loads(bounded_read(prepared,0));need(same_actor(p['expected']),'Native generation changed')
    body=run/'native_activate_lldb.py'
    need(hashlib.sha256(bounded_read(body,0)).hexdigest()==row['body_sha256'],'Publication source changed')
    configuration=dict(run=str(run),prepared=str(prepared),mode=mode,deadline=time.monotonic()+20)
    wrapper=run/(mode+'-entry.py')
    wrapper.write_text('import lldb,os,traceback,hashlib\nCONFIG='+repr(configuration)+'\nok=False\ntry:\n'
        '    source=open('+repr(str(body))+',"rb").read()\n'
        '    assert hashlib.sha256(source).hexdigest()=='+repr(row['body_sha256'])+'\n'
        '    exec(compile(source,"native_publication","exec"),globals())\n    ok=True\n'
        'except BaseException:\n    os.write(2,traceback.format_exc().encode())\n'
        'finally:\n    error=lldb.debugger.GetSelectedTarget().GetProcess().Detach()\n'
        '    os.write(1,("NATIVE_DETACH "+str(error.Success())+" SUCCESS "+str(ok)+"\\n").encode())\n'
        '    if error.Success():os._exit(0 if ok else 1)\n')
    log=run/(mode+'.log')
    with log.open('w') as stream:
        child=subprocess.Popen(['/usr/bin/arch','-arm64',protected_tool('lldb'),'--no-lldbinit',
            '-O','plugin disable symbol-file','-O','plugin disable instrumentation-runtime',
            '-O','plugin disable language-runtime.swift','-O','settings set target.detach-on-error true',
            '-O','settings set target.preload-symbols false','-O','settings set symbols.enable-external-lookup false',
            '-O','settings set target.load-script-from-symbol-file false','-p',str(p['expected']['pid']),
            '-o','script exec(compile(open('+repr(str(wrapper))+').read(),"native_publication_entry","exec"))'],
            stdin=subprocess.DEVNULL,stdout=stream,stderr=subprocess.STDOUT)
        try:code=child.wait(timeout=max(.1,configuration['deadline']-time.monotonic()))
        except subprocess.TimeoutExpired:
            child.kill();child.wait(timeout=3)
            raise RuntimeError('Owned debugger disconnected at deadline; inspect '+str(log))
    text=log.read_text()
    resumed=running_after_detach(p['expected']) if code==0 and 'NATIVE_DETACH True SUCCESS True' in text else None
    need(code==0 and 'NATIVE_DETACH True SUCCESS True' in text and resumed and same_actor(p['expected']),
         'Native publication refused; inspect '+str(log))
    return json.loads((run/'activation.json').read_text()),p
def wait_ticks(path,previous=None):
    descriptor=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        first=os.pread(descriptor,256,0);need(len(first)==256,'Channel header unavailable')
        need(struct.unpack_from('<Q',first)[0]==0x3531574d52505948,'Native channel identity differs')
        before=struct.unpack_from('<I',first,32)[0] if previous is None else previous
        end=time.monotonic()+1.5
        while time.monotonic()<end:
            header=os.pread(descriptor,256,0)
            if struct.unpack_from('<I',header,32)[0]!=before:return
            time.sleep(.01)
        raise RuntimeError('Native timer did not advance; mappings and journal retained')
    finally:os.close(descriptor)
def drain(run,p):
    sys.path.insert(0,str(Path(run['prepared']).parent));import native_state as schema
    import ctypes
    item=p['files']['control'];path=Path(item['path'])
    fd=os.open(path,os.O_RDWR|os.O_NOFOLLOW)
    try:
        info=os.fstat(fd)
        need([info.st_dev,info.st_ino]==item['inode'] and info.st_uid==88 and info.st_size==65536
             and stat.S_ISREG(info.st_mode) and info.st_nlink==1 and not info.st_mode&0o077,'Control ownership changed')
        with mmap.mmap(fd,65536) as memory:
            # A refused inverse can leave an already destroyed graph installed.
            # Its timer no longer runs Ordinary, so repeating OFF cannot ACK.
            # Keep that command untouched; the stopped inverse still proves
            # every resource empty before it can restore any native boundary.
            current=schema.RGBA.from_buffer_copy(memory[:ctypes.sizeof(schema.RGBA)])
            ordinary=schema.Ordinary.from_buffer_copy(memory[12800:12800+ctypes.sizeof(schema.Ordinary)])
            off=(ordinary.command==0 and ordinary.sequence==ordinary.ack) or (
                ordinary.command==2 and ordinary.sequence==ordinary.ack+1)
            if (current.destroyed and current.pc.dead and not current.pc.gpu_pending
                    and not current.pc.active_command and not current.pc.command
                    and current.pc.command_ack==current.pc.command_sequence
                    and not current.renderer and not current.update and not current.root
                    and not ordinary.enabled and off):
                return
            def poll(offset,kind,command):
                before=kind.from_buffer_copy(memory[offset:offset+ctypes.sizeof(kind)])
                sequence_name='sequence' if kind==schema.Ordinary else 'command_sequence'
                ack_name='ack' if kind==schema.Ordinary else 'command_ack'
                command_name='command'
                need(getattr(before,sequence_name)==getattr(before,ack_name) and not before.command
                     and not getattr(before,'active_command',0),
                     'Native control command already pending')
                sequence=getattr(before,sequence_name)+1
                need(sequence<2**64,'Native command sequence exhausted')
                struct.pack_into('<Q',memory,offset+getattr(kind,command_name).offset,command)
                ctypes.CDLL('/usr/lib/libSystem.B.dylib').OSMemoryBarrier()
                struct.pack_into('<Q',memory,offset+getattr(kind,sequence_name).offset,sequence)
                end=time.monotonic()+4
                while time.monotonic()<end:
                    value=kind.from_buffer_copy(memory[offset:offset+ctypes.sizeof(kind)])
                    if getattr(value,ack_name)==sequence and not value.command:return value
                    time.sleep(.01)
                raise RuntimeError('Native resources retained: drain acknowledgement pending')
            ordinary=poll(12800,schema.Ordinary,2)
            need(not ordinary.enabled,'Ordinary drain refused')
            capture=poll(0,schema.Capture,4)
            need(not capture.active_command,'Capture drain refused')
    finally:os.close(fd)
def retire(run):
    row=json.loads((run/'activation.json').read_text());p=json.loads(bounded_read(Path(row['prepared']),0))
    no_manager(row.get('control_socket','/tmp/hyprwm.ctl'));need(row['phase'] in ('native-active','published','native-retired','retired'),'Native activation is not active')
    need(same_actor(p['expected']),'Native generation changed')
    if row['phase'] not in ('native-retired','retired'):
        drain(row,p);row,p=attach(run,'retire')
    for key in ('engine_state','pointer'):
        value=row[key]
        if value.get('published'):replace_file(value,value['data'],value['new_data']);value['published']=False;save(run,row)
    row['phase']='retired';save(run,row)
    if row.get('previous_native') and row['pointer']['data']:
        wait_ticks(Path(bytes.fromhex(row['pointer']['data']).decode().strip()))
    print('Native retired; exact previous publications restored: '+str(run/'activation.json'))
def activate(prepared,state_path,owner,previous_receipt,control_path):
    root_directory(prepared.parent);p=json.loads(bounded_read(prepared,0))
    need(p['owner_uid']==owner and p['phase']=='prepared-disabled' and not p['published'], 'Fresh disabled receipt required')
    need(same_actor(p['expected']),'Native generation changed');no_manager(control_path)
    publication_directory(Path('/private/tmp/hyprwm'),0,0o1777)
    state_path=publication_directory(state_path.parent,owner)/state_path.name
    run=Path(tempfile.mkdtemp(prefix='hyprwm-native-active-',dir='/private/tmp'));os.chmod(run,0o700)
    source=bounded_read(Path(__file__).with_name('native_activate_lldb.py'),owner)
    (run/'native_activate_lldb.py').write_bytes(source)
    state=snapshot(state_path,owner);pointer=snapshot(Path('/tmp/hyprwm/chan_path'),owner)
    previous=None;stale_previous=None
    if state['data'] is not None:
        fields=bytes.fromhex(state['data']).decode().split()
        need(len(fields)==5 and int(fields[0])>1,'Previous native state differs')
        need(pointer['data'] is not None,'Previous channel publication missing')
        need(previous_receipt is not None,'An exact qualified predecessor receipt is required for replacement')
        root_directory(previous_receipt.parent)
        predecessor=json.loads(bounded_read(previous_receipt,0))
        frozen=bounded_read(previous_receipt.parent/'freeze-manifest.json',0)
        manifest=json.loads(frozen);review=json.loads(bounded_read(previous_receipt.parent/'reviewed-generation.json',0))
        need(review.get('reviewed') is True and review['freeze_manifest_sha256']==hashlib.sha256(frozen).hexdigest()
             and predecessor.get('self_restored') is True and predecessor['engine_state']==fields==manifest['engine_state']
             and predecessor['candidate_sha256']==manifest['candidate_sha256'],'Predecessor has not completed its qualified inverse')
        actor=manifest['windowserver'];birth=actor['birth'];fresh=p['expected']
        need(actor['pid']==int(fields[0]) and birth[0]==actor['pid'] and birth[1]==88
             and actor['executable']==fresh['path']
             and bytes.fromhex(pointer['data']).decode().strip()==manifest['channel'],
             'Predecessor process or channel ownership differs')
        same_generation=(fresh['pid']==birth[0] and fresh['uid']==birth[1]
                         and fresh['seconds']==birth[2] and fresh['micros']==birth[3])
        if not same_generation:
            gone=False
            try:os.kill(actor['pid'],0)
            except ProcessLookupError:gone=True
            current=identity(actor['pid']) if not gone else None
            replaced=current and [current['pid'],current['uid'],current['seconds'],current['micros']]!=birth
            need(gone or replaced,'Previous WindowServer departure has not been proven')
            # A receipt from a dead generation is filesystem history only. Never
            # inspect, disable or queue any address from that process in this one.
            stale_previous=dict(receipt=str(previous_receipt),windowserver=actor)
        else:
            previous=dict(code=int(fields[1],16),context=int(fields[2],16),channel=int(fields[3],16))
            images=[(Path(name),digest) for name,digest in manifest['external_files'].items() if Path(name).name=='old-anim4.bin']
            need(len(images)==1,'Exact predecessor core image is unavailable')
            image,digest=images[0];raw=bounded_read(image,owner)
            need(hashlib.sha256(raw).hexdigest()==digest and hashlib.sha1(raw).hexdigest()[:12]==fields[4],
                 'Predecessor core image differs from its qualified build')
            dispatcher=predecessor['old_self'];offset=(dispatcher&0x00007fffffffffff)-previous['code']
            need(0<=offset<offset+16<=len(raw),'Predecessor dispatcher is outside its exact image')
            previous.update(dispatcher=dispatcher,control=predecessor['state'],image_path=str(image),
                            image_sha256=digest,image_size=len(raw),dispatcher_offset=offset)
    else:need(pointer['data'] is None,'Refusing an unrecognized existing native channel')
    channel=Path(pointer['path']).parent/('chan.'+os.urandom(12).hex())
    state['new_data']=('%d %x %x %x %s\n'%(p['expected']['pid'],p['code'],p['context'],p['channel'],
        hashlib.sha1(bounded_read(prepared.parent/'probe-eh.bin',0)).hexdigest()[:12])).encode().hex()
    # LiveEngine's logical /tmp contract and the canonical FD refer to one inode.
    pointer['new_data']=('/tmp/hyprwm/'+channel.name+'\n').encode().hex()
    boundaries={kind:dict(value,patch=struct.pack('<IIQ',0x58000050,0xd61f0a1f,value['target']).hex(),
                         installed=False,intent=None) for kind,value in p['boundaries'].items()}
    row=dict(schema=1,prepared=str(prepared),control_socket=str(control_path),body_sha256=hashlib.sha256(source).hexdigest(),phase='publication-ready',
             engine_state=state,pointer=pointer,channel=str(channel),boundaries=boundaries,
             previous_native=previous,stale_previous=stale_previous,maps_retained=True,registrations_retained=True)
    save(run,row)
    row,p=attach(run,'activate')
    try:
        item=p['files']['channel'];original=Path(item['path']);fd=os.open(original,os.O_RDWR|os.O_NOFOLLOW)
        try:
            info=os.fstat(fd)
            need([info.st_dev,info.st_ino]==item['inode'] and info.st_uid==88 and info.st_size==item['size']
                 and info.st_nlink==1 and stat.S_ISREG(info.st_mode),'Prepared channel changed')
            # Move, never copy: the native mapping and public consumer use one inode.
            os.fchown(fd,owner,-1);os.fchmod(fd,0o600)
            directory=os.open(channel.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
            try:
                parent=os.fstat(directory);need([parent.st_dev,parent.st_ino]==pointer['parent_inode'],'Channel directory changed')
                os.rename(original,channel.name,dst_dir_fd=directory);os.fsync(directory)
            finally:os.close(directory)
            need([channel.stat().st_dev,channel.stat().st_ino]==item['inode'],'Published channel inode differs')
        finally:os.close(fd)
        wait_ticks(channel)
        for key in ('engine_state','pointer'):
            value=row[key];replace_file(value,value['new_data'],value['data']);value['published']=True;save(run,row)
        row['phase']='published';save(run,row)
    except BaseException:
        # No manager may attach until both publications complete. Drain the new
        # graph while its own timer still runs, then restore the old publications.
        retire(run);raise
    print('Native graph published: '+str(run/'activation.json'))

def main():
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest='mode',required=True)
    on=sub.add_parser('activate');on.add_argument('--prepared',required=True,type=Path)
    on.add_argument('--engine-state',required=True,type=Path);on.add_argument('--owner-uid',required=True,type=int)
    on.add_argument('--previous-native',type=Path)
    on.add_argument('--control-socket',type=Path,default=Path(os.environ.get('HYPRWM_CTL','/tmp/hyprwm.ctl')))
    off=sub.add_parser('retire');off.add_argument('--receipt',required=True,type=Path)
    args=parser.parse_args();need(os.geteuid()==0 and not sys.flags.optimize,'Explicit unoptimized root publication required')
    os.umask(0o077)
    if args.mode=='activate':activate(args.prepared,args.engine_state,args.owner_uid,args.previous_native,args.control_socket)
    else:root_directory(args.receipt.parent);retire(args.receipt.parent)
if __name__=='__main__':main()
