#!/usr/bin/env python3
"""Load the reversible application-menu modifier into one exact user app."""
from pathlib import Path
import ctypes,json,os,plistlib,pwd,shutil,stat,struct,subprocess,sys,tempfile,time

def identity(pid):
    class Info(ctypes.Structure):
        _fields_=[('header',ctypes.c_uint32*12),('comm',ctypes.c_char*16),('name',ctypes.c_char*32),('tail',ctypes.c_uint32*6),('sec',ctypes.c_uint64),('usec',ctypes.c_uint64)]
    lib=ctypes.CDLL('/usr/lib/libproc.dylib');lib.proc_pidinfo.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int];lib.proc_pidpath.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32]
    def sample():
        row=Info();path=ctypes.create_string_buffer(4096)
        if lib.proc_pidinfo(pid,3,0,ctypes.byref(row),ctypes.sizeof(row))!=ctypes.sizeof(row) or lib.proc_pidpath(pid,path,len(path))<=0:return None
        return dict(pid=int(row.header[3]),uid=int(row.header[5]),seconds=int(row.sec),micros=int(row.usec),path=os.path.realpath(os.fsdecode(path.value)),status=int(row.header[1]))
    first=sample();second=sample()
    if not first or not second or any(first[k]!=second[k] for k in ['pid','uid','seconds','micros','path']):return None
    return first

def notify():
    lib=ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    lib.notify_register_check.argtypes=[ctypes.c_char_p,ctypes.POINTER(ctypes.c_int)]
    lib.notify_set_state.argtypes=[ctypes.c_int,ctypes.c_uint64]
    lib.notify_get_state.argtypes=[ctypes.c_int,ctypes.POINTER(ctypes.c_uint64)]
    lib.notify_post.argtypes=[ctypes.c_char_p];lib.notify_cancel.argtypes=[ctypes.c_int]
    return lib

def request(lib,pid,enabled):
    name=f'hyprwm.menus.v2.request.{pid}'.encode();token=ctypes.c_int()
    assert lib.notify_register_check(name,ctypes.byref(token))==0
    assert lib.notify_set_state(token.value,int(enabled))==0;lib.notify_post(name)
    return token.value

def capability(lib,pid):
    token=ctypes.c_int();value=ctypes.c_uint64()
    assert lib.notify_register_check(f'hyprwm.menus.v2.cap.{pid}'.encode(),ctypes.byref(token))==0
    try:
        assert lib.notify_get_state(token.value,ctypes.byref(value))==0
        return value.value
    finally:lib.notify_cancel(token.value)

def protected_tool(name):
    path=Path('/Library/Developer/CommandLineTools/usr/bin')/name
    resolved=path.resolve(strict=True)
    for entry in [resolved,*resolved.parents,path,*path.parents]:
        info=entry.stat()
        assert info.st_uid==0 and not info.st_mode&0o022,'unprotected tool path: '+str(entry)
    assert resolved.is_file() and os.access(resolved,os.X_OK)
    return str(path)

def loader_entry(name='dlopen',library='/usr/lib/system/libdyld.dylib'):
    # Shared-cache code is callable only after the stopped target matches this image.
    class DlInfo(ctypes.Structure):
        _fields_=[('name',ctypes.c_char_p),('base',ctypes.c_void_p),('symbol',ctypes.c_char_p),('address',ctypes.c_void_p)]
    dyld=ctypes.CDLL(library)
    dyld.dladdr.argtypes=[ctypes.c_void_p,ctypes.POINTER(DlInfo)];dyld.dladdr.restype=ctypes.c_int
    address=ctypes.cast(getattr(dyld,name),ctypes.c_void_p).value;info=DlInfo()
    assert address and dyld.dladdr(address,ctypes.byref(info)) and info.base
    fields=struct.unpack('<8I',ctypes.string_at(info.base,32))
    assert fields[0]==0xfeedfacf and fields[4]<2048 and fields[5]<1048576
    commands=ctypes.string_at(info.base+32,fields[5]);offset=0;uuid=None
    for _ in range(fields[4]):
        command,size=struct.unpack_from('<II',commands,offset)
        assert size>=8 and offset+size<=len(commands)
        if command==0x1b:
            assert size==24 and uuid is None;uuid=commands[offset+8:offset+24].hex()
        offset+=size
    assert uuid and offset==len(commands)
    return dict(address=address,base=info.base,uuid=uuid,code=ctypes.string_at(address,16).hex())

def load(pid,uid,seconds,micros):
    expected=identity(pid)
    assert expected and expected['uid']==uid and expected['seconds']==seconds and expected['micros']==micros and uid>0 and pid>1
    assert expected['status']!=4 and '.app/Contents/MacOS/' in expected['path']
    protected=['Dock','SystemUIServer','ControlCenter','WindowManager','loginwindow']
    assert expected['path'] not in [f'/System/Library/CoreServices/{name}.app/Contents/MacOS/{name}' for name in protected]
    lib=notify();cap=ctypes.c_int();value=ctypes.c_uint64()
    assert lib.notify_register_check(f'hyprwm.menus.v2.cap.{pid}'.encode(),ctypes.byref(cap))==0
    lib.notify_get_state(cap.value,ctypes.byref(value))
    if value.value==1:
        hold=request(lib,pid,True)
        lib.notify_cancel(cap.value);lib.notify_cancel(hold);return dict(ok=True,pid=pid,existing=True)
    assert value.value==0,'modifier previously refused this application'
    hold=request(lib,pid,False)
    source=Path(__file__).resolve().with_name('hyprmenus.dylib');assert source.is_file()
    app=Path(expected['path'].split('.app/')[0]+'.app');bid=None
    try:bid=plistlib.loads((app/'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier')
    except (OSError,ValueError):pass
    account=pwd.getpwuid(uid);home=Path(account.pw_dir).resolve()
    directory=home/'Library/Application Support/HyprWM/Client Modules'
    if not directory.exists():
        directory.mkdir(mode=0o700,parents=True);os.chown(directory,uid,account.pw_gid)
    if isinstance(bid,str) and bid and all(c.isalnum() or c in '._-' for c in bid):
        box=Path(account.pw_dir)/'Library/Containers'/bid/'Data'
        if box.is_dir() and not box.is_symlink():directory=box
    directory=directory.resolve();assert directory.is_relative_to(home)
    descriptor=os.open(directory,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        assert os.fstat(descriptor).st_uid==uid
        destination=directory/'hyprmenus.v2.dylib';temporary='hyprmenus.v2.dylib.new'
        fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o644,dir_fd=descriptor)
        try:
            with os.fdopen(fd,'wb') as stream:stream.write(source.read_bytes());stream.flush();os.fsync(stream.fileno())
            os.replace(temporary,destination.name,src_dir_fd=descriptor,dst_dir_fd=descriptor)
        finally:
            try:os.unlink(temporary,dir_fd=descriptor)
            except FileNotFoundError:pass
    finally:os.close(descriptor)
    directory=Path(tempfile.mkdtemp(prefix='hyprwm-menu-load-'));wrapper=directory/'load.py';log=directory/'load.log'
    guard=Path(__file__).read_text().split('def notify():')[0]
    wrapper.write_text('import lldb,os,json,ctypes\n'+guard+'\nEXPECTED='+repr(expected)+'\nLIBRARY='+repr(str(destination))+'\nENTRY='+repr(loader_entry())+'''\nok=False
try:
    process=lldb.debugger.GetSelectedTarget().GetProcess()
    assert process.GetState()==lldb.eStateStopped and process.GetProcessID()==EXPECTED['pid']
    main=next((thread for thread in process if thread.GetIndexID()==1),None);assert main is not None;process.SetSelectedThread(main)
    fresh=identity(EXPECTED['pid']);assert fresh and all(fresh[k]==EXPECTED[k] for k in ['pid','uid','seconds','micros','path'])
    target=lldb.debugger.GetSelectedTarget()
    modules=[module for module in target.modules if (module.GetUUIDString() or '').replace('-','').lower()==ENTRY['uuid']]
    assert len(modules)==1 and modules[0].GetObjectFileHeaderAddress().GetLoadAddress(target)==ENTRY['base'],'loader image mapping differs'
    error=lldb.SBError();code=process.ReadMemory(ENTRY['address'],16,error)
    assert error.Success() and code.hex()==ENTRY['code'],'loader code differs'
    packet=lldb.SBCommandReturnObject();lldb.debugger.GetCommandInterpreter().HandleCommand('process plugin packet send QSetDetachOnError:1',packet)
    assert packet.Succeeded() and 'response: OK' in packet.GetOutput()
    options=lldb.SBExpressionOptions();options.SetIgnoreBreakpoints(True);options.SetStopOthers(True);options.SetTryAllThreads(False);options.SetUnwindOnError(True);options.SetTimeoutInMicroSeconds(2000000);options.SetLanguage(lldb.eLanguageTypeC)
    pointer='(void *)'+str(ENTRY['address'])
    if target.GetTriple().startswith('arm64e-'):
        pointer='__builtin_ptrauth_sign_unauthenticated('+pointer+',0,0)'
    result=target.EvaluateExpression('((void *(*)(const char *,int))'+pointer+')('+json.dumps(LIBRARY)+',2)',options)
    assert result.IsValid() and result.GetError().Success() and result.GetValueAsUnsigned()!=0,str(result.GetError())
    ok=True
except BaseException as failure:
    os.write(2,('MENU_REFUSED '+repr(failure)+'\\n').encode())
finally:
    error=lldb.debugger.GetSelectedTarget().GetProcess().Detach()
    os.write(1,('MENU_DETACH '+str(error.Success())+' LOADED '+str(ok)+'\\n').encode())
    if error.Success():os._exit(0 if ok else 1)
''')
    try:
        with log.open('w') as output:
            child=subprocess.Popen(['/usr/bin/arch','-arm64',protected_tool('lldb'),'--no-lldbinit','-O','plugin disable symbol-file','-O','plugin disable instrumentation-runtime','-O','plugin disable language-runtime.swift','-O','settings set target.detach-on-error true','-O','settings set target.preload-symbols false','-O','settings set symbols.enable-external-lookup false','-O','settings set target.load-script-from-symbol-file false','-p',str(pid),'-o','script exec(compile(open('+repr(str(wrapper))+').read(),"menu_loader","exec"))'],stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT)
            try:code=child.wait(timeout=15)
            except subprocess.TimeoutExpired:child.kill();child.wait(timeout=2);raise RuntimeError('owned debugger timed out and disconnected: '+log.read_text()[-2400:])
        output=log.read_text();assert code==0 and 'MENU_DETACH True LOADED True' in output,output[-2400:]
        end=time.monotonic()+2
        while time.monotonic()<end:
            lib.notify_get_state(cap.value,ctypes.byref(value))
            if value.value:break
            time.sleep(.02)
        assert value.value==1,'application menu modifier did not become ready'
        assert lib.notify_set_state(hold,1)==0
        lib.notify_post(f'hyprwm.menus.v2.request.{pid}'.encode())
        return dict(ok=True,pid=pid,existing=False)
    finally:
        lib.notify_cancel(cap.value);lib.notify_cancel(hold);shutil.rmtree(directory)

if __name__=='__main__':
    assert os.geteuid()==0 and len(sys.argv)==5
    print(json.dumps(load(*map(int,sys.argv[1:]))),flush=True)
