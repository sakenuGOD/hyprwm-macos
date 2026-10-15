import copy
import json
import unittest

from identity_protocol import IdentityStore, ProtocolError, parse_snapshot


def packet(publication=1, seq=3, generation=1, **overrides):
    r = dict(schema=1, transport='ws-connection-v1', pid=10, launch='launch-A', generation=generation,
             publication=publication, seq=seq, revision=1, settled_revision=1, reconcile_pending=False,
             installed=True, complete=True, gap=False, dropped_events=0,
             windows=[dict(object=1, wid=11, group=5, group_known=True, group_kvo=True, hidden_tab=False,
                           phase='ordered')],
             groups=[dict(group=5, members=[dict(object=1, wid=11)], selected=1, selected_wid=11,
                          membership_kvo=True, selection_kvo=True)],
             events=[dict(seq=seq, generation=generation, cause='settled')])
    r.update(overrides)
    return json.dumps(r).encode()


class ProtocolTests(unittest.TestCase):
    def test_unknown_wid_and_pending_never_prove_membership(self):
        s = parse_snapshot(packet())
        self.assertIsNotNone(s.window(11))
        for wid in (0, -1, 12, True):
            self.assertIsNone(s.window(wid))
        self.assertIsNone(parse_snapshot(packet(reconcile_pending=True)).window(11))
        self.assertIsNone(parse_snapshot(packet(complete=False)).window(11))

    def test_order_and_generation(self):
        store = IdentityStore(10, 100, 'launch-A')
        self.assertEqual(store.accept(packet(2, 4), 100).kind, 'baseline')
        self.assertFalse(store.accept(packet(1, 3), 100).accepted)
        self.assertFalse(store.accept(packet(3, 4, launch='old-launch'), 100).accepted)
        self.assertFalse(store.accept(packet(3, 4), 101).accepted)
        self.assertEqual(store.accept(packet(3, 1, generation=2), 100).kind, 'baseline')
        self.assertFalse(store.accept(packet(4, 20, generation=1), 100).accepted)

    def test_missing_events_recover_current_facts_without_replaying_history(self):
        store = IdentityStore(10, 100, 'launch-A')
        store.accept(packet(1, 3), 100)
        update = store.accept(packet(2, 40, dropped_events=36), 100)
        self.assertEqual(update.kind, 'recovered')
        self.assertTrue(update.events_gap)
        self.assertIsNotNone(store.snapshot.window(11))

    def test_tombstone_revokes_across_gap_and_rejects_old_write(self):
        store = IdentityStore(10, 100, 'launch-A')
        store.accept(packet(1, 3), 100)
        revoked = packet(4, 10, installed=False, windows=[], groups=[], events=[], gap=True)
        self.assertEqual(store.accept(revoked, 100).kind, 'revoked')
        self.assertIsNone(store.snapshot.window(11))
        self.assertFalse(store.accept(packet(3, 9), 100).accepted)
        self.assertEqual(store.accept(packet(5, 1, generation=2), 100).kind, 'baseline')
        self.assertIsNotNone(store.snapshot.window(11))
        self.assertFalse(store.accept(revoked, 100).accepted)

    def test_closed_reopen_is_new_phase_not_new_object_or_group(self):
        base = json.loads(packet())
        base['windows'][0].update(group=None, phase='closed')
        base['groups'] = []
        closed = parse_snapshot(json.dumps(base).encode())
        reopened = copy.deepcopy(base)
        reopened.update(publication=2, seq=4)
        reopened['windows'][0]['phase'] = 'ordered'
        current = parse_snapshot(json.dumps(reopened).encode())
        self.assertEqual(closed.windows[1]['object'], current.windows[1]['object'])
        self.assertIsNone(current.window(11)['group'])

    def test_bounds_and_forged_complete_membership(self):
        with self.assertRaises(ProtocolError):
            parse_snapshot(b' ' * 65537)
        with self.assertRaises(ProtocolError):
            parse_snapshot(packet(groups=[]))
        bad = json.loads(packet())
        bad['windows'][0]['group_known'] = False
        with self.assertRaises(ProtocolError):
            parse_snapshot(json.dumps(bad).encode())
        with self.assertRaises(ProtocolError):
            parse_snapshot(packet(events=[dict(seq=99, generation=1)]))
        bad = json.loads(packet())
        bad['groups'][0]['selected_wid'] = 999
        with self.assertRaises(ProtocolError):
            parse_snapshot(json.dumps(bad).encode())
        bad = json.loads(packet())
        bad['windows'][0]['wid'] = 2**32
        with self.assertRaises(ProtocolError):
            parse_snapshot(json.dumps(bad).encode())


if __name__ == '__main__':
    unittest.main()
