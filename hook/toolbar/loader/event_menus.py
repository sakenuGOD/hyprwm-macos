"""Staged native-event menu manager. No service, attach or polling on import.

The root-supplied Runtime is the qualified process/transport boundary. This
module neither weakens a frozen controller nor invents a new debugger ABI.
"""
from __future__ import annotations
import hashlib,hmac,json,os,plistlib,stat,struct,time
from pathlib import Path
from typing import Protocol

class PreparationPending(RuntimeError):
 """Refusal proved to precede any native attach/mutation; an event may retry."""

PRIVATE_JSON_LIMIT=1048576
def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def private_json(path):
 p=Path(path);fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
 try:
  s=os.fstat(fd)
  if not stat.S_ISREG(s.st_mode) or s.st_uid!=os.getuid() or s.st_mode&0o077 or not 0<s.st_size<=PRIVATE_JSON_LIMIT:raise ValueError('owned bounded private JSON required')
  return json.loads(os.read(fd,s.st_size+1))
 finally:os.close(fd)
def atomic(path,value):
 p=Path(path);p.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
 info=p.parent.lstat()
 if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077:raise ValueError('owned0700 state directory required')
 tmp=p.with_name('.'+p.name+'.'+os.urandom(12).hex())
 fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
 try:
  with os.fdopen(fd,'wb') as out:out.write(canonical(value)+b'\n');out.flush();os.fsync(out.fileno())
  os.replace(tmp,p)
 finally:
  if tmp.exists():tmp.unlink()
def sign(payload,key):return {'payload':payload,'hmac_sha256':hmac.new(key,canonical(payload),hashlib.sha256).hexdigest()}
def verify(envelope,key):
 if type(envelope)!=dict or type(envelope.get('payload'))!=dict or type(envelope.get('hmac_sha256'))!=str:return False
 return hmac.compare_digest(envelope['hmac_sha256'],hmac.new(key,canonical(envelope['payload']),hashlib.sha256).hexdigest())
def identity(application):
 b=application.get('birth');pid=application.get('pid');exe=application.get('executable')
 if (type(pid)!=int or pid<=0 or type(b)!=list or len(b)!=4 or any(type(n)!=int for n in b) or
     b[0]!=pid or b[1]!=os.getuid() or b[2]<=0 or not 0<=b[3]<1000000 or type(exe)!=str or not exe.startswith('/') or '\0' in exe):raise ValueError('exact own-UID event PID/birth/executable required')
 return {'pid':pid,'birth':b,'executable':exe,'argv':None}
def key_of(i):return ':'.join(map(str,i['birth']))+':'+i['executable']

def macho_images(path):
 """Read bounded installed Mach-O UUID/CPU metadata, never load its code."""
 with Path(path).open('rb') as f:
  size=os.fstat(f.fileno()).st_size;head=f.read(8)
  if len(head)!=8:raise ValueError('truncated Mach-O')
  slices=[]
  if head[:4] in (b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf'):
   count=struct.unpack('>I',head[4:])[0]
   if not 1<=count<=16:raise ValueError('fat architecture bound')
   fat64=head[:4]==b'\xca\xfe\xba\xbf';n=32 if fat64 else 20
   table=f.read(count*n)
   if len(table)!=count*n:raise ValueError('truncated fat architecture table')
   for j in range(count):
    row=table[j*n:(j+1)*n]
    cpu,sub,offset,length=struct.unpack('>iiQQ' if fat64 else '>iiII',row[:24 if fat64 else 16])
    if cpu==0x100000c:slices.append((offset,length))
  else:slices=[(0,size)]
  rows=[]
  for offset,length in slices:
   if offset<0 or length<32 or offset+length>size:raise ValueError('Mach-O slice outside file')
   f.seek(offset);h=f.read(32)
   if h[:4]!=b'\xcf\xfa\xed\xfe':continue
   _,cpu,sub,_,count,commands,_,_=struct.unpack('<IiiIIIII',h)
   if cpu!=0x100000c:continue
   if count>512 or commands>1048576 or commands>length-32:raise ValueError('Mach-O load-command bound')
   data=f.read(commands);cursor=0;u=None
   for _ in range(count):
    if cursor+8>len(data):raise ValueError('truncated load command')
    cmd,n=struct.unpack_from('<II',data,cursor)
    if n<8 or cursor+n>len(data):raise ValueError('invalid load command')
    if cmd==0x1b and n==24:u=data[cursor+8:cursor+24].hex()
    cursor+=n
   if u:rows.append({'architecture':'arm64e' if sub&0xffffff==2 else 'arm64','main_uuid':u})
  if not rows:raise ValueError('no supported installed ARM64 main-image UUID')
  return rows

def grant_includes_logic(grant):
 all_apps=grant.get('all_applications',False);except_logic=grant.get('all_applications_except_logic',False)
 if type(all_apps)!=bool or type(except_logic)!=bool or all_apps==except_logic:raise ValueError('exactly one explicit all-applications menu policy required')
 return all_apps

class InstalledBundles:
 def __init__(self,logic_info=None,logic_sha=None,*,include_logic=False):
  if type(include_logic)!=bool:raise ValueError('explicit Boolean menu policy required')
  self.include_logic=include_logic
  # Optional installed metadata preserves the identity used by legacy grants.
  self.logic_info=None;self.logic_id='com.apple.logic10'
  if logic_info is None:
   if logic_sha is not None:raise ValueError('Logic metadata digest requires its path')
   return
  self.logic_info=Path(logic_info).resolve(strict=True)
  if sha(self.logic_info)!=logic_sha:raise ValueError('installed Logic exemption metadata changed')
  if plistlib.loads(self.logic_info.read_bytes()).get('CFBundleIdentifier')!=self.logic_id:raise ValueError('installed Logic bundle identity differs from the exemption')
 def excluded(self,application):
  # This branch precedes any Runtime.identity/inspect/load call on Logic.
  return not self.include_logic and application.get('bundle_id')==self.logic_id
 def inspect(self,application):
  bundle=Path(application['bundle_path']).resolve(strict=True);info=bundle/'Contents/Info.plist'
  s=info.stat()
  if not stat.S_ISREG(s.st_mode) or s.st_size>1048576:raise ValueError('bounded installed bundle metadata required')
  p=plistlib.loads(info.read_bytes());bundle_id=p.get('CFBundleIdentifier');name=p.get('CFBundleExecutable')
  if bundle_id!=application.get('bundle_id') or not isinstance(bundle_id,str) or not bundle_id or not isinstance(name,str) or '/' in name:raise ValueError('event/bundle identifier or executable mismatch')
  executable=(bundle/'Contents/MacOS'/name).resolve(strict=True)
  if str(executable)!=application['executable']:raise ValueError('installed bundle executable mismatch')
  if self.excluded({'bundle_id':bundle_id}):raise ValueError('Logic is exempt before any runtime contact')
  return {'bundle_id':bundle_id,'bundle_path':str(bundle),'executable':str(executable),'images':macho_images(executable)}

class Runtime(Protocol):
 """Root adapter must implement actual qualified, bounded operations.

 load_once verifies the selected loaded main UUID against descriptor.images,
 root module/profile/architecture/source pins, actual main thread, exact birth
 before/after, native C ABI and detach/liveness; it returns the envelope below.
 It must refuse missing menu before mutation, never activate a process, retain
 the ObjC image and reuse that handle on the one permitted menu-readiness retry.
 """
 def identity(self,pid:int)->dict|None: ...
 def load_once(self,identity:dict,descriptor:dict,request:dict,previous:dict|None)->dict: ...
 def off_owned(self,identity:dict,owner:dict,request:dict)->dict: ...
 def resume_owned(self,identity:dict,owner:dict,request:dict)->dict: ...
 def verify_existing_owner(self,owner:dict)->bool: ...

class MenuManager:
 def __init__(self,directory,grant,key,bundles:InstalledBundles,runtime:Runtime):
  include_logic=grant_includes_logic(grant)
  if len(key)<32 or grant.get('schema')!=1 or grant.get('logic_bundle_id')!=bundles.logic_id or getattr(bundles,'include_logic',False) is not include_logic or not grant.get('epoch') or not grant.get('nonce'):raise ValueError('explicit signed matching application menu policy required')
  if grant.get('allow_activation') is not False or grant.get('allow_input') is not False or grant.get('allow_restart') is not False:raise ValueError('menu-only effect contract required')
  self.root=Path(directory);self.grant=grant;self.secret=key;self.bundles=bundles;self.runtime=runtime
  self.owners={};self.attempts={};self.enabled=grant.get('enabled') is True;self.suspended=False
  state=self.root/'state.json'
  if state.exists():
   saved=private_json(state)
   if not verify(saved,key):raise ValueError('menu state signature mismatch')
   value=saved['payload']
   if value.get('epoch')!=grant['epoch'] or value.get('nonce')!=grant['nonce']:raise ValueError('foreign menu epoch requires explicit owned handoff')
   self.owners=value.get('owners',{});self.attempts=value.get('attempts',{})
   self.enabled=self.enabled and value.get('enabled') is True
   self.suspended=value.get('suspended') is True
 def persist(self):
  owners=dict(self.owners);attempts=dict(self.attempts);retired={};retired_attempts={}
  witness=getattr(self.runtime,'generation_retired',None)
  if callable(witness):
   for key,owner in self.owners.items():
    try:
     i=identity(owner['identity'])
     if key_of(i)!=key or witness(i) is not True:continue
    except (OSError,ValueError,KeyError,TypeError):continue
    retired[key]=owners.pop(key)
    if key in attempts:retired_attempts[key]=attempts.pop(key)
  payload={'schema':1,'epoch':self.grant['epoch'],'nonce':self.grant['nonce'],'enabled':self.enabled,'suspended':self.suspended,'owners':owners,'attempts':attempts}
  envelope=sign(payload,self.secret)
  if len(canonical(envelope))+1>PRIVATE_JSON_LIMIT:raise ValueError('live menu state exceeds private JSON bound; previous state preserved')
  archives=[]
  for key,owner in retired.items():
   archive=sign({'schema':1,'epoch':self.grant['epoch'],'nonce':self.grant['nonce'],'reason':'kernel-generation-retired','owners':{key:owner},'attempts':{key:retired_attempts[key]} if key in retired_attempts else {}},self.secret)
   if len(canonical(archive))+1>PRIVATE_JSON_LIMIT:raise ValueError('retired menu record exceeds archive bound; previous state preserved')
   destination=self.root/'retired'/(hashlib.sha256(canonical(archive)).hexdigest()+'.json')
   archives.append((destination,archive))
  for destination,archive in archives:
   if destination.exists():
    if private_json(destination)!=archive:raise ValueError('retired menu archive changed; previous state preserved')
   else:atomic(destination,archive)
  atomic(self.root/'state.json',envelope)
  # application() still owns references to its in-flight attempt. Filter the
  # durable snapshot without deleting those references during native teardown.
 def request(self):return {'epoch':self.grant['epoch'],'nonce':self.grant['nonce'],'action':'stage-existing-inactive','allow_activation':False,'allow_input':False,'allow_restart':False}
 def receipt(self,state,reason,**values):
  v={'schema':1,'state':state,'reason':reason,'epoch':self.grant['epoch'],'nonce':self.grant['nonce'],'time':time.time(),**values}
  atomic(self.root/'last-receipt.json',sign(v,self.secret));return v
 def validate_native(self,value,i,descriptor):
  if (type(value)!=dict or value.get('identity')!=i or value.get('detached') is not True or value.get('not_stopped_after_detach') is not True or
      value.get('identity_after_detach') is not True or value.get('activation_attempted') is not False or value.get('input_attempted') is not False or
      value.get('module_sha256') not in self.grant.get('module_sha256',[]) or
      value.get('main_uuid') not in [r['main_uuid'] for r in descriptor['images']]):raise ValueError('qualified exact-self native load/postflight receipt required')
  return value
 def adopt_existing(self,envelope):
  """Explicit root handoff of a real old token chain, never adoption by flags."""
  if not verify(envelope,self.secret):raise ValueError('owned handoff signature mismatch')
  owner=envelope['payload']
  if owner.get('epoch')!=self.grant['epoch'] or owner.get('nonce')!=self.grant['nonce'] or owner.get('phase')!='applied':raise ValueError('exact root menu handoff epoch/nonce required')
  descriptor=owner['descriptor']
  if self.bundles.excluded(descriptor):raise ValueError('Logic cannot be adopted or changed')
  i=owner['identity'];self.validate_native(owner['proof'],i,descriptor)
  validator=getattr(self.runtime,'verify_existing_owner',None)
  if not callable(validator) or validator(owner) is not True:raise ValueError('actual immutable retained-handle/token receipt chain required')
  if self.runtime.identity(i['pid'])!=i:raise ValueError('owned handoff process generation changed')
  key=key_of(i)
  if key in self.owners and self.owners[key]!=owner:raise ValueError('another owned binding already occupies this birth')
  self.owners[key]=owner;self.attempts[key]={'count':1,'reason':'explicit_root_owned_handoff'};self.persist()
 def application(self,event,app):
  if self.bundles.excluded(app):return self.receipt('skipped','installed Logic exemption; no runtime contact',logic_exempt=True)
  policy=app.get('activation_policy')
  if type(policy)!=int:return self.receipt('pending','native activation_policy metadata required; no process contact',attempted=False)
  if policy!=0:return self.receipt('skipped','not a native regular application/menu owner; no process contact',attempted=False)
  i=identity(app);key=key_of(i)
  if not self.enabled:return self.receipt('off','durable menu kill-switch',attempted=False)
  if self.suspended:return self.receipt('pending','menu policy suspended; no new attach',attempted=False)
  if self.runtime.identity(i['pid'])!=i:return self.receipt('pending','event birth changed; no process adoption',attempted=False)
  old=self.owners.get(key);attempt=self.attempts.get(key,{})
  if old and old.get('phase')=='applied':return self.receipt('applied','already loaded/staged once for this birth; no attach on activation',identity=i,attempted=False,proof=old['proof'])
  count=attempt.get('count',0)
  retry=count==1 and attempt.get('reason')=='existing_menu_not_ready' and event=='application_activated'
  if count and not retry:return self.receipt('pending','generation deduplicated or quarantined',identity=i,attempted=False)
  descriptor=self.bundles.inspect(app)
  if not self.enabled or self.runtime.identity(i['pid'])!=i:return self.receipt('pending','birth/kill-switch changed before load',attempted=False)
  # Durable intent prevents a supervisor crash from automatically repeating an
  # attach with an ambiguous outcome. Root must resolve the recorded receipt.
  self.attempts[key]={'count':count+1,'reason':'ambiguous_inflight'}
  self.owners[key]={'identity':i,'descriptor':descriptor,'phase':'ambiguous','epoch':self.grant['epoch'],'nonce':self.grant['nonce']};self.persist()
  try:value=self.validate_native(self.runtime.load_once(i,descriptor,self.request(),old),i,descriptor)
  except PreparationPending as e:
   if old is None:self.owners.pop(key,None)
   else:self.owners[key]=old
   if attempt:self.attempts[key]=attempt
   else:self.attempts.pop(key,None)
   self.persist();return self.receipt('pending',str(e),identity=i,attempted=False)
  except Exception as e:
   self.attempts[key]['reason']='quarantined';self.persist();return self.receipt('pending',str(e),identity=i,attempted=True)
  if self.runtime.identity(i['pid'])!=i:
   self.attempts[key]['reason']='generation_changed';self.persist();return self.receipt('pending','process generation changed after detached load',identity=i,attempted=True)
  phase='applied' if value.get('ok') is True and value.get('enabled') is True and value.get('current_menu_matches') is True else 'pending'
  reason='existing_menu_not_ready' if value.get('reason')=='existing_menu_not_ready' and value.get('mutation_attempted') is False else 'quarantined' if phase!='applied' else 'applied'
  if phase!='applied' and value.get('mutation_attempted') is not False:phase='ambiguous'
  self.attempts[key]['reason']=reason
  self.owners[key]={'identity':i,'descriptor':descriptor,'phase':phase,'proof':value,'epoch':self.grant['epoch'],'nonce':self.grant['nonce']};self.persist()
  return self.receipt(phase,reason,identity=i,attempted=True,proof=value)
 def handle(self,event):
  kind=event.get('event')
  if kind=='application_terminated':
   app=event.get('application',{})
   if self.bundles.excluded(app):return self.receipt('skipped','Logic termination ignored')
   i=identity(app);key=key_of(i)
   if key in self.owners:self.owners[key]['phase']='gone'
   self.attempts.pop(key,None);self.persist()
   return self.receipt('off','native terminated event marks only exact cached birth gone; no runtime contact',identity=i,attempted=False)
  apps=event.get('applications',[]) if kind=='startup' else [event.get('application',{})] if kind in ('application_launched','application_activated') else []
  if kind=='startup' and event.get('complete') is not True:return self.receipt('pending','incomplete native startup snapshot refused',attempted=False)
  if kind not in ('startup','application_launched','application_activated'):return self.receipt('skipped','not a process menu lifecycle event',attempted=False)
  if len(apps)>512:return self.receipt('pending','native app snapshot bound',attempted=False)
  results=[]
  for app in apps:
   try:results.append(self.application(kind,app))
   except (OSError,ValueError,KeyError,TypeError) as e:results.append(self.receipt('pending',str(e),attempted=False))
  return results
 def _off_owners(self,phase):
  results=[]
  for key,owner in list(self.owners.items()):
   if owner.get('phase')=='suspended' and phase=='off':owner['phase']='off';continue
   if owner.get('phase')=='ambiguous' or (owner.get('phase')=='pending' and owner.get('proof',{}).get('mutation_attempted') is not False):
    results.append({'identity':owner['identity'],'state':'pending','reason':'ambiguous loader outcome requires retained native receipt review'});continue
   if owner.get('phase')!='applied':continue
   i=owner['identity']
   if owner.get('epoch')!=self.grant['epoch'] or owner.get('nonce')!=self.grant['nonce']:continue
   current=self.runtime.identity(i['pid'])
   if current!=i:
    birth=current.get('birth') if isinstance(current,dict) else None
    replaced=(type(birth)==list and len(birth)==4 and all(type(n)==int for n in birth) and birth[0]==i['pid'] and birth[2]>0 and 0<=birth[3]<1000000 and birth!=i['birth'])
    retired=getattr(self.runtime,'generation_retired',None)
    if replaced or (callable(retired) and retired(i) is True):owner['phase']='gone'
    else:results.append({'identity':i,'state':'pending','reason':'owner birth unreadable; retained binding preserved'})
    continue
   # A crash or timeout after this point cannot repeat an unknown native OFF.
   owner['phase']='ambiguous';owner['transition']=phase;self.persist()
   try:result=self.runtime.off_owned(i,owner,self.request())
   except Exception as e:
    results.append({'identity':i,'state':'pending','reason':str(e)});continue
   if result.get('ok') is True and result.get('enabled') is False and result.get('detached') is True and self.runtime.identity(i['pid'])==i:
    owner['phase']=phase;owner.pop('transition',None);owner['off_proof']=dict(result)
    if result.get('postflight'):owner['off_proof']['postflight_sha256']=sha(result['postflight'])
   else:results.append({'identity':i,'state':'pending','reason':'owned OFF unconfirmed; no foreign cleanup'})
  self.persist();return results
 def disable(self):
  self.enabled=False;self.suspended=False;self.persist();return self._off_owners('off')
 def suspend(self):
  self.suspended=True;self.persist();return self._off_owners('suspended')
 def resume(self,*,explicit_enable=False,may_resume=None):
  if explicit_enable:
   if self.grant.get('enabled') is not True:raise ValueError('signed menu grant disabled')
   self.enabled=True
   for owner in self.owners.values():
    if owner.get('phase')=='off':owner['phase']='suspended'
  if not self.enabled:return [{'state':'off','reason':'durable menu kill-switch'}]
  self.suspended=False;self.persist();results=[]
  for key,owner in list(self.owners.items()):
   if owner.get('phase') not in (('suspended','off') if explicit_enable else ('suspended',)):continue
   if may_resume is not None and may_resume() is not True:
    results.append({'state':'pending','reason':'authenticated session gate closed before retained resume','attempted':False});break
   i=owner['identity']
   if self.runtime.identity(i['pid'])!=i:
    results.append({'identity':i,'state':'pending','reason':'resume requires the same readable birth'});continue
   before=dict(owner);owner['phase']='ambiguous';owner['transition']='resume';self.persist()
   try:
    value=self.validate_native(self.runtime.resume_owned(i,owner,self.request()),i,owner['descriptor'])
   except PreparationPending as error:
    if explicit_enable and before.get('phase')=='off':before['phase']='suspended'
    self.owners[key]=before;results.append({'identity':i,'state':'pending','reason':str(error),'attempted':False});self.persist();continue
   except Exception as error:
    results.append({'identity':i,'state':'pending','reason':str(error),'attempted':True});self.persist();continue
   if (value.get('ok') is True and value.get('enabled') is True and value.get('current_menu_matches') is True and self.runtime.identity(i['pid'])==i):
    owner['proof']=value;owner['phase']='applied';owner.pop('transition',None);owner.pop('resume_proof',None)
   else:
    owner['resume_proof']=value;results.append({'identity':i,'state':'pending','reason':'retained resume outcome unconfirmed','attempted':True})
   self.persist()
  return results

def signed_grant(path,key):
 envelope=private_json(path)
 if not verify(envelope,key):raise ValueError('root manifest HMAC mismatch')
 return envelope['payload']
