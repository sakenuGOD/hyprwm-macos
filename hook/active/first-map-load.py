"""Bounded loader body; CONFIG is supplied by the root-owned policy helper."""
import lldb,os,json,importlib.util,traceback
ok=False
try:
    spec=importlib.util.spec_from_file_location('first_map_inject',CONFIG['module'])
    helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
    expected=CONFIG['expected'];native=helper.loader()
    target=lldb.debugger.GetSelectedTarget();process=target.GetProcess()
    assert process.GetState()==lldb.eStateStopped and process.GetProcessID()==expected['pid']
    current=native.identity(expected['pid']);assert current and all(current[k]==expected[k] for k in ['pid','uid','seconds','micros','path'])
    main=next((thread for thread in process if thread.GetIndexID()==1),None);assert main;process.SetSelectedThread(main)
    packet=lldb.SBCommandReturnObject();lldb.debugger.GetCommandInterpreter().HandleCommand('process plugin packet send QSetDetachOnError:1',packet)
    assert packet.Succeeded() and 'response: OK' in packet.GetOutput()
    entry=CONFIG['dylib_loader']
    modules=[module for module in target.modules if (module.GetUUIDString() or '').replace('-','').lower()==entry['uuid']]
    assert len(modules)==1 and modules[0].GetObjectFileHeaderAddress().GetLoadAddress(target)==entry['base']
    error=lldb.SBError();assert process.ReadMemory(entry['address'],16,error).hex()==entry['code'] and error.Success()
    owner=[module for module in target.modules if os.path.realpath(module.GetFileSpec().fullpath)==expected['path']]
    assert len(owner)==1
    grant=dict(birth=[expected['pid'],expected['uid'],expected['seconds'],expected['micros']],
               executable=expected['path'],main_uuid=owner[0].GetUUIDString().upper(),server_executable=CONFIG['server']['path'])
    helper.publish_grant(grant,expected['uid'],CONFIG['control'])
    options=lldb.SBExpressionOptions();options.SetIgnoreBreakpoints(True);options.SetStopOthers(True)
    options.SetTryAllThreads(False);options.SetUnwindOnError(True);options.SetTimeoutInMicroSeconds(2000000);options.SetLanguage(lldb.eLanguageTypeC)
    arm64e=target.GetTriple().startswith('arm64e-')
    pointer='(void*)'+str(entry['address'])
    if arm64e:pointer='__builtin_ptrauth_sign_unauthenticated('+pointer+',0,0)'
    loaded=target.EvaluateExpression('((void*(*)(const char*,int))'+pointer+')('+json.dumps(CONFIG['library'])+',2)',options)
    assert loaded.IsValid() and loaded.GetError().Success() and loaded.GetValueAsUnsigned()!=0,str(loaded.GetError())
    # dyld can select the arm64e sidecar even for an arm64 main executable.
    # Bind the entry to the actual loaded, verified slice, never the app triple.
    images=[(module,entry) for module in target.modules for entry in CONFIG['entries'].values()
            if (module.GetUUIDString() or '').upper()==entry['uuid']]
    assert len(images)==1,'verified first-map image unavailable: '+repr([
        (module.GetFileSpec().fullpath,module.GetUUIDString()) for module in target.modules
        if module.GetFileSpec().filename=='hypradmission.v2.dylib'])
    image,own=images[0]
    address=image.GetObjectFileHeaderAddress().GetLoadAddress(target)+own['offset']
    assert process.ReadMemory(address,16,error).hex()==own['prefix'] and error.Success()
    region=lldb.SBMemoryRegionInfo();assert process.GetMemoryRegionInfo(address,region).Success() and region.IsExecutable() and not region.IsWritable()
    pointer='(void*)'+str(address)
    if arm64e:pointer='__builtin_ptrauth_sign_unauthenticated('+pointer+',0,0)'
    result=target.EvaluateExpression('((int(*)(void))'+pointer+')()',options)
    assert result.IsValid() and result.GetError().Success() and result.GetValueAsSigned()==1,(
        'grant install result='+str(result.GetValueAsSigned())+' error='+str(result.GetError())+
        ' image='+str(image.GetUUIDString())+' main='+str(grant['main_uuid']))
    ok=True
except BaseException:
    os.write(2,('FIRST_MAP_REFUSED '+traceback.format_exc()[-1800:]+'\n').encode())
finally:
    error=lldb.debugger.GetSelectedTarget().GetProcess().Detach()
    os.write(1,('FIRST_MAP_DETACH '+str(error.Success())+' INSTALLED '+str(ok)+'\n').encode())
    if error.Success():os._exit(0 if ok else 1)
