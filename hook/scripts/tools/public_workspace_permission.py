#!/usr/bin/env python3
"""Root-only public empty-desktop round trip; permission follows actual proof.

Prepare reads files only. Run uses ordinary public Mission Control AX actions,
never a raw Space setter, app activation, creation/deletion or window refill.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import sys
import stat
import tempfile
import types

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'hook'))
from managed_space_switch import NativeDriver,Snapshot,SwitchRefused,_bounded_receipt,_frozen
from managed_space_create import catalog,MissionControlCreator,NativeMissionControlActions,dock_identity,public_snapshot,canonical_public,appended_space
from public_workspace_factory import SOURCE_GATE
from scripts.tools import public_workspace_switch as switch
import ordinary_workspace_witness as ordinary
SWIFT_SOURCE_GATE=tuple('hook/swift/Sources/'+name for name in (
    'CSnap/workspace.m','HyprCore/PublicWorkspace.swift','HyprCore/WM.swift','HyprCore/Interfaces.swift',
    'HyprCore/WMProduction.swift','HyprCore/WorkspaceCommand.swift','hyprwm-swift/VerifiedPublicWorkspace.swift','hyprwm-swift/main.swift'))


def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def artifacts(helper,source,identity):
    return dict(helper=str(helper.resolve()),source=str(source.resolve()),identity_library=str(identity.resolve()),
                helper_sha=digest(helper),source_sha=digest(source),identity_library_sha=digest(identity),
                identity_source_sha=digest(ROOT/'hook/src/managed_process_identity.c'),
                sources={relative:digest(ROOT/relative) for relative in SOURCE_GATE})


def prepare(args):
    actor=_bounded_receipt(args.manager_record)
    if (type(actor.get('pid')) is not int or not isinstance(actor.get('birth'),list) or len(actor['birth'])!=4 or
            any(type(value) is not int for value in actor['birth']) or actor['birth'][0]!=actor['pid'] or
            actor['birth'][1]!=os.getuid() or actor['birth'][2]<=0 or not 0<=actor['birth'][3]<1000000):
        raise SwitchRefused('exact same-owner final daemon birth record required')
    reviewed=artifacts(args.helper,args.source,args.identity_library)
    manager_runtime='python';manager_image=None;swift_sources=None
    if args.manager_image:
        manager_runtime='swift';manager_image=dict(path=str(args.manager_image.resolve()),sha256=digest(args.manager_image))
        swift_sources={relative:digest(ROOT/relative) for relative in SWIFT_SOURCE_GATE}
        if args.manager_image.name!='hyprwm-swift':raise SwitchRefused('exact Swift manager binary name required')
        if (actor.get('sha')!=manager_image['sha256'] or
                not isinstance(actor.get('image'),str) or str(Path(actor['image']).resolve())!=manager_image['path']):
            raise SwitchRefused('actual launched Swift image receipt differs from current binary; adopt final frozen build first')
    else:
        if not args.daemon_sources:raise SwitchRefused('actual Python source freeze or exact Swift manager image required')
        loaded=_bounded_receipt(args.daemon_sources)
        for relative in ('hook/hyprwm.py','hook/public_workspace.py','hook/public_workspace_factory.py','hook/scripts/tools/public_workspace_switch.py'):
            if loaded.get(relative)!=reviewed['sources'][relative]:
                raise SwitchRefused('final daemon source freeze differs: '+relative)
    target=dict(empty_sid=args.empty_sid,empty_ordinal=args.empty_ordinal,empty_uuid=args.empty_uuid)
    catalog_review=None
    if args.catalog_proof:
        observed=_bounded_receipt(args.catalog_proof)
        if observed.get('mode')!='public-empty-inspection' or observed.get('setter_called') is not False:
            raise SwitchRefused('read-only public ordinary catalog proof required')
        matches=[row for row in observed.get('targets',[]) if row.get('ordinal')==args.empty_ordinal]
        if len(matches)!=1 or matches[0].get('type')!=0 or not ordinary.validate(matches[0],space=matches[0].get('sid'),require_empty=True):
            raise SwitchRefused('selected fresh ordinary target is not actually empty')
        target=dict(empty_sid=matches[0]['sid'],empty_ordinal=matches[0]['ordinal'],empty_uuid=matches[0]['uuid'])
        catalog_review=dict(path=str(args.catalog_proof.resolve()),sha256=digest(args.catalog_proof),generation=observed['generation'])
    creator=None
    if args.creator_receipt:
        _bounded_receipt(args.creator_receipt)  # Provenance only; native gates never trust a creator sender ACK.
        creator=dict(path=str(args.creator_receipt.resolve()),sha256=digest(args.creator_receipt))
    return dict(schema=1,mode='public-empty-round-trip-plan',manager_record=actor,
                daemon_sources=str(args.daemon_sources.resolve()) if args.daemon_sources else None,
                manager_runtime=manager_runtime,manager_image=manager_image,swift_sources=swift_sources,reviewed_artifacts=reviewed,
                **target,catalog_review=catalog_review,creator_provenance=creator,
                permission=str(args.permission.resolve()),native_actions_performed=False)


def checked_ack(value,*,empty=False,v2=False):
    result=value.get('result',{})
    if result.get('acknowledged') is not True or result.get('state')!='acknowledged':
        raise SwitchRefused('public sender/independent/manager round-trip ACK absent')
    independent=result.get('independent_samples',[]);manager=result.get('manager_samples',[])
    if (len(independent)<3 or len(manager)<3 or independent[-1]['time']-independent[0]['time']<.15 or
            manager[-1]['time']-manager[0]['time']<.15 or
            len({_frozen(row['observer']) for row in independent})!=len(independent) or
            len({row['sample_sequence'] for row in manager})!=len(manager)):
        raise SwitchRefused('three distinct durable independent/native manager samples required')
    if v2:
        if any(not ordinary.validate(row,require_empty=empty) for row in manager+independent):
            raise SwitchRefused('complete independent and manager ordinary occupancy descriptors required')
    elif empty and any(type(row.get('native_current_window_count')) is not int or row['native_current_window_count']!=0 for row in manager):
        raise SwitchRefused('actual destination native window count is not durably zero')
    return result


def native_occupancy(native):
    # This operation only runs in Root's explicit device command, on its main thread.
    lib=ctypes.CDLL(str(ROOT/'hook/build/libwinsnap.dylib'))
    lib.ws_snapshot.argtypes=[ctypes.c_void_p,ctypes.c_int];lib.ws_snapshot.restype=ctypes.c_int
    buffer=ctypes.create_string_buffer(1<<21)
    if lib.ws_snapshot(buffer,len(buffer))<0:raise SwitchRefused('bounded native window census unavailable')
    snapshot=json.loads(buffer.value)
    if snapshot.get('stable') not in (True,1) or snapshot.get('space_type')!=0:
        raise SwitchRefused('fresh stable ordinary native window census required')
    counts={};records=[]
    for window in snapshot['windows']:
        if window.get('owner')=='hyprdeco':continue  # Exactly the manager's native census contract.
        sid=window.get('space');counts[sid]=counts.get(sid,0)+1
        owner=ctypes.c_int();level=ctypes.c_int();native_pid=ctypes.c_int()
        native.sl.SLSGetWindowOwner.argtypes=[ctypes.c_int,ctypes.c_uint32,ctypes.POINTER(ctypes.c_int)]
        native.sl.SLSGetWindowLevel.argtypes=[ctypes.c_int,ctypes.c_uint32,ctypes.POINTER(ctypes.c_int)]
        native.sl.SLSConnectionGetPID.argtypes=[ctypes.c_int,ctypes.POINTER(ctypes.c_int)]
        code=native.sl.SLSGetWindowOwner(native.sl.SLSMainConnectionID(),window['wid'],ctypes.byref(owner))
        owner_code=native.sl.SLSConnectionGetPID(owner.value,ctypes.byref(native_pid)) if code==0 else -1
        level_code=native.sl.SLSGetWindowLevel(native.sl.SLSMainConnectionID(),window['wid'],ctypes.byref(level))
        try:birth=native._identity(native_pid.value if owner_code==0 else window['pid'])
        except (OSError,ValueError):birth=None
        records.append(dict(wid=window['wid'],pid=window['pid'],native_owner_pid=native_pid.value if owner_code==0 else None,
            birth=list(birth[:4]) if birth else None,executable=birth[4] if birth else None,
            owner_connection=owner.value if code==0 else None,layer=window.get('layer'),level=level.value if level_code==0 else None,
            on=window.get('on'),alpha=window.get('alpha'),space=sid))
    return dict(active=snapshot['space'],counts=counts,windows=records,stable=True,titles_read=False)


def inspect_empty(identity):
    native=NativeDriver(identity_library=str(identity));before=Snapshot.parse(native.snapshot())
    occupancy=native_occupancy(native)
    if Snapshot.parse(native.snapshot())!=before or occupancy['active']!=before.active:
        raise SwitchRefused('native source/catalog changed during read-only occupancy inspection')
    targets=[]
    for target in catalog(before).targets:
        descriptor=before.find(target.display,target.sid)
        witness=ordinary.Reader(ROOT/'hook').describe(occupancy['windows'],target.sid)
        targets.append(dict(ordinal=target.ordinal,sid=target.sid,display=target.display,uuid=descriptor.uuid,type=0,**witness,
            actual_window_count=occupancy['counts'].get(target.sid,0),
            windows=[row for row in occupancy['windows'] if row['space']==target.sid]))
    return dict(schema=1,mode='public-empty-inspection',generation=before.generation,active=before.active,
        observer_identity=native._identity(os.getpid()),targets=targets,source_stable=True,
        setter_called=False,public_action_called=False,titles_read=False)


def request_for(before,target):
    space=before.find(target.display,target.sid)
    return dict(ordinal=target.ordinal,sid=target.sid,display=target.display,uuid=space.uuid,type=0,
                source_sid=before.active,generation=before.generation)


def create_empty(args):
    """Append exactly one own ordinary desktop, then select the exact original publicly."""
    review=artifacts(args.helper,args.source,args.identity_library)
    native=NativeDriver(identity_library=str(args.identity_library));before=Snapshot.parse(native.snapshot())
    if before.locked or len(before.topology)!=1:raise SwitchRefused('unlocked single ordinary display required')
    ordinal=len(catalog(before).targets)+1
    if ordinal>10 or args.empty_ordinal!=ordinal:raise SwitchRefused('creation requires exact next ordinary ordinal; existing desktops untouched')
    original=catalog(before).by_sid(before.active)
    actions=NativeMissionControlActions(args.helper,source_sha256=review['source_sha'],binary_sha256=review['helper_sha'])
    class FencedNative:
        def snapshot(self):
            value=native.snapshot()
            if value['generation']!=before.generation:raise SwitchRefused('native session changed during public creation')
            return value
    creator=MissionControlCreator(FencedNative(),actions,timeout=10)
    creator.ensure(ordinal)
    after=Snapshot.parse(native.snapshot());created=appended_space(before,after)
    if created is None:raise SwitchRefused('exact single appended ordinary desktop not proven')
    # ensure() already returns through the exact original Desktop AX control
    # and waits for its native acknowledgement. Do not press its retained AX
    # control again after Mission Control has closed.
    returned=creator.receipts[-1]
    source=after.find(original.display,original.sid)
    request=dict(target=dict(display=source.display,sid=source.sid,uuid=source.uuid,type=0))
    final=Snapshot.parse(native.snapshot())
    if final!=after or final.active!=before.active or artifacts(args.helper,args.source,args.identity_library)!=review:
        raise SwitchRefused('native source/topology/artifacts changed after public create/return')
    observed=inspect_empty(args.identity_library);target=next(row for row in observed['targets'] if row['sid']==created.sid)
    if not ordinary.validate(target,space=created.sid,require_empty=True):raise SwitchRefused('own new desktop has ordinary windows or incomplete identities')
    return dict(schema=2,mode='public-create-own-empty-desktop',created=True,returned_original=True,
                original=request['target'],target=target,creation_result=creator.last_result,
                creation_receipts=creator.receipts,return_receipt=returned,generation=before.generation,
                reviewed_artifacts=review,inspection=observed,permission_issued=False,setter_called=False)


def execute(plan,folder):
    review=plan['reviewed_artifacts'];helper=Path(review['helper']);source=Path(review['source']);identity=Path(review['identity_library'])
    if artifacts(helper,source,identity)!=review:raise SwitchRefused('prepared source/image hashes changed')
    native=NativeDriver(identity_library=str(identity));before=Snapshot.parse(native.snapshot())
    if plan.get('catalog_review'):
        observed=plan['catalog_review']
        if digest(observed['path'])!=observed['sha256'] or _frozen(observed['generation'])!=before.generation:
            raise SwitchRefused('reviewed fresh native catalog/session changed')
    if plan.get('creator_provenance'):
        creator=plan['creator_provenance']
        if digest(creator['path'])!=creator['sha256']:raise SwitchRefused('optional creator provenance changed')
    if before.locked or len(before.topology)!=1:raise SwitchRefused('unlocked single ordinary display required')
    actor=plan['manager_record'];manager_identity=native._identity(actor['pid'])
    if list(manager_identity[:4])!=actor['birth']:raise SwitchRefused('final manager PID birth changed')
    if plan.get('manager_runtime')=='swift':
        image=plan.get('manager_image') or {}
        if manager_identity[4]!=image.get('path') or digest(image['path'])!=image.get('sha256'):
            raise SwitchRefused('actual Swift manager executable/image hash changed')
        if plan.get('swift_sources')!={relative:digest(ROOT/relative) for relative in SWIFT_SOURCE_GATE}:
            raise SwitchRefused('exact final Swift source gate changed')
    manager,_=switch.manager(native,manager_identity)
    if manager.get('space')!=before.active or manager.get('stable') not in (True,1):
        raise SwitchRefused('fresh manager/native original desktop differs')
    target=catalog(before).ordinal(str(plan['empty_ordinal']))
    expected=before.find(target.display,target.sid)
    if (target.sid!=plan['empty_sid'] or target.sid==before.active or expected.kind!=0 or
            expected.uuid!=plan['empty_uuid']):
        raise SwitchRefused('exact separate ordinary empty desktop required')
    original=catalog(before).by_sid(before.active)
    folder.mkdir(parents=True,exist_ok=False)
    occupancy=native_occupancy(native)
    (folder/'preflight-occupancy.json').write_text(json.dumps(occupancy,indent=2)+'\n')
    if occupancy['active']!=before.active or Snapshot.parse(native.snapshot())!=before:
        raise SwitchRefused('source/current/catalog changed during fresh occupancy census; no AX action')
    empty_witness=ordinary.Reader(ROOT/'hook').describe(occupancy['windows'],target.sid)
    (folder/'preflight-ordinary.json').write_text(json.dumps(empty_witness,indent=2)+'\n')
    if not ordinary.validate(empty_witness,space=target.sid,require_empty=True):
        raise SwitchRefused('target SID %d has %d ordinary application windows or incomplete identities; no AX action'%
                            (target.sid,empty_witness['ordinary_window_count']))
    proof=dict(schema=1,mode='public-empty-round-trip',passed=False,original=request_for(before,original),
               empty_target=request_for(before,target),manager_identity=manager_identity,
               reviewed_artifacts=review,preflight_actual_window_count=occupancy['counts'].get(target.sid,0),
               preflight_ordinary_witness=empty_witness,permission_issued=False)
    def commit(destination,label):
        now=Snapshot.parse(native.snapshot())
        if now.generation!=before.generation or now.topology!=before.topology or native._identity(actor['pid'])!=manager_identity:
            raise SwitchRefused('native topology/session or manager birth changed')
        request=folder/(label+'-request.json');request.write_text(json.dumps(request_for(now,destination),indent=2)+'\n')
        arguments=types.SimpleNamespace(commit=True,request=request,helper=helper,helper_sha=review['helper_sha'],
            source_sha=review['source_sha'],identity_library=identity)
        result=switch.run(arguments);(folder/(label+'-result.json')).write_text(json.dumps(result,indent=2)+'\n')
        if result.get('manager_identity')!=manager_identity:raise SwitchRefused('round-trip manager identity differs')
        return result
    error=None
    try:
        proof['outbound']=commit(target,'outbound');checked_ack(proof['outbound'],empty=True,v2=True)
        occupancy=native_occupancy(native)
        (folder/'destination-occupancy.json').write_text(json.dumps(occupancy,indent=2)+'\n')
        witness=ordinary.Reader(ROOT/'hook').describe(occupancy['windows'],target.sid)
        if occupancy['active']!=target.sid or not ordinary.validate(witness,space=target.sid,require_empty=True):
            raise SwitchRefused('destination ordinary occupancy changed or exclusion identities incomplete')
    except Exception as exc:error=exc;proof['error']=str(exc)
    finally:
        try:
            current=Snapshot.parse(native.snapshot())
            if current.active==target.sid:
                proof['return']=commit(original,'return');checked_ack(proof['return'],v2=True)
            elif current.active!=before.active:
                raise SwitchRefused('user/native current changed to another desktop; do not override it')
            proof['returned_original']=Snapshot.parse(native.snapshot()).active==before.active
        except Exception as exc:
            proof['return_error']=str(exc);error=error or exc
        (folder/'proof.json').write_text(json.dumps(proof,indent=2)+'\n')
    if error:raise SwitchRefused(str(error))
    if ('return' not in proof or artifacts(helper,source,identity)!=review or
            plan.get('manager_runtime')=='swift' and (
                digest(plan['manager_image']['path'])!=plan['manager_image']['sha256'] or
                plan.get('swift_sources')!={relative:digest(ROOT/relative) for relative in SWIFT_SOURCE_GATE})):
        raise SwitchRefused('actual return ACK or unchanged final source gate absent')
    permission=dict(schema=2,backend='public-Mission-Control-AX',acknowledged=True,independent_ack=True,manager_ack=True,
                    explicit_commands=dict(switch_existing=True,create_ordinary=False),
                    manager_empty_ordinary_space_ack=True,ordinary_scope=ordinary.SCOPE,shell_exclusions_complete=True,
                    returned_original=True,generation=before.generation,
                    manager_identity=manager_identity,manager_runtime=plan.get('manager_runtime','python'),
                    manager_image=plan.get('manager_image'),manager_image_sha=(plan.get('manager_image') or {}).get('sha256'),
                    swift_sources=plan.get('swift_sources'),proof=str((folder/'proof.json').resolve()),**review)
    proof['passed']=True
    (folder/'proof.json').write_text(json.dumps(proof,indent=2)+'\n')
    path=Path(plan['permission']);path.parent.mkdir(parents=True,exist_ok=True)
    if path.exists():
        metadata=path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid!=os.getuid() or stat.S_IMODE(metadata.st_mode)!=0o600 or metadata.st_size>262144:
            raise SwitchRefused('existing private permission is not a bounded same-owner0600 regular file')
        prior=path.read_bytes();(folder/'previous-permission.json').write_bytes(prior)
        os.chmod(folder/'previous-permission.json',0o600)
    fd,name=tempfile.mkstemp(prefix='.public-workspace-permission-',dir=path.parent)
    try:
        with os.fdopen(fd,'w') as stream:
            json.dump(permission,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
        os.replace(name,path)
    finally:
        if os.path.exists(name):os.unlink(name)
    proof.update(passed=True,permission_issued=True)
    (folder/'proof.json').write_text(json.dumps(proof,indent=2)+'\n')
    return proof


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    modes=parser.add_mutually_exclusive_group(required=True);modes.add_argument('--prepare',action='store_true');modes.add_argument('--run',type=Path)
    modes.add_argument('--inspect-empty',action='store_true')
    modes.add_argument('--create-empty',action='store_true')
    parser.add_argument('--manager-record',type=Path);parser.add_argument('--daemon-sources',type=Path)
    parser.add_argument('--helper',type=Path,default=ROOT/'hook/build/mission_control_ax')
    parser.add_argument('--source',type=Path,default=ROOT/'hook/scripts/tools/mission_control_ax.m')
    parser.add_argument('--identity-library',type=Path,default=ROOT/'hook/build/libmanaged_process_identity.dylib')
    parser.add_argument('--permission',type=Path,default=ROOT/'hook/workspace-public-permission.json')
    parser.add_argument('--empty-sid',type=int,default=3);parser.add_argument('--empty-ordinal',type=int,default=3)
    parser.add_argument('--empty-uuid',default='D759D39B-B3CC-4FB3-9088-D9BA38927A7B')
    parser.add_argument('--catalog-proof',type=Path);parser.add_argument('--creator-receipt',type=Path)
    parser.add_argument('--manager-image',type=Path)
    parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    try:
        if args.create_empty:
            try:value=create_empty(args)
            except Exception as exc:
                args.output.write_text(json.dumps(dict(schema=2,mode='public-create-own-empty-desktop-refused',
                    error=str(exc),permission_issued=False,setter_called=False),indent=2)+'\n');raise
            args.output.write_text(json.dumps(value,indent=2)+'\n')
        elif args.inspect_empty:
            value=inspect_empty(args.identity_library);args.output.write_text(json.dumps(value,indent=2)+'\n')
        elif args.prepare:
            if not args.manager_record or not(args.daemon_sources or args.manager_image):parser.error('final manager record and source freeze/image required')
            value=prepare(args);args.output.write_text(json.dumps(value,indent=2)+'\n')
        else:value=execute(_bounded_receipt(args.run),args.output)
        print(json.dumps(dict(passed=value.get('passed'),prepared=args.prepare,permission_issued=value.get('permission_issued',False))))
    except Exception as exc:
        print('refused: '+str(exc),file=sys.stderr);raise SystemExit(1)
