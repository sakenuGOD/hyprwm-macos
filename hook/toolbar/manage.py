#!/usr/bin/env python3
"""Configure and control the optional, locally qualified toolbar session."""
import argparse,hashlib,json,os,plistlib,secrets,shutil,stat,subprocess,sys,tempfile,time
from pathlib import Path
sys.dont_write_bytecode=True
from session import Session,Platform,lock,private_directory,private_json,atomic,sha,recipe,lifecycle,checked_file
from native_companion import BUNDLE,LIMIT,read

LABEL='dev.hyprwm.toolbar.session'


def build_graph(source):
    if not source.is_absolute() or source.resolve()!=source or not source.is_dir():raise ValueError('canonical toolbar build directory required')
    files=set()
    for index,path in enumerate(source.rglob('*')):
        if index>=4096:raise ValueError('toolbar build exceeds file bound')
        info=path.lstat()
        if path.is_symlink() or path.resolve()!=path or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
            raise ValueError('toolbar build must contain only canonical directories and regular files')
        if stat.S_ISREG(info.st_mode):files.add(str(path.relative_to(source)))
    receipt_data=read(source/'build-receipt.json',1048576);receipt=json.loads(receipt_data)
    manifest=json.loads(read(source/'source-manifest.json',1048576))
    digest=lambda value:isinstance(value,str) and len(value)==64 and all(c in '0123456789abcdef' for c in value)
    if (not isinstance(receipt,dict) or receipt.get('schema')!=1 or receipt.get('architecture')!='arm64' or
            receipt.get('source_manifest_sha256')!=sha(source/'source-manifest.json') or
            not isinstance(manifest,dict) or manifest.get('schema')!=1 or not isinstance(manifest.get('sha256'),dict) or not manifest['sha256']):
        raise ValueError('matching toolbar build receipt and source manifest required')
    for graph in (manifest['sha256'],receipt.get('runtime')):
        if not isinstance(graph,dict) or not graph:raise ValueError('complete toolbar hash graph required')
        for name,wanted in graph.items():
            relative=Path(name)
            if (not name or str(relative)!=name or relative.is_absolute() or '..' in relative.parts or not digest(wanted)):
                raise ValueError('unsafe toolbar hash graph entry')
    if files-{'build-receipt.json','source-manifest.json'}!=set(receipt['runtime']):raise ValueError('toolbar build file inventory differs from its receipt')
    for name,wanted in receipt['runtime'].items():
        if sha_bytes(read(source/name,LIMIT))!=wanted:raise ValueError('toolbar build file changed: '+name)
    if any(receipt.get(key) is not False for key in ('GUI_started','services_changed','live_visual_qualified','workspace_clicks_enabled','wm_state_polling')):
        raise ValueError('fresh unqualified toolbar build receipt required')
    profiles=receipt.get('profiles')
    if not isinstance(profiles,dict) or set(profiles)!={'arm64','arm64e'}:raise ValueError('both unqualified toolbar module profiles required')
    for profile in profiles.values():
        if (not isinstance(profile,dict) or profile.get('qualified') is not False or
                profile.get('external_v3_stage') is not True or not isinstance(profile.get('path'),str) or profile['path'] not in receipt['runtime'] or
                profile.get('sha256')!=receipt['runtime'][profile['path']]):raise ValueError('unqualified toolbar profile differs from its runtime graph')
    required=('HyprWM Spaces.app/Contents/MacOS/HyprWMSpaces','HyprWM Spaces.app/Contents/Info.plist',
              'HyprWM Spaces.app/Contents/Resources/bridge.py','HyprWM Spaces.app/Contents/Resources/metadata',
              'HyprWM Spaces.app/Contents/Resources/session-events',
              'HyprWM Spaces.app/Contents/Resources/hook/toolbar/manage.py','settings.json')
    if any(name not in receipt['runtime'] for name in required):raise ValueError('incomplete packaged toolbar graph')
    info=plistlib.loads(read(source/'HyprWM Spaces.app/Contents/Info.plist',65536))
    if not isinstance(info,dict) or info.get('CFBundleIdentifier')!=BUNDLE or info.get('LSUIElement') is not True:raise ValueError('exact toolbar UIElement bundle required')
    return receipt,sha_bytes(receipt_data)


def sha_bytes(data):
    return hashlib.sha256(data).hexdigest()


def prepare(runtime,source,settings_source):
    source=source.expanduser()
    receipt,receipt_sha256=build_graph(source)
    supplied=json.loads(read(settings_source.expanduser(),65536))
    if not isinstance(supplied,dict):raise ValueError('explicit toolbar settings source required')
    settings=json.loads(read(source/'settings.json',65536))
    if not isinstance(settings,dict) or settings.get('schema')!=1:raise ValueError('toolbar build settings schema1 required')
    for key in ('forest_path','wm_executable'):
        value=supplied.get(key)
        if not isinstance(value,str) or not value or not Path(value).is_absolute() or Path(value).resolve()!=Path(value):
            raise ValueError('explicit canonical '+key+' required')
        settings[key]=value
    executable=Path(settings['wm_executable'])
    checked_file(executable)
    if not executable.stat().st_mode&0o111:raise ValueError('existing executable WM required')
    for key in ('control_socket','events_socket'):
        value=supplied.get(key,settings.get(key))
        if not isinstance(value,str) or not value or not Path(value).is_absolute():raise ValueError('absolute '+key+' required')
        value=str(Path(value).resolve())
        if len(os.fsencode(value))>=104:raise ValueError('bounded '+key+' required')
        settings[key]=value
    directory=runtime/'native-companion'
    if source==directory or source in directory.parents:raise ValueError('companion destination must be outside its build')
    retained=('native-companion','native-companion-lifecycle','native-toolbar-session','native-menus','settings.json','state.json')
    if any((runtime/name).exists() or (runtime/name).is_symlink() for name in retained):
        raise ValueError('existing toolbar or legacy runtime retained; fresh prepare cannot migrate an owned graph')
    private_directory(runtime)
    with lock(runtime/'native-toolbar-prepare.lock'):
        if any((runtime/name).exists() or (runtime/name).is_symlink() for name in retained):
            raise ValueError('existing toolbar or legacy runtime retained; fresh prepare cannot migrate an owned graph')
        with tempfile.TemporaryDirectory(prefix='.native-companion-',dir=runtime) as temporary:
            staged=Path(temporary)/'native-companion';staged.mkdir(mode=0o700)
            shutil.copytree(source/'HyprWM Spaces.app',staged/'HyprWM Spaces.app',symlinks=True)
            for name in ('source-manifest.json','build-receipt.json'):shutil.copy2(source/name,staged/name)
            graph={name:wanted for name,wanted in receipt['runtime'].items() if name.startswith('HyprWM Spaces.app/')}
            copied=list((staged/'HyprWM Spaces.app').rglob('*'))
            if (any(path.is_symlink() or path.resolve()!=path for path in copied) or
                    {str(path.relative_to(staged)) for path in copied if path.is_file()}!=set(graph)):
                raise ValueError('staged toolbar graph differs from its build receipt')
            for name,wanted in graph.items():
                if sha_bytes(read(staged/name,LIMIT))!=wanted:raise ValueError('staged toolbar file changed: '+name)
            if (sha(staged/'source-manifest.json')!=receipt['source_manifest_sha256'] or
                    sha(staged/'build-receipt.json')!=receipt_sha256):raise ValueError('toolbar provenance changed while staging')
            resources=directory/'HyprWM Spaces.app/Contents/Resources'
            status=directory/'hyprwm-native-companion';(staged/status.name).mkdir(mode=0o700)
            settings.update(status_path=str(status/'status.json'),native_ui_status_path=str(status/'ui-status.json'),
                            python_executable=str(Path(sys.executable).resolve()),bridge_script=str(resources/'bridge.py'),
                            metadata_helper=str(resources/'metadata'),presentation='left-inline',own_space_panels_enabled=False,
                            workspace_clicks_enabled=False,b15_menu_enabled=False)
            atomic(staged/'settings.json',settings);graph['settings.json']=sha(staged/'settings.json')
            manifest={'schema':1,'bundle_id':BUNDLE,'source_manifest_sha256':receipt['source_manifest_sha256'],
                      'build_receipt_sha256':sha(staged/'build-receipt.json'),'runtime':graph,'autoload_qualified':False,
                      'root_qualification':'PENDING actual local toolbar, menu access, placement and restoration acceptance',
                      'own_space_panels_enabled':False,'wm_state_polling':False}
            atomic(staged/'install-manifest.json',manifest)
            # Claim the new destination exclusively; no rename may replace an existing graph.
            # Publish the manifest last. A failed publication retains the partial directory.
            directory.mkdir(mode=0o700)
            for child in staged.iterdir():
                if child.name!='install-manifest.json':child.rename(directory/child.name)
            (staged/'install-manifest.json').rename(directory/'install-manifest.json')
    return {'state':'off','prepared':True,'install_dir':str(directory),'manifest':str(directory/'install-manifest.json'),
            'autoload_qualified':False,'live_qualified':False,'app_launched':False,'services_changed':False}


def service_plist(runtime):
    return {'Label':LABEL,'ProgramArguments':[str(Path(sys.executable).resolve()),str(Path(__file__).with_name('session.py').resolve()),'--runtime',str(runtime)],
            'RunAtLoad':True,'KeepAlive':{'SuccessfulExit':False},'ProcessType':'Background','ThrottleInterval':10,
            'EnvironmentVariables':{'PYTHONDONTWRITEBYTECODE':'1'},'StandardOutPath':str(runtime/'native-toolbar-session/observer.log'),
            'StandardErrorPath':str(runtime/'native-toolbar-session/observer.err.log')}


def observer(runtime):
    path=runtime/'native-toolbar-session/status.json'
    if not path.exists():return None
    value=private_json(path);identity=value.get('identity');reader=lifecycle().DarwinProcesses()
    if not identity:return None
    current=reader.identity(identity['pid'])
    if current==identity:return identity
    if current is not None and current.get('birth')!=identity.get('birth'):return None
    try:os.kill(identity['pid'],0)
    except ProcessLookupError:return None
    raise ValueError('recorded observer generation is unreadable; resources retained')


def configure(runtime,configuration):
    directory=private_directory(runtime/'native-toolbar-session')
    with lock(directory/'owner.lock'):
        path=directory/'settings.json'
        if path.exists():raise ValueError('existing session configuration retained; drain and explicitly migrate its owned graph before replacing it')
        value=private_json(configuration)
        if value.get('runtime')!=str(runtime):raise ValueError('configuration runtime must match its selected destination')
        value={**value,'manager':str(Path(__file__).resolve()),'manager_sha256':sha(__file__)}
        atomic(path,value)
        try:Platform(directory)
        except Exception:
            path.unlink();raise
        atomic(directory/'desired.json',{'schema':1,'enabled':False,'epoch':None})
    return {'state':'off','configured':True,'services_changed':False}


def enable(runtime,qualification):
    if runtime!=Path.home()/'.config/hyprwm-style':raise ValueError('native toolbar ownership uses the standard per-user runtime')
    directory=runtime/'native-toolbar-session'
    with lock(directory/'intent.lock'):
        desire_path=directory/'desired.json';previous_desire=sha(desire_path) if desire_path.exists() else None
    with lock(runtime/'lock'):
        session=Session(directory);session.initialize_menus();launch=recipe(session.p)
        accepted=private_json(qualification)
        if (accepted.get('schema')!=1 or accepted.get('companion_manifest_sha256')!=launch['manifest_sha256'] or
                accepted.get('settings_sha256')!=session.p.settings_sha256):raise ValueError('matching actual local toolbar acceptance required')
        evidence=accepted.get('evidence',[])
        if not evidence or len(evidence)>32:raise ValueError('bounded actual qualification evidence required')
        for proof in evidence:
            if sha(proof['path'])!=proof['sha256']:raise ValueError('qualification evidence changed')
        if any(accepted.get(key) is not True for key in ('original_menu_access_verified','owned_panel_placement_verified','disable_restore_verified')):
            raise ValueError('actual toolbar/menu/restore acceptance is incomplete')
        if session.p.config['menus_enabled']:
            if session.adapter is None:raise ValueError('qualified signed menu grant is absent')
            grant=session.adapter.manager.grant
            if (grant.get('first_map') or {}).get('mode')!='external-v3':raise ValueError('separate qualified v3 admission required')
            profiles=grant.get('profiles',{})
            if not profiles or any(p.get('qualified') is not True or p.get('external_v3_stage') is not True for p in profiles.values()):raise ValueError('actual external-menu architecture qualification required')
            if accepted.get('menu_grant_sha256')!=sha(runtime/'native-menus/grant.json'):raise ValueError('actual acceptance does not match the signed menu graph')
        with lock(directory/'intent.lock'):
            if (sha(desire_path) if desire_path.exists() else None)!=previous_desire:raise ValueError('newer toolbar intent superseded this enable request')
            atomic(directory/'acceptance.json',accepted)
            atomic(desire_path,{'schema':1,'enabled':True,'epoch':secrets.token_hex(24),'qualification_sha256':sha(qualification)})
    return {'state':'pending','reason':'enabled intent recorded; observer must confirm runtime acceptance'}


def disable(runtime,*,offline=False,timeout=30):
    directory=runtime/'native-toolbar-session'
    if not (directory/'settings.json').exists():return {'state':'off','drained':True,'configured':False}
    with lock(directory/'intent.lock'):
        value=private_json(directory/'desired.json') if (directory/'desired.json').exists() else {'schema':1,'epoch':None}
        atomic(directory/'desired.json',{**value,'enabled':False})
    current=observer(runtime)
    if offline and current:raise ValueError('offline removal refuses a live toolbar observer')
    if not current:
        with lock(directory/'owner.lock'),lock(runtime/'session-supervisor/lock'):
            session=Session(directory);session.initialize_menus()
            result=session.reconcile()
        return {**result,'drained':result['state']=='off'}
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        value=private_json(directory/'status.json')
        if value.get('identity')==current and value.get('state')=='off' and value.get('desired',{}).get('enabled') is False:
            return {**value,'drained':True}
        if observer(runtime)!=current:raise ValueError('observer changed before restoration confirmation; installation retained')
        time.sleep(.05)
    return {'state':'pending','drained':False,'reason':'owned toolbar restoration is still pending'}


def install_service(runtime):
    Platform(runtime/'native-toolbar-session')
    path=Path.home()/'Library/LaunchAgents'/f'{LABEL}.plist'
    value=service_plist(runtime)
    if path.exists() or path.is_symlink():
        if path.is_symlink() or plistlib.loads(path.read_bytes())!=value:raise ValueError('another LaunchAgent configuration was retained')
        raise ValueError('toolbar LaunchAgent already exists; inspect its current identity before restarting')
    path.parent.mkdir(parents=True,exist_ok=True)
    data=plistlib.dumps(value);path.write_bytes(data);path.chmod(0o600)
    result=subprocess.run(['/bin/launchctl','bootstrap',f'gui/{os.getuid()}',str(path)],capture_output=True,text=True,timeout=12)
    if result.returncode:raise ValueError('LaunchAgent bootstrap refused: '+result.stderr[-400:])
    return {'state':'pending','service_installed':True}


def remove_service(runtime,offline=False):
    result=disable(runtime,offline=offline)
    if result.get('drained') is not True:return result
    path=Path.home()/'Library/LaunchAgents'/f'{LABEL}.plist'
    expected=service_plist(runtime)
    if path.exists():
        if path.is_symlink() or plistlib.loads(path.read_bytes())!=expected:raise ValueError('unowned toolbar LaunchAgent retained')
        identity=observer(runtime);helper=result.get('helper')
        if offline and identity:raise ValueError('offline removal refuses a live toolbar observer')
        value=subprocess.run(['/bin/launchctl','bootout',f'gui/{os.getuid()}/{LABEL}'],capture_output=True,text=True,timeout=15)
        if value.returncode and 'Could not find service' not in value.stderr:raise ValueError('observer stop not confirmed; code retained')
        deadline=time.monotonic()+5
        while observer(runtime) is not None:
            if time.monotonic()>=deadline:raise ValueError('observer drain pending; code retained')
            time.sleep(.05)
        if helper:
            reader=lifecycle().DarwinProcesses();deadline=time.monotonic()+5
            while True:
                current=reader.identity(helper['pid'],read_argv=False)
                if current is not None and current['birth']!=helper['birth']:break
                if current is None:
                    try:os.kill(helper['pid'],0)
                    except ProcessLookupError:break
                if time.monotonic()>=deadline:raise ValueError('owned event helper drain pending; code retained')
                time.sleep(.05)
        path.unlink()
    elif observer(runtime) is not None:raise ValueError('manual toolbar observer is alive; code retained')
    return {**result,'service_removed':True}


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--runtime',type=Path,default=Path.home()/'.config/hyprwm-style')
    commands=parser.add_subparsers(dest='action',required=True)
    command=commands.add_parser('prepare',help='Stage a new disabled companion; actual local qualification is still required')
    command.add_argument('--source',type=Path,default=Path(__file__).resolve().parents[5],help='Raw toolbar build directory (defaults to this packaged toolbar)')
    command.add_argument('--settings-source',type=Path,required=True,help='Owned JSON with explicit forest_path and wm_executable; optional IPC paths')
    command=commands.add_parser('configure');command.add_argument('--configuration',type=Path,required=True)
    command=commands.add_parser('enable');command.add_argument('--qualification',type=Path,required=True)
    commands.add_parser('install-service');commands.add_parser('status');commands.add_parser('disable')
    command=commands.add_parser('remove-service');command.add_argument('--offline',action='store_true')
    args=parser.parse_args();os.umask(0o077);runtime=args.runtime.expanduser()
    if not runtime.is_absolute() or runtime.resolve()!=runtime:raise ValueError('canonical absolute runtime required')
    if args.action=='prepare':value=prepare(runtime,args.source,args.settings_source)
    elif args.action=='configure':value=configure(runtime,args.configuration)
    elif args.action=='enable':value=enable(runtime,args.qualification)
    elif args.action=='disable':value=disable(runtime)
    elif args.action=='install-service':value=install_service(runtime)
    elif args.action=='remove-service':value=remove_service(runtime,args.offline)
    else:value=private_json(runtime/'native-toolbar-session/status.json')
    print(json.dumps(value,sort_keys=True));return 1 if value.get('drained') is False else 0


if __name__=='__main__':
    try:raise SystemExit(main())
    except (OSError,ValueError,RuntimeError) as error:print(str(error),file=sys.stderr);raise SystemExit(1)
