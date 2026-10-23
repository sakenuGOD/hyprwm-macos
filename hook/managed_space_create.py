"""Bounded public Mission Control AX creation, with native identity readback.

Constructors are inert. Only explicit ensure() opens Mission Control or presses
its spaces-bar controls. No raw Space creation, coordinates or user windows.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time

from managed_space_switch import Snapshot, SnapshotUnstable, SwitchRefused
from workspace_policy import Catalog, Target


def public_snapshot(snapshot):
    return {'active': snapshot.active, 'displays': [
        {'display': display, 'current': dict(snapshot.currents)[display], 'spaces': [
            {'id64': s.sid, 'ManagedSpaceID': s.sid, 'type': s.kind, 'uuid': s.uuid}
            for s in spaces]} for display, spaces in snapshot.topology]}


def canonical_public(value):
    """Compare only identity fields, preserving all native Space order/types."""
    if not isinstance(value, dict) or value.get('error'):
        raise SwitchRefused('bounded public native Space snapshot required')
    displays = value.get('displays')
    if not isinstance(displays, list) or len(displays) != 1:
        raise SwitchRefused('creation requires exactly one managed display')
    d = displays[0]
    raw = {'generation': ('public',), 'active': value.get('active'), 'locked': False,
           'displays': [{'Display Identifier': d.get('display'), 'Spaces': d.get('spaces'),
                         'Current Space': {'id64': d.get('current')}}]}
    return public_snapshot(Snapshot.parse(raw))


def dock_identity(generation):
    if len(generation) != 4 or not isinstance(generation[3], tuple) or len(generation[3]) != 5:
        raise SwitchRefused('exact native Dock birth/path generation required')
    pid, uid, sec, usec, path = generation[3]
    return dict(pid=pid, uid=uid, start_sec=sec, start_usec=usec, path=path)


def catalog(snapshot):
    spaces = [s for _, rows in snapshot.topology for s in rows if s.kind == 0]
    return Catalog(tuple(Target(n + 1, s.sid, s.display) for n, s in enumerate(spaces)), snapshot.active)


def appended_space(before, after):
    if (before.generation != after.generation or before.locked or after.locked or
            before.currents != after.currents or before.active != after.active or
            len(before.topology) != 1 or len(after.topology) != 1):
        raise SwitchRefused('native generation/current/lock/display changed during creation')
    display, old = before.topology[0]
    new_display, new = after.topology[0]
    if new_display != display:
        raise SwitchRefused('managed display changed during creation')
    if new == old:
        return None
    if len(new) != len(old) + 1 or new[:-1] != old:
        raise SwitchRefused('AX add did not preserve every original native Space identity/order')
    added = new[-1]
    if added.kind != 0 or not added.uuid or added.uuid in {s.uuid for s in old}:
        raise SwitchRefused('new unique ordinary native Space/UUID required')
    return added


class MissionControlCreator:
    def __init__(self, native, actions, *, locked=lambda: False, clock=time.monotonic,
                 sleep=time.sleep, timeout=25):
        self.native, self.actions, self.locked = native, actions, locked
        self.clock, self.sleep = clock, sleep
        self.timeout = min(25, max(1, timeout))
        self.last_result = {'requested': False, 'acknowledged': False, 'state': 'not-started'}
        self.receipts = []

    def ensure(self, ordinal):
        self.last_result = {'requested': False, 'acknowledged': False, 'state': 'not-started'}
        self.receipts = []
        try:
            return self._ensure(ordinal)
        except (SwitchRefused, OSError, ValueError, TypeError, AttributeError, subprocess.TimeoutExpired) as error:
            self.last_result.update(acknowledged=False, state='refused', reason=str(error))
            raise

    def _ensure(self, ordinal):
        if type(ordinal) is not int or not 1 <= ordinal <= 10:
            raise SwitchRefused('creation selector must be ordinal1..10')
        deadline = self.clock() + self.timeout
        def read():
            if self.locked() or self.clock() >= deadline:
                raise SwitchRefused('session locked or bounded creation deadline elapsed')
            value = Snapshot.parse(self.native.snapshot())
            if value.locked:
                raise SwitchRefused('native session locked during creation')
            return value
        initial = read()
        current_catalog = catalog(initial)
        if any(t.ordinal == ordinal for t in current_catalog.targets):
            self.last_result = dict(requested=False, acknowledged=True, state='already-exists')
            return current_catalog
        if len(initial.topology) != 1 or initial.find(initial.topology[0][0], initial.active).kind != 0:
            raise SwitchRefused('single display and current ordinary desktop required for creation')
        if dict(initial.currents)[initial.topology[0][0]] != initial.active:
            raise SwitchRefused('per-display and global current differ before creation')
        identity = dock_identity(initial.generation)
        self.actions.prepare()  # Verify helper before opening any native UI.
        authorization = self.actions.inspect(identity['pid'])
        if authorization.get('error') or authorization.get('dock') != identity:
            raise SwitchRefused('exact Dock generation and nonprompting AX access required before opening Mission Control')
        if read() != initial:
            raise SwitchRefused('native state changed before opening Mission Control')
        self.last_result = dict(requested=True, acknowledged=False, state='opening', created=[])
        self.actions.open_overview()
        state = initial
        for _ in range(10 - len(current_catalog.targets)):
            if len(catalog(state).targets) >= ordinal:
                break
            inspection_deadline = min(deadline, self.clock() + 3)
            while True:
                inspection = self.actions.inspect(identity['pid'])
                if (inspection.get('error') or inspection.get('mode') != 'inspect' or
                        inspection.get('truncated') is not False or inspection.get('dock') != identity):
                    raise SwitchRefused('fresh bounded exact-generation spaces-bar inspection required')
                controls = inspection.get('controls', [])
                if not isinstance(controls, list) or len(controls) > 128:
                    raise SwitchRefused('bounded spaces-bar controls required')
                add = [row for row in controls if isinstance(row, dict) and row.get('identifier') == 'mc.spaces.add']
                if len(add) > 1:
                    raise SwitchRefused('ambiguous public AX add-desktop control')
                if len(add) == 1 and add[0].get('role') == 'AXButton' and add[0].get('press') is True:
                    break
                if self.clock() >= inspection_deadline:
                    raise SwitchRefused('unique public AX add-desktop control unavailable')
                if read() != state:
                    raise SwitchRefused('native state changed while waiting for spaces-bar control')
                self.sleep(.05)
            if read() != state:
                raise SwitchRefused('native state changed before single public AX add')
            receipt = self.actions.press_add(identity['pid'], inspection)
            self.receipts.append(receipt)
            if (receipt.get('error') or receipt.get('mode') != 'press' or receipt.get('dock') != identity or
                    receipt.get('dock_fence_after') is not True or type(receipt.get('ax_error')) is not int or
                    receipt['ax_error'] != 0 or receipt.get('control') != add[0] or
                    canonical_public(receipt.get('before_spaces')) != public_snapshot(state)):
                raise SwitchRefused('single public AX add failed its exact native pre-action fence')
            # An action is never retried. Only native readback may settle.
            addition_deadline = min(deadline, self.clock() + 2)
            while True:
                try:
                    fresh = read()
                    added = appended_space(state, fresh)
                except SnapshotUnstable:
                    added = None
                if added is not None:
                    state = fresh
                    self.last_result['created'].append(dict(sid=added.sid, uuid=added.uuid, display=added.display, type=0))
                    break
                if self.clock() >= addition_deadline:
                    raise SwitchRefused('single AX add yielded no unique native ordinary Space ACK')
                self.sleep(.02)
        if len(catalog(state).targets) < ordinal:
            raise SwitchRefused('bounded ordinary Space addition limit reached')
        if read() != state:
            raise SwitchRefused('native state changed before exact original desktop return')
        inspection = self.actions.inspect(identity['pid'])
        original = initial.find(initial.topology[0][0], initial.active)
        target = dict(display=original.display, sid=original.sid, uuid=original.uuid, type=0)
        request = dict(dock=identity, snapshot=public_snapshot(state), target=target)
        # Native selector validates exact inspection/control again and presses once.
        receipt = self.actions.select_ordinary(identity['pid'], request, inspection)
        self.receipts.append(receipt)
        if (receipt.get('error') or receipt.get('mode') != 'select-ordinary' or receipt.get('target') != target or
                receipt.get('dock') != identity or receipt.get('dock_fence_after') is not True or
                receipt.get('native_current_ack') is not True or type(receipt.get('ax_error')) is not int or receipt['ax_error'] != 0 or
                canonical_public(receipt.get('before_spaces')) != public_snapshot(state)):
            raise SwitchRefused('public AX return to exact original ordinary desktop not acknowledged')
        final = read()
        if final != state:
            raise SwitchRefused('final native generation/topology/original current differs after desktop return')
        self.last_result.update(acknowledged=True, state='acknowledged', ordinal=ordinal)
        return catalog(final)


class NativeMissionControlActions:
    """Explicit root-operated candidate; construction has no file/UI/native calls."""
    def __init__(self, helper, *, source_sha256, binary_sha256):
        self.helper = Path(helper)
        self.source_sha256, self.binary_sha256 = source_sha256, binary_sha256

    def prepare(self):
        source = Path(__file__).parent / 'scripts' / 'tools' / 'mission_control_ax.m'
        if (hashlib.sha256(source.read_bytes()).hexdigest() != self.source_sha256 or
                hashlib.sha256(self.helper.read_bytes()).hexdigest() != self.binary_sha256):
            raise SwitchRefused('Mission Control helper source/artifact hash changed')
        result = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(self.helper)],
                                capture_output=True, timeout=1)
        if result.returncode:
            raise SwitchRefused('Mission Control helper signature failed')

    def open_overview(self):
        result = subprocess.run(['/usr/bin/open', '/System/Applications/Mission Control.app'],
                                capture_output=True, timeout=2)
        if result.returncode:
            raise SwitchRefused('public Mission Control application could not be opened')

    def _run(self, argv):
        self.prepare()
        with tempfile.TemporaryFile() as output:
            result = subprocess.run([str(self.helper), *argv], stdout=output, stderr=subprocess.DEVNULL, timeout=8)
            output.seek(0);data = output.read(262145)
        if not 0 < len(data) <= 262144:
            raise SwitchRefused('bounded Mission Control helper metadata required')
        value = json.loads(data)
        if not isinstance(value, dict) or result.returncode or value.get('error'):
            error=SwitchRefused('Mission Control helper refused: ' + str(value.get('error') if isinstance(value, dict) else 'invalid metadata'))
            error.helper_receipt=value if isinstance(value,dict) else None
            raise error
        return value

    def inspect(self, pid):
        return self._run(['--inspect', str(pid)])

    def press_add(self, pid, inspection):
        with tempfile.TemporaryDirectory(prefix='hypr-mc-add-') as directory:
            receipt = Path(directory) / 'inspection.json';receipt.write_text(json.dumps(inspection))
            return self._run(['--press', str(pid), 'mc.spaces.add', '--receipt', str(receipt)])

    def select_ordinary(self, pid, request, inspection):
        with tempfile.TemporaryDirectory(prefix='hypr-mc-return-') as directory:
            target = Path(directory) / 'target.json';target.write_text(json.dumps(request))
            receipt = Path(directory) / 'inspection.json';receipt.write_text(json.dumps(inspection))
            return self._run(['--select-ordinary', str(pid), '--target', str(target), '--receipt', str(receipt)])
