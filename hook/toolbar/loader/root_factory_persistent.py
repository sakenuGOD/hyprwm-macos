"""Optional root-reviewed palette factory, disabled when no private grant exists.

Compose this result with existing adapters; do not replace Ghostty/HUD factories.
No service installation or process attachment happens in create().
"""
import os,stat,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
info=HERE.stat()
if HERE.is_symlink() or info.st_uid!=os.getuid() or info.st_mode&0o022:raise ValueError('trusted owned adapter source directory required')
if str(HERE) not in sys.path:sys.path.insert(0,str(HERE))
from event_menus import InstalledBundles,MenuManager,private_json,sha,signed_grant
from qualified_runtime import QualifiedRuntime
from persistent_adapter import PersistentMenuAdapter as NativeMenuAdapter
from legacy_handoff import envelope
def read_key(path):
 fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
 try:
  s=os.fstat(fd)
  if not stat.S_ISREG(s.st_mode) or s.st_uid!=os.getuid() or s.st_mode&0o077 or s.st_size!=32:raise ValueError('private owned0600 exact32byte menu HMAC key required')
  return os.read(fd,33)
 finally:os.close(fd)
def create(platform,durable_state=None):
 directory=Path(platform.runtime)/'native-menus';grant_path=directory/'grant.json';key_path=directory/'grant.key'
 if not grant_path.exists() or not key_path.exists():return {}
 key=read_key(key_path);grant=signed_grant(grant_path,key)
 launcher=grant.get('launcher')
 if launcher is None:
  runtime=QualifiedRuntime(directory/'loader',grant_path,key)
 elif launcher=='host-ready-v1':
  from host_ready_runtime import HostReadyRuntime
  runtime=HostReadyRuntime(directory/'loader',grant_path,key)
 else:raise ValueError('unsupported explicitly selected native menu launcher')
 bundles=InstalledBundles(grant.get('logic_info_plist'),grant.get('logic_info_sha256'))
 manager=MenuManager(directory/'state',grant,key,bundles,runtime)
 if durable_state is None:
  def durable_state():return private_json(Path(platform.runtime)/'state.json')
 def prepare_handoffs():
  if grant.get('legacy_handoffs_reviewed') is not True or type(grant.get('required_handoffs')) is not list:raise ValueError('root must review complete current legacy ownership inventory')
  if len(grant['required_handoffs'])>64:raise ValueError('legacy handoff inventory bound')
  values=[]
  for item in grant['required_handoffs']:
   for field in ('token','on'):
    if sha(item[field])!=item[field+'_sha256']:raise ValueError('root-pinned original handoff file changed')
   token=private_json(item['token']);expected=token['identity']
   retired=grant.get('retired_handoffs',{}).get(item['token_sha256'])
   if retired:
    if sha(retired['proof'])!=retired['sha256']:raise ValueError('retired lease proof changed')
    proof=private_json(retired['proof']);status=proof.get('native',{}).get('status',{})
    if proof.get('identity')!=expected or not all(proof.get(k) is True for k in ('detached','identity_after_detach','not_stopped_after_detach')) or status.get('enabled') is not False or any(status.get(k)!=0 for k in ('records','prepared','owned_hidden','owned_allows')):raise ValueError('retired lease must prove exact detached empty disabled native state')
    continue
   current=runtime.identity(expected['pid'])
   if current is None:
    try:os.kill(expected['pid'],0)
    except ProcessLookupError:continue
    except PermissionError:raise ValueError('legacy generation unreadable; no new loads')
    raise ValueError('legacy PID exists without verified identity')
   if current!=expected:continue
   values.append(envelope(runtime,bundles,key,item['token'],item['on']))
  return values
 return {'native_menus':NativeMenuAdapter(manager,durable_state,prepare_handoffs)}
