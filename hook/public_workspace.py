"""Async public Mission Control switch; sender ACK alone never completes it.

No native imports/loads/actions at construction. Only an explicitly permitted
commit schedules one public AX select. No raw setter/create/delete fallback.
"""
import copy
import threading
import time

from managed_space_switch import Snapshot,SwitchRefused,_frozen
from managed_space_create import catalog,dock_identity,public_snapshot,canonical_public
import ordinary_workspace_witness as ordinary


class PendingACK(SwitchRefused):
    pass


def independent(row,before,target,*,ordinary_required=False):
    if (not isinstance(row,dict) or row.get('mode')!='native-diagnostic' or row.get('setter_called') is not False or
            row.get('locked') is not False or _frozen(row.get('generation'))!=before.generation):
        raise SwitchRefused('independent display/global native observation disagrees')
    identity=_frozen(row.get('observer_identity'))
    if not isinstance(identity,tuple) or len(identity)!=5 or type(identity[0]) is not int or identity[0]<=0:
        raise SwitchRefused('exact independent observer native birth required')
    rows=row.get('displays')
    if not isinstance(rows,list) or len(rows)!=1:
        raise SwitchRefused('single-display independent current witness required')
    d=rows[0]
    topology=[dict(sid=s.sid,uuid=s.uuid,type=s.kind) for _,spaces in before.topology for s in spaces]
    if (d.get('display')!=target.display or d.get('spaces')!=topology or type(d.get('current_getter')) is not int):
        raise SwitchRefused('independent display getter/catalog/UUID topology differs')
    if (row.get('consistent') is not True or row.get('active_before')!=target.sid or
            row.get('active_after')!=target.sid or d.get('current_catalog')!=target.sid or d.get('current_getter')!=target.sid):
        raise PendingACK('independent display/global native target not durably observed yet')
    if ordinary_required and not ordinary.validate(row,space=target.sid):
        raise SwitchRefused('complete independent ordinary-application occupancy required')
    return identity


class PublicWorkspaceProvider:
    def __init__(self,native,actions,read_independent,*,locked=lambda:False,permitted=lambda:False,
                 clock=time.monotonic,sleep=time.sleep,submit=None,timeout=6,ordinary_required=False):
        self.native,self.actions,self.read_independent=native,actions,read_independent
        self.locked,self.permitted,self.clock,self.sleep=locked,permitted,clock,sleep
        self.submit=submit or (lambda fn:threading.Thread(target=fn,daemon=True).start())
        self.timeout=min(10,max(2,timeout));self.ticket=None;self.pending=None
        self.ordinary_required=ordinary_required
        self.lock=threading.Lock();self.manager=[];self.serial=0;self.manager_sequence=None
        self.last_result=dict(requested=False,acknowledged=False,state='not-loaded',backend='public-Mission-Control-AX')

    def _read(self):
        if self.locked():raise SwitchRefused('session locked')
        value=Snapshot.parse(self.native.snapshot())
        if value.locked or len(value.topology)!=1:raise SwitchRefused('single ordinary display required')
        return value

    def __call__(self,target,*,preflight=False):
        try:
            if type(target.ordinal) is not int or not 1<=target.ordinal<=10 or type(target.sid) is not int:
                raise SwitchRefused('bounded native ordinal/integer SID required')
            if self.permitted() is not True:raise SwitchRefused('public backend device/source permission absent')
            fresh=self._read();resolved=catalog(fresh).ordinal(str(target.ordinal))
            expected=fresh.find(target.display,target.sid)
            if resolved!=target or expected is None or expected.kind!=0:
                raise SwitchRefused('exact native ordinal/display/SID/UUID target changed')
            source=fresh.find(target.display,fresh.active)
            if source is None or source.kind!=0 or dict(fresh.currents)[target.display]!=fresh.active:
                raise SwitchRefused('ordinary source display/global current required')
            with self.lock:
                if self.pending is not None:raise SwitchRefused('public switch already pending')
                if preflight:
                    self.actions.prepare()
                    self.ticket=(expected,fresh,self.clock()+1)
                    self.last_result=dict(requested=False,acknowledged=False,state='prepared',backend='public-Mission-Control-AX')
                    return True
                ticket,self.ticket=self.ticket,None
                if (not ticket or self.clock()>ticket[2] or ticket[0]!=expected or
                        fresh.generation!=ticket[1].generation or fresh.topology!=ticket[1].topology or
                        fresh.active not in (ticket[1].active,expected.sid)):
                    raise SwitchRefused('public preflight expired/native identity changed')
                self.serial+=1;epoch=self.serial;self.pending=epoch;self.manager=[];self.manager_sequence=None
                self.last_result=dict(requested=True,acknowledged=False,state='pending',backend='public-Mission-Control-AX',
                    epoch=epoch,sid=expected.sid,uuid=expected.uuid,display=expected.display,
                    target_type=0,started=self.clock(),generation=fresh.generation)
                self.last_result['public_action_called']=False
            self.submit(lambda:self._execute(epoch,expected,fresh))
            return True
        except (ValueError,OSError,TypeError,AttributeError) as error:
            with self.lock:
                self.ticket=None
                if self.pending is None:self.last_result.update(acknowledged=False,state='refused',reason=str(error))
            return False

    def observe_manager(self,value,*,fresh):
        """Only the actual main-loop native snapshot enters this inbox.

        Empty window lists are valid. No tree/focus/key-window occupancy alias
        can substitute for current native SID/display/UUID/type0 metadata.
        """
        if not fresh:return
        with self.lock:
            if self.pending is None:return
            sequence=value.get('sample_sequence')
            if sequence is not None:
                if type(sequence) is not int or sequence==self.manager_sequence:return
                if self.manager_sequence is not None and sequence<self.manager_sequence:
                    self.manager=[];return
                self.manager_sequence=sequence
            state=self.last_result
            matches=[row for row in value.get('workspace_native',[]) if row.get('display')==state['display']]
            valid=(value.get('stable') in (True,1) and value.get('space')==state['sid'] and
                   value.get('space_type')==0 and len(matches)==1 and matches[0].get('sid')==state['sid'] and
                   matches[0].get('uuid')==state['uuid'] and matches[0].get('type')==0 and not self.locked())
            if not valid:self.manager=[];return
            if self.ordinary_required and not ordinary.validate(value,space=state['sid']):self.manager=[];return
            sample=dict(epoch=self.pending,time=self.clock(),space=state['sid'],native=copy.deepcopy(matches[0]))
            if sequence is not None:sample['sample_sequence']=sequence
            count=value.get('native_current_window_count')
            if type(count) is int and count>=0:sample['native_current_window_count']=count
            if self.ordinary_required:
                sample.update(ordinary_window_count=value['ordinary_window_count'],ordinary_descriptor=copy.deepcopy(value['ordinary_descriptor']))
            self.manager.append(sample)
            self.manager=self.manager[-16:]

    def _execute(self,epoch,target,before):
        try:
            if self.permitted() is not True:raise SwitchRefused('public source/device permission revoked before worker')
            deadline=self.clock()+self.timeout
            identity=dock_identity(before.generation)
            now=self._read()
            if now!=before:raise SwitchRefused('native state changed before public action')
            if now.active!=target.sid:
                # Dock retains Desktop AX buttons offscreen after overview closes.
                # Their mere presence cannot establish that a public action is live.
                self.actions.open_overview()
                inspection=self.actions.inspect(identity['pid'])
                if inspection.get('dock')!=identity or inspection.get('error') or inspection.get('truncated') is not False:
                    raise SwitchRefused('fresh complete exact Dock birth inspection required')
                ordinal=catalog(before).by_sid(target.sid).ordinal
                description='выйти на Рабочий стол %d'%ordinal
                controls=inspection.get('controls',[])
                visible=any(row.get('description')==description and row.get('role')=='AXButton' for row in controls)
                inspect_deadline=min(deadline,self.clock()+3)
                while True:
                    if self._read()!=before:raise SwitchRefused('native pre-action current/topology changed')
                    inspection=self.actions.inspect(identity['pid'])
                    if (inspection.get('dock')!=identity or inspection.get('error') or inspection.get('truncated') is not False):
                        raise SwitchRefused('public spaces-bar identity/inspection changed')
                    matches=[row for row in inspection.get('controls',[]) if row==dict(identifier='',role='AXButton',description=description,press=True)]
                    if len(matches)==1:break
                    if len(matches)>1 or self.clock()>=inspect_deadline:raise SwitchRefused('unique exact ordinary Desktop control unavailable')
                    self.sleep(.05)
                request=dict(dock=identity,snapshot=public_snapshot(before),
                             target=dict(display=target.display,sid=target.sid,uuid=target.uuid,type=0))
                if self.permitted() is not True:raise SwitchRefused('public source/device permission revoked before AX request')
                with self.lock:self.last_result['public_action_called']=True
                receipt=self.actions.select_ordinary(identity['pid'],request,inspection)
                if (receipt.get('mode')!='select-ordinary' or receipt.get('target')!=request['target'] or
                        receipt.get('dock')!=identity or receipt.get('ax_error')!=0 or receipt.get('native_current_ack') is not True or
                        receipt.get('dock_fence_after') is not True or
                        canonical_public(receipt.get('before_spaces'))!=public_snapshot(before)):
                    raise SwitchRefused('public AX request identity/ACK refused')
            # Child/helper sender ACK is not the daemon ACK. Independently read
            # fresh processes, then also require three actual main-loop samples.
            # Sender already has its own bounded timeout; grant a fresh bounded
            # ACK interval after it returns, matching the native Swift provider.
            deadline=self.clock()+self.timeout
            seen=set();samples=[]
            while self.clock()<deadline:
                native=self._read()
                if native.generation!=before.generation or native.topology!=before.topology:
                    raise SwitchRefused('native session/Dock/topology changed after public request')
                if native.active!=target.sid or dict(native.currents)[target.display]!=target.sid:
                    samples=[];self.sleep(.05);continue
                row=self.read_independent()
                try:observer=independent(row,before,target,ordinary_required=self.ordinary_required)
                except PendingACK:
                    samples=[];self.sleep(.05);continue
                if observer in seen:raise SwitchRefused('independent ACK reused observer process')
                seen.add(observer);sample=dict(time=self.clock(),observer=observer)
                if self.ordinary_required:
                    sample.update(ordinary_window_count=row['ordinary_window_count'],ordinary_descriptor=copy.deepcopy(row['ordinary_descriptor']),
                                  native_current_window_count=row.get('native_current_window_count'))
                samples.append(sample)
                with self.lock:manager=copy.deepcopy(self.manager)
                if (len(samples)>=3 and samples[-1]['time']-samples[0]['time']>=.15 and
                        len(manager)>=3 and manager[-1]['time']-manager[0]['time']>=.15):
                    with self.lock:
                        if self.pending!=epoch:raise SwitchRefused('request epoch invalidated')
                        self.last_result.update(acknowledged=True,state='acknowledged',independent_samples=samples,
                                                manager_samples=manager,completed=self.clock())
                        self.pending=None
                    return
                self.sleep(.05)
            raise SwitchRefused('independent/manager durable native ACK timed out')
        except Exception as error:
            with self.lock:
                if self.pending==epoch:
                    self.pending=None;self.last_result.update(acknowledged=False,state='failed',reason=str(error))
                    if isinstance(getattr(error,'helper_receipt',None),dict):
                        self.last_result['helper_receipt']=copy.deepcopy(error.helper_receipt)
