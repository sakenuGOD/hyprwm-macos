#!/usr/bin/env python3
"""Own the optional toolbar session from native events and authenticated WM IPC."""
from __future__ import annotations
import argparse, contextlib, fcntl, hashlib, importlib.util, json, os, select, signal, socket, stat, struct, subprocess, sys, time
from pathlib import Path

HERE=Path(__file__).resolve().parent
HOOK=HERE.parent
sys.path.insert(0,str(HERE/'loader'))
sys.path.insert(0,str(HERE/'dependencies'))
from event_menus import atomic,private_json,sha
from qualified_runtime import LIFECYCLE_SHA,checked_file,private_directory
from root_factory_persistent import create
from lib.model import EventDecoder
from native_companion import Companion,read,recipe


@contextlib.contextmanager
def lock(path):
    path=Path(path);private_directory(path.parent)
    fd=os.open(path,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    try:
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077:raise ValueError('private owned session lock required')
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        yield
    finally:os.close(fd)


def lifecycle():
    path=checked_file(HOOK/'lifecycle.py',LIFECYCLE_SHA)
    spec=importlib.util.spec_from_file_location('_toolbar_owned_lifecycle',path)
    api=importlib.util.module_from_spec(spec);sys.modules[spec.name]=api;spec.loader.exec_module(api)
    return api


class Platform:
    def __init__(self,directory):
        self.directory=private_directory(directory)
        self.config_path=self.directory/'settings.json'
        self.config=private_json(self.config_path)
        value=self.config
        if value.get('schema')!=1 or type(value.get('menus_enabled')) is not bool:raise ValueError('explicit toolbar session configuration required')
        for key in ('runtime','ownership_root','wm_root','wm_executable','control_socket','events_socket','event_helper'):
            path=Path(value[key])
            if not path.is_absolute() or path.resolve()!=path:raise ValueError('canonical configured path required: '+key)
        self.runtime=private_directory(value['runtime']);self.root=Path(value['ownership_root'])
        if self.directory!=self.runtime/'native-toolbar-session':raise ValueError('separate native-toolbar-session namespace required')
        checked_file(value['event_helper'],value['event_helper_sha256'])
        if value.get('bar_backend')!='native':raise ValueError('native toolbar backend required')
        self.settings_sha256=sha(self.config_path)
    def settings(self):return self.config


class Session:
    def __init__(self,directory):
        self.p=Platform(directory);self.directory=self.p.directory;self.api=lifecycle();self.processes=self.api.DarwinProcesses()
        self.companion=Companion(self.p,api=self.api)
        self.control=self.api.Control(self.p.config['control_socket'],self.processes)
        self.adapter=None;self.apps={};self.menu_results={};self.complete=False;self.effective=False;self.last_status=None;self.bar_identity=None
        previous=self.directory/'status.json'
        self.owned_viewport=private_json(previous).get('last_viewport') if previous.exists() else None
        self.reset_requested=None
        self.peer=None;self.stream=None;self.decoder=None;self.session_events=False;self.inventory_ready=False
        self.helper=None;self.helper_identity=None;self.helper_buffer=b'';self.stopping=False;self.error=None
        self.queue=None;self.descriptors=[];self.process_watches=set();self.file_stamps=None
        self.signal_read=None;self.signal_write=None;self.reason='waiting for native startup and authenticated WM'
    def desired(self):
        path=self.directory/'desired.json'
        value=private_json(path) if path.exists() else {'schema':1,'enabled':False,'epoch':None}
        if value.get('schema')!=1 or type(value.get('enabled')) is not bool:raise ValueError('explicit durable toolbar desire required')
        if value['enabled'] and (not isinstance(value.get('epoch'),str) or not value['epoch']):raise ValueError('enabled toolbar epoch required')
        if value['enabled'] and self.p.runtime!=Path.home()/'.config/hyprwm-style':raise ValueError('native toolbar ownership uses the standard per-user runtime')
        return value
    def context(self):return {'enabled':self.effective,'wallpaper_epoch':self.desired().get('epoch')}
    def initialize_menus(self):
        adapters=create(self.p,durable_state=self.context)
        self.adapter=adapters.get('native_menus')
        if self.adapter is None and (self.p.runtime/'native-menus/state/state.json').exists():raise ValueError('retained menu state requires its original grant/key/code')
        if self.adapter:self.adapter.manager.runtime.effect_gate=self.may_effect
    def may_effect(self):return self.desired()['enabled'] and self.gate()
    def owns_companion(self):
        path=self.p.runtime/'native-companion-lifecycle/lifecycle.json'
        if not path.exists():return False
        store=self.companion.runtime()
        with store.lock():record=store.load()
        owner=record['owned'].get('menu')
        return bool(owner and self.companion.role(owner,record.get('launch',{}))=='menu')
    def persist(self,state=None):
        pending_births={tuple(owner['identity']['birth']) for owner in self.adapter.manager.owners.values() if owner.get('phase') in ('ambiguous','pending','suspended')} if self.adapter else set()
        pending_births.update(birth for birth,state in self.menu_results.items() if state=='pending')
        pending=len(pending_births)
        value={'schema':1,'state':state or ('pending' if pending else 'applied' if self.effective else 'pending' if self.desired()['enabled'] else 'off'),
               'pid':os.getpid(),'identity':self.processes.identity(os.getpid()),'helper':self.helper_identity,
               'effective':self.effective,'reason':self.reason,'last_error':self.error,'updated_at':time.time(),
               'desired':self.desired(),'wm_peer':self.peer,'native_inventory_complete':self.complete,
               'wm_session_events':self.session_events,'last_viewport':self.owned_viewport,'menu_pending':pending,'idle_status_polling':False}
        atomic(self.directory/'status.json',value);return value
    def authenticated_status(self):
        text,peer=self.control.request('status',self.peer)
        value=json.loads(text)
        if (peer['birth'][1]!=os.getuid() or peer['executable']!=self.p.config['wm_executable'] or
                value.get('daemon',{}).get('pid')!=peer['pid']):raise ValueError('same-user configured WM generation required')
        self.last_status=value
        if self.owns_companion():self.owned_viewport=value.get('viewport',{}).get('window')
        return value,peer
    def gate(self):
        value,peer=self.authenticated_status()
        if self.effective and self.bar_identity and self.processes.identity(self.bar_identity['pid'])!=self.bar_identity:return False
        return (self.stream is not None and self.session_events and self.decoder.connected and self.peer==peer and
                self.complete and value.get('enabled') is True and value.get('compatibility',{}).get('verified') is True)
    def reset_viewport(self):
        if not self.owns_companion() and self.owned_viewport is None:return True
        try:value,peer=self.authenticated_status()
        except (OSError,ValueError,self.api.LifecycleError):
            # A previously observed active lease cannot be discarded at disconnect.
            old=self.owned_viewport
            return not old or (old.get('x')==0 and old.get('y')==0 and old.get('pending') is False)
        view=value.get('viewport',{}).get('window')
        if view is None:return True
        if view.get('pending') is not False:return False
        if view.get('x')==0 and view.get('y')==0:self.reset_requested=None;return True
        selector=[str(view[k]) for k in ('wid','pid','birth','space')]
        for part in selector:
            if not part or any(c.isspace() for c in part):raise ValueError('exact viewport selector required')
        current_selector=tuple(selector)
        if self.reset_requested==current_selector:return False
        response,_=self.control.request('pan reset '+' '.join(selector),peer)
        if response!=f'content pan queued: {view["wid"]} → 0, 0':return False
        self.reset_requested=current_selector
        after,owner=self.authenticated_status();current=after.get('viewport',{}).get('window')
        return owner==peer and (current is None or (all(current.get(k)==view[k] for k in ('wid','pid','birth','space')) and current.get('pending') is False and current.get('x')==0 and current.get('y')==0))
    def restore(self,disabled):
        disabled=disabled or not self.desired()['enabled']
        self.effective=False
        pending=[]
        if self.adapter:
            pending=self.adapter.manager.disable() if disabled else self.adapter.manager.suspend()
        reset=self.reset_viewport()
        if pending or not reset:
            self.reason='owned menu restoration pending' if pending else 'viewport reset acknowledgement pending'
            return self.persist('pending')
        stopped=self.companion.reconcile(False)
        if stopped.get('drained') is not True:self.reason=stopped.get('reason','companion drain pending');return self.persist('pending')
        self.reason='disabled and restored' if disabled else 'waiting for verified enabled WM'
        return self.persist('off' if disabled else 'pending')
    def reconcile(self,event=None):
        with lock(self.p.runtime/'lock'):
            desired=self.desired()
            try:ready=self.gate() if desired['enabled'] else False
            except (OSError,ValueError,self.api.LifecycleError):ready=False
            if not desired['enabled'] or not ready:return self.restore(not desired['enabled'])
            if self.p.config['menus_enabled']:
                if self.adapter is None:raise ValueError('qualified menu grant required before starting the toolbar')
                manager=self.adapter.manager
                if (manager.grant.get('first_map') or {}).get('mode')!='external-v3':raise ValueError('portable menu session requires separately owned v3 admission')
                manager.runtime.external_server_identity=self.peer
                self.adapter.ensure_handoffs()
            if not self.effective:
                recipe(self.p)
                result=self.companion.reconcile(True,desired['epoch'])
                if result.get('state')!='applied':self.reason=result.get('reason','companion not ready');return self.persist('pending')
                if result.get('identity'):
                    self.bar_identity=result['identity'];self.watch_process(self.bar_identity['pid'])
                if self.adapter and self.p.config['menus_enabled']:
                    activation_path=self.directory/'activation.json'
                    previous=private_json(activation_path) if activation_path.exists() else {}
                    explicit=previous.get('epoch')!=desired['epoch']
                    if explicit:atomic(activation_path,{'schema':1,'epoch':desired['epoch']})
                    pending=self.adapter.manager.resume(explicit_enable=explicit,may_resume=self.may_effect)
                    if pending:self.reason='retained menu resume pending';return self.persist('pending')
                self.effective=True
                if self.adapter and self.p.config['menus_enabled']:
                    for app in self.apps.values():
                        if not self.may_effect():return self.restore(False)
                        self.menu_event({'event':'startup','complete':self.complete,'applications':[app]},app)
            elif self.adapter and self.p.config['menus_enabled'] and event:
                if event.get('event') in ('application_launched','application_activated','application_terminated'):
                    self.menu_event(event,event['application'])
                elif event.get('event')=='admission_changed':
                    self.menu_event({'event':'application_activated','application':event['application']},event['application'])
                self.adapter.manager.resume(may_resume=self.may_effect)
            if not self.may_effect():return self.restore(False)
            self.reason='verified WM and complete native application inventory';self.error=None
            return self.persist()
    def menu_event(self,event,app):
        results=self.adapter.manager.handle(event);birth=tuple(app['birth'])
        if event['event']=='application_terminated':self.menu_results.pop(birth,None);return
        if not isinstance(results,list):results=[results]
        self.menu_results[birth]='pending' if any(value.get('state') in ('pending','ambiguous') for value in results) else 'applied'
    @staticmethod
    def stamp(path):
        try:s=Path(path).lstat();return (s.st_dev,s.st_ino,s.st_mtime_ns,s.st_size)
        except FileNotFoundError:return None
    def stamps(self):
        paths=[self.directory/'desired.json',self.p.config_path,self.p.runtime/'native-menus/grant.json',self.p.runtime/'native-menus/grant.key',
               Path(self.p.config['native_companion']['install_dir'])/'install-manifest.json',Path(self.p.config['events_socket'])]
        return {str(p):self.stamp(p) for p in paths}
    def register(self,ident,kind,flags=0):
        self.queue.control([select.kevent(ident,filter=kind,flags=select.KQ_EV_ADD|select.KQ_EV_ENABLE,fflags=flags)],0,0)
    def watch_process(self,pid):
        if self.queue is not None and pid not in self.process_watches:
            self.register(pid,select.KQ_FILTER_PROC,select.KQ_NOTE_EXIT);self.process_watches.add(pid)
    def disconnect(self):
        if self.stream is not None:
            self.stream.close();self.stream=None
        self.peer=None;self.decoder=None;self.session_events=False
    def connect(self):
        if self.stream is not None:return
        client=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
        try:
            client.settimeout(2);client.connect(self.p.config['events_socket'])
            pid=struct.unpack('=i',client.getsockopt(0,2,4))[0];peer=self.processes.identity(pid)
            if peer is None or peer['birth'][1]!=os.getuid() or peer['executable']!=self.p.config['wm_executable']:raise ValueError('reviewed event-stream peer required')
            text,control=self.control.request('status',peer)
            if control!=peer or json.loads(text).get('daemon',{}).get('pid')!=pid or self.processes.identity(pid)!=peer:raise ValueError('same control/event WM generation required')
            client.setblocking(False);self.register(client.fileno(),select.KQ_FILTER_READ);self.watch_process(pid)
            self.peer=peer;self.stream=client;self.decoder=EventDecoder()
        except Exception:client.close();raise
    def native_event(self,event):
        kind=event.get('event')
        if kind=='startup':
            values=event.get('applications')
            if event.get('complete') is not True or not isinstance(values,list) or len(values)>512:
                self.complete=False;self.reconcile();return
            self.apps={tuple(app['birth']):app for app in values};self.complete=True
        elif kind in ('application_launched','application_activated','admission_changed'):
            app=event['application'];self.apps[tuple(app['birth'])]=app
        elif kind=='application_terminated':
            app=event['application'];self.apps.pop(tuple(app['birth']),None)
        self.reconcile(event)
    def run(self):
        with lock(self.directory/'owner.lock'),lock(self.p.runtime/'session-supervisor/lock'):
            self.initialize_menus();self.queue=select.kqueue()
            self.signal_read,self.signal_write=os.pipe();os.set_blocking(self.signal_read,False);os.set_blocking(self.signal_write,False)
            self.register(self.signal_read,select.KQ_FILTER_READ)
            def stop(*_):
                self.stopping=True
                try:os.write(self.signal_write,b'x')
                except OSError:pass
            signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
            parent=self.processes.identity(os.getpid());birth=':'.join(map(str,parent['birth']))
            command=[self.p.config['event_helper'],'--runtime',str(self.p.runtime),'--owner-pid',str(os.getpid()),'--owner-birth',birth]
            with self.api.open_log(self.directory/'events.log') as log:
                self.helper=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=log,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'})
            try:
                deadline=time.monotonic()+3
                while True:
                    identity=self.processes.identity(self.helper.pid)
                    if identity and identity['executable']==command[0] and identity.get('argv')==command:
                        self.helper_identity=identity;break
                    if self.helper.poll() is not None or time.monotonic()>=deadline:raise ValueError('owned event helper identity not confirmed')
                    time.sleep(.01)
                os.set_blocking(self.helper.stdout.fileno(),False);self.register(self.helper.stdout.fileno(),select.KQ_FILTER_READ)
                paths={self.directory,self.p.runtime,Path(self.p.config['events_socket']).parent,Path(self.p.config['native_companion']['install_dir']),self.p.runtime/'native-menus'}
                for path in paths:
                    if path.is_dir():
                        fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC);self.descriptors.append(fd)
                        self.register(fd,select.KQ_FILTER_VNODE,select.KQ_NOTE_WRITE|select.KQ_NOTE_RENAME|select.KQ_NOTE_DELETE)
                self.file_stamps=self.stamps()
                try:self.connect()
                except (OSError,ValueError,self.api.LifecycleError):pass
                self.persist()
                while not self.stopping:
                    for event in self.queue.control(None,32,None):
                        if self.stopping:break
                        try:
                            if event.filter==select.KQ_FILTER_PROC:
                                self.process_watches.discard(event.ident)
                                if self.peer and event.ident==self.peer['pid']:self.disconnect()
                                if self.bar_identity and event.ident==self.bar_identity['pid']:
                                    with lock(self.p.runtime/'lock'):self.restore(False)
                                    self.bar_identity=None
                                self.reconcile()
                            elif event.filter==select.KQ_FILTER_VNODE:
                                current=self.stamps()
                                if current==self.file_stamps:continue
                                if sha(self.p.config_path)!=self.p.settings_sha256:raise ValueError('configuration changed; observer replacement required')
                                for path in (self.p.runtime/'native-menus/grant.json',self.p.runtime/'native-menus/grant.key'):
                                    if current[str(path)]!=self.file_stamps[str(path)]:raise ValueError('signed menu graph changed; observer replacement required')
                                self.file_stamps=current
                                if self.stream is None:
                                    try:self.connect()
                                    except (OSError,ValueError,self.api.LifecycleError):pass
                                self.reconcile()
                            elif event.ident==self.helper.stdout.fileno():
                                data=os.read(event.ident,65536)
                                if not data:self.complete=False;self.reconcile();raise RuntimeError('native event source ended')
                                self.helper_buffer+=data
                                if len(self.helper_buffer)>1048576:raise ValueError('bounded native event record required')
                                while b'\n' in self.helper_buffer:
                                    line,self.helper_buffer=self.helper_buffer.split(b'\n',1);self.native_event(json.loads(line))
                            elif self.stream and event.ident==self.stream.fileno():
                                data=self.stream.recv(65536)
                                if not data:self.disconnect();self.reconcile();continue
                                for name,value in self.decoder.feed(data):
                                    if value.get('event')=='connected':self.session_events=all(cap in value.get('capabilities',[]) for cap in ('session-gate','viewport-events'))
                                self.reconcile()
                        except (OSError,ValueError,self.api.LifecycleError) as error:
                            self.error=str(error);self.reason='event reconciliation refused';self.disconnect()
                            try:self.reconcile()
                            except Exception as recovery:self.reason='owned restoration pending: '+str(recovery)
                            self.persist('pending')
                            if sha(self.p.config_path)!=self.p.settings_sha256:self.stopping=True
                            if any(self.stamps()[str(path)]!=self.file_stamps[str(path)] for path in (self.p.runtime/'native-menus/grant.json',self.p.runtime/'native-menus/grant.key')):self.stopping=True
            finally:
                # Observer replacement preserves a still-enabled epoch and its
                # retained images. Explicit disable restores under the apply lock.
                if not self.desired()['enabled']:self.reconcile()
                self.disconnect()
                if self.helper.poll() is None:self.helper.terminate()
                self.helper.wait(timeout=3)
                self.helper.stdout.close()
                for fd in self.descriptors+[self.signal_read,self.signal_write]:os.close(fd)
                self.queue.close();self.reason='observer stopped; durable desire retained';self.persist('stopped')


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--runtime',type=Path,required=True)
    args=parser.parse_args();os.umask(0o077);Session(args.runtime/'native-toolbar-session').run()


if __name__=='__main__':main()
