"""Owned native companion lifetime, composed with the existing WM lifecycle.

No GUI, process census, launch or signal occurs on import/construction. The
session supervisor calls reconcile only after its committed-theme gate.
"""
import copy,ctypes,hashlib,importlib.util,json,os,plistlib,stat,subprocess,time
from pathlib import Path

BUNDLE='dev.hyprwm.style.native-bar'
LIMIT=4*1024*1024

def read(path,limit=262144):
    path=Path(path);fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as stream:
        info=os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o022 or info.st_size>limit:raise ValueError('Unsafe companion file')
        data=stream.read(limit+1)
        if len(data)>limit:raise ValueError('Companion file exceeds bound')
    return data

def contract(platform):
    path=Path(platform.settings()['wm_root'])/'hook/lifecycle.py'
    spec=importlib.util.spec_from_file_location('_native_companion_wm_lifecycle',path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module

class Processes:
    def __init__(self,api):self.reader=api.DarwinProcesses()
    def identity(self,pid,read_argv=True):return self.reader.identity(pid,read_argv=read_argv)
    def all(self):return self.reader.all()
    def terminate(self,value):return self.reader.terminate(value)
    def children(self,parent):
        if self.identity(parent['pid'])!=parent:raise RuntimeError('Owned parent generation changed before child discovery')
        function=self.reader.lib.proc_listchildpids
        function.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_int]
        values=(ctypes.c_int*1024)();count=function(parent['pid'],values,ctypes.sizeof(values))
        # libproc's proc_listchildpids returns PID count, unlike proc_listpids'
        # byte count. Verified against a new own child on the installed SDK.
        if count<0 or count>=len(values):raise RuntimeError('Incomplete owned child census')
        result=[value for pid in values[:count] if (value:=self.identity(pid))]
        if self.identity(parent['pid'])!=parent:raise RuntimeError('Owned parent changed during child discovery')
        return result

def configuration(platform):
    options=platform.settings().get('native_companion',{})
    if not isinstance(options,dict) or type(options.get('enabled',False)) is not bool:raise ValueError('native_companion.enabled must be boolean')
    directory=Path(options.get('install_dir',platform.runtime/'native-companion')).expanduser()
    if not directory.is_absolute() or directory.resolve()!=directory:raise ValueError('Canonical companion installation directory required')
    return options,directory

def recipe(platform):
    _,directory=configuration(platform);manifest=json.loads(read(directory/'install-manifest.json'))
    if manifest.get('schema')!=1 or manifest.get('bundle_id')!=BUNDLE or not isinstance(manifest.get('runtime'),dict):raise ValueError('Reviewed companion installation manifest required')
    if manifest.get('autoload_qualified') is not True:raise ValueError('Root actual R7 qualification is required before companion autoload')
    for name,wanted in manifest['runtime'].items():
        relative=Path(name)
        if relative.is_absolute() or '..' in relative.parts:raise ValueError('Unsafe companion manifest path')
        path=directory/relative
        if path.resolve()!=path or hashlib.sha256(read(path,LIMIT)).hexdigest()!=wanted:raise ValueError('Companion installed source/binary changed: '+name)
    binary=directory/'HyprWM Spaces.app/Contents/MacOS/HyprWMSpaces';settings_path=directory/'settings.json'
    required=[str(binary.relative_to(directory)),str(settings_path.relative_to(directory)),
              'HyprWM Spaces.app/Contents/Info.plist','HyprWM Spaces.app/Contents/Resources/bridge.py',
              'HyprWM Spaces.app/Contents/Resources/metadata']
    if any(name not in manifest['runtime'] for name in required):raise ValueError('Incomplete companion production graph')
    settings=json.loads(read(settings_path,65536));resources=binary.parents[1]/'Resources'
    panels=settings.get('own_space_panels_enabled')
    clicks=settings.get('workspace_clicks_enabled')
    if settings.get('presentation')!='left-inline' or type(panels) is not bool or type(clicks) is not bool:raise ValueError('Only qualified inline companion with explicit Space click policy may autoload')
    if manifest.get('own_space_panels_enabled',False) is not panels:raise ValueError('own-Space mode differs from the reviewed installation')
    if panels:
        proof=manifest.get('own_space_qualification',{});source=manifest.get('source_manifest_sha256')
        digest=lambda value:isinstance(value,str) and len(value)==64 and all(c in '0123456789abcdef' for c in value)
        if (not isinstance(proof,dict) or type(proof.get('schema')) is not int or proof['schema']!=1
                or not digest(source) or proof.get('source_manifest_sha256')!=source or not digest(proof.get('evidence_sha256'))
                or any(proof.get(key) is not True for key in ('native_placement_verified','own_windows_only','current_space_pixels_inspected'))
                or any(proof.get(key) is not False for key in ('space_activation_api_called','foreign_window_acted_on'))):
            raise ValueError('own-Space mode requires matching root live qualification without foreign or activation actions')
    if clicks:
        proof=manifest.get('workspace_qualification',{});source=manifest.get('source_manifest_sha256')
        backend=settings.get('workspace_backend')
        required=('actual_button_switch_acknowledged','native_existing_workspace_catalog_verified','actual_return_path_acknowledged') if backend=='wm-native-dock-v1' else ('actual_button_switch_acknowledged','actual_shortcut_create_acknowledged')
        digest=lambda value:isinstance(value,str) and len(value)==64 and all(c in '0123456789abcdef' for c in value)
        if (not isinstance(proof,dict) or type(proof.get('schema')) is not int or proof['schema']!=1
                or not digest(source) or proof.get('source_manifest_sha256')!=source or not digest(proof.get('evidence_sha256'))
                or settings.get('workspace_backend') not in ('wm-verified-public-v1','wm-native-dock-v1') or proof.get('backend')!=settings['workspace_backend']
                or any(proof.get(key) is not True for key in required)):
            raise ValueError('Space clicks require matching actual qualification for the selected workspace backend')
    if settings.get('bridge_script')!=str(resources/'bridge.py') or settings.get('metadata_helper')!=str(resources/'metadata'):raise ValueError('Companion child graph differs from installed bundle')
    info=plistlib.loads(read(binary.parents[1]/'Info.plist',65536))
    if info.get('CFBundleIdentifier')!=BUNDLE or info.get('LSUIElement') is not True:raise ValueError('Exact UIElement companion bundle required')
    python=Path(settings['python_executable']).resolve()
    return {'directory':str(directory),'command':[str(binary),'--settings',str(settings_path)],'python':str(python),'bridge':str(resources/'bridge.py'),'metadata':str(resources/'metadata'),'settings':str(settings_path),'manifest_sha256':hashlib.sha256(read(directory/'install-manifest.json')).hexdigest()}

class Companion:
    def __init__(self,platform,api=None,processes=None,spawn=None,clock=time.monotonic,sleep=time.sleep):
        self.p=platform;self.api=api;self.processes=processes;self.spawn=spawn;self.clock=clock;self.sleep=sleep
    def runtime(self):
        if self.api is None:self.api=contract(self.p)
        if self.processes is None:self.processes=Processes(self.api)
        directory=self.p.runtime/'native-companion-lifecycle'
        return self.api.RecordStore(directory,self.p.root)
    @staticmethod
    def role(value,launch):
        return 'menu' if value.get('executable')==launch['command'][0] and value.get('argv')==launch['command'] else None
    def census(self):
        result=[]
        for value in self.processes.all():
            path=Path(value['executable'])
            if path.name!='HyprWMSpaces':continue
            try:info=plistlib.loads(read(path.parents[1]/'Info.plist',65536))
            except (OSError,ValueError,plistlib.InvalidFileException):continue
            if info.get('CFBundleIdentifier')==BUNDLE:result.append(value)
        return result
    def ensure(self,epoch):
        launch=recipe(self.p);store=self.runtime()
        with store.lock():
            record=store.load();owned=record['owned'].get('menu');found=self.census()
            if owned and self.processes.identity(owned['pid'])==owned:
                if self.role(owned,launch)!='menu' or record.get('launch',{}).get('manifest_sha256')!=launch['manifest_sha256']:raise RuntimeError('Owned companion graph changed; stop exact old generation before upgrade')
                if len(found)!=1 or found[0]['birth']!=owned['birth']:raise RuntimeError('Another companion generation exists; duplicate launch refused')
                return {'state':'applied','already_running':True,'identity':owned,'wm_state_polling':False}
            if any(self.processes.identity(value['pid'])==value for value in record.get('children',[])):
                raise RuntimeError('Prior owned companion children are still alive; drain retained ownership before a new launch')
            if found:raise RuntimeError('Unowned/manual companion exists; root must stop or explicitly adopt it before autoload')
            record['owned'].pop('menu',None);record.update(launch=launch,children=[],intent={'epoch':epoch,'command':launch['command'],'started_at':time.time()});store.save(record)
            def spawn(command,log):
                if self.spawn:pid=self.spawn(command,log)
                else:
                    with self.api.open_log(log) as stream:
                        child=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=stream,stderr=stream,start_new_session=True,cwd=launch['directory'],env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'})
                    pid=child.pid
                record['intent']['pid']=pid;store.save(record);return pid
            life=self.api.Lifecycle(self.p.root,self.processes,None,store,spawn=spawn,clock=self.clock,sleep=self.sleep)
            life.role=lambda identity:self.role(identity,launch)
            identity=life.launch('menu',launch['command'],store.directory/'companion.log',record)
            record.pop('intent',None);store.save(record)
            return {'state':'applied','already_running':False,'identity':identity,'wm_state_polling':False}
    @staticmethod
    def child_allowed(identity,launch):
        argv=identity.get('argv');path=identity.get('executable')
        return (path==launch['python'] and argv==[launch['python'],launch['bridge'],'--settings',launch['settings']]) or (path==launch['metadata'] and argv==[launch['metadata'],'snapshot'])
    def collect_children(self,parent,launch,known):
        for child in self.processes.children(parent):
            if not self.child_allowed(child,launch):raise RuntimeError('Unknown child retained; no broad process cleanup permitted')
            known[tuple(child['birth'])]=child
            # Only a validated bridge can own the configured metadata helper.
            if child['executable']==launch['python']:
                for nested in self.processes.children(child):
                    if not self.child_allowed(nested,launch) or nested['executable']!=launch['metadata']:raise RuntimeError('Unknown bridge child retained')
                    known[tuple(nested['birth'])]=nested
    def stop(self):
        directory=self.p.runtime/'native-companion-lifecycle'
        if not (directory/'lifecycle.json').exists():return {'state':'off','attempted':False,'drained':True}
        store=self.runtime()
        with store.lock():
            record=store.load();owned=record['owned'].get('menu');launch=record.get('launch',{})
            if not owned and record.get('intent'):
                intent=record['intent'];pid=intent.get('pid')
                if (type(pid) is int and self.processes.identity(pid,read_argv=False) is not None) or self.census():
                    return {'state':'pending','reason':'launch_intent_generation_unproven_no_signal','drained':False}
                record.pop('intent',None);store.save(record)
            known={tuple(v['birth']):v for v in record.get('children',[])}
            if owned:
                current=self.processes.identity(owned['pid'])
                if current==owned:
                    if self.role(owned,launch)!='menu':raise RuntimeError('Owned companion command is not verified')
                    self.collect_children(owned,launch,known);record['children']=list(known.values());store.save(record)
                    self.processes.terminate(owned)
                elif current is not None:
                    return {'state':'pending','reason':'owned_pid_reused_no_signal','drained':False}
            deadline=self.clock()+3
            while self.clock()<deadline:
                alive=[v for v in known.values() if self.processes.identity(v['pid'])==v]
                for child in alive:
                    if child['executable']==launch.get('python'):
                        for nested in self.processes.children(child):
                            if not self.child_allowed(nested,launch) or nested['executable']!=launch['metadata']:raise RuntimeError('Unknown bridge child retained')
                            known[tuple(nested['birth'])]=nested
                if not alive and (not owned or self.processes.identity(owned['pid'])!=owned):break
                self.sleep(.05)
            remaining=[v for v in known.values() if self.processes.identity(v['pid'])==v]
            for child in remaining:
                if not self.child_allowed(child,launch):raise RuntimeError('Unverified recorded child is retained')
                self.processes.terminate(child)
            deadline=self.clock()+3
            while self.clock()<deadline and any(self.processes.identity(v['pid'])==v for v in remaining):self.sleep(.05)
            record['children']=[v for v in known.values() if self.processes.identity(v['pid'])==v]
            root_alive=bool(owned and self.processes.identity(owned['pid'])==owned)
            if not root_alive:record['owned'].pop('menu',None)
            if not root_alive and not record['children']:record.pop('intent',None)
            store.save(record)
            if root_alive or record['children']:return {'state':'pending','reason':'owned_processes_not_drained','drained':False}
            return {'state':'off','attempted':bool(owned or known),'drained':True}
    def reconcile(self,enabled,epoch=None):
        try:
            options,_=configuration(self.p)
            backend=self.p.settings().get('bar_backend','native')
            if backend not in ('native','sketchybar'):raise ValueError('bar_backend must be native or sketchybar')
            if enabled and backend=='native' and options.get('enabled') is True:return self.ensure(epoch)
            return self.stop()
        except Exception as error:return {'state':'pending','reason':str(error),'attempted':False,'wm_state_polling':False}
