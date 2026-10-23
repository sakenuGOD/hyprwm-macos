"""Lazy public provider behind an explicit reviewed device permission file."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from managed_space_switch import NativeDriver,SwitchRefused,_bounded_receipt,_frozen
from managed_space_create import NativeMissionControlActions
from public_workspace import PublicWorkspaceProvider

LEGACY_SOURCE_GATE=('hook/hyprwm.py','hook/src/winsnap.m','hook/build/libwinsnap.dylib',
             'hook/public_workspace.py','hook/public_workspace_factory.py',
             'hook/scripts/tools/public_workspace_switch.py')
SOURCE_GATE=LEGACY_SOURCE_GATE+('hook/ordinary_workspace_witness.py','hook/system_ui.py','hook/own_ui.py','hook/lifecycle.py')


class VerifiedPublicProvider:
    def __init__(self,*,locked,permission,identity_library,driver_factory=NativeDriver,
                 actions_factory=NativeMissionControlActions,independent_reader=None):
        self.locked,self.permission,self.identity_library=locked,Path(permission),Path(identity_library)
        self.driver_factory,self.actions_factory=driver_factory,actions_factory
        self.independent_reader=independent_reader;self.backend=None
        self.last_result=dict(requested=False,acknowledged=False,state='not-loaded',backend='public-Mission-Control-AX')

    def _verify(self):
        proof=_bounded_receipt(self.permission)
        v2=proof.get('schema')==2
        empty_ack=(proof.get('manager_empty_ordinary_space_ack') is True and
                   proof.get('ordinary_scope')=='native-layer0-application-windows' and
                   proof.get('shell_exclusions_complete') is True) if v2 else proof.get('manager_empty_space_ack') is True
        if (proof.get('backend')!='public-Mission-Control-AX' or proof.get('acknowledged') is not True or
                proof.get('independent_ack') is not True or proof.get('manager_ack') is not True or
                not empty_ack or proof.get('returned_original') is not True):
            raise SwitchRefused('public independent/manager/empty-Space/return device permission absent')
        helper=Path(proof['helper']);source=Path(proof['source'])
        identity_source=Path(__file__).resolve().parent/'src/managed_process_identity.c'
        if (source.name!='mission_control_ax.m' or
                hashlib.sha256(helper.read_bytes()).hexdigest()!=proof.get('helper_sha') or
                hashlib.sha256(source.read_bytes()).hexdigest()!=proof.get('source_sha') or
                subprocess.run(['/usr/bin/codesign','--verify','--strict',str(helper)],capture_output=True,timeout=1).returncode):
            raise SwitchRefused('public helper source/image/signature differs')
        if (hashlib.sha256(self.identity_library.read_bytes()).hexdigest()!=proof.get('identity_library_sha') or
                hashlib.sha256(identity_source.read_bytes()).hexdigest()!=proof.get('identity_source_sha') or
                subprocess.run(['/usr/bin/codesign','--verify','--strict',str(self.identity_library)],capture_output=True,timeout=1).returncode):
            raise SwitchRefused('public native identity helper source/image/signature differs')
        root=Path(__file__).resolve().parent.parent
        gates=proof.get('sources')
        source_gate=SOURCE_GATE if v2 else LEGACY_SOURCE_GATE
        if not isinstance(gates,dict) or set(gates)!=set(source_gate):
            raise SwitchRefused('reviewed installed public WM/native/provider source gate absent')
        for relative in source_gate:
            if hashlib.sha256((root/relative).read_bytes()).hexdigest()!=gates[relative]:
                raise SwitchRefused('installed public source/image gate differs: '+relative)
        return proof

    def _independent(self):
        script=Path(__file__).resolve().parent/'ordinary_workspace_witness.py'
        child=subprocess.run([sys.executable,str(script),'--diagnostic','--identity-library',str(self.identity_library)],
            capture_output=True,text=True,timeout=1)
        if child.returncode or len(child.stdout.encode())>262144:raise SwitchRefused('fresh bounded independent native observer failed')
        value=json.loads(child.stdout)
        if value.get('observer_identity',[os.getpid()])[0]==os.getpid():raise SwitchRefused('observer must be a fresh independent process')
        return value

    def __call__(self,target,*,preflight=False):
        try:
            proof=self._verify()
            expected=_frozen(proof['generation'])
            if self.backend is None:
                native=self.driver_factory(identity_library=str(self.identity_library))
                if _frozen(proof.get('manager_identity'))!=_frozen(native._identity(os.getpid())):
                    raise SwitchRefused('public reviewed manager birth/path differs')
                class FencedNative:
                    def snapshot(driver):
                        value=native.snapshot()
                        if value['generation']!=expected:raise SwitchRefused('public device native session generation changed')
                        return value
                actions=self.actions_factory(proof['helper'],source_sha256=proof['source_sha'],binary_sha256=proof['helper_sha'])
                self.backend=PublicWorkspaceProvider(FencedNative(),actions,self.independent_reader or self._independent,
                    locked=self.locked,permitted=lambda:self._verify().get('acknowledged') is True,
                    ordinary_required=proof.get('schema')==2)
            accepted=self.backend(target,preflight=preflight)
            self.last_result=dict(self.backend.last_result)
            return accepted
        except (ValueError,OSError,TypeError,AttributeError,KeyError,subprocess.TimeoutExpired) as error:
            self.last_result=dict(requested=False,acknowledged=False,state='refused',backend='public-Mission-Control-AX',reason=str(error))
            return False

    def observe_manager(self,value,*,fresh):
        if self.backend:
            self.backend.observe_manager(value,fresh=fresh)
            self.last_result=dict(self.backend.last_result)


def provider(*,locked,permission=None,identity_library=None):
    hook=Path(__file__).resolve().parent
    return VerifiedPublicProvider(locked=locked,permission=permission or hook/'workspace-public-permission.json',
        identity_library=identity_library or hook/'build/libmanaged_process_identity.dylib')
