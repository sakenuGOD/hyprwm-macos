"""Fenced ordinary managed-Space switch candidate; imports never call native APIs.

The exported setter is asynchronous on 25G241. A dispatched request is distinct
from an acknowledgement observed in a fresh native catalog. No create, destroy,
show/hide, Dock restart, user-window mutation, or static-address calls exist here.
"""
from dataclasses import dataclass
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import time
import uuid


class SwitchRefused(ValueError):
    pass


class SnapshotUnstable(SwitchRefused):
    """A read straddled native transition; only bounded readback may be retried."""


@dataclass(frozen=True)
class Space:
    display: str
    sid: int
    uuid: str
    kind: int


@dataclass(frozen=True)
class Snapshot:
    generation: tuple
    topology: tuple
    currents: tuple
    active: int
    locked: bool

    @classmethod
    def parse(cls, value):
        if not isinstance(value, dict) or not isinstance(value.get('generation'), tuple) or not value['generation']:
            raise SwitchRefused('native session generation required')
        displays = value.get('displays')
        if not isinstance(displays, list) or not 0 < len(displays) <= 16:
            raise SwitchRefused('bounded native display catalog required')
        topology, currents, ids, identifiers = [], [], set(), set()
        for d in displays:
            identifier = d.get('Display Identifier') if isinstance(d, dict) else None
            rows = d.get('Spaces') if isinstance(d, dict) else None
            if not isinstance(identifier, str) or not identifier or len(identifier) > 128 or '\0' in identifier or identifier in identifiers:
                raise SwitchRefused('unique native display identifier required')
            identifiers.add(identifier)
            if not isinstance(rows, list) or not 0 < len(rows) <= 64:
                raise SwitchRefused('bounded native Space list required')
            spaces = []
            for row in rows:
                if not isinstance(row, dict):
                    raise SwitchRefused('invalid native Space row')
                sid = row.get('id64', row.get('ManagedSpaceID'))
                kind = row.get('type')
                name = row.get('uuid', row.get('UUID'))
                if type(sid) is not int or not 0 < sid < 2**53 or sid in ids or type(kind) is not int:
                    raise SwitchRefused('unique exactly representable native SID/type required')
                if ('ManagedSpaceID' in row and row['ManagedSpaceID'] != sid) or ('UUID' in row and row['UUID'] != name):
                    raise SwitchRefused('native identity aliases disagree')
                if not isinstance(name, str) or len(name) > 128 or '\0' in name:
                    raise SwitchRefused('explicit native UUID required, including the original empty UUID')
                ids.add(sid)
                spaces.append(Space(identifier, sid, name, kind))
            current = d.get('Current Space', {})
            current = current.get('id64', current.get('ManagedSpaceID')) if isinstance(current, dict) else None
            if type(current) is not int or current not in {s.sid for s in spaces}:
                raise SwitchRefused('display current Space is not in its native list')
            topology.append((identifier, tuple(spaces)))
            currents.append((identifier, current))
        active, locked = value.get('active'), value.get('locked')
        if type(active) is not int or active not in ids or type(locked) is not bool:
            raise SwitchRefused('fresh native active Space and lock state required')
        return cls(value['generation'], tuple(topology), tuple(currents), active, locked)

    def find(self, display, sid):
        return next((s for d, spaces in self.topology if d == display for s in spaces if s.sid == sid), None)


@dataclass(frozen=True)
class Ticket:
    target: Space
    before: Snapshot
    expires: float


class ManagedSpaceSwitcher:
    """Provider for workspace_policy.Target; success means accepted, not ACK.

    Commit performs one native request and one readback, with no sleeps. The
    standalone root-owned device probe can call wait_ack; the daemon instead
    consumes fresh native catalogs through its normal observation loop.
    """
    def __init__(self, driver, *, locked=lambda: False, clock=time.monotonic, ttl=1.0):
        if not 0 < ttl <= 2:
            raise ValueError('preflight TTL must be bounded to 2 seconds')
        self.driver, self.locked, self.clock, self.ttl = driver, locked, clock, ttl
        self.ticket = self.pending = None
        self.last_result = {'requested': False, 'acknowledged': False}

    def snapshot(self):
        snapshot = Snapshot.parse(self.driver.snapshot())
        if snapshot.locked or self.locked():
            raise SwitchRefused('session locked; no native switch')
        return snapshot

    def __call__(self, target, *, preflight=False):
        try:
            if type(target.sid) is not int or not isinstance(target.display, str):
                raise SwitchRefused('exact display/SID target required')
            if hasattr(target, 'kind') and (type(target.kind) is not int or target.kind != 0):
                raise SwitchRefused('expected target type must be ordinary native type0')
            now = self.clock()
            fresh = self.snapshot()
            expected = fresh.find(target.display, target.sid)
            source = fresh.find(target.display, dict(fresh.currents).get(target.display))
            if expected is None or expected.kind != 0 or source is None or source.kind != 0:
                raise SwitchRefused('both source and target must be existing ordinary managed Spaces')
            if hasattr(target, 'uuid') and target.uuid != expected.uuid:
                raise SwitchRefused('expected native UUID changed')
            if preflight:
                if self.pending is not None and not self.observe(fresh):
                    raise SwitchRefused('previous native switch is pending')
                if not self.driver.supports_display(expected.display):
                    raise SwitchRefused('display switch ABI unsupported for this identifier')
                self.ticket = Ticket(expected, fresh, now + self.ttl)
                self.last_result = {'requested': False, 'acknowledged': False, 'state': 'prepared'}
                return True
            ticket, self.ticket = self.ticket, None  # Every prepared lease is consumed once.
            if ticket is None or now > ticket.expires or ticket.target != expected or ticket.before != fresh:
                raise SwitchRefused('preflight expired or native identity/current/topology/generation changed')
            # Revalidate immediately at send; never reuse an old catalog after a move commit.
            if self.snapshot() != fresh:
                raise SwitchRefused('native state changed at final send fence')
            self.driver.set_current(expected.display, expected.sid)
            self.pending = Ticket(expected, fresh, self.clock() + 2)
            self.last_result = {'requested': True, 'acknowledged': False, 'state': 'pending',
                                'display': expected.display, 'sid': expected.sid, 'uuid': expected.uuid}
            self.observe()
            return self.last_result['state'] in ('pending', 'acknowledged')
        except (SwitchRefused, OSError, ValueError, TypeError, AttributeError) as error:
            self.ticket = None
            self.last_result = {'requested': self.pending is not None, 'acknowledged': False,
                                'state': 'refused', 'reason': str(error)}
            return False

    def observe(self, fresh=None):
        if self.pending is None:
            return True
        try:
            fresh = fresh if fresh is not None else self.snapshot()
            request = self.pending
            if fresh.generation != request.before.generation or fresh.topology != request.before.topology:
                raise SwitchRefused('native session or Space ownership changed after request')
            other_before = {d: sid for d, sid in request.before.currents if d != request.target.display}
            other_after = {d: sid for d, sid in fresh.currents if d != request.target.display}
            if other_before != other_after:
                raise SwitchRefused('another display changed during switch')
            acknowledged = (dict(fresh.currents)[request.target.display] == request.target.sid and
                            fresh.active == request.target.sid)
            if acknowledged:
                self.pending = None
                self.last_result.update(acknowledged=True, state='acknowledged')
                self.last_result.pop('reason', None)
                return True
            if self.clock() >= request.expires:
                raise SwitchRefused('native switch acknowledgement timed out')
            return False
        except SnapshotUnstable as error:
            if self.clock() >= self.pending.expires:
                self.pending = None
                self.last_result.update(acknowledged=False, state='failed',
                                        reason='native switch acknowledgement timed out during unstable readback')
            else:
                self.last_result.update(acknowledged=False, state='pending', reason=str(error))
            return False
        except (SwitchRefused, OSError, ValueError, TypeError, AttributeError) as error:
            self.pending = None
            self.last_result.update(acknowledged=False, state='failed', reason=str(error))
            return False

    def wait_ack(self, timeout=2.0, sleep=time.sleep):
        if not 0 < timeout <= 2:
            raise ValueError('ACK wait must be bounded to 2 seconds')
        deadline = self.clock() + timeout
        while self.pending is not None and self.clock() < deadline:
            if self.observe():
                break
            sleep(min(.02, max(0, deadline - self.clock())))
        self.observe()
        return self.last_result.get('acknowledged', False)


class NativeDriver:
    """Named SkyLight API only, gated to the inspected build/image and native births."""
    EXPECTED_BUILD = '25G241'
    EXPECTED_UUID = 'CD5F2362-8462-38D4-8C57-0BCD4E04F962'

    def __init__(self, identity_library=None):
        self.sl = self.cf = self.proc = None
        self.pids = None
        self.ready = False
        self.identity_path = identity_library or str(Path(__file__).resolve().parent / 'build' / 'libmanaged_process_identity.dylib')
        self.identity_lib = None

    def _load(self):
        if self.ready:
            return
        build = subprocess.run(['sysctl', '-n', 'kern.osversion'], capture_output=True, text=True, timeout=1)
        if build.returncode or build.stdout.strip() != self.EXPECTED_BUILD:
            raise SwitchRefused('host build differs from inspected managed-switch ABI')
        self.sl = ctypes.CDLL('/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight')
        self.cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        dyld = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        dyld._dyld_image_count.restype = ctypes.c_uint32
        dyld._dyld_get_image_name.argtypes = [ctypes.c_uint32]; dyld._dyld_get_image_name.restype = ctypes.c_char_p
        dyld._dyld_get_image_header.argtypes = [ctypes.c_uint32]; dyld._dyld_get_image_header.restype = ctypes.c_void_p
        found = None
        count = dyld._dyld_image_count()
        if count > 4096:
            raise SwitchRefused('dyld image catalog exceeds bound')
        for i in range(count):
            name = dyld._dyld_get_image_name(i) or b''
            if not name.endswith(b'/SkyLight'):
                continue
            address = dyld._dyld_get_image_header(i)
            header = ctypes.string_at(address, 32)
            magic, _, _, _, ncmds, size, _, _ = struct.unpack('<8I', header)
            if magic != 0xfeedfacf or ncmds > 256 or size > 1048576:
                raise SwitchRefused('invalid bounded loaded SkyLight Mach-O header')
            commands = ctypes.string_at(address + 32, size)
            offset = 0
            for _ in range(ncmds):
                if offset + 8 > size:
                    raise SwitchRefused('truncated native load commands')
                command, length = struct.unpack_from('<II', commands, offset)
                if length < 8 or offset + length > size:
                    raise SwitchRefused('invalid native load command size')
                if command == 0x1b and length == 24:
                    found = str(uuid.UUID(bytes=commands[offset + 8:offset + 24])).upper()
                offset += length
        if found != self.EXPECTED_UUID:
            self.sl = None
            raise SwitchRefused('loaded SkyLight UUID differs from inspected binary')
        self.sl.SLSMainConnectionID.restype = ctypes.c_int
        self.sl.SLSCopyManagedDisplaySpaces.argtypes = [ctypes.c_int]; self.sl.SLSCopyManagedDisplaySpaces.restype = ctypes.c_void_p
        self.sl.SLSGetActiveSpace.argtypes = [ctypes.c_int]; self.sl.SLSGetActiveSpace.restype = ctypes.c_uint64
        self.sl.SLSManagedDisplayGetCurrentSpace.argtypes = [ctypes.c_int, ctypes.c_void_p]
        self.sl.SLSManagedDisplayGetCurrentSpace.restype = ctypes.c_uint64
        self.sl.SLSManagedDisplaySetCurrentSpace.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint64]
        self.sl.SLSManagedDisplaySetCurrentSpace.restype = None  # Async bridge/raw send is not an ACK.
        self.cf.CFPropertyListCreateData.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long, ctypes.c_long, ctypes.c_void_p]
        self.cf.CFPropertyListCreateData.restype = ctypes.c_void_p
        self.cf.CFDataGetLength.argtypes = [ctypes.c_void_p]; self.cf.CFDataGetLength.restype = ctypes.c_long
        self.cf.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]; self.cf.CFDataGetBytePtr.restype = ctypes.c_void_p
        self.cf.CFRelease.argtypes = [ctypes.c_void_p]
        self.cf.CFRelease.restype = None
        self.cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        self.cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        self.cg = ctypes.CDLL('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
        self.cg.CGSessionCopyCurrentDictionary.restype = ctypes.c_void_p
        self.proc = ctypes.CDLL('/usr/lib/libproc.dylib')
        self.proc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        self.proc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.identity_lib = ctypes.CDLL(self.identity_path)
        self.identity_lib.managed_process_identity.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint64)]
        self.identity_lib.managed_process_identity.restype = ctypes.c_int
        self.pids = []
        for name in ('WindowServer', 'Dock'):
            command = ['pgrep', '-x', name] if name == 'WindowServer' else ['pgrep', '-u', str(os.getuid()), '-x', name]
            result = subprocess.run(command, capture_output=True, text=True, timeout=1)
            values = result.stdout.split()
            if result.returncode or len(values) != 1 or not values[0].isdigit():
                raise SwitchRefused('one exact native WindowServer and user Dock required')
            self.pids.append(int(values[0]))
        self.ready = True

    def _identity(self, pid):
        path = ctypes.create_string_buffer(4096)
        birth = (ctypes.c_uint64 * 4)()
        if (self.identity_lib.managed_process_identity(pid, birth) != 0 or
                self.proc.proc_pidpath(pid, path, len(path)) <= 0 or birth[0] != pid or not birth[2]):
            raise SwitchRefused('native process birth unavailable')
        return (pid, birth[1], birth[2], birth[3], path.value.decode())

    def _plist(self, pointer):
        data = self.cf.CFPropertyListCreateData(None, pointer, 100, 0, None)
        if not data:
            raise SwitchRefused('native property-list data unavailable')
        try:
            length = self.cf.CFDataGetLength(data)
            if not 0 < length <= 262144:
                raise SwitchRefused('native metadata exceeds bounded limit')
            return plistlib.loads(ctypes.string_at(self.cf.CFDataGetBytePtr(data), length))
        finally:
            self.cf.CFRelease(data)

    def process_identity_alive(self, identity):
        """Only ESRCH/recycled birth proves exit; denied metadata is unknown."""
        if not isinstance(identity, tuple) or len(identity) != 5 or type(identity[0]) is not int or identity[0] <= 0:
            raise SwitchRefused('exact native actor birth required')
        self._load()
        birth = (ctypes.c_uint64 * 4)()
        status = self.identity_lib.managed_process_identity(identity[0], birth)
        if status == errno.ESRCH:
            return False
        if status != 0:
            raise SwitchRefused('actor native birth unavailable; process exit cannot be inferred')
        if tuple(birth) != identity[:4]:
            return False
        return self._identity(identity[0]) == identity

    def snapshot(self):
        self._load()
        server, dock = [self._identity(pid) for pid in self.pids]
        if not (server[4].startswith('/System/Library/PrivateFrameworks/SkyLight.framework/') and server[4].endswith('/WindowServer')):
            raise SwitchRefused('WindowServer executable identity changed')
        if dock[1] != os.getuid() or dock[4] != '/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock':
            raise SwitchRefused('user Dock executable identity changed')
        cid = self.sl.SLSMainConnectionID()
        active_before = int(self.sl.SLSGetActiveSpace(cid))
        raw = self.sl.SLSCopyManagedDisplaySpaces(cid)
        session = self.cg.CGSessionCopyCurrentDictionary()
        if not raw or not session:
            if raw: self.cf.CFRelease(raw)
            if session: self.cf.CFRelease(session)
            raise SwitchRefused('native managed catalog or session lock metadata unavailable')
        try:
            displays, state = self._plist(raw), self._plist(session)
            if not isinstance(displays, list) or not 0 < len(displays) <= 16 or not isinstance(state, dict):
                raise SwitchRefused('bounded native catalog/session dictionary required')
            for display in displays:
                identifier = display.get('Display Identifier') if isinstance(display, dict) else None
                if not self.supports_display(identifier):
                    continue
                native = self.cf.CFStringCreateWithCString(None, identifier.encode(), 0x08000100)
                if not native:
                    raise SwitchRefused('native display allocation failed during readback')
                try:
                    current = display.get('Current Space', {})
                    sid = current.get('id64', current.get('ManagedSpaceID'))
                    if sid != int(self.sl.SLSManagedDisplayGetCurrentSpace(cid, native)):
                        raise SnapshotUnstable('display catalog/getter disagree; transition not stable')
                finally:
                    self.cf.CFRelease(native)
            active_after = int(self.sl.SLSGetActiveSpace(cid))
            if active_before != active_after:
                raise SnapshotUnstable('active native Space changed during snapshot')
            if server != self._identity(self.pids[0]) or dock != self._identity(self.pids[1]):
                raise SwitchRefused('native process generation changed during catalog read')
            return {'generation': (self.EXPECTED_BUILD, self.EXPECTED_UUID, server, dock),
                    'displays': displays, 'active': active_after, 'locked': bool(state.get('CGSSessionScreenIsLocked', False))}
        finally:
            self.cf.CFRelease(raw); self.cf.CFRelease(session)

    def supports_display(self, display):
        try:
            uuid.UUID(display)
            return True
        except (ValueError, AttributeError, TypeError):
            return False  # The special "Main" identifier's setter ABI is not verified here.

    def diagnostic_snapshot(self):
        """Read-only matrix row preserving disagreements instead of masking them."""
        self._load()
        server, dock = [self._identity(pid) for pid in self.pids]
        cid = self.sl.SLSMainConnectionID()
        active_before = int(self.sl.SLSGetActiveSpace(cid))
        raw = self.sl.SLSCopyManagedDisplaySpaces(cid)
        session = self.cg.CGSessionCopyCurrentDictionary()
        if not raw or not session:
            if raw:self.cf.CFRelease(raw)
            if session:self.cf.CFRelease(session)
            raise SwitchRefused('native diagnostic catalog/session unavailable')
        try:
            displays, state = self._plist(raw), self._plist(session)
            generation = (self.EXPECTED_BUILD, self.EXPECTED_UUID, server, dock)
            parsed = Snapshot.parse(dict(generation=generation, displays=displays, active=active_before,
                                         locked=bool(state.get('CGSSessionScreenIsLocked', False))))
            rows = []
            for display, spaces in parsed.topology:
                getter = None
                if self.supports_display(display):
                    string = self.cf.CFStringCreateWithCString(None, display.encode(), 0x08000100)
                    if not string:raise SwitchRefused('native display allocation failed during diagnostic')
                    try:getter = int(self.sl.SLSManagedDisplayGetCurrentSpace(cid, string))
                    finally:self.cf.CFRelease(string)
                rows.append(dict(display=display, current_catalog=dict(parsed.currents)[display], current_getter=getter,
                                 spaces=[dict(sid=s.sid, uuid=s.uuid, type=s.kind) for s in spaces]))
            active_after = int(self.sl.SLSGetActiveSpace(cid))
            if server != self._identity(self.pids[0]) or dock != self._identity(self.pids[1]):
                raise SwitchRefused('native process birth changed during diagnostic')
            if not (server[4].startswith('/System/Library/PrivateFrameworks/SkyLight.framework/') and server[4].endswith('/WindowServer')) or dock[1] != os.getuid() or dock[4] != '/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock':
                raise SwitchRefused('native diagnostic process executable/UID differs')
            return dict(mode='native-diagnostic', setter_called=False, observer_identity=self._identity(os.getpid()),
                        generation=generation, connection_id=cid, active_before=active_before, active_after=active_after,
                        displays=rows, locked=parsed.locked,
                        consistent=active_before == active_after and all(r['current_getter'] == r['current_catalog'] for r in rows))
        finally:
            self.cf.CFRelease(raw);self.cf.CFRelease(session)

    def set_current(self, display, sid):
        self._load()
        if not self.supports_display(display) or type(sid) is not int or not 0 < sid < 2**53:
            raise SwitchRefused('exact verified native display UUID/SID required')
        native = self.cf.CFStringCreateWithCString(None, display.encode(), 0x08000100)
        if not native:
            raise SwitchRefused('native display string allocation failed')
        try:
            self.sl.SLSManagedDisplaySetCurrentSpace(self.sl.SLSMainConnectionID(), native, sid)
        finally:
            self.cf.CFRelease(native)


def _frozen(value):
    return tuple(_frozen(v) for v in value) if isinstance(value, list) else value


def _bounded_receipt(path):
    with Path(path).open('rb') as stream:
        data = stream.read(262145)
    if not 0 < len(data) <= 262144:
        raise SwitchRefused('bounded native verification receipt required')
    value = json.loads(data)
    if not isinstance(value, dict):
        raise SwitchRefused('native verification receipt must be an object')
    return value


def validate_independent_ack(proof, *, generation, target, actor=None):
    """Require fresh read-only processes to agree over a durable native window.

    This proves native observations across processes, never physical pixels.
    A sender's synchronous bridged getter is deliberately insufficient.
    """
    if (not isinstance(target, dict) or type(target.get('sid')) is not int or not 0 < target['sid'] < 2**53 or
            type(target.get('type')) is not int or target['type'] != 0 or
            not isinstance(target.get('display'), str) or not isinstance(target.get('uuid'), str)):
        raise SwitchRefused('exact ordinary native target required for independent ACK')
    if (not isinstance(proof, dict) or proof.get('mode') != 'independent-durable-native-ack' or
            proof.get('acknowledged') is not True or _frozen(proof.get('generation')) != generation or
            proof.get('target') != target):
        raise SwitchRefused('independent durable native ACK receipt required')
    actor = _frozen(actor if actor is not None else proof.get('actor_identity'))
    if not isinstance(actor, tuple) or len(actor) != 5 or type(actor[0]) is not int or actor[0] <= 0:
        raise SwitchRefused('exact setter process identity required for independent ACK')
    samples = proof.get('samples')
    if not isinstance(samples, list) or not 3 <= len(samples) <= 64:
        raise SwitchRefused('bounded independent native samples required')
    readers, times = set(), []
    for sample in samples:
        if not isinstance(sample, dict):
            raise SwitchRefused('invalid independent native observation')
        identity = _frozen(sample.get('observer_identity'))
        elapsed = sample.get('elapsed_ms')
        current = dict(_frozen(sample.get('currents', []))).get(target['display'])
        if (sample.get('setter_called') is not False or sample.get('actor_alive') is not False or
                not isinstance(identity, tuple) or len(identity) != 5 or
                type(identity[0]) is not int or identity[0] <= 0 or identity == actor or identity[0] == actor[0] or
                identity in readers or _frozen(sample.get('generation')) != generation or
                type(elapsed) not in (int, float) or not 0 <= elapsed <= 2000 or
                (times and elapsed <= times[-1]) or type(sample.get('active')) is not int or sample.get('active') != target['sid'] or
                type(current) is not int or current != target['sid'] or
                sample.get('target_identity') != target):
            raise SwitchRefused('independent read-only process/native target/generation observation disagrees')
        readers.add(identity);times.append(elapsed)
    if times[-1] - times[0] < 150:
        raise SwitchRefused('independent native ACK must remain stable for at least150ms')
    return True


class VerifiedWorkspaceProvider:
    """Lazy daemon adapter backed by the observed switch/return and signed helper.

    Construction performs no reads, native calls, subprocesses or library loads.
    The receipt's exact live process generation remains mandatory on every read.
    """
    def __init__(self, *, locked, receipt_dir, identity_library, driver_factory=NativeDriver,
                 signature_check=None):
        self.locked, self.receipt_dir = locked, Path(receipt_dir)
        self.identity_library = Path(identity_library)
        self.driver_factory = driver_factory
        self.signature_check = signature_check or self._signature
        self.backend = None
        self.last_result = {'requested': False, 'acknowledged': False, 'state': 'not-loaded'}

    @staticmethod
    def _signature(path):
        result = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(path)],
                                capture_output=True, timeout=1)
        return result.returncode == 0

    def _verified_generation(self):
        outgoing = _bounded_receipt(self.receipt_dir / 'device-switch1.json')
        incoming = _bounded_receipt(self.receipt_dir / 'device-return1.json')
        helper = _bounded_receipt(self.receipt_dir / 'identity-helper-receipt.json')
        independent = _bounded_receipt(self.receipt_dir / 'device-independent-ack.json')
        generation = _frozen(outgoing.get('generation'))
        if (not isinstance(generation, tuple) or len(generation) != 4 or
                generation[:2] != (NativeDriver.EXPECTED_BUILD, NativeDriver.EXPECTED_UUID) or
                generation != _frozen(incoming.get('generation'))):
            raise SwitchRefused('device switch/return native generation receipts disagree')
        for receipt in (outgoing, incoming):
            target, result = receipt.get('target', {}), receipt.get('result', {})
            if (receipt.get('mode') != 'commit' or receipt.get('setter_called') is not True or
                    receipt.get('accepted') is not True or receipt.get('preflight') is not True or
                    result.get('acknowledged') is not True or result.get('state') != 'acknowledged' or
                    type(target.get('type')) is not int or target.get('type') != 0 or
                    type(target.get('sid')) is not int or target['sid'] <= 0 or
                    not isinstance(target.get('display'), str) or not isinstance(target.get('uuid'), str) or
                    any(result.get(key) != target.get(key) for key in ('display', 'sid', 'uuid'))):
                raise SwitchRefused('actual ordinary native switch/return ACK receipts required')
        if (outgoing['target']['display'] != incoming['target']['display'] or
                outgoing['active'] == outgoing['target']['sid'] or
                outgoing['active'] != incoming['target']['sid'] or incoming['active'] != outgoing['target']['sid']):
            raise SwitchRefused('device probe did not return to its exact original Space')
        if not isinstance(independent, dict) or independent.get('backend') != 'SLSManagedDisplaySetCurrentSpace':
            raise SwitchRefused('independent evidence must verify this exact native switch backend')
        for name, receipt in (('outgoing', outgoing), ('return', incoming)):
            validate_independent_ack(independent.get(name), generation=generation, target=receipt['target'])
        source = Path(__file__).resolve().parent / 'src' / 'managed_process_identity.c'
        if (helper.get('codesign_verified') is not True or
                hashlib.sha256(source.read_bytes()).hexdigest() != helper.get('source_sha256') or
                hashlib.sha256(self.identity_library.read_bytes()).hexdigest() != helper.get('binary_sha256') or
                not self.signature_check(self.identity_library)):
            raise SwitchRefused('installed native identity helper signature/source/binary differs from verified artifact')
        return generation

    def __call__(self, target, *, preflight=False):
        try:
            if self.backend is None:
                expected = self._verified_generation()
                native = self.driver_factory(identity_library=str(self.identity_library))
                class VerifiedDriver:
                    def snapshot(driver):
                        value = native.snapshot()
                        if value.get('generation') != expected:
                            raise SwitchRefused('live native generation differs from device-verified workspace backend')
                        return value
                    def supports_display(driver, display):
                        return native.supports_display(display)
                    def set_current(driver, display, sid):
                        return native.set_current(display, sid)
                self.backend = ManagedSpaceSwitcher(VerifiedDriver(), locked=self.locked)
            accepted = self.backend(target, preflight=preflight)
            self.last_result = dict(self.backend.last_result)
            return accepted
        except (SwitchRefused, OSError, ValueError, TypeError, AttributeError, subprocess.TimeoutExpired) as error:
            self.last_result = {'requested': False, 'acknowledged': False, 'state': 'refused', 'reason': str(error)}
            return False


def verified_provider(*, locked, receipt_dir=None, identity_library=None):
    """Default daemon callback is inert until its first workspace command."""
    hook = Path(__file__).resolve().parent
    return VerifiedWorkspaceProvider(locked=locked,
        receipt_dir=receipt_dir or hook.parent / 'cache' / 'continuation-20261013' / 'managed-switch-source1',
        identity_library=identity_library or hook / 'build' / 'libmanaged_process_identity.dylib')
