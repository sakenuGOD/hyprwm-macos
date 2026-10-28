"""Adoption regressions with isolated paths and mocked root observation only."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('setup_adoption_test', ROOT / 'scripts/setup_hyprwm.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class SetupAdoptionTests(unittest.TestCase):
    def test_canonical_previous_checkout_is_discovered_but_unrelated_executable_is_not(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            hook = base / 'previous-checkout/hook'
            binary = hook / 'swift/.build/arm64-apple-macosx/release/hyprwm-swift'
            binary.parent.mkdir(parents=True)
            binary.write_text('previous signed manager fixture')
            (hook / 'swift/.build/release').symlink_to('arm64-apple-macosx/release', target_is_directory=True)
            self.assertEqual(setup.manager_hook(binary.resolve(), base), hook.resolve())
            unrelated = base / 'unrelated/hyprwm-swift'
            unrelated.parent.mkdir()
            unrelated.write_text('unrelated executable fixture')
            self.assertIsNone(setup.manager_hook(unrelated.resolve(), base))

    def test_published_activation_without_socket_peer_retains_receipt_without_workspace_scan(self):
        uid = os.getuid()
        receipt = Path('/private/tmp/hyprwm-native-active-fixture/activation.json')
        prepared = Path('/private/tmp/hyprwm-native-prepared-fixture/prepared.json')
        state = Path('/fixture/engine.state')
        documents = {
            receipt: json.dumps(dict(phase='published', prepared=str(prepared),
                                    engine_state=dict(published=True, path=str(state), new_data=b'state'.hex()),
                                    pointer=dict(published=True, path='/fixture/pointer', new_data='pointer'))).encode(),
            prepared: json.dumps(dict(owner_uid=uid, expected=dict(pid=88))).encode(), state: b'state'}
        service = types.SimpleNamespace(read=mock.Mock(side_effect=lambda path, *a, **kw: documents[path]),
                                        same=mock.Mock(return_value=True))
        preparation = types.SimpleNamespace(identity=mock.Mock())
        activation = types.SimpleNamespace(snapshot=mock.Mock(return_value=dict(data='pointer')))
        connection = mock.MagicMock()
        connection.__enter__.return_value = connection
        connection.connect.side_effect = FileNotFoundError('no manager control socket')
        patterns = []
        def glob(path, pattern):
            patterns.append(pattern)
            self.assertEqual(path, Path('/private/tmp'))
            self.assertEqual(pattern, 'hyprwm-native-active-*/activation.json', 'Workspace directories must not be scanned')
            return iter([receipt])
        captured = io.StringIO()
        with mock.patch.object(setup.os, 'geteuid', return_value=0), \
                mock.patch.object(setup, 'check_host'), mock.patch.object(setup, 'observe_host', return_value={}), \
                mock.patch.object(setup, 'module', return_value=service), \
                mock.patch.object(setup, 'sha', return_value='a' * 64), \
                mock.patch.dict(sys.modules, prepare_native=preparation, activate_native=activation), \
                mock.patch.object(sys, 'path', list(sys.path)), \
                mock.patch.object(setup.socket, 'socket', return_value=connection), \
                mock.patch.object(Path, 'glob', glob), contextlib.redirect_stdout(captured):
            setup.inspect_active(uid)
        active = json.loads(captured.getvalue())['active']
        self.assertEqual(active['activation'], str(receipt))
        self.assertEqual(active['prepared'], str(prepared))
        self.assertIsNone(active['workspace_receipt'])
        self.assertNotIn('manager_verified', active)
        self.assertEqual(patterns, ['hyprwm-native-active-*/activation.json'])
        preparation.identity.assert_not_called()


if __name__ == '__main__':
    unittest.main()
