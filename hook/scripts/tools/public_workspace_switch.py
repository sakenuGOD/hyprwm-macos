#!/usr/bin/env python3
"""Explicit ROOT public ordinary-Space probe; inspect stays read-only.

One commit uses only public Mission Control AX select. Completion requires
fresh independent display/global getters and fresh manager native witnesses.
No raw setter, creation, deletion, coordinate or keyboard input fallback.
"""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT/'hook'))
from managed_space_switch import NativeDriver,Snapshot,SwitchRefused,_frozen
from managed_space_create import NativeMissionControlActions,catalog
from public_workspace import PublicWorkspaceProvider
from public_workspace_factory import SOURCE_GATE


def manager(native,expected=None):
    with socket.socket(socket.AF_UNIX) as stream:
        stream.settimeout(.3);stream.connect('/tmp/hyprwm.ctl')
        deadline=time.monotonic()+.3
        peer=stream.getsockopt(0,0x002);identity=native._identity(peer)
        if expected is not None and identity!=expected:raise SwitchRefused('manager native birth/path changed during request')
        stream.sendall(b'["status"]\n')
        data=b''
        while not data.endswith(b'\n'):
            remaining=deadline-time.monotonic()
            if remaining<=0:raise SwitchRefused('overall manager witness deadline elapsed')
            stream.settimeout(remaining)
            chunk=stream.recv(4096)
            if not chunk or len(data)+len(chunk)>262144:raise SwitchRefused('bounded complete manager reply required')
            data+=chunk
        if native._identity(peer)!=identity:raise SwitchRefused('manager native birth changed during observation')
    payload=json.loads(data)
    # Both runtimes publish the SAME native witness with different status
    # envelopes. Never synthesize one from top-level Space/tree occupancy.
    daemon=payload.get('daemon',{})
    if (payload.get('runtime')=='swift' and daemon.get('runtime')=='swift' and daemon.get('pid')==peer):
        value=payload.get('workspace_manager')
    else:
        value=payload.get('configure_state',{}).get('workspace_manager')
    if not isinstance(value,dict) or type(value.get('sample_sequence')) is not int:
        raise SwitchRefused('staged native manager workspace witness unavailable; no occupancy alias fallback')
    return value,identity


def independent(identity):
    child=subprocess.run([sys.executable,str(ROOT/'hook/ordinary_workspace_witness.py'),'--diagnostic',
        '--identity-library',str(identity)],capture_output=True,text=True,timeout=1)
    if child.returncode or len(child.stdout)>262144:raise SwitchRefused('independent native observer failed')
    return json.loads(child.stdout)


def run(args):
    native=NativeDriver(identity_library=str(args.identity_library));before=Snapshot.parse(native.snapshot())
    if not args.commit:
        return dict(mode='public-inspect',generation=before.generation,active=before.active,
            targets=[dict(ordinal=t.ordinal,sid=t.sid,display=t.display,uuid=before.find(t.display,t.sid).uuid,type=0)
                     for t in catalog(before).targets],setter_called=False,public_action_called=False)
    if not args.request or not args.helper or not args.helper_sha or not args.source_sha:
        raise SwitchRefused('exact request and reviewed signed public helper hashes required')
    path=Path(args.request)
    if not 0<path.stat().st_size<=16384:raise SwitchRefused('bounded expected request required')
    request=json.loads(path.read_text())
    if set(request)!={'ordinal','sid','display','uuid','type','source_sid','generation'}:
        raise SwitchRefused('exact ordinary target/source/native generation fields required')
    target=catalog(before).ordinal(str(request['ordinal']));expected=before.find(target.display,target.sid)
    if (target.sid!=request['sid'] or target.display!=request['display'] or expected.uuid!=request['uuid'] or
            type(request['type']) is not int or request['type']!=0 or request['source_sid']!=before.active or
            _frozen(request['generation'])!=before.generation):raise SwitchRefused('native request identity/current changed')
    initial,manager_identity=manager(native)  # Refuse before UI if the actual manager cannot witness.
    current=before.find(target.display,before.active)
    if (initial.get('stable') not in (True,1) or initial.get('space')!=before.active or
            initial.get('space_type')!=0 or initial.get('workspace_native')!=[
                dict(display=current.display,sid=current.sid,uuid=current.uuid,type=0)]):
        raise SwitchRefused('actual manager has not durably reached the ordinary native source')
    digest=lambda path:hashlib.sha256(Path(path).read_bytes()).hexdigest()
    artifacts=dict(helper=str(args.helper.resolve()),helper_sha=args.helper_sha,source_sha=args.source_sha,
        identity_library_sha=digest(args.identity_library),identity_source_sha=digest(ROOT/'hook/src/managed_process_identity.c'),
        sources={relative:digest(ROOT/relative) for relative in SOURCE_GATE})
    actions=NativeMissionControlActions(args.helper,source_sha256=args.source_sha,binary_sha256=args.helper_sha)
    jobs=[];last=[None]
    def wait_observation(seconds):
        native.cf.CFRunLoopRunInMode.argtypes=[ctypes.c_void_p,ctypes.c_double,ctypes.c_bool]
        native.cf.CFRunLoopRunInMode.restype=ctypes.c_int
        mode=ctypes.c_void_p.in_dll(native.cf,'kCFRunLoopDefaultMode')
        result=native.cf.CFRunLoopRunInMode(mode,seconds,False)
        if result in (1,2):time.sleep(seconds)
    def read_independent():
        value,_=manager(native,manager_identity);sequence=value['sample_sequence']
        provider.observe_manager(value,fresh=sequence!=last[0]);last[0]=sequence
        return independent(args.identity_library)
    # This CLI has no AppKit main loop. Keep its existing native connection on
    # the thread that created it, pumping only this probe's observation events.
    # The product's asynchronous worker and all ACK requirements stay intact.
    provider=PublicWorkspaceProvider(native,actions,read_independent,permitted=lambda:True,
        ordinary_required=True,submit=jobs.append,sleep=wait_observation)
    if not provider(target,preflight=True) or not provider(target,preflight=False):raise SwitchRefused(str(provider.last_result))
    if len(jobs)!=1:raise SwitchRefused('one root public operation required')
    jobs.pop()()
    return dict(mode='public-commit',generation=before.generation,target=request,result=provider.last_result,
                manager_identity=manager_identity,initial_manager=initial,reviewed_artifacts=artifacts,
                setter_called=False,public_action_called=provider.last_result.get('public_action_called',False),physical_pixels_claimed=False)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--commit',action='store_true');parser.add_argument('--request',type=Path)
    parser.add_argument('--helper',type=Path);parser.add_argument('--helper-sha');parser.add_argument('--source-sha')
    parser.add_argument('--identity-library',type=Path,default=ROOT/'hook/build/libmanaged_process_identity.dylib')
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    value=run(args);args.output.write_text(json.dumps(value,indent=2)+'\n')
    raise SystemExit(0 if not args.commit or value['result'].get('acknowledged') else 1)
