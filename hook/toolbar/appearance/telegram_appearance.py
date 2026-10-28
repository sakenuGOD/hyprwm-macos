"""Telegram-only main appearance on existing session events; never real focus."""
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import time

from .source_support import atomic, contract, read

BUNDLE='ru.keepcoder.Telegram'
EXECUTABLE='/Applications/Telegram.app/Contents/MacOS/Telegram'
LIFECYCLE_SHA='9943ac9b93596617fc08d9fb04bdb4d7467e43ff44ed88c79eda78034005cc33'


class PreparationPending(ValueError):
    """The generated controller refused before any native operation."""


def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class TelegramAppearanceAdapter:
    def __init__(self,platform,runner=None,identity=None):
        self.p=platform;self.root=platform.runtime/'telegram-main-only'
        self.run=runner or subprocess.run
        self.identity=identity or (lambda pid:contract(platform).DarwinProcesses().identity(pid,read_argv=False))
    def policy(self):
        value=json.loads(read(self.root/'policy.json'))
        if value.get('enabled') is not True or value.get('bundle')!=BUNDLE or value.get('executable')!=EXECUTABLE:
            raise ValueError('Explicit enabled Telegram-only policy required')
        if any(value.get(k) is not False for k in ('allow_activation','allow_input','allow_restart')):
            raise ValueError('Only main appearance without focus/input/restart is authorized')
        for key in ('template','body','metadata','module'):
            if digest(value[key])!=value[key+'_sha256']:raise ValueError('Telegram native source pin changed: '+key)
        lifecycle=Path(value['lifecycle'])
        expected=Path(self.p.settings()['wm_root'])/'hook/lifecycle.py'
        if (lifecycle.is_symlink() or lifecycle!=lifecycle.resolve(strict=True) or lifecycle!=expected.resolve(strict=True)
                or value.get('lifecycle_sha256')!=LIFECYCLE_SHA or digest(lifecycle)!=LIFECYCLE_SHA):
            raise ValueError('Reviewed Telegram lifecycle dependency required')
        return value
    def matches(self,identity,application):
        return identity.get('executable')==EXECUTABLE and application.get('bundle_id')==BUNDLE
    def save(self,path,value):
        atomic(path,(json.dumps(value,indent=2)+'\n').encode())
    def owner(self,policy,identity):
        path=Path(policy.get('adopted_token',''))
        if not path.is_file():return None
        token=json.loads(read(path));proof=json.loads(read(token['source_receipt']))
        if token.get('identity')!=identity:return None
        if digest(token['source_receipt'])!=token['source_receipt_sha256'] or token.get('module_sha256')!=policy['module_sha256']:
            raise ValueError('Current Telegram original handle chain changed')
        if proof.get('ok') is not True or proof.get('detached') is not True or proof.get('native',{}).get('force_main_after') is not True:
            raise ValueError('Current Telegram native main-only apply not qualified')
        return {'identity':identity,'wid':token['wid'],'token':str(path),'proof':token['source_receipt'],'adopted':True}
    def descriptor(self,policy,identity):
        value=self.run([policy['metadata'],'snapshot'],capture_output=True,text=True,timeout=6,check=True)
        snapshot=json.loads(value.stdout)
        if snapshot.get('available') is not True or snapshot.get('census_complete') is not True:
            raise ValueError('Complete native census required')
        windows=[w for w in snapshot['windows'] if w.get('pid')==identity['pid'] and w.get('process_birth')==identity['birth'] and w.get('bundle')==BUNDLE and w.get('layer')==0 and len(w.get('bounds',[]))==4 and w['bounds'][2]>=120 and w['bounds'][3]>=120 and w.get('spaces')]
        if len(windows)!=1:raise ValueError('Exactly one native Telegram primary candidate required')
        return windows[0]['wid']
    def prepare(self,policy,identity,folder,wid):
        template=Path(policy['template']).read_text();source=Path(policy['template']).parent
        controller=folder/'appearance-controller.py';manifest=folder/'controller-manifest.json'
        code=template
        start=code.index('def production_target_matches(');end=code.index('\nBODY=',start)
        code=code[:start]+"def production_target_matches(i,wid,u):\n return i=="+repr(identity)+" and wid=="+str(wid)+" and u=="+repr(policy['main_uuid'])+code[end:]
        code=code.replace("MODULE=HERE.parent/'Appearance.arm64.dylib'",'MODULE=Path('+repr(policy['module'])+')')
        code=code.replace("BODY=(HERE/'driver-body.txt').read_text()",'BODY=Path('+repr(policy['body'])+').read_text()')
        code=code.replace("manifest=read(HERE/'driver-manifest-v4-current.json')",'manifest=read('+repr(str(manifest))+')')
        code,count=re.subn(r"^LIFE=Path\([^\n]+\)$",'LIFE=Path('+repr(policy['lifecycle'])+')',code,flags=re.MULTILINE)
        if count!=1:raise PreparationPending('Expected lifecycle path declaration missing')
        code,count=re.subn(r"^LIFE_SHA='[0-9a-f]{64}'$",'LIFE_SHA='+repr(policy['lifecycle_sha256']),code,flags=re.MULTILINE)
        if count!=1:raise PreparationPending('Expected lifecycle pin declaration missing')
        code=re.sub(r"DEADLINE=datetime.datetime.fromisoformat\('[^']+'\)", 'DEADLINE=datetime.datetime.fromisoformat('+repr((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=2)).isoformat())+')',code)
        code=code.replace("HERE/'own-runs'",'Path('+repr(str(self.root))+')')
        compile(code,str(controller),'exec');controller.write_text(code);controller.chmod(0o600)
        pins=json.loads((source/'driver-manifest-v3.json').read_text());pins['pins'][str(controller)]=digest(controller);self.save(manifest,pins)
        identity_path=folder/'identity.json';self.save(identity_path,identity)
        common=['--run','--identity',str(identity_path),'--pid',str(identity['pid']),'--wid',str(wid),'--main-uuid',policy['main_uuid'],'--artifact-dir',policy['artifact_dir'],'--operation-epoch','appearance-owner-request-20261017-2216','--lease-token','coordinator']
        # The controller's existing plan validates its complete pinned graph
        # without querying a PID, creating an output directory or attaching.
        prepared=self.run([policy['python'],str(controller),'status','--plan',*common[1:],'--output',str(folder/'status')],capture_output=True,text=True,timeout=8,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'})
        try:plan=json.loads(prepared.stdout) if prepared.returncode==0 else {}
        except (TypeError,ValueError):plan={}
        if plan.get('prepared_only') is not True or plan.get('PID_queried') is not False or plan.get('attach') is not False:
            raise PreparationPending('Telegram controller preflight refused; no attach: '+str(prepared.stderr)[-400:])
        self.save(folder/'preflight.json',{'identity':identity,'controller_sha256':digest(controller),'lifecycle_sha256':policy['lifecycle_sha256'],'plan':plan,'native_attempted':False})
        return controller,common
    def apply(self,policy,identity,folder,wid):
        try:controller,common=self.prepare(policy,identity,folder,wid)
        except Exception as error:raise PreparationPending(str(error)) from error
        # A crash after this durable barrier cannot re-run an unknown ON.
        self.save(folder/'owner.json',{'identity':identity,'quarantined':True,'reason':'native operation in progress','attempt':str(folder/'attempt.json')})
        for action in ['status','on-main-only']:
            output=folder/('status' if action=='status' else 'on')
            command=[policy['python'],str(controller),action,*common,'--output',str(output)]
            if action=='on-main-only':command+=['--prior-status',str(folder/'status/postflight.json')]
            self.save(folder/'attempt.json',{'identity':identity,'action':action,'phase':'native_intent','controller_sha256':digest(controller),'time':time.time()})
            result=self.run(command,capture_output=True,text=True,timeout=32,env={**os.environ,'PYTHONDONTWRITEBYTECODE':'1'})
            if result.returncode:raise ValueError('Native Telegram operation refused; no retry: '+result.stdout[-400:]+result.stderr[-400:])
        proof=json.loads(read(folder/'on/postflight.json'))
        if (proof.get('identity')!=identity or proof.get('expected_wid')!=wid or proof.get('action')!=3
                or proof.get('main_uuid')!=policy['main_uuid'] or proof.get('module_sha256')!=policy['module_sha256']
                or proof.get('ok') is not True or proof.get('detached') is not True
                or any(proof.get(k) is not True for k in ('identity_after_detach','identity_after_state_query','not_stopped_after_detach','handle_retained','buffer_freed'))
                or proof.get('native',{}).get('nonappearance_state_unchanged') is not True
                or proof.get('native',{}).get('force_main_after') is not True or self.identity(identity['pid'])!=identity):
            raise ValueError('Telegram native focus-preservation proof missing')
        return {'identity':identity,'wid':wid,'token':str(folder/'on/handle-token.json'),'proof':str(folder/'on/postflight.json'),'adopted':False}
    def handle(self,event,context,identity,application,palette):
        policy=self.policy()
        if event=='off':
            return {'state':'skipped','attempted':False,'reason':'main-only policy persists across observer/palette restart; explicit original-token OFF only'}
        if identity is None:
            for path in sorted(self.root.glob('birth-*/owner.json'))[-16:]:
                owner=json.loads(read(path));current=owner.get('identity',{})
                if not owner.get('quarantined') and current.get('pid') and self.identity(current['pid'])==current:
                    return {'state':'applied','attempted':False,'reason':'owned Telegram main-only preserved','pid':current['pid'],'wid':owner['wid'],'actual_focus_modified':False,'network_state_qualified':False}
            return {'state':'pending','attempted':False,'reason':'waiting for authenticated Telegram event'}
        if context.get('apply_lock_held') is not True or any(context.get(k) is not False for k in ('allow_restart','allow_input','allow_true_focus','allow_core_reset')):
            raise ValueError('Locked no-focus session context required')
        if not self.matches(identity,application) or self.identity(identity['pid'])!=identity:raise ValueError('Fresh Telegram generation required')
        key='-'.join(map(str,identity['birth']));folder=self.root/('birth-'+key);folder.mkdir(mode=0o700,parents=True,exist_ok=True)
        state=folder/'owner.json'
        if state.exists():
            owner=json.loads(read(state))
            if owner.get('quarantined'):return {'state':'pending','attempted':False,'reason':'native uncertainty quarantined; no retry'}
            if owner.get('identity')!=identity:raise ValueError('Telegram owner generation mismatch')
        else:
            owner=self.owner(policy,identity)
            if owner is None:
                uuid_result=self.run(['xcrun','dwarfdump','--uuid',EXECUTABLE],capture_output=True,text=True,timeout=5,check=True)
                if not any(policy['main_uuid']==line.split()[1].replace('-','').lower() for line in uuid_result.stdout.splitlines() if '(arm64)' in line):raise ValueError('Telegram update needs renewed UUID qualification')
                wid=self.descriptor(policy,identity)
                try:owner=self.apply(policy,identity,folder,wid)
                except PreparationPending as error:
                    self.save(folder/'preparation-failure.json',{'identity':identity,'reason':str(error),'native_attempted':False,'time':time.time()});raise
                except Exception as error:
                    self.save(state,{'identity':identity,'quarantined':True,'reason':str(error),'attempt':str(folder/'attempt.json')});raise
            self.save(state,owner)
        return {'state':'applied','attempted':False,'reason':'owned Telegram main-only','pid':identity['pid'],'wid':owner['wid'],'actual_focus_modified':False,'network_state_qualified':False}


def create(platform):
    if not (platform.runtime/'telegram-main-only/policy.json').is_file():return {}
    return {'active_appearance':TelegramAppearanceAdapter(platform)}
