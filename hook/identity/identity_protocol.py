"""Passive identity schema/parser. Import and parsing perform no native/WS calls.

NativeReader.read is explicit. No fallback to PID/rectangle tab guesses exists here.
Daemon integration owns source binding, inventory, layout and animation decisions.
"""
from __future__ import annotations

import ctypes
import json
from dataclasses import dataclass

MAX_BYTES = 65536


class ProtocolError(ValueError):
    pass


def _integer(value, minimum=0):
    return type(value) is int and minimum <= value < 2**63


def _wid(value):
    return type(value) is int and -(2**31) <= value <= 2**32 - 1


def _require(condition, message):
    if not condition:
        raise ProtocolError(message)


@dataclass(frozen=True)
class Snapshot:
    raw: dict
    windows: dict
    groups: dict

    @property
    def ready(self):
        r = self.raw
        return (r['installed'] and r['complete'] and not r['reconcile_pending']
                and r['revision'] == r['settled_revision'])

    def window(self, wid):
        """Unknown/nonpositive WIDs or unsettled facts never confer identity proof."""
        if not self.ready or not _integer(wid, 1):
            return None
        return next((w for w in self.windows.values() if w['wid'] == wid), None)


def parse_snapshot(data: bytes) -> Snapshot:
    _require(isinstance(data, bytes) and 0 < len(data) <= MAX_BYTES, 'wire byte ceiling')
    try:
        r = json.loads(data, parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
    except (ValueError, UnicodeError) as error:
        raise ProtocolError('invalid JSON') from error
    _require(isinstance(r, dict), 'envelope object required')
    _require(type(r.get('schema')) is int and r['schema'] == 1 and r.get('transport') == 'ws-connection-v1', 'unsupported schema')
    _require(isinstance(r.get('launch'), str) and 0 < len(r['launch']) <= 128, 'launch nonce')
    for key in ('pid', 'generation', 'publication'):
        _require(_integer(r.get(key), 1), key)
    for key in ('seq', 'revision', 'settled_revision', 'dropped_events'):
        _require(_integer(r.get(key)), key)
    _require(r['settled_revision'] <= r['revision'], 'future settled revision')
    for key in ('installed', 'complete', 'reconcile_pending', 'gap'):
        _require(type(r.get(key)) is bool, key)
    for key, limit in (('windows', 128), ('groups', 128), ('events', 32)):
        _require(isinstance(r.get(key), list) and len(r[key]) <= limit, key + ' bound')
    windows, groups, wids = {}, {}, set()
    for w in r['windows']:
        _require(isinstance(w, dict) and _integer(w.get('object'), 1), 'window identity')
        _require(_wid(w.get('wid')), 'window number')
        _require(w['object'] not in windows, 'duplicate window object')
        _require(w.get('group') is None or _integer(w['group'], 1), 'window group')
        for key in ('group_known', 'group_kvo'):
            _require(type(w.get(key)) is bool, key)
        _require(w.get('hidden_tab') is None or type(w['hidden_tab']) is bool, 'hidden tab')
        if w['wid'] > 0:
            _require(w['wid'] not in wids, 'duplicate positive WID')
            wids.add(w['wid'])
        windows[w['object']] = w
    for g in r['groups']:
        _require(isinstance(g, dict) and _integer(g.get('group'), 1), 'group identity')
        _require(g['group'] not in groups, 'duplicate group')
        _require(isinstance(g.get('members'), list) and len(g['members']) <= 128, 'members bound')
        ids = set()
        for member in g['members']:
            _require(isinstance(member, dict) and _integer(member.get('object'), 1)
                     and _wid(member.get('wid')), 'group member')
            _require(member['object'] not in ids, 'duplicate member')
            ids.add(member['object'])
        _require(g.get('selected') is None or g['selected'] in ids, 'selection outside group')
        selected_wid = next((m['wid'] for m in g['members'] if m['object'] == g.get('selected')), 0)
        _require(_wid(g.get('selected_wid')) and g['selected_wid'] == selected_wid, 'selected WID mismatch')
        for key in ('membership_kvo', 'selection_kvo'):
            _require(type(g.get(key)) is bool, key)
        groups[g['group']] = g
    previous = 0
    for event in r['events']:
        _require(isinstance(event, dict) and _integer(event.get('seq'), 1), 'event sequence')
        _require(previous < event['seq'] <= r['seq'] and event.get('generation') == r['generation'], 'event order/generation')
        previous = event['seq']
    if r['installed'] and r['complete']:
        for w in windows.values():
            _require(w['group_known'] and w['group_kvo'] and type(w['hidden_tab']) is bool,
                     'complete snapshot contains unknown window facts')
            if w['group'] is not None:
                _require(w['group'] in groups and any(m['object'] == w['object'] for m in groups[w['group']]['members']),
                         'window group membership missing')
        for g in groups.values():
            _require(g['membership_kvo'] and g['selection_kvo'], 'complete group lacks observation')
            for member in g['members']:
                w = windows.get(member['object'])
                _require(w is not None and w['group'] == g['group'] and w['wid'] == member['wid'], 'incoherent group member')
    return Snapshot(r, windows, groups)


@dataclass(frozen=True)
class Update:
    accepted: bool
    kind: str
    events_gap: bool = False


class IdentityStore:
    """One externally validated process/connection incarnation.

    A new random launch nonce is never accepted merely because it arrived later.
    The daemon must rebind after validating process/connection replacement. A new
    install generation inside the same launch is a baseline, not replayed opens.
    """
    def __init__(self, pid: int, connection: int, launch: str):
        self.pid, self.connection, self.launch = pid, connection, launch
        self.snapshot = None

    def accept(self, data: bytes, source_connection: int) -> Update:
        new = parse_snapshot(data)
        r = new.raw
        if source_connection != self.connection or r['pid'] != self.pid or r['launch'] != self.launch:
            return Update(False, 'wrong-source')
        old = self.snapshot
        if old and (r['generation'] < old.raw['generation'] or r['publication'] <= old.raw['publication']):
            return Update(False, 'stale')
        baseline = old is None or r['generation'] != old.raw['generation']
        if old and not baseline and r['seq'] < old.raw['seq']:
            return Update(False, 'stale')
        first = r['events'][0]['seq'] if r['events'] else r['seq'] + 1
        gap = bool(r['gap'] or (not baseline and old.raw['seq'] + 1 < first))
        self.snapshot = new
        if not r['installed']:
            return Update(True, 'revoked', gap)  # Revocation is authoritative even after a gap.
        if baseline:
            return Update(True, 'baseline', True)
        return Update(True, 'recovered' if gap and new.ready else 'incomplete' if not new.ready else 'update', gap)


class NativeReader:
    """Loads the small Foundation reader; read() alone performs explicit WS IPC."""
    def __init__(self, library: str, caller_connection: int):
        self.caller = caller_connection
        self.lib = ctypes.CDLL(library)
        self.copy = self.lib.hypridentity_copy_connection_json
        self.copy.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_int))
        self.copy.restype = ctypes.c_void_p
        self.libc = ctypes.CDLL(None)
        self.libc.free.argtypes = (ctypes.c_void_p,)

    def read(self, target_connection: int, expected_pid: int) -> bytes:
        error = ctypes.c_int()
        pointer = self.copy(self.caller, target_connection, expected_pid, ctypes.byref(error))
        if not pointer:
            raise OSError(error.value, 'identity property read failed')
        try:
            return ctypes.string_at(pointer)
        finally:
            self.libc.free(pointer)
