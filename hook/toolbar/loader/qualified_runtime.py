"""Concrete event-only, exact-self C ABI runtime. No attach on import.

All effects require a verified enabled root grant. The only debugger target is
the exact event birth; importing this source never discovers or queries a PID.
"""
from __future__ import annotations
import ctypes,fcntl,hashlib,importlib.util,json,os,plistlib,socket,stat,subprocess,time,uuid
from pathlib import Path
from event_menus import InstalledBundles,PreparationPending,atomic,canonical,grant_includes_logic,identity,private_json,sha,signed_grant

HERE=Path(__file__).resolve().parent
LIFECYCLE=HERE.parents[1]/'lifecycle.py'
LIFECYCLE_SHA='9943ac9b93596617fc08d9fb04bdb4d7467e43ff44ed88c79eda78034005cc33'

def checked_file(path,digest=None):
 p=Path(path)
 if p.is_symlink() or p.absolute()!=p.resolve(strict=True):raise ValueError('canonical trusted file required')
 s=p.stat()
 if not stat.S_ISREG(s.st_mode) or s.st_uid!=os.getuid() or s.st_mode&0o022:raise ValueError('owned non-writable trusted source required')
 if digest and sha(p)!=digest:raise ValueError('source/module digest mismatch')
 return p
def private_directory(path):
 p=Path(path);p.mkdir(mode=0o700,parents=True,exist_ok=True);s=p.lstat()
 if p.is_symlink() or not stat.S_ISDIR(s.st_mode) or s.st_uid!=os.getuid() or s.st_mode&0o077:raise ValueError('owned private operation directory required')
 return p.resolve()
def native_identity(pid):
 checked_file(LIFECYCLE,LIFECYCLE_SHA)
 spec=importlib.util.spec_from_file_location('menus_native_birth',LIFECYCLE);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
 return m.DarwinProcesses().identity(pid,read_argv=False)
def sandboxed(executable):
 v=subprocess.run(['/usr/bin/codesign','-d','--entitlements',':-',executable],capture_output=True,timeout=3)
 if v.returncode:raise ValueError('installed executable signature/entitlement discovery refused')
 out=v.stdout;start=out.find(b'<?xml')
 if start<0:start=out.find(b'<plist')
 return bool(plistlib.loads(out[start:]).get('com.apple.security.app-sandbox',False)) if start>=0 else False

class QualifiedRuntime:
 def __init__(self,directory,grant_path,key):
  self.directory=private_directory(directory);self.grant_path=Path(grant_path).resolve(strict=True);self.key=key
  self._grant=self.grant()
  self.bundles=InstalledBundles(self._grant.get('logic_info_plist'),self._grant.get('logic_info_sha256'),include_logic=grant_includes_logic(self._grant))
  self.source_pins={name:sha(HERE/name) for name in ('qualified_runtime.py','generic-driver.txt','qualified-symbols.txt')}
  for name,digest in self._grant['runtime_source_pins'].items():checked_file(HERE/name,digest)
  if self.source_pins!=self._grant['runtime_source_pins']:raise ValueError('complete exact runtime source pins required')
  checked_file(LIFECYCLE,LIFECYCLE_SHA)
 def grant(self):
  v=signed_grant(self.grant_path,self.key)
  grant_includes_logic(v)
  if v.get('schema')!=1 or any(v.get(k) is not False for k in ('allow_activation','allow_input','allow_restart')):raise ValueError('explicit menu-only root grant required')
  return v
 def identity(self,pid):return native_identity(pid)
 def generation_retired(self,previous):
  # No debugger or application call: only a kernel process-generation witness.
  # A missing identity alone may mean unreadable, so it cannot retire a lease.
  current=self.identity(previous['pid'])
  if current is not None:
   birth=current.get('birth')
   return (type(birth)==list and len(birth)==4 and all(type(n)==int for n in birth) and
           birth[0]==previous['pid'] and birth[1]==os.getuid() and birth[2]>0 and 0<=birth[3]<1000000 and
           birth!=previous['birth'])
  try:os.kill(previous['pid'],0)
  except ProcessLookupError:return True
  except OSError:return False
  return False
 def first_map_server(self,policy):
  path=Path('/tmp')/('hyprwm-admission-'+str(os.getuid()))/'service.sock'
  parent=path.parent.lstat();before=path.lstat()
  if not stat.S_ISDIR(parent.st_mode) or parent.st_uid!=os.getuid() or parent.st_mode&0o077 or not stat.S_ISSOCK(before.st_mode) or before.st_uid!=os.getuid() or before.st_mode&0o077:raise ValueError('private first-map server required')
  with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as peer:
   peer.settimeout(.25);peer.connect(str(path));pid=peer.getsockopt(0,2) # Darwin SOL_LOCAL / LOCAL_PEERPID
   server=self.identity(pid);after=path.lstat()
   if not server or server['birth'][1]!=os.getuid() or server['executable']!=policy['server_executable'] or (before.st_dev,before.st_ino)!=(after.st_dev,after.st_ino) or self.identity(pid)!=server:raise ValueError('exact first-map server generation required')
  return server
 def first_map_container(self,i,d,server):
  if not sandboxed(d['executable']):return None
  container=Path.home()/'Library/Containers'/d['bundle_id']/'Data'
  if container.is_symlink() or container.absolute()!=container.resolve(strict=True):raise ValueError('canonical sandbox container required')
  self.artifact_base(d) # Verify the installed sandbox container metadata.
  directory=private_directory(container/'.hwm')
  path=str(directory/('s'+str(i['pid'])))
  if len(os.fsencode(path))>=104:raise ValueError('sandbox first-map UNIX path too long')
  request={'birth':i['birth'],'executable':i['executable'],'server_executable':server['executable'],'socket':path}
  with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as control:
   control.settimeout(1);control.connect('/tmp/hyprwm.ctl')
   if self.identity(control.getsockopt(0,2))!=server:raise ValueError('exact first-map control server required')
   control.sendall(b'firstmap-listen '+canonical(request)+b'\n')
   if control.makefile('rb').readline(8192).decode().strip()!=path:raise ValueError('sandbox first-map listener not ready')
  return directory
 def ensure_first_map_grant(self,i,d,grant):
  policy=grant.get('first_map')
  if policy is None:return False
  if type(policy)!=dict or type(policy.get('enabled'))!=bool:raise ValueError('explicit signed first-map policy required')
  revoking=policy['enabled'] is False
  if not revoking and (type(policy.get('server_executable'))!=str or not policy['server_executable'].startswith('/')):raise ValueError('exact first-map server executable required')
  if (not grant_includes_logic(grant) and d.get('bundle_id')==self.bundles.logic_id) or d['executable'] in policy.get('protected_executables',[]):raise ValueError('protected application cannot receive first-map grant')
  if policy.get('mode')=='external-v3':
   if revoking:return False # The WM owns admission; this loader never revokes it.
   server=self.first_map_server(policy)
   expected=getattr(self,'external_server_identity',None)
   if not expected or {k:expected[k] for k in ('pid','birth','executable')}!={k:server[k] for k in ('pid','birth','executable')}:raise ValueError('authenticated current WM admission owner required')
   directory=Path('/Library/Application Support/HyprWM/Admission Bindings')/str(os.getuid())
   for parent in (directory,*directory.parents):
    info=parent.lstat()
    if parent.is_symlink() or info.st_uid!=0 or not stat.S_ISDIR(info.st_mode) or info.st_mode&0o022:raise ValueError('root-owned admission binding directory required')
   path=directory/('-'.join(map(str,i['birth']))+'.json')
   fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK|os.O_CLOEXEC)
   with os.fdopen(fd,'rb') as stream:
    info=os.fstat(stream.fileno())
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=0 or info.st_mode&0o022 or not 0<info.st_size<=65536:raise ValueError('bounded root admission proof required')
    raw=stream.read(65537);after=os.fstat(stream.fileno())
    if len(raw)!=info.st_size or (info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns):raise ValueError('admission proof changed during read')
   binding=json.loads(raw);target=binding.get('target',{})
   if (binding.get('schema')!=1 or binding.get('version')!=3 or binding.get('installed') is not True or binding.get('detached') is not True or
       target.get('birth')!=i['birth'] or target.get('executable')!=i['executable'] or
       str(target.get('main_uuid','')).replace('-','').lower() not in {image['main_uuid'].replace('-','').lower() for image in d['images']} or
       binding.get('server')!={k:server[k] for k in ('pid','birth','executable')} or
       binding.get('module_sha256') not in policy.get('module_sha256',[])):
    raise ValueError('accepted loaded-v3 target/current-server binding required')
   library=ctypes.CDLL('/usr/lib/libSystem.B.dylib');token=ctypes.c_int();state=ctypes.c_uint64()
   library.notify_register_check.argtypes=[ctypes.c_char_p,ctypes.POINTER(ctypes.c_int)]
   library.notify_get_state.argtypes=[ctypes.c_int,ctypes.POINTER(ctypes.c_uint64)]
   library.notify_cancel.argtypes=[ctypes.c_int]
   if library.notify_register_check(f'hyprwm.admission.v3.cap.{i["pid"]}'.encode(),ctypes.byref(token))!=0:raise ValueError('v3 admission readiness unavailable')
   try:
    if library.notify_get_state(token.value,ctypes.byref(state))!=0 or state.value!=1 or self.identity(i['pid'])!=i or self.identity(server['pid'])!=server:raise ValueError('exact current v3 admission client is not ready')
   finally:library.notify_cancel(token.value)
   qualified=[p for p in grant['profiles'].values() if p.get('qualified') is True]
   if not qualified or any(p.get('external_v3_stage') is not True for p in qualified):raise ValueError('external staging needs explicitly qualified external-v3 module profiles')
   return True
  if policy.get('mode') not in (None,'embedded-v1'):raise ValueError('unsupported explicit first-map ownership mode')
  server=None if revoking else self.first_map_server(policy)
  container=None if revoking else self.first_map_container(i,d,server)
  directory=private_directory(getattr(self,'first_map_directory',Path.home()/'Library/Application Support/HyprWM/first-map'))
  fd=os.open(directory/'grants.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
  try:
   info=os.fstat(fd)
   if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077:raise ValueError('private first-map grant lock required')
   fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
   path=directory/'grants.json'
   if path.is_symlink():raise ValueError('canonical first-map grant required')
   if path.exists() and path.stat().st_size>65536:raise ValueError('bounded first-map table required')
   before=path.read_bytes() if path.exists() else None
   value=private_json(path) if before is not None else {'schema':1,'targets':[]}
   if (before is not None and len(before)>65536) or value.get('schema')!=1 or type(value.get('targets'))!=list or len(value['targets'])>128:raise ValueError('bounded first-map table required')
   rows=[]
   for target in value['targets']:
    # Unknown/unreadable processes keep their grants. Only a proven dead or
    # replaced generation can be pruned; no live owner's record is evicted.
    actor=identity({'pid':target['birth'][0],'birth':target['birth'],'executable':target['executable']})
    current=self.identity(actor['pid']);dead=current is not None and current!=actor
    if current is None:
     try:os.kill(actor['pid'],0)
     except ProcessLookupError:dead=True
     except PermissionError:pass
    if not dead:rows.append(target)
   if revoking:rows=[row for row in rows if row['birth']!=i['birth'] or row['executable']!=i['executable']]
   for image in ([] if revoking else d['images']):
    if image['architecture'] not in ('arm64','arm64e'):continue
    target={'birth':i['birth'],'executable':i['executable'],'main_uuid':str(uuid.UUID(hex=image['main_uuid'])).upper(),'server_executable':policy['server_executable']}
    if container is not None:target['socket']=str(container/('s'+str(i['pid'])))
    rows=[row for row in rows if not (row['birth']==target['birth'] and row['executable']==target['executable'] and row['main_uuid']==target['main_uuid'] and row!=target)]
    if target not in rows:rows.append(target)
   result={'schema':1,'targets':rows};encoded=canonical(result)+b'\n'
   if len(rows)>128 or len(encoded)>65536:raise ValueError('first-map table full; live owners preserved')
   if self.identity(i['pid'])!=i or (server is not None and self.identity(server['pid'])!=server):raise ValueError('first-map generation changed before publication')
   if (path.read_bytes() if path.exists() else None)!=before:raise ValueError('first-map table changed before publication')
   if before!=encoded:atomic(path,result)
   if container is not None:atomic(container/('g'+str(i['pid'])),{'schema':1,'targets':[row for row in rows if row['birth']==i['birth'] and row['executable']==i['executable']]})
   if revoking:
    scoped=Path.home()/'Library/Containers'/d['bundle_id']/'Data/.hwm'/('g'+str(i['pid']))
    if scoped.exists():
     if scoped.is_symlink() or scoped.absolute()!=scoped.resolve(strict=True) or scoped.stat().st_size>65536:raise ValueError('canonical bounded scoped grant required')
     value=private_json(scoped)
     if value.get('schema')!=1 or type(value.get('targets'))!=list or len(value['targets'])>128:raise ValueError('bounded scoped grant required')
     kept=[row for row in value['targets'] if row['birth']!=i['birth'] or row['executable']!=i['executable']]
     if kept!=value['targets']:atomic(scoped,{'schema':1,'targets':kept})
   return not revoking
  finally:os.close(fd)
 def authorize(self,i,d,request,off=False):
  grant=self.grant()
  if not grant_includes_logic(grant) and d.get('bundle_id')==self.bundles.logic_id:raise ValueError('installed Logic is exempt; no attach')
  gate=getattr(self,'effect_gate',None)
  if not off and callable(gate) and gate() is not True:raise PreparationPending('authenticated session gate closed before native operation')
  if grant.get('qualification_scope')=='own-fixture' and i['executable'] not in grant.get('own_fixture_executables',[]):raise ValueError('own qualification grant cannot target any owner/system process')
  if not off and grant.get('enabled') is not True:raise ValueError('durable root grant disabled')
  if request.get('epoch')!=grant['epoch'] or request.get('nonce')!=grant['nonce'] or any(request.get(k) is not False for k in ('allow_activation','allow_input','allow_restart')):raise ValueError('exact root epoch/nonce/effect boundary required')
  if d['executable']!=i['executable'] or i['birth'][0]!=i['pid'] or i['birth'][1]!=os.getuid() or self.identity(i['pid'])!=i:raise ValueError('exact current event birth required')
  for name,digest in self.source_pins.items():checked_file(HERE/name,digest)
  return grant
 def artifact_base(self,d):
  if not sandboxed(d['executable']):return private_directory(self.directory/'artifacts')
  container=Path.home()/'Library/Containers'/d['bundle_id'];data=container/'Data'
  if not data.is_dir():raise ValueError('sandbox container is not initialized; no outside-container load')
  meta=container/'.com.apple.containermanagerd.metadata.plist'
  if meta.exists():
   if meta.stat().st_size>1048576 or plistlib.loads(meta.read_bytes()).get('MCMMetadataIdentifier')!=d['bundle_id']:raise ValueError('sandbox container identity mismatch')
  return private_directory(data/'Library/Application Support/hyprwm-native-menus')
 def prepare_profiles(self,base,grant):
  rows={}
  for architecture,p in grant['profiles'].items():
   if architecture not in ('arm64','arm64e') or p.get('qualified') is not True:continue
   module=checked_file(p['path'],p['sha256']);folder=private_directory(base/('module-'+p['sha256']));dest=folder/'AppMenus.dylib'
   if not dest.exists():
    fd=os.open(dest,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as f:f.write(module.read_bytes());f.flush();os.fsync(f.fileno())
   checked_file(dest,p['sha256'])
   rows[architecture]={'artifact':str(dest),'sha256':p['sha256'],'uuid':p['uuid'].replace('-','').lower()}
  if not rows:raise ValueError('no actually qualified architecture/module profiles')
  return rows
 def render(self,i,d,profiles,flags,handle,action,output):
  values={'IDENTITY':i,'EXPECTED_UUIDS':[x['main_uuid'] for x in d['images']],'PROFILES':profiles,'FLAGS':flags,'EXISTING_HANDLE':handle,'ACTION':action,
          'LIFECYCLE':str(LIFECYCLE),'OUTPUT':str(output),'SOURCE_PINS':self.source_pins}
  body=(HERE/'generic-driver.txt').read_text().replace('__QUALIFIED_SYMBOL_HELPERS__',(HERE/'qualified-symbols.txt').read_text().rstrip())
  result='\n'.join(k+'='+repr(v) for k,v in values.items())+'\n'+body;compile(result,'qualified-native-menu-driver','exec');return result
 def invoke(self,i,d,profiles,flags,handle,action,folder):
  if self.identity(i['pid'])!=i:raise ValueError('birth changed immediately before attach')
  folder=private_directory(folder);script=folder/'lldb-driver.py';output=folder/'native.json'
  if script.exists() or output.exists():raise ValueError('new native operation directory required')
  script.write_text(self.render(i,d,profiles,flags,handle,action,output));script.chmod(0o600)
  argv=['/usr/bin/lldb','--batch','-p',str(i['pid']),'-o','settings set target.auto-import-clang-modules false','-o','script exec(compile(open('+repr(str(script))+').read(),'+repr(str(script))+',"exec"))',
    '-o','script p=lldb.debugger.GetSelectedTarget().GetProcess(); p.Detach(False) if p.IsValid() and p.GetState() not in (lldb.eStateDetached,lldb.eStateExited,lldb.eStateInvalid) else None','-o','quit']
  try:v=subprocess.run(argv,capture_output=True,text=True,timeout=25,umask=0o077);(folder/'lldb.log').write_text(v.stdout+v.stderr)
  except subprocess.TimeoutExpired as e:
   (folder/'lldb.log').write_text(str(e.stdout or '')+str(e.stderr or '')+'\nTIMEOUT; detach unconfirmed; no retry\n');raise RuntimeError('bounded debugger timeout; generation quarantined')
  if not output.exists():raise RuntimeError('no native detach receipt; generation quarantined')
  value=private_json(output);value['identity_after_detach']=self.identity(i['pid'])==i
  state=subprocess.run(['/bin/ps','-p',str(i['pid']),'-o','state='],capture_output=True,text=True,timeout=3)
  value['not_stopped_after_detach']=state.returncode==0 and bool(state.stdout.strip()) and state.stdout.strip()[0] not in 'TZ'
  value['identity_after_state_query']=self.identity(i['pid'])==i
  if any(value.get(k) is not True for k in ('detached','identity_after_detach','identity_after_state_query','not_stopped_after_detach','actual_main_thread','buffer_freed','handle_retained')):value['ok']=False;value['reason']='unqualified-native-postflight'
  value['postflight']=str(folder/'postflight.json');atomic(folder/'postflight.json',value)
  return value
 def load_once(self,i,d,request,previous):
  grant=self.authorize(i,d,request);base=private_directory(self.directory/('birth-'+'-'.join(map(str,i['birth']))))
  lock=os.open(base/'operation.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
  try:
   fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
   if previous:
    proof=previous['proof'];binding=self.binding(proof,i)
    if proof.get('reason')!='existing_menu_not_ready' or proof.get('mutation_attempted') is not False:raise ValueError('only proven unready menu can retry with retained handle')
    allowed={architecture:(p['sha256'],p['uuid'].replace('-','').lower()) for architecture,p in grant['profiles'].items() if architecture in ('arm64','arm64e') and p.get('qualified') is True}
    if (not binding['profiles'] or proof.get('module_sha256') not in {p['sha256'] for p in binding['profiles'].values()} or
        any(allowed.get(architecture)!=(p['sha256'],p['uuid'].replace('-','').lower()) for architecture,p in binding['profiles'].items())):
     raise ValueError('retained ON profiles differ from current root qualification; no attach')
    profiles=binding['profiles'];flags=binding['flags'];handle=binding['handle']
   else:
    try:profiles=self.prepare_profiles(self.artifact_base(d),grant)
    except (OSError,ValueError,KeyError,TypeError) as error:raise PreparationPending(str(error)) from error
    flags=0x80000000|(int.from_bytes(os.urandom(4),'big')&0x7fffffff or 1);handle=0
   try:self.ensure_first_map_grant(i,d,grant)
   except (OSError,ValueError,KeyError,TypeError) as error:raise PreparationPending(str(error)) from error
   action=4 if (grant.get('first_map') or {}).get('mode')=='external-v3' else 3
   folder=base/('operation-'+os.urandom(12).hex());atomic(base/'intent.json',{'identity':i,'epoch':grant['epoch'],'nonce':grant['nonce'],'action':action,'profiles':profiles,'flags':flags,'previous_handle':handle,'folder':str(folder)})
   value=self.invoke(i,d,profiles,flags,handle,action,folder)
   if action==4 and value.get('ok') is True and (value.get('native',{}).get('external_first_map') is not True or value.get('native',{}).get('first_map_installed') is not False):
    value['ok']=False;value['reason']='external-admission-nonownership-unconfirmed'
   value['_binding']={'identity':i,'epoch':grant['epoch'],'nonce':grant['nonce'],'profiles':profiles,'flags':flags,'handle':value.get('retained_handle',0),'postflight':value['postflight'],'postflight_sha256':sha(value['postflight'])}
   return value
  finally:os.close(lock)
 def binding(self,proof,i):
  b=proof['_binding']
  if b['identity']!=i or type(b['handle'])!=int or b['handle']<=0 or b['epoch']!=self._grant['epoch'] or b['nonce']!=self._grant['nonce']:raise ValueError('owned exact-self binding required')
  file=Path(b['postflight']);native=private_json(file)
  handle=native.get('handle') if b.get('legacy') else native.get('retained_handle')
  if sha(file)!=b['postflight_sha256'] or native.get('identity')!=i or handle!=b['handle'] or native.get('detached') is not True:raise ValueError('actual immutable retained-handle receipt chain required')
  for p in b['profiles'].values():checked_file(p['artifact'],p['sha256'])
  return b
 def off_owned(self,i,owner,request):
  self.authorize(i,owner['descriptor'],request,off=True);b=self.binding(owner['proof'],i)
  base=private_directory(self.directory/('birth-'+'-'.join(map(str,i['birth']))));lock=os.open(base/'operation.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
  try:
   fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
   return self.invoke(i,owner['descriptor'],b['profiles'],b['flags'],b['handle'],2,base/('off-'+os.urandom(12).hex()))
  finally:os.close(lock)
 def resume_owned(self,i,owner,request):
  """Resume only an exact retained image after its confirmed owned OFF."""
  grant=self.authorize(i,owner['descriptor'],request);b=self.binding(owner['proof'],i)
  off=owner['off_proof'];path=Path(off['postflight']);saved=private_json(path)
  if (sha(path)!=off['postflight_sha256'] or saved.get('identity')!=i or saved.get('action')!=2 or
      saved.get('ok') is not True or saved.get('enabled') is not False or
      saved.get('retained_handle')!=b['handle'] or
      any(saved.get(k) is not True for k in ('detached','buffer_freed','identity_after_detach','not_stopped_after_detach'))):
   raise ValueError('immutable exact retained OFF receipt required; no resume attach')
  architecture=saved['architecture'];profile=b['profiles'][architecture]
  if (saved.get('artifact')!=profile['artifact'] or saved.get('module_sha256')!=profile['sha256'] or
      saved.get('module_uuid','').replace('-','').lower()!=profile['uuid'].replace('-','').lower() or
      profile['sha256'] not in grant['module_sha256']):raise ValueError('retained OFF image is not currently granted')
  current=grant.get('profiles',{}).get(architecture,{})
  if (current.get('qualified') is not True or current.get('sha256')!=profile['sha256'] or
      current.get('uuid','').replace('-','').lower()!=profile['uuid'].replace('-','').lower() or
      ((grant.get('first_map') or {}).get('mode')=='external-v3' and current.get('external_v3_stage') is not True)):
   raise PreparationPending('retained image architecture is no longer qualified for resume; no attach')
  base=private_directory(self.directory/('birth-'+'-'.join(map(str,i['birth']))))
  lock=os.open(base/'operation.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
  try:
   fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
   try:self.ensure_first_map_grant(i,owner['descriptor'],grant)
   except (OSError,ValueError,KeyError,TypeError) as error:raise PreparationPending(str(error)) from error
   action=4 if (grant.get('first_map') or {}).get('mode')=='external-v3' else 3
   if action==4 and owner['proof'].get('action')!=4:raise PreparationPending('legacy binding requires explicit external-mode migration; no resume attach')
   folder=base/('resume-'+os.urandom(12).hex())
   atomic(base/'intent.json',{'identity':i,'epoch':grant['epoch'],'nonce':grant['nonce'],'action':action,'profiles':b['profiles'],'flags':b['flags'],'previous_handle':b['handle'],'folder':str(folder),'resume_after':str(path),'resume_after_sha256':off['postflight_sha256']})
   value=self.invoke(i,owner['descriptor'],b['profiles'],b['flags'],b['handle'],action,folder)
   if action==4 and value.get('ok') is True and (value.get('native',{}).get('external_first_map') is not True or value.get('native',{}).get('first_map_installed') is not False):
    value['ok']=False;value['reason']='external-admission-nonownership-unconfirmed'
   if value.get('retained_handle')!=b['handle']:raise RuntimeError('retained native handle changed; outcome requires review')
   value['_binding']={**b,'postflight':value['postflight'],'postflight_sha256':sha(value['postflight']),'legacy':False}
   return value
  finally:os.close(lock)
 def verify_existing_owner(self,owner):
  try:self.binding(owner['proof'],owner['identity']);return True
  except (KeyError,ValueError,OSError,TypeError):return self.verify_legacy_owner(owner)
 def verify_legacy_owner(self,owner):
  """Read real original manual token AND successful ON receipts; no attach."""
  try:
   proof=owner['proof'];p=Path(proof['legacy_token']).resolve(strict=True);token=private_json(p);i=owner['identity']
   if p.name!='handle-token.json' or p.parent!=Path(token['source_receipt']).parent:raise ValueError('original legacy token path required')
   source=private_json(token['source_receipt']);on=private_json(proof['legacy_on_receipt'])
   if sha(token['source_receipt'])!=token['source_receipt_sha256'] or sha(proof['legacy_on_receipt'])!=proof['legacy_on_sha256']:raise ValueError('legacy immutable receipt hashes required')
   if token['identity']!=i or source.get('identity')!=i or on.get('identity')!=i or on.get('handle')!=token['handle'] or on.get('module_sha256')!=token['module_sha256'] or on.get('detached') is not True or on.get('native',{}).get('enabled') is not True:raise ValueError('actual matching legacy ON binding required')
   for k in ('handle_retained','detached','identity_after_detach','not_stopped_after_detach'):
    if source.get(k) is not True or on.get(k) is not True:raise ValueError('legacy liveness/detach required')
   if token['module_sha256'] not in self._grant['module_sha256']:raise ValueError('legacy module is not root granted')
   checked_file(token['artifact'],token['module_sha256'])
   # New manager epoch owns the explicit handoff; underlying manual token's
   # original flag/handle/module remain exact and are never re-snapshotted.
   proof['_binding']={'identity':i,'epoch':self._grant['epoch'],'nonce':self._grant['nonce'],'profiles':{'arm64':{'artifact':token['artifact'],'sha256':token['module_sha256'],'uuid':token['module_uuid']}},'flags':token['menu_lease_flags'],'handle':token['handle'],'postflight':str(Path(proof['legacy_on_receipt']).resolve()),'postflight_sha256':proof['legacy_on_sha256'],'legacy':True}
   return True
  except (ValueError,KeyError,TypeError,OSError):return False
