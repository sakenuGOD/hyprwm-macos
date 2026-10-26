#!/usr/bin/env python3
"""Enable the existing first-frame client for one exact regular app generation."""
from pathlib import Path
import ctypes,importlib.util,json,os,plistlib,pwd,shutil,socket,stat,struct,subprocess,sys,tempfile,time,uuid
if sys.flags.optimize:
    raise RuntimeError('First-map identity guards require Python optimization disabled')

def loader():
    spec=importlib.util.spec_from_file_location('menu_inject',Path(__file__).with_name('menu-inject.py'))
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value

def request(library,pid,enabled):
    token=ctypes.c_int();name=f'hyprwm.admission.v2.request.{pid}'.encode()
    assert library.notify_register_check(name,ctypes.byref(token))==0
    assert library.notify_set_state(token.value,int(enabled))==0
    library.notify_post(name);return token.value

def capability(library,pid):
    token=ctypes.c_int();value=ctypes.c_uint64()
    assert library.notify_register_check(f'hyprwm.admission.v2.cap.{pid}'.encode(),ctypes.byref(token))==0
    try:assert library.notify_get_state(token.value,ctypes.byref(value))==0;return value.value
    finally:library.notify_cancel(token.value)

def manager(control,uid):
    native=loader()
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(2);connection.connect(control)
        pid=struct.unpack('=i',connection.getsockopt(0,2,4))[0];actor=native.identity(pid)
        assert actor and actor['uid']==uid and Path(actor['path']).name=='hyprwm-swift'
        connection.sendall(b'status\n');data=connection.makefile('rb').readline(262145)
        value=json.loads(data);fresh=native.identity(pid)
        assert fresh and all(fresh[k]==actor[k] for k in ['pid','uid','seconds','micros','path'])
        assert value['daemon']['pid']==pid and value['enabled'] and value['compatibility']['verified']
        return actor

def owned_directory(path,uid,gid,create=False,private=False):
    home=Path(pwd.getpwuid(uid).pw_dir).resolve();path=Path(path)
    relative=path.relative_to(home)
    fd=os.open(home,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC)
    try:
        info=os.fstat(fd);assert info.st_uid==uid and not info.st_mode&0o022
        for name in relative.parts:
            assert name not in ('','.','..')
            created=False
            try:child=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC,dir_fd=fd)
            except FileNotFoundError:
                if not create:raise
                os.mkdir(name,0o700,dir_fd=fd);created=True
                child=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC,dir_fd=fd)
            try:
                info=os.fstat(child)
                if created:
                    assert info.st_uid==0 and not os.listdir(child)
                    os.fchown(child,uid,gid)
                    info=os.fstat(child)
                assert info.st_uid==uid and not info.st_mode&0o022
            except BaseException:os.close(child);raise
            os.close(fd);fd=child
        if private:assert os.fstat(fd).st_mode&0o077==0
        result=fd;fd=None;return result
    finally:
        if fd is not None:os.close(fd)

def read_grants(path,uid,directory=None):
    owned=None
    if directory is None:
        owned=owned_directory(path.parent,uid,pwd.getpwuid(uid).pw_gid,private=True);directory=owned
    try:fd=os.open(path.name,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC|os.O_NONBLOCK,dir_fd=directory)
    except FileNotFoundError:return None,dict(schema=1,targets=[])
    finally:
        if owned is not None:os.close(owned)
    try:
        before=os.fstat(fd)
        assert stat.S_ISREG(before.st_mode) and before.st_uid==uid and before.st_mode&0o077==0 and before.st_nlink==1 and 0<before.st_size<=65536
        data=os.read(fd,65537);after=os.fstat(fd)
        assert len(data)==before.st_size and (before.st_dev,before.st_ino,before.st_mtime_ns,before.st_size)==(after.st_dev,after.st_ino,after.st_mtime_ns,after.st_size)
    finally:os.close(fd)
    value=json.loads(data);assert value.get('schema')==1 and isinstance(value.get('targets'),list) and len(value['targets'])<=128
    return data,value

def write_grant(path,target,uid,gid):
    directory=owned_directory(path.parent,uid,gid,create=True,private=True)
    tmp='.grant-'+uuid.uuid4().hex
    try:
        before,value=read_grants(path,uid,directory);native=loader();retained=[]
        for row in value['targets']:
            assert isinstance(row,dict) and isinstance(row.get('birth'),list) and len(row['birth'])==4
            assert all(isinstance(part,int) and not isinstance(part,bool) for part in row['birth'])
            assert row['birth'][0]>1 and row['birth'][1]==uid and row['birth'][2]>0 and 0<=row['birth'][3]<1000000
            pid=row['birth'][0]
            if pid==target['birth'][0]:continue
            actor=native.identity(pid)
            if actor is None:
                try:os.kill(pid,0)
                except ProcessLookupError:continue
                except PermissionError:pass
            elif [actor['pid'],actor['uid'],actor['seconds'],actor['micros']]!=row['birth'] or actor['path']!=row.get('executable'):continue
            retained.append(row)
        value['targets']=retained+[target];assert len(value['targets'])<=128
        data=(json.dumps(value,separators=(',',':'))+'\n').encode();assert len(data)<=65536
        fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600,dir_fd=directory)
        os.fchown(fd,uid,gid);os.fchmod(fd,0o600)
        with os.fdopen(fd,'wb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
        assert read_grants(path,uid,directory)[0]==before,'admission grant changed concurrently'
        os.replace(tmp,path.name,src_dir_fd=directory,dst_dir_fd=directory)
    finally:
        try:os.unlink(tmp,dir_fd=directory)
        except FileNotFoundError:pass
        os.close(directory)

def publish_grant(target,uid,control):
    native=loader();current=native.identity(target['birth'][0]);server=manager(control,uid)
    assert current and [current['pid'],current['uid'],current['seconds'],current['micros']]==target['birth'] and current['path']==target['executable']
    assert server['path']==target['server_executable']
    user=pwd.getpwuid(uid);home=Path(user.pw_dir).resolve()
    folder=home/'Library/Application Support/HyprWM/first-map'
    directory=owned_directory(folder,uid,user.pw_gid,create=True,private=True);os.close(directory)
    bundle=Path(current['path'].split('.app/')[0]+'.app')
    metadata=plistlib.loads((bundle/'Contents/Info.plist').read_bytes());bid=metadata.get('CFBundleIdentifier')
    if isinstance(bid,str) and bid and all(c.isalnum() or c in '._-' for c in bid):
        container=home/'Library/Containers'/bid/'Data'
        if container.is_dir() and not container.is_symlink() and container.resolve()==container:
            item=container.stat();assert item.st_uid==uid and not item.st_mode&0o022
            directory=container/'.hwm';handle=owned_directory(directory,uid,user.pw_gid,create=True,private=True);os.close(handle)
            endpoint=str(directory/f's{current["pid"]}')
            if len(endpoint.encode())<104:
                target=dict(target,socket=endpoint)
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.settimeout(3);connection.connect(control)
                    assert struct.unpack('=i',connection.getsockopt(0,2,4))[0]==server['pid']
                    connection.sendall(('firstmap-listen '+json.dumps(target)+'\n').encode())
                    assert connection.makefile('rb').readline(8192).decode().strip()==endpoint,'container first-map listener refused'
                write_grant(directory/f'g{current["pid"]}',target,uid,user.pw_gid)
    write_grant(folder/'grants.json',target,uid,user.pw_gid)

def image_entry(path,architecture):
    raw=path.read_bytes();assert len(raw)<=2**21
    if struct.unpack_from('>I',raw)[0]==0xcafebabe:
        count=struct.unpack_from('>I',raw,4)[0];assert 0<count<=8;matches=[]
        for index in range(count):
            cpu,sub,offset,size,_=struct.unpack_from('>5I',raw,8+20*index)
            if cpu==0x100000c and sub&0xffffff==(2 if architecture=='arm64e' else 0):
                assert 0<offset<offset+size<=len(raw);matches.append(raw[offset:offset+size])
        assert len(matches)==1;raw=matches[0]
    assert struct.unpack_from('<I',raw)[0]==0xfeedfacf
    count,length=struct.unpack_from('<II',raw,16);assert 0<count<2048 and 32+length<=len(raw)
    pos=32;identifier=None;text=None;symtab=None;code_sections=[]
    for _ in range(count):
        command,size=struct.unpack_from('<II',raw,pos);assert size>=8 and pos+size<=32+length
        if command==0x1b:assert size==24;identifier=str(uuid.UUID(bytes=raw[pos+8:pos+24])).upper()
        elif command==2:symtab=struct.unpack_from('<4I',raw,pos+8)
        elif command==0x19:
            name=raw[pos+8:pos+24].rstrip(b'\0');vm,_,offset,_=struct.unpack_from('<4Q',raw,pos+24)
            if name==b'__TEXT':text=(vm,offset)
            n=struct.unpack_from('<I',raw,pos+64)[0];assert 72+n*80<=size
            for i in range(n):
                s=pos+72+i*80;address,extent,fileoff=struct.unpack_from('<QQI',raw,s+32)
                if struct.unpack_from('<I',raw,s+64)[0]&0x80000400:code_sections.append((address,extent,fileoff))
        pos+=size
    assert pos==32+length and identifier and text and symtab
    symoff,nsyms,stroff,strsize=symtab;assert nsyms<=65536 and symoff+16*nsyms<=len(raw) and stroff+strsize<=len(raw)
    entries=[]
    for i in range(nsyms):
        index,kind,_,_,address=struct.unpack_from('<IBBHQ',raw,symoff+16*i)
        if not index or kind&0xe0 or kind&0xf!=0xf:continue
        assert index<strsize;end=raw.find(b'\0',stroff+index,stroff+strsize);assert end>=0
        if raw[stroff+index:end]!=b'_HAInstallCurrentGrant':continue
        for start,size,offset in code_sections:
            if start<=address<address+16<=start+size:
                entries.append(dict(uuid=identifier,offset=address-text[0],prefix=raw[offset+address-start:offset+address-start+16].hex()))
    assert len(entries)==1;return entries[0]

def load(pid,uid,seconds,micros,control='/tmp/hyprwm.ctl'):
    assert os.geteuid()==0 and not sys.flags.optimize
    native=loader();expected=native.identity(pid);server=manager(control,uid)
    assert expected and expected['uid']==uid and expected['seconds']==seconds and expected['micros']==micros and expected['status']!=4
    assert uid>0 and pid>1 and '.app/Contents/MacOS/' in expected['path']
    protected=['Dock','SystemUIServer','ControlCenter','WindowManager','loginwindow']
    assert expected['path'] not in [f'/System/Library/CoreServices/{name}.app/Contents/MacOS/{name}' for name in protected]
    library=native.notify()
    if capability(library,pid)==1:
        home=Path(pwd.getpwuid(uid).pw_dir).resolve();folder=home/'Library/Application Support/HyprWM/first-map'
        _,table=read_grants(folder/'grants.json',uid)
        rows=[row for row in table['targets'] if row.get('birth')==[pid,uid,seconds,micros] and row.get('executable')==expected['path']]
        assert len(rows)==1 and isinstance(rows[0].get('main_uuid'),str),'existing first-map grant identity unavailable'
        publish_grant(dict(rows[0],server_executable=server['path']),uid,control)
        token=request(library,pid,True);library.notify_cancel(token)
        return dict(ok=True,pid=pid,admission=True,existing=True)
    source=Path(__file__).with_name('hypradmission.v2.dylib');assert source.is_file()
    user=pwd.getpwuid(uid);home=Path(user.pw_dir).resolve()
    folder=home/'Library/Application Support/HyprWM/Client Modules';assert folder.is_dir() and folder.stat().st_uid==uid
    bundle=Path(expected['path'].split('.app/')[0]+'.app');bid=plistlib.loads((bundle/'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier')
    if isinstance(bid,str) and bid and all(c.isalnum() or c in '._-' for c in bid):
        container=home/'Library/Containers'/bid/'Data'
        if container.is_dir() and not container.is_symlink() and container.resolve()==container:folder=container
    item=folder.lstat();assert stat.S_ISDIR(item.st_mode) and item.st_uid==uid and not item.st_mode&0o022
    destination=folder/'hypradmission.v2.dylib';temporary=folder/('.admission-'+uuid.uuid4().hex)
    directory=owned_directory(folder,uid,user.pw_gid)
    descriptor=os.open(temporary.name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=directory)
    try:
        os.fchown(descriptor,uid,user.pw_gid)
        with os.fdopen(descriptor,'wb') as stream:stream.write(source.read_bytes());stream.flush();os.fsync(stream.fileno())
        os.replace(temporary.name,destination.name,src_dir_fd=directory,dst_dir_fd=directory)
    finally:
        try:os.unlink(temporary.name,dir_fd=directory)
        except FileNotFoundError:pass
        os.close(directory)
    directory=Path(tempfile.mkdtemp(prefix='hyprwm-first-map-load-'));wrapper=directory/'load.py';log=directory/'load.log'
    config=dict(expected=expected,server=server,control=control,library=str(destination),
                entries={arch:image_entry(source,arch) for arch in ['arm64','arm64e']},
                dylib_loader=native.loader_entry(),module=str(Path(__file__).resolve()))
    wrapper.write_text('CONFIG='+repr(config)+'\n'+Path(__file__).with_name('first-map-load.py').read_text())
    try:
        with log.open('w') as output:
            child=subprocess.Popen(['/usr/bin/arch','-arm64',native.protected_tool('lldb'),'--no-lldbinit',
                '-O','plugin disable symbol-file','-O','plugin disable instrumentation-runtime','-O','plugin disable language-runtime.swift',
                '-O','settings set target.detach-on-error true','-O','settings set target.preload-symbols false',
                '-O','settings set symbols.enable-external-lookup false','-O','settings set target.load-script-from-symbol-file false',
                '-p',str(pid),'-o','script exec(compile(open('+repr(str(wrapper))+').read(),"first_map_loader","exec"))'],
                stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT)
            try:code=child.wait(timeout=15)
            except subprocess.TimeoutExpired:child.kill();child.wait(timeout=2);raise RuntimeError('owned first-map debugger disconnected: '+log.read_text()[-1500:])
        output=log.read_text();assert code==0 and 'FIRST_MAP_DETACH True INSTALLED True' in output,output[-1500:]
        assert capability(library,pid)==1,'first-map client did not become ready'
        token=request(library,pid,True);library.notify_cancel(token)
        return dict(ok=True,pid=pid,admission=True,existing=False)
    finally:shutil.rmtree(directory)

if __name__=='__main__':
    assert len(sys.argv)==5
    print(json.dumps(load(*map(int,sys.argv[1:]))),flush=True)
