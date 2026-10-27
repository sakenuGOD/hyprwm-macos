"""Bounded six-boundary publication/inverse for an already qualified graph."""
from pathlib import Path
import hashlib
import json
import os
import struct
import sys
import time
import lldb
from ctypes import sizeof as ctypes_size

run=Path(CONFIG['run']); prepared=Path(CONFIG['prepared'])
sys.path.insert(0,str(prepared.parent))
from prepare_native import identity
import native_state as schema

def need(value,message):
    if not value: raise RuntimeError(message)

record=json.loads((run/'activation.json').read_text())
p=json.loads(prepared.read_text()); expected=p['expected']
target=lldb.debugger.GetSelectedTarget(); process=target.GetProcess()
def same_actor():
    row=identity(expected['pid'])
    return row and all(row[k]==expected[k] for k in ('pid','uid','seconds','micros','path'))
need(os.geteuid()==0 and same_actor() and process.GetProcessID()==expected['pid']
     and process.GetState()==lldb.eStateStopped,'Exact stopped native generation required')
packet=lldb.SBCommandReturnObject()
lldb.debugger.GetCommandInterpreter().HandleCommand('process plugin packet send QSetDetachOnError:1',packet)
need(packet.Succeeded() and 'response: OK' in packet.GetOutput(),'Detach-on-error refused')
threads=[t for t in process if t.GetName()=='ws_main_thread']
need(len(threads)==1,'Native main thread unavailable'); process.SetSelectedThread(threads[0])
started=time.monotonic();inverting=False
def deadline():
    need((inverting or time.monotonic()-started<9) and time.monotonic()<CONFIG['deadline']-(1 if inverting else 3),'Native publication deadline')
def read(address,size):
    deadline(); error=lldb.SBError(); data=process.ReadMemory(address,size,error)
    need(error.Success() and len(data)==size,'Native read refused'); return data
def write(address,data):
    deadline(); error=lldb.SBError(); count=process.WriteMemory(address,data,error)
    need(error.Success() and count==len(data),'Native write refused')
def q(address): return struct.unpack('<Q',read(address,8))[0]
def u(address): return struct.unpack('<I',read(address,4))[0]
def put(address,value): write(address,struct.pack('<I',value))
options=lldb.SBExpressionOptions();options.SetIgnoreBreakpoints(True);options.SetStopOthers(True)
options.SetTryAllThreads(False);options.SetUnwindOnError(True);options.SetTimeoutInMicroSeconds(1500000)
options.SetLanguage(lldb.eLanguageTypeC)
def ev(expression):
    deadline(); v=target.EvaluateExpression(expression,options)
    need(v.IsValid() and v.GetError().Success() and v.GetValue() is not None,'Native expression refused: '+str(v.GetError()))
    return v.GetValueAsUnsigned()
def save():
    temporary=run/'activation.json.next'
    with temporary.open('w') as stream:
        json.dump(record,stream,indent=2);stream.flush();os.fsync(stream.fileno())
    os.replace(temporary,run/'activation.json')
def rx(address):
    region=lldb.SBMemoryRegionInfo()
    need(process.GetMemoryRegionInfo(address,region).Success() and region.IsExecutable()
         and not region.IsWritable(),'Native boundary is not RX')
def excluded(address,size):
    for thread in process:
        need(not address<=thread.GetFrameAtIndex(0).GetPC()<address+size,'Native boundary is executing')
def flush(address):
    need(ev('({((void(*)(void*,unsigned long))0x%x)((void*)0x%x,16);(unsigned long)1;})'%
            (p['functions']['cache'],address))==1,'Native cache flush refused')
def patch(row,forward):
    original=bytes.fromhex(row['original']); changed=bytes.fromhex(row['patch'])+original[16:]
    before,after=(original,changed) if forward else (changed,original)
    actual=read(row['address'],len(original))
    if not forward and actual==original:
        if row['installed'] or row.get('intent'):
            excluded(row['address'],len(original));flush(row['address']);rx(row['address'])
            need(read(row['address'],len(original))==original,'Restored prefix readback differs')
        row['installed']=False;row['intent']=None;save();return
    owned_mix=(not forward and (row['installed'] or row.get('intent')) and actual[16:]==original[16:]
               and all(value in (old,new) for value,old,new in zip(actual[:16],original[:16],changed[:16])))
    need(actual==before or owned_mix,'Native prefix changed during publication')
    excluded(row['address'],len(original));rx(row['address'])
    # Save intent BEFORE the write; readback also resolves a torn parent operation.
    row['intent']='publish' if forward else 'restore';save()
    write(row['address'],after[:16]);flush(row['address'])
    need(read(row['address'],len(original))==after,'Native complete prefix/tail readback differs')
    rx(row['address']);row['installed']=forward;row['intent']=None;save()
def schedule(context,scheduler,dispatcher,queue,session):
    # Exactly the existing MAIN scheduler ABI, including the queue ADDRESS.
    need(ev('({((void(*)(void*,void*,void*,void*,int,int,double))0x%x)'
            '((void*)0x%x,(void*)0x%x,(void*)0x%x,(void*)0x%x,1,1,0.0);(unsigned long)1;})'%
            (scheduler,queue,dispatcher,context,session))==1,'Native scheduler refused')

engine=p['context'];control=p['control'];previous=record.get('previous_native')
need(hashlib.sha256(read(p['code'],p['code_size'])).hexdigest()==p['runtime_image_sha256'],
     'Qualified runtime image changed')
rx(p['code'])
modules=[m for m in target.modules if m.GetFileSpec().GetFilename()=='SkyLight']
need(len(modules)==1 and modules[0].GetUUIDString().upper()=='CD5F2362-8462-38D4-8C57-0BCD4E04F962',
     'Native framework generation changed')
need(q(engine+8)==p['scheduler'] and q(engine+0x10)==p['dispatcher']
     and q(engine+0x18)==p['queue'] and q(engine+0x20)==p['session']
     and q(engine+0x60)==p['channel'] and q(engine+0x6e0)==control,'Prepared graph links changed')
order=['normal','begin','scene','content','frame','ingestion']
if CONFIG['mode']=='activate':
    need(p['phase']=='prepared-disabled' and not p['published']
         and p['registered_fdes']==p['sdk_lookup_fdes']==414,'Complete fresh qualification required')
    need(hashlib.sha256(read(engine,16384)).hexdigest()==p['context_sha256']
         and hashlib.sha256(read(control,65536)).hexdigest()==p['control_sha256']
         and u(engine+0x74)==1,'Disabled graph changed before publication')
    for kind in order:
        row=record['boundaries'][kind];original=bytes.fromhex(row['original'])
        need(read(row['address'],len(original))==original,'Previous native hook is still installed')
        rx(row['address']);excluded(row['address'],len(original))
    if previous:
        old=previous['context'];need(old!=engine and q(old+0x60)==previous['channel'], 'Previous graph differs')
        own=q(old+0x10)
        need(own==previous['dispatcher'] and q(old+0x6e8)==own and u(old+0x74)==0
             and hashlib.sha256(read(previous['code'],previous['image_size'])).hexdigest()==previous['image_sha256']
             and (own&0x00007fffffffffff)==previous['code']+previous['dispatcher_offset'],
             'Previous graph must be drained to its qualified original dispatcher')
        old_control=q(old+0x6e0)
        need(old_control==previous['control'] and q(old+8)==p['scheduler']
             and q(old+0x18)==p['queue'] and q(old+0x20)==p['session'],'Predecessor scheduling graph changed')
        if old_control:
            g=schema.RGBA.from_buffer_copy(read(old_control,ctypes_size(schema.RGBA)))
            need(g.pc.engine==old and g.destroyed and not g.pc.clone and not g.pc.gpu_pending
                 and not g.renderer and not g.update and not g.root,'Previous presentation graph has not retired')
        previous.update(dispatcher=own,scheduler=q(old+8),queue=q(old+0x18),session=q(old+0x20),dead=0)
        save()
    try:
        if previous:put(previous['context']+0x74,1);record['previous_disabled']=True;save()
        for kind in order:patch(record['boundaries'][kind],True)
        # Production permission is separate from debug command1's 30-second lease.
        put(control+11264+schema.Drawing.pad.offset,1)
        write(control+12800+schema.Ordinary.expires.offset,struct.pack('<d',1e100))
        put(control+12800+schema.Ordinary.enabled.offset,1)
        record['phase']='published-before-timer';save()
        put(engine+0x74,0)
        schedule(engine,p['scheduler'],p['dispatcher'],p['queue'],p['session'])
        record['phase']='native-active';record['timer_queued']=True;save()
    except BaseException:
        inverting=True
        put(engine+0x74,1)
        failures=[]
        for kind in reversed(order):
            try:patch(record['boundaries'][kind],False)
            except BaseException as error:failures.append(kind+': '+str(error))
        need(not failures,'Native inverse retained ownership: '+'; '.join(failures))
        if previous and record.get('previous_disabled'):
            put(previous['context']+0x74,0)
            schedule(previous['context'],previous['scheduler'],previous['dispatcher'],previous['queue'],previous['session'])
        record['phase']='publication-inverted';save();raise
else:
    need(CONFIG['mode']=='retire','Unsupported native operation')
    g=schema.RGBA.from_buffer_copy(read(control,ctypes_size(schema.RGBA)))
    n=schema.NormalBinding.from_buffer_copy(read(control+12288,ctypes_size(schema.NormalBinding)))
    b=schema.BeginBinding.from_buffer_copy(read(control+57344,ctypes_size(schema.BeginBinding)))
    carrier=schema.Carrier.from_buffer_copy(read(control+10240,ctypes_size(schema.Carrier)))
    draw=schema.Drawing.from_buffer_copy(read(control+11264,ctypes_size(schema.Drawing)))
    close=schema.AcceptedCloseControl.from_buffer_copy(read(control+7168,ctypes_size(schema.AcceptedCloseControl)))
    legacy=schema.CloseControl.from_buffer_copy(read(control+6144,ctypes_size(schema.CloseControl)))
    need(g.destroyed and not g.pc.clone and not g.pc.gpu_pending and not g.pc.active_command
         and g.pc.command_ack==g.pc.command_sequence and not g.renderer and not g.update and not g.root
         and not n.inflight and not b.claiming and not carrier.depth and not carrier.preparing
         and not carrier.storage and not draw.storage and not close.storage and not close.callback_depth
         and not legacy.storage,'Native resources must drain before inverse')
    for kind in order:
        row=record['boundaries'][kind];original=bytes.fromhex(row['original'])
        actual=read(row['address'],len(original));changed=bytes.fromhex(row['patch'])+original[16:]
        need(actual==changed or (not row['installed'] and actual==original) or
             (row.get('intent') and actual[16:]==original[16:] and
              all(value in (old,new) for value,old,new in zip(actual[:16],original[:16],changed[:16]))),
             'Native ownership changed')
        excluded(row['address'],len(original));rx(row['address'])
    failures=[]
    for kind in reversed(order):
        try:patch(record['boundaries'][kind],False)
        except BaseException as error:failures.append(kind+': '+str(error))
    need(not failures,'Native inverse retained ownership: '+'; '.join(failures))
    put(engine+0x74,1)
    if previous:
        need(u(previous['context']+0x74)==1 and q(previous['context']+0x10)==previous['dispatcher'],
             'Previous graph changed while retained')
        put(previous['context']+0x74,0)
        schedule(previous['context'],previous['scheduler'],previous['dispatcher'],previous['queue'],previous['session'])
    record['phase']='native-retired';save()
need(same_actor(),'Native generation changed')
os.write(1,b'NATIVE_PUBLICATION_OK\n')
