"""Read existing passive tab publishers. Never inject, install or change windows."""
from pathlib import Path
import time

from .identity_protocol import IdentityStore, NativeReader, ProtocolError, parse_snapshot


class TabReader:
    def __init__(self, identity, connection, caller, library=None, reader=None, clock=time.monotonic):
        self.identity, self.connection = identity, connection
        self.caller = caller
        self.library = Path(library or Path(__file__).parents[1] / 'build/libhypridentity_reader.dylib')
        self.reader = reader
        self.stores = {}
        self.absent = {}
        self.clock = clock
        self.status = 'publisher-unavailable'

    def read(self, wins):
        facts = {}
        if self.reader is None:
            if not self.library.is_file():
                return facts
            try:
                self.reader = NativeReader(str(self.library), self.caller)
            except (OSError, AttributeError):
                self.status = 'reader-unavailable'
                return facts
        sources = {}
        for w in wins:
            if not w.get('layer') and w.get('pid') and w.get('wid'):
                sources.setdefault(w['pid'], w['wid'])
        for pid in list(self.stores):
            if pid not in sources:
                self.stores.pop(pid, None)
        for pid in list(self.absent):
            if pid not in sources:
                self.absent.pop(pid, None)
        for pid, wid in sources.items():
            birth = cid = None
            try:
                birth = self.identity(pid)
                cid = self.connection(wid, pid)
                if not birth or not cid:
                    self.stores.pop(pid, None)
                    continue
                missing = self.absent.get(pid)
                if missing and missing[:2] == (tuple(birth), cid) and self.clock() < missing[2]:
                    continue
                raw = self.reader.read(cid, pid)
                self.absent.pop(pid, None)
                snapshot = parse_snapshot(raw)
                if self.identity(pid) != birth or self.connection(wid, pid) != cid:
                    self.stores.pop(pid, None)
                    continue
                key = (tuple(birth), cid, snapshot.raw['launch'])
                old = self.stores.get(pid)
                if old is None or old[0][:2] != key[:2]:
                    store = IdentityStore(pid, cid, snapshot.raw['launch'])
                    self.stores[pid] = (key, store)
                else:
                    store = old[1]
                update = store.accept(raw, cid)
                # Unchanged property is valid only when freshly reread and byte
                # identical under the same native process/connection fences.
                if not update.accepted and (update.kind != 'stale' or store.snapshot.raw != snapshot.raw):
                    continue
                if not snapshot.ready:
                    continue
                for group in snapshot.groups.values():
                    selected = group['selected_wid']
                    members = [m['wid'] for m in group['members'] if m['wid'] > 0]
                    if selected <= 0 or len(members) < 2:
                        continue
                    for member in members:
                        facts[member] = dict(pid=pid, members=members, selected=selected,
                                             generation=tuple(birth))
            except (OSError, ValueError, ProtocolError, TypeError, KeyError):
                self.stores.pop(pid, None)
                if birth and cid:
                    # Applications without a publisher cannot change tab facts.
                    # Retry boundedly rather than querying every opening frame.
                    self.absent[pid] = (tuple(birth), cid, self.clock()+1.0)
        self.status = 'ready' if facts else 'publisher-unavailable'
        return facts
