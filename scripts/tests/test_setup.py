"""Safety regressions: no sudo, launchd, Carbon registration or native attachment."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import pwd
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


setup = load('setup_safety_test', ROOT / 'scripts/setup_hyprwm.py')
QUALIFIED = dict(system='Darwin', arch='arm64', build='25G241',
                 sip=setup.SIP_DISABLED, clt=True, git=True)
DRY_HOST = dict(HYPRWM_TEST_SYSTEM='Darwin', HYPRWM_TEST_ARCH='arm64',
                HYPRWM_TEST_BUILD='25G241', HYPRWM_TEST_SIP=setup.SIP_DISABLED)


class SetupSafetyTests(unittest.TestCase):
    def dry_run(self, home, **overrides):
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith('HYPRWM_TEST_')}
        environment.update(HOME=str(home), PYTHONDONTWRITEBYTECODE='1', **DRY_HOST)
        environment.update(overrides)
        result = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/setup_hyprwm.py'),
                                 '--dry-run', '--yes'], env=environment, capture_output=True,
                                text=True, timeout=30)
        return result, json.loads(result.stdout)

    def test_dry_run_is_read_only_and_describes_default_autostart(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            result, report = self.dry_run(home)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(list(home.iterdir()), [])
            self.assertFalse(report['mutations'])
            self.assertTrue(report['default_autostart'])
            self.assertEqual(len(report['plan']), 7)
            self.assertRegex(report['toolgraph']['toolgraph_sha256'], r'^[0-9a-f]{64}$')

    def test_dry_run_refuses_unqualified_build_sip_and_architecture(self):
        for override in (dict(HYPRWM_TEST_BUILD='24Z999'), dict(HYPRWM_TEST_ARCH='x86_64'),
                         dict(HYPRWM_TEST_SIP='System Integrity Protection status: enabled.'),
                         dict(HYPRWM_TEST_SIP='System Integrity Protection status: unknown (Custom Configuration).')):
            with self.subTest(override=override), tempfile.TemporaryDirectory() as temporary:
                result, report = self.dry_run(Path(temporary), **override)
                self.assertEqual(result.returncode, 1)
                self.assertFalse(report['qualified'])
                self.assertTrue(report['errors'])
                self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_live_test_overrides_cannot_admit_an_unsafe_observed_host(self):
        for unsafe in (dict(build='24Z999'), dict(arch='x86_64'), dict(sip='unverified')):
            with self.subTest(unsafe=unsafe), mock.patch.dict(os.environ, DRY_HOST), \
                    mock.patch.object(setup, 'observe_host', return_value={**QUALIFIED, **unsafe}), \
                    mock.patch.object(setup, 'sudo') as privileged, \
                    mock.patch.object(setup, 'conflicts') as mutation, contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(RuntimeError):
                    setup.setup(argparse.Namespace(yes=True))
                privileged.assert_not_called()
                mutation.assert_not_called()

    def test_live_test_overrides_are_rejected_even_on_a_qualified_host(self):
        with mock.patch.dict(os.environ, {**DRY_HOST, 'HOME': pwd.getpwuid(os.getuid()).pw_dir}), \
                mock.patch.object(setup, 'observe_host', return_value=QUALIFIED), \
                mock.patch.object(setup.os, 'geteuid', return_value=501), \
                mock.patch.object(setup, 'output', return_value=types.SimpleNamespace(returncode=0)), \
                mock.patch.object(setup.shutil, 'which', return_value='/usr/bin/git'), \
                mock.patch.object(setup, 'sudo') as privileged, \
                mock.patch.object(setup, 'conflicts') as mutation, contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, 'accepted only with --dry-run'):
                setup.setup(argparse.Namespace(yes=True))
            privileged.assert_not_called()
            mutation.assert_not_called()

    def test_portable_binding_generation_needs_no_lua_or_owner_config(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / 'bindings.json'
            result = subprocess.run([sys.executable, '-B', str(ROOT / 'hook/keys/binds.py'),
                                     '--source', str(ROOT / 'hook/config/portable-defaults.json'),
                                     '--output', str(destination)], capture_output=True, text=True,
                                    env={**os.environ, 'HOME': temporary, 'PATH': '/no-programs'}, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            bindings = json.loads(destination.read_text())
            self.assertIn(['focus', 'left'], [row['cmd'] for row in bindings])
            self.assertIn(['retile'], [row['cmd'] for row in bindings])
            self.assertFalse(any('lua' in str(row['cmd']).lower() for row in bindings))
            self.assertEqual([path.name for path in Path(temporary).iterdir()], ['bindings.json'])

    def cache_fixture(self, directory):
        cache = directory / 'native'
        cache.mkdir(mode=0o700)
        builder = load('setup_cache_test_builder', ROOT / 'hook/tools/build_native.py')
        (cache / 'source-manifest.json').write_text(json.dumps(builder.inputs()))
        os_input = dict(build='25G241', skylight_uuid='fixture', body_sha256='fixture',
                        cache='fixture', file_offset=0)
        names = ('probe-eh.dylib', 'probe-eh.bin', 'probe-eh-meta.json', 'display-local.S',
                 'display-local.json', 'source-manifest.json', 'native-channel')
        for name in names:
            if not (cache / name).exists():
                (cache / name).write_text(json.dumps(os_input) if name == 'display-local.json' else 'fixture')
        provenance = dict(schema=1, build='25G241', arch='arm64', os_input=os_input,
                          artifacts={name: setup.sha(cache / name) for name in names})
        (cache / 'setup-provenance.json').write_text(json.dumps(provenance))
        setup.native_cache(cache, host=False)
        return cache

    def test_native_cache_refuses_image_tampering_and_source_drift(self):
        for name, message in (('probe-eh.dylib', 'artifact changed'),
                              ('source-manifest.json', 'source manifest changed')):
            with self.subTest(file=name), tempfile.TemporaryDirectory() as temporary:
                cache = self.cache_fixture(Path(temporary).resolve())
                (cache / name).write_text('{}')
                with self.assertRaisesRegex(RuntimeError, message):
                    setup.native_cache(cache, host=False)

    def test_bundled_lifecycle_hook_cannot_escape_the_installed_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'HyprWM.app'
            hook = app / 'Contents/Resources/hook'
            binary = hook / 'swift/.build/release/hyprwm-swift'
            binary.parent.mkdir(parents=True)
            binary.write_text('fixture')
            receipt = app / 'Contents/Resources/InstallReceipt.json'
            for relative in ('Contents/Resources/hook', '..', '/private/tmp'):
                receipt.write_text(json.dumps(dict(installer='hyprwm-user-install-v1',
                                                   lifecycle_hook_relative=relative)))
                with self.subTest(relative=relative):
                    if relative == 'Contents/Resources/hook':
                        self.assertEqual(setup.app_contract(dict(app=app))[0], hook.resolve())
                    else:
                        with self.assertRaises(RuntimeError):
                            setup.app_contract(dict(app=app))

    def test_accessibility_prompt_precedes_settings_and_read_only_polling(self):
        calls = []
        with mock.patch.object(setup, 'permissions', side_effect=[False, True]), \
                mock.patch.object(setup, 'run_json', side_effect=lambda command: calls.append(command)), \
                mock.patch.object(setup, 'run', side_effect=lambda command: calls.append(command)), \
                contextlib.redirect_stdout(io.StringIO()):
            setup.wait_permissions(Path('/fixture/HyprWM'), no_open=False)
        self.assertEqual(calls[0], [Path('/fixture/HyprWM'), '--request-permissions-json'])
        self.assertEqual(calls[1][0], '/usr/bin/open')
        with mock.patch.object(setup, 'permissions', return_value=False), \
                mock.patch.object(setup, 'run_json') as prompt, mock.patch.object(setup, 'run') as opening:
            with self.assertRaises(RuntimeError):
                setup.wait_permissions(Path('/fixture/HyprWM'), no_open=True)
            prompt.assert_not_called()
            opening.assert_not_called()

    def test_completed_workspace_receipt_adopts_only_exact_peer_birth(self):
        service = load('setup_workspace_receipt_service', ROOT / 'hook/tools/autostart.py')
        workspace = load('setup_workspace_receipt_actor', ROOT / 'hook/tools/bootstrap_workspaces.py')
        uid = os.getuid()
        peer = dict(pid=123, uid=uid, seconds=40, micros=50, path='/fixture/manager', status=3)
        server = dict(peer, pid=88, uid=88, path='/fixture/WindowServer')
        dock = dict(peer, pid=456, path='/fixture/Dock')
        actors = {row['pid']: row for row in (server, dock)}
        lease = str(Path(pwd.getpwuid(uid).pw_dir) / 'Library/Application Support/HyprWM/native-spaces/lease.json')
        request = dict(peer=workspace.actor(peer))
        context = dict(uid=uid, manager_path=peer['path'], lease=lease, request=request, server=server, dock=dock)
        documents = {'context.json': context, 'published.json': dict(lease=lease),
                     'native.json': dict(ok=True, detached=True, native=dict(installed=True)), 'lease.json': request}
        directory = Path('/private/tmp/complete-workspace-fixture')
        def read(path, *args, **kwargs):
            return json.dumps(documents[path.name]).encode()
        with mock.patch.object(service, 'read', side_effect=read):
            self.assertEqual(setup.validate_workspace_receipt(directory, uid, dict(manager=peer['path']), peer,
                                                              service, actors.get), str(directory))
            for field in ('sec', 'usec'):
                with self.subTest(changed=field):
                    original = request['peer'][field]
                    request['peer'][field] += 1
                    with self.assertRaisesRegex(RuntimeError, 'exact current peer'):
                        setup.validate_workspace_receipt(directory, uid, dict(manager=peer['path']), peer,
                                                         service, actors.get)
                    request['peer'][field] = original

    def test_prepare_adapter_isolates_python_child_progress_and_restores_fd(self):
        def fake_prepare(image, uid):
            print('PYTHON_PROGRESS')
            os.write(1, b'RAW_PROGRESS\n')
            subprocess.run([sys.executable, '-B', '-c', 'print("CHILD_PROGRESS")'], check=True)
            return Path('/private/tmp/fake-prepared')
        with tempfile.TemporaryDirectory() as temporary, tempfile.TemporaryFile() as raw_error:
            before = os.fstat(1)
            saved_error = os.dup(2)
            python_out, python_error = io.StringIO(), io.StringIO()
            try:
                os.dup2(raw_error.fileno(), 2)
                with mock.patch.object(setup.os, 'geteuid', return_value=0), \
                        mock.patch.object(setup, 'check_host'), \
                        mock.patch.object(setup, 'observe_host', return_value={}), \
                        mock.patch.object(setup, 'module', return_value=types.SimpleNamespace(prepare=fake_prepare)), \
                        contextlib.redirect_stdout(python_out), contextlib.redirect_stderr(python_error):
                    setup.prepare_native_json(Path(temporary), 501)
            finally:
                os.dup2(saved_error, 2)
                os.close(saved_error)
            self.assertEqual(json.loads(python_out.getvalue()),
                             dict(prepared='/private/tmp/fake-prepared/prepared.json'))
            self.assertIn('PYTHON_PROGRESS', python_error.getvalue())
            raw_error.seek(0)
            self.assertEqual(set(raw_error.read().decode().splitlines()), {'RAW_PROGRESS', 'CHILD_PROGRESS'})
            after = os.fstat(1)
            self.assertEqual((before.st_dev, before.st_ino), (after.st_dev, after.st_ino))


if __name__ == '__main__':
    unittest.main()
