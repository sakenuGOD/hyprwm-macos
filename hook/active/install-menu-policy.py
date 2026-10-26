#!/usr/bin/env python3
"""Install or remove the optional, reversible native application-menu policy."""
from pathlib import Path
import argparse, importlib.util, os, plistlib, pwd, stat, subprocess, time

def checked_directory(path):
    if not path.exists(): path.mkdir(mode=0o700)
    info=path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid!=0 or info.st_mode&0o022:
        raise RuntimeError('Installation directory must be owned and writable only by root: '+str(path))

def atomic_write(path,data,mode):
    temporary=path.with_name(path.name+'.new')
    fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,mode)
    try:
        with os.fdopen(fd,'wb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
        os.replace(temporary,path)
    finally:
        try:temporary.unlink()
        except FileNotFoundError:pass

def command(*arguments):
    return subprocess.run(arguments,capture_output=True,text=True,timeout=20)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['install','uninstall'])
    parser.add_argument('--uid',type=int,default=int(os.environ.get('SUDO_UID','0')))
    args=parser.parse_args()
    if os.geteuid()!=0 or args.uid<=0:parser.error('Run through sudo with the target user UID.')
    pwd.getpwuid(args.uid)
    source=Path(__file__).resolve().parent
    parent=Path('/Library/Application Support/HyprWM')
    folder=parent/('menu-policy-'+str(args.uid))
    label='dev.hyprwm.application-menus.'+str(args.uid)
    plist=Path('/Library/LaunchDaemons')/(label+'.plist')
    spec=importlib.util.spec_from_file_location('menu_inject',source/'menu-inject.py')
    loader=importlib.util.module_from_spec(spec);spec.loader.exec_module(loader)
    python=loader.protected_tool('python3');loader.protected_tool('lldb')
    interpreter=['/bin/launchctl','asuser',str(args.uid),'/usr/bin/arch','-arm64',python,'-I','-S']
    if args.action=='install':
        for name in ['menu-policy.py','menu-inject.py','hyprmenus.dylib','first-map-inject.py','first-map-load.py','hypradmission.v2.dylib']:
            if not (source/name).is_file():parser.error('Missing '+name+'; run hook/active/build.sh first.')
        result=command('/usr/bin/codesign','--verify','--strict',str(source/'hyprmenus.dylib'))
        if result.returncode:raise RuntimeError(result.stderr)
        result=command('/usr/bin/codesign','--verify','--strict',str(source/'hypradmission.v2.dylib'))
        if result.returncode:raise RuntimeError(result.stderr)
    # Stop only this policy, allowing its exit handler to restore menu entries.
    command('/bin/launchctl','bootout','system/'+label)
    deadline=time.monotonic()+20
    while command('/bin/launchctl','print','system/'+label).returncode==0:
        if time.monotonic()>=deadline:
            raise RuntimeError('Previous menu policy is still registered; files were preserved.')
        time.sleep(.1)
    if folder.exists():
        checked_directory(folder)
        if (folder/'menu-policy.py').is_file():
            result=command(*interpreter,str(source/'menu-policy.py'),'--uid',str(args.uid),'--restore')
            if result.returncode:raise RuntimeError('Menu restoration failed: '+result.stderr)
    if args.action=='uninstall':
        if plist.exists():plist.unlink()
        # Retain installed code/logs for recovery; no module is unloaded from apps.
        print('Application menus restored; policy disabled.')
        return
    checked_directory(parent);checked_directory(folder)
    for name in ['menu-policy.py','menu-inject.py','hyprmenus.dylib','first-map-inject.py','first-map-load.py','hypradmission.v2.dylib']:
        atomic_write(folder/name,(source/name).read_bytes(),0o600)
    value=dict(Label=label,ProgramArguments=interpreter+[str(folder/'menu-policy.py'),'--uid',str(args.uid)],
               RunAtLoad=True,KeepAlive=True,ThrottleInterval=10,ProcessType='Standard',
               StandardOutPath=str(folder/'agent.log'),StandardErrorPath=str(folder/'agent.log'))
    atomic_write(plist,plistlib.dumps(value),0o644)
    result=command('/bin/launchctl','bootstrap','system',str(plist))
    if result.returncode:raise RuntimeError(result.stderr)
    print('Application-menu policy installed for UID '+str(args.uid)+'.')

if __name__=='__main__':main()
