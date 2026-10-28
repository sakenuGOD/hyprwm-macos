"""Reuse the reviewed split identity graph even when a rebuild changes its artifact."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value

setup = load('protected_workspace_setup_test', ROOT / 'scripts/setup_hyprwm.py')
installer = load('protected_workspace_installer_test', ROOT / 'scripts/install_autostart.py')


class ProtectedWorkspaceTests(unittest.TestCase):
    @contextlib.contextmanager
    def fixture(self):
        with tempfile.TemporaryDirectory() as temporary, contextlib.ExitStack() as patches:
            base = Path(temporary).resolve(); frozen = base / 'native-session'
            home = base / 'home'; home.mkdir()
            workspaces = frozen / 'graph/workspaces'; helper = frozen / 'graph/identity/ProcessIdentity.dylib'
            workspaces.mkdir(parents=True); helper.parent.mkdir(parents=True)
            helper.write_bytes(b'old reviewed helper')
            rebuilt = base / 'rebuilt'; rebuilt.mkdir(); (rebuilt / helper.name).write_bytes(b'new artifact; same C source')
            specification = dict(file=helper.name, sha256=setup.sha(helper), source=installer.service.IDENTITY_SOURCE,
                                 source_sha256=installer.service.IDENTITY_SOURCE_SHA256)
            rebuilt_specification = dict(specification, sha256=setup.sha(rebuilt / helper.name))
            (rebuilt / 'workspace-images.json').write_text(json.dumps(dict(identity_helper=rebuilt_specification)))
            blobs = {'workspace-images.json': json.dumps(dict(identity_helper=specification)).encode(),
                     'DockSpacesBridge.arm64.dylib': b'reviewed arm64', 'DockSpacesBridge.arm64e.dylib': b'reviewed arm64e'}
            for name, data in blobs.items(): (workspaces / name).write_bytes(data)
            manager = base / 'manager'; manager.write_bytes(b'current manager')
            config = dict(uid=os.getuid(), home=str(home), base=str(frozen), manager=str(manager), hook=str(base / 'hook'),
                          manager_sha256=setup.sha(manager), native_sha256='same-native', identity_helper=specification,
                          workspace_files={name: installer.service.sha(data) for name, data in blobs.items()})
            (frozen / 'config.json').write_text(json.dumps(config))
            paths = dict(home=home, autostart=frozen, state=base / 'setup/receipt.json')
            patches.enter_context(mock.patch.object(setup.pwd, 'getpwuid', return_value=types.SimpleNamespace(pw_dir=str(home))))
            patches.enter_context(mock.patch.object(setup, 'module', return_value=installer))
            patches.enter_context(mock.patch.object(installer.service, 'load_config', return_value=config))
            patches.enter_context(mock.patch.object(installer, 'approved_workspaces', return_value=blobs))
            patches.enter_context(mock.patch.object(installer.service, 'read', side_effect=lambda path, *a, **kw: path.read_bytes()))
            image_check = patches.enter_context(mock.patch.object(installer.service, 'identity_image'))
            yield dict(paths=paths, config=config, workspaces=workspaces, helper=helper, rebuilt=rebuilt, image_check=image_check)

    def test_rebuilt_artifact_drift_preserves_exact_protected_helper_and_split_cache(self):
        with self.fixture() as f, mock.patch.object(setup, 'save_receipt'), mock.patch.object(setup, 'run') as build, \
                contextlib.redirect_stdout(io.StringIO()):
            rebuilt_specification = json.loads((f['rebuilt'] / 'workspace-images.json').read_text())['identity_helper']
            self.assertEqual(rebuilt_specification['source_sha256'], f['config']['identity_helper']['source_sha256'])
            self.assertNotEqual(rebuilt_specification['sha256'], f['config']['identity_helper']['sha256'])
            self.assertFalse((f['workspaces'] / f['helper'].name).exists())
            protected = setup.protected_workspaces(f['paths'])
            active = dict(manager_verified=True, manager_identity=dict(pid=123), manager=f['config']['manager'],
                          hook=f['config']['hook'], native_sha256=f['config']['native_sha256'])
            status = dict(enabled=True, compatibility=dict(verified=True), daemon=dict(pid=123))
            setup.retain_protected_workspaces(protected, active, status)
            receipt = dict(workspace_image_dir=str(f['rebuilt']))
            self.assertEqual(setup.build_workspaces(f['paths'], receipt, protected), f['workspaces'])
            self.assertEqual(receipt['workspace_identity_helper'], str(f['helper']))
            self.assertEqual(receipt['workspace_identity_sha256'], f['config']['identity_helper']['sha256'])
            self.assertEqual(setup.protected_workspaces(f['paths'])['validation'], protected['validation'])
            f['image_check'].assert_called_with(b'old reviewed helper')
            build.assert_not_called()

    def test_other_home_never_loads_or_binds_the_owner_protected_cache(self):
        with self.fixture() as f:
            home = f['paths']['home'].parent / 'isolated-home'; home.mkdir()
            base = home / 'setup'; base.mkdir()
            paths = dict(home=home, base=base, state=base / 'receipt.json', autostart=f['paths']['autostart'],
                         app=home / 'Applications/HyprWM.app')
            paths['state'].write_text(json.dumps(dict(installer=setup.MARKER, root=str(setup.ROOT),
                workspace_image_dir=str(f['workspaces']), workspace_identity_helper=str(f['helper']),
                workspace_identity_sha256=f['config']['identity_helper']['sha256'])))
            host = dict(system='Darwin', arch='arm64', build='25G241', sip=setup.SIP_DISABLED)
            captured = io.StringIO()
            with mock.patch.object(installer.service, 'load_config') as loading, \
                    mock.patch.object(setup, 'locations', return_value=paths), \
                    mock.patch.object(setup, 'observe_host', return_value=host), \
                    mock.patch.object(setup, 'toolgraph', return_value={}), contextlib.redirect_stdout(captured):
                self.assertIsNone(setup.protected_workspaces(paths))
                self.assertEqual(setup.dry_run(argparse.Namespace(no_autostart=False, no_open=True)), 0)
                loading.assert_not_called()
            report = json.loads(captured.getvalue())
            self.assertTrue(report['qualified']); self.assertFalse(report['mutations'])
            self.assertFalse(report['artifacts']['workspace_image_dir']['available'])
            self.assertNotIn('validation', report['artifacts']['workspace_image_dir'])

    def test_protected_helper_tamper_refuses_before_sudo_or_other_mutations(self):
        with self.fixture() as f, mock.patch.object(setup, 'check_host'), \
                mock.patch.object(setup, 'observe_host', return_value={}), \
                mock.patch.object(setup, 'locations', return_value=f['paths']), \
                mock.patch.object(setup, 'sudo') as privileged, mock.patch.object(setup, 'conflicts') as mutation, \
                mock.patch.dict(os.environ, HYPRWM_CTL='/tmp/hyprwm.ctl'), contextlib.redirect_stdout(io.StringIO()):
            f['helper'].write_bytes(b'tampered old helper')
            with self.assertRaisesRegex(RuntimeError, 'differs from its approved artifact hash'):
                setup.setup(argparse.Namespace(yes=True))
            privileged.assert_not_called(); mutation.assert_not_called()
            f['image_check'].assert_not_called()


if __name__ == '__main__':
    unittest.main()
