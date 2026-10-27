# Existing qualified main-thread loader, specialized for the workspace bridge.
# The launcher supplies frozen identities/profiles; imports perform no attach.
from prepare_native import identity
import json,lldb,os,time
def execute():
 target=lldb.debugger.GetSelectedTarget();process=target.GetProcess()
 receipt={'schema':1,'identity':IDENTITY,'action':ACTION,'ok':False,'detached':False,'activation_attempted':False,'input_attempted':False,'mutation_attempted':bool(PRIOR_ATTEMPTED),'start_wall_ns':time.time_ns(),'steps':[],'source_pins':SOURCE_PINS,'prior_installed':bool(PRIOR_INSTALLED)}
 handle=EXISTING_HANDLE;buffer=0;evaluate=None;native={};exports={};profile=None
 def save():
  temporary=OUTPUT+'.next'
  with open(temporary,'w') as output:
   json.dump(receipt,output,indent=2);output.write('\n');output.flush();os.fsync(output.fileno())
  os.replace(temporary,OUTPUT)
 def uuid(v):return v.replace('-','').lower()
 def path(spec):return spec.fullpath
 def generation():
  row=identity(IDENTITY['pid'])
  if not row:return None
  return dict(pid=row['pid'],birth=[row['pid'],row['uid'],row['seconds'],row['micros']],executable=row['path'],argv=None)
 def native_symbol(name):
  expected={'pthread_main_np':'/usr/lib/system/libsystem_pthread.dylib',
            'dlopen':'/usr/lib/system/libdyld.dylib','dlsym':'/usr/lib/system/libdyld.dylib',
            'dlclose':'/usr/lib/system/libdyld.dylib',
            'malloc':'/usr/lib/system/libsystem_malloc.dylib','free':'/usr/lib/system/libsystem_malloc.dylib'}[name]
  # Record all returned kinds, but only a genuine Code symbol can authorize a call.
  values=set();contexts=target.FindSymbols(name,lldb.eSymbolTypeCode);count=contexts.GetSize()
  rows=[];receipt.setdefault('native_symbol_candidates',{})[name]={'expected_name':name,'expected_image':expected,'count':count,'rows':rows}
  if count>512:raise RuntimeError('bounded native symbol candidates exceeded: '+name)
  for index in range(count):
   context=contexts.GetContextAtIndex(index);module=context.GetModule();symbol=context.GetSymbol()
   image=path(module.GetFileSpec());actual_name=symbol.GetName();address=symbol.GetStartAddress().GetLoadAddress(target)
   row={'name':actual_name[:256] if actual_name else None,'symbol_type':int(symbol.GetType()),'image':image[:1024] if image else None,
        'image_uuid':uuid(module.GetUUIDString() or ''),'address':hex(address),'accepted':False};rows.append(row)
   if symbol.GetType()!=lldb.eSymbolTypeCode:row['refusal']='non-code-symbol-type';continue
   if actual_name!=name:row['refusal']='nonexact-symbol-name';continue
   if image!=expected:row['refusal']='wrong-native-image';continue
   if not address or address==lldb.LLDB_INVALID_ADDRESS:row['refusal']='invalid-load-address';continue
   owner=target.ResolveLoadAddress(address).GetModule()
   if not owner.IsValid() or path(owner.GetFileSpec())!=expected or uuid(owner.GetUUIDString() or '')!=row['image_uuid']:
    row['refusal']='load-address-owner-mismatch';continue
   row['accepted']=True;values.add(address)
  if len(values)!=1:raise RuntimeError('exact native symbol unavailable/ambiguous: '+name+'; exact distinct addresses='+str(len(values)))
  address=values.pop();receipt.setdefault('native_symbol_selected',{})[name]={'name':name,'image':expected,'address':hex(address)}
  return address
 def export_code(name):
  if name!='hypr_dockspaces_v1_json':raise RuntimeError('unreviewed C export refused')
  contexts=target.FindSymbols(name,lldb.eSymbolTypeCode);count=contexts.GetSize();values=set();rows=[]
  receipt['export_code_candidates']={'name':name,'count':count,'rows':rows,'expected_image':ARTIFACT,'expected_uuid':MODULE_UUID}
  if count>512:raise RuntimeError('bounded exact C export candidates exceeded')
  for index in range(count):
   context=contexts.GetContextAtIndex(index);module=context.GetModule();symbol=context.GetSymbol()
   image=path(module.GetFileSpec());address=symbol.GetStartAddress().GetLoadAddress(target)
   row={'name':symbol.GetName(),'type':int(symbol.GetType()),'image':image,'uuid':uuid(module.GetUUIDString() or ''),'address':hex(address),'accepted':False};rows.append(row)
   if symbol.GetType()!=lldb.eSymbolTypeCode or symbol.GetName()!=name or image!=ARTIFACT or row['uuid']!=MODULE_UUID:continue
   if not address or address==lldb.LLDB_INVALID_ADDRESS:continue
   owner=target.ResolveLoadAddress(address).GetModule()
   if not owner.IsValid() or path(owner.GetFileSpec())!=ARTIFACT or uuid(owner.GetUUIDString() or '')!=MODULE_UUID:continue
   row['accepted']=True;values.add(address)
  if len(values)!=1:raise RuntimeError('exact loaded C export Code address absent/ambiguous')
  return values.pop()

 def c_expression(name,args):
  signatures={'pthread_main_np':'int(*)(void)','dlopen':'void*(*)(const char*,int)','malloc':'void*(*)(unsigned long)','free':'void(*)(void*)','hypr_dockspaces_v1_json':'int(*)(const char*,char*,unsigned)'}
  if name not in signatures:raise RuntimeError('unqualified C signature')
  address=(exports if name=='hypr_dockspaces_v1_json' else native).get(name)
  if not address:raise RuntimeError('canonical qualified Code address required')
  pointer='__builtin_ptrauth_sign_unauthenticated((void*)'+hex(address)+',0,0)' if architecture=='arm64e' else hex(address)
  return '(('+signatures[name]+')'+pointer+')('+args+')'
 try:
  packet=lldb.SBCommandReturnObject()
  lldb.debugger.GetCommandInterpreter().HandleCommand('process plugin packet send QSetDetachOnError:1',packet)
  if not packet.Succeeded() or 'response: OK' not in packet.GetOutput():raise RuntimeError('debugger detach-on-error transport unavailable')
  if process.GetProcessID()!=IDENTITY['pid'] or generation()!=IDENTITY:raise RuntimeError('exact native generation after attach refused')
  main=target.FindModule(target.GetExecutable())
  if not main.IsValid() or path(main.GetFileSpec())!=IDENTITY['executable']:raise RuntimeError('loaded executable path refused')
  MAIN_UUID=uuid(main.GetUUIDString() or '')
  if MAIN_UUID not in EXPECTED_UUIDS:raise RuntimeError('loaded UUID absent from installed executable metadata')
  triple=target.GetTriple();architecture='arm64e' if triple.startswith('arm64e-') else 'arm64' if triple.startswith('arm64-') else None
  if architecture not in PROFILES:raise RuntimeError('architecture has no qualified module/transport profile')
  profile=PROFILES[architecture];ARTIFACT=profile['artifact'];MODULE_UUID=profile['uuid'];MODULE_SHA=profile['sha256']
  receipt.update(main_uuid=MAIN_UUID,architecture=architecture,target_triple=triple,module_sha256=MODULE_SHA,module_uuid=MODULE_UUID,artifact=ARTIFACT)
  thread=next((t for t in process if t.GetIndexID()==1),None)
  if thread is None:raise RuntimeError('main thread index1 missing')
  def idle_main(t):
   frames=list(t)[:128];names=[f.GetFunctionName() or '' for f in frames]
   return bool(names and names[0] in ('mach_msg2_trap','mach_msg_trap','__CFRunLoopServiceMachPort') and
    names.count('__CFRunLoopServiceMachPort')==1 and names.count('-[NSApplication run]')==0 and
    {f.GetSymbol().GetStartAddress().GetFileAddress() for f in frames if path(f.GetModule().GetFileSpec())==IDENTITY['executable']}=={0x10004d324,0x10004bc20,0x1000060c0} and
    sum('RunSpecific' in n for n in names)==1 and
    not any(any(s in n for s in ('dispatch_once','dlopen','load_images','initialize]')) for n in names))
  receipt['main_idle_at_attach']=idle_main(thread)
  if not receipt['main_idle_at_attach']:
   # Stop at a normal event-receive boundary, never inside launch/initializers.
   # Until then all application threads run; the timeout is a refusal bound.
   image='/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation'
   contexts=target.FindSymbols('__CFRunLoopServiceMachPort',lldb.eSymbolTypeCode)
   addresses={c.GetSymbol().GetStartAddress().GetLoadAddress(target) for c in contexts
    if c.GetSymbol().GetName()=='__CFRunLoopServiceMachPort' and path(c.GetModule().GetFileSpec())==image}
   if len(addresses)!=1 or lldb.LLDB_INVALID_ADDRESS in addresses:raise RuntimeError('qualified main-runloop boundary unavailable')
   bp=target.BreakpointCreateByAddress(addresses.pop());bp.SetThreadID(thread.GetThreadID())
   listener=lldb.SBListener('hyprwm-native-menu-main-idle')
   listener.StartListeningForEvents(process.GetBroadcaster(),lldb.SBProcess.eBroadcastBitStateChanged)
   asynchronous=lldb.debugger.GetAsync();deadline=time.monotonic()+5;arrived=False
   receipt['main_idle_wait_started_ns']=time.monotonic_ns();receipt['main_idle_stops']=0
   try:
    lldb.debugger.SetAsync(True)
    while time.monotonic()<deadline:
     if process.Continue().Fail():raise RuntimeError('main-runloop continuation refused')
     while time.monotonic()<deadline:
      event=lldb.SBEvent()
      if not listener.WaitForEvent(1,event):continue
      if not lldb.SBProcess.EventIsProcessEvent(event):continue
      if lldb.SBProcess.GetRestartedFromEvent(event):continue
      state=lldb.SBProcess.GetStateFromEvent(event)
      if state in (lldb.eStateRunning,lldb.eStateStepping):continue
      if state!=lldb.eStateStopped:raise RuntimeError('target left the owned runloop wait')
      thread=process.GetThreadByIndexID(1);receipt['main_idle_stops']+=1
      if thread.GetStopReason()!=lldb.eStopReasonBreakpoint or thread.GetStopReasonDataAtIndex(0)!=bp.GetID():raise RuntimeError('unrelated target stop; no expression allowed')
      arrived=idle_main(thread)
      if not arrived:
       receipt['last_nonidle_main_stack']=[f.GetFunctionName() or '' for f in list(thread)[:128]]
      break
     if arrived or time.monotonic()>=deadline:break
    if not arrived:raise RuntimeError('bounded main-runloop idle event did not arrive')
   finally:
    if process.GetState() in (lldb.eStateRunning,lldb.eStateStepping):process.Stop()
    target.BreakpointDelete(bp.GetID());listener.StopListeningForEvents(process.GetBroadcaster(),lldb.SBProcess.eBroadcastBitStateChanged)
    lldb.debugger.SetAsync(asynchronous);receipt['main_idle_wait_finished_ns']=time.monotonic_ns()
   if generation()!=IDENTITY:raise RuntimeError('generation changed at main-runloop boundary')
  if not idle_main(thread):raise RuntimeError('verified main-runloop idle frame required')
  receipt['main_idle_verified']=True
  process.SetSelectedThread(thread);frame=thread.GetFrameAtIndex(0)
  options=lldb.SBExpressionOptions();options.SetLanguage(lldb.eLanguageTypeC);options.SetTryAllThreads(False);options.SetIgnoreBreakpoints(True);options.SetUnwindOnError(True)
  options.SetStopOthers(False) # Other threads must be able to finish dyld/once work.
  def evaluate(expression,label):
   options.SetTimeoutInMicroSeconds(3000000 if label=='dlopen' else 1000000)
   step={'label':label,'start':time.monotonic_ns()};receipt['steps'].append(step)
   try:
    value=frame.EvaluateExpression(expression,options)
    if value.GetError().Fail():raise RuntimeError(str(value.GetError()))
    return value
   finally:step['elapsed_ns']=time.monotonic_ns()-step['start'];options.SetTimeoutInMicroSeconds(1000000)
  for name in ('pthread_main_np','dlopen','malloc','free'):native[name]=native_symbol(name)
  if evaluate(c_expression('pthread_main_np',''),'actual_main').GetValueAsSigned()!=1:raise RuntimeError('actual pthread_main_np refused')
  receipt['actual_main_thread']=True;receipt['thread_index']=1
  mapped=[m for m in target.modules if uuid(m.GetUUIDString() or '')==MODULE_UUID]
  if mapped:
   if not RESUME or len(mapped)!=1 or path(mapped[0].GetFileSpec())!=ARTIFACT:raise RuntimeError('existing module requires its exact root bootstrap receipt')
   # RTLD_NOLOAD obtains only the already mapped, exact owned image. It cannot
   # load an unknown image or rerun a constructor, and is never paired with dlclose.
   handle=evaluate(c_expression('dlopen',json.dumps(ARTIFACT)+',18'),'adopt_noload').GetValueAsUnsigned()
  else:
   if handle:raise RuntimeError('retained image mapping disappeared')
   handle=evaluate(c_expression('dlopen',json.dumps(ARTIFACT)+',2'),'dlopen').GetValueAsUnsigned()
  if not handle:raise RuntimeError('one bounded dlopen failed; no retry')
  module=next((m for m in target.modules if path(m.GetFileSpec())==ARTIFACT),None)
  if module is None or uuid(module.GetUUIDString() or '')!=MODULE_UUID:raise RuntimeError('loaded exact artifact UUID/path refused')
  receipt.update(retained_handle=handle,module_base=module.GetObjectFileHeaderAddress().GetLoadAddress(target))
  save()
  exports['hypr_dockspaces_v1_json']=export_code('hypr_dockspaces_v1_json')
  buffer=evaluate(c_expression('malloc','65536'),'malloc').GetValueAsUnsigned()
  if not buffer:raise RuntimeError('bounded output buffer allocation failed')
  def call(operation):
   request=dict(REQUEST,op=operation)
   args=json.dumps(json.dumps(request,separators=(',',':')))+',(char*)'+hex(buffer)+',65536'
   code=evaluate(c_expression('hypr_dockspaces_v1_json',args),'native_'+operation).GetValueAsSigned()
   error=lldb.SBError();raw=process.ReadCStringFromMemory(buffer,65536,error)
   if error.Fail():raise RuntimeError(str(error))
   value=json.loads(raw)
   if type(value)!=dict:raise RuntimeError('native JSON object required')
   return code,value
  if generation()!=IDENTITY:raise RuntimeError('generation changed before native install')
  code,status=call('status')
  if ALLOW_SUCCESSOR:
   # With the original manager gone, only probe the original authenticated
   # service. session_generation follows DSAuth in the pinned bridge, proving
   # that install completed even if its reply was lost. Never install here.
   if not RESUME or not ((not code and status.get('ok') is True) or status.get('error')=='session_generation'):
    raise RuntimeError('successor probe could not confirm the original installation; no install attempted')
   receipt.update(native={'ok':True,'installed':True},native_code=0,adopted_install=True,prior_installed=True)
   save()
  elif RESUME and PRIOR_INSTALLED:
   # A completed install is not repeated, including when its first status or
   # publication failed. The original nonce/request stays authoritative.
   receipt.update(native={'ok':True,'installed':True},native_code=0,adopted_install=True,prior_installed=True)
  elif not code and status.get('ok') is True:
   if not RESUME:raise RuntimeError('unexpected preexisting service')
   receipt.update(native={'ok':True,'installed':True},native_code=0,adopted_install=True,prior_installed=True)
  else:
   if status.get('error')!='current_lifetime_auth_required':raise RuntimeError('unconfirmed workspace state; install not repeated')
   receipt['mutation_attempted']=True;save()
   code,value=call('install');receipt.update(native=value,native_code=code);save()
   if code or value.get('ok') is not True or value.get('installed') is not True:raise RuntimeError('native workspace install refused: '+str(value.get('error')))
   receipt['prior_installed']=True;save()
  code,status=call('status');receipt.update(status=status,status_code=code)
  if code or status.get('ok') is not True:
   if not (RESUME and receipt['prior_installed'] and ALLOW_SUCCESSOR and status.get('error')=='session_generation'):
    raise RuntimeError('native workspace status refused: '+str(status.get('error')))
   receipt['peer_rebind_required']=True
  if generation()!=IDENTITY:raise RuntimeError('generation changed after native install')
  receipt.update(ok=True,reason='native-existing-service-installed')
 except BaseException as error:receipt['error']=str(error)
 finally:
  if buffer and evaluate and native.get('free') and process.GetState()==lldb.eStateStopped:
   try:evaluate('({ '+c_expression('free','(void*)'+hex(buffer))+'; 0; })','free');receipt['buffer_freed']=True
   except Exception as error:receipt.update(buffer_free_error=str(error),ok=False)
  receipt.update(retained_handle=handle,handle_retained=bool(handle),dlclose_called=False)
  try:
   error=process.Detach(False);receipt['detached']=error.Success()
   if error.Fail():receipt.update(ok=False,detach_error=str(error))
  except Exception as error:receipt.update(detached=False,ok=False,detach_error=str(error))
  receipt['end_wall_ns']=time.time_ns()
  save()
execute()
