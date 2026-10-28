"""Supervisor-only upgrade contracts. All service/native effects are mocked."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('autostart_upgrade_test', ROOT / 'scripts/install_autostart.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class AutostartUpgradeTests(unittest.TestCase):
    def config(self, base):
        return dict(uid=501, home=str(base / 'home'), base=str(base / 'session'), python='/protected/python',
                    hook=str(base / 'hook'), manager=str(base / 'manager'), manager_sha256=installer.service.sha(b'manager'),
                    python_sha256=installer.service.sha(b'python'), graph_sha256='old-graph', native_sha256='same-native', workspace_files={'image': 'same'}, identity_helper={'same': True})

    def test_rejects_unaligned_or_child_killing_supervisor_plists(self):
        config = self.config(Path('/fixture'))
        paths = (Path('/fixture/root.plist'), Path('/fixture/user.plist'))
        for changed in ('AbandonProcessGroup', 'ProgramArguments', 'receipt'):
            data = installer.launch_plists(config)
            value = plistlib.loads(data[1])
            if changed == 'AbandonProcessGroup': value[changed] = False
            if changed == 'ProgramArguments': value[changed] = ['/unrelated/command']
            data[1] = plistlib.dumps(value)
            config['plists'] = {str(path): installer.service.sha(blob) for path, blob in zip(paths, data)}
            if changed == 'receipt': config['plists'][str(paths[1])] = '0' * 64
            with self.subTest(changed=changed), mock.patch.object(installer, 'plist_paths', return_value=paths), \
                    mock.patch.object(installer.service, 'read', side_effect=lambda path, *a: data[paths.index(path)]):
                with self.assertRaises(RuntimeError): installer.owned_plists(config)

    def test_supervisor_birth_change_refuses_bootout(self):
        config = self.config(Path('/fixture')); data = installer.launch_plists(config)
        rows = {10: dict(pid=10, uid=0, seconds=1, micros=2, path=config['python'], status=3),
                11: dict(pid=11, uid=501, seconds=1, micros=2, path=config['python'], status=3)}
        arguments = {10: plistlib.loads(data[0])['ProgramArguments'], 11: plistlib.loads(data[1])['ProgramArguments']}
        processes = dict(identity=lambda pid: dict(rows[pid]), argv=arguments.get, python_images={config['python']: config['python_sha256']})
        def report(command, **kwargs):
            pid = 10 if command[-1].startswith('system/') else 11
            return types.SimpleNamespace(returncode=0, stdout='pid = ' + str(pid) + '\nproperties = abandon process group\n', stderr='')
        with mock.patch.object(installer.subprocess, 'run', side_effect=report), mock.patch.object(installer, 'launchctl') as effect, \
                mock.patch.object(installer.service, 'read', return_value=b'python'):
            snapshots = [installer.supervisor(config, index, blob, processes) for index, blob in enumerate(data)]
            rows[11]['seconds'] += 1
            with self.assertRaisesRegex(RuntimeError, 'generations changed'):
                installer.stop_supervisors(config, data, processes, expected=snapshots)
            effect.assert_not_called()

    def test_only_exact_derived_protected_framework_kernel_can_replace_argv_zero(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); config = self.config(root)
            version = root / 'Python3.framework/Versions/3.9'
            launcher = version / 'bin/python3.9'; kernel = version / 'Resources/Python.app/Contents/MacOS/Python'
            for path in (launcher, kernel):
                path.parent.mkdir(parents=True); path.write_bytes(b'python'); path.chmod(0o755)
            config['python'] = str(launcher)
            with mock.patch.object(installer.service, 'canonical', side_effect=lambda path, *a, **kw: path), \
                    mock.patch.object(installer.service, 'read', side_effect=lambda path, *a: path.read_bytes()):
                images = installer.python_images(config)
                self.assertEqual(set(images), {str(launcher), str(kernel)})
                data = installer.launch_plists(config)[0]
                arguments = [str(kernel), *plistlib.loads(data)['ProgramArguments'][1:]]
                row = dict(pid=10, uid=0, seconds=1, micros=2, path=str(kernel), status=3)
                processes = dict(identity=lambda pid: dict(row), argv=lambda pid: arguments, python_images=images)
                report = types.SimpleNamespace(returncode=0, stdout='pid = 10\nproperties = abandon process group\n', stderr='')
                with mock.patch.object(installer.subprocess, 'run', return_value=report):
                    self.assertEqual(installer.supervisor(config, 0, data, processes)['argv'], arguments)
                    row['path'] = str(kernel.parent / 'OtherPython')
                    with self.assertRaisesRegex(RuntimeError, 'identity/argv differs'):
                        installer.supervisor(config, 0, data, processes)

    def test_upgrade_refuses_different_native_before_staging(self):
        old = self.config(Path('/fixture')); new = dict(old, native_sha256='different')
        args = types.SimpleNamespace(adopt_activation=Path('/receipt'), adopt_workspaces=Path('/workspaces'))
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(installer.service, 'BASE', Path(temporary)), \
                mock.patch.object(installer, 'configuration', return_value=old), \
                mock.patch.object(installer.tempfile, 'mkdtemp') as staging:
            with self.assertRaisesRegex(RuntimeError, 'preserve exact'):
                installer.upgrade_reviewed(args, new, {}, b'', {}, b'')
            staging.assert_not_called()

    @contextlib.contextmanager
    def transaction(self, failure=None, drift=False):
        with tempfile.TemporaryDirectory() as temporary, contextlib.ExitStack() as stack:
            root = Path(temporary); old = self.config(root); new = dict(old, graph_sha256='new-graph')
            base = Path(old['base']); staged = root / 'next'; recovery = root / 'recovery'
            for directory in (base / 'graph', base / 'runtime', staged / 'graph', recovery): directory.mkdir(parents=True)
            (base / 'graph/identity').write_text('old graph'); (staged / 'graph/identity').write_text('new graph')
            Path(old['manager']).write_bytes(b'manager')
            paths = (root / 'root.plist', root / 'user.plist')
            old_data, new_data = [b'old daemon', b'old agent'], [b'new daemon', b'new agent']
            for path, data in zip(paths, old_data): path.write_bytes(data)
            (base / 'config.json').write_text(json.dumps(old))
            for name in ('current.json', 'status.json'): (recovery / name).write_text(json.dumps({'old': name}))
            row = dict(phase='workspaces-ready', windowserver={'pid': 88, 'seconds': 1})
            args = types.SimpleNamespace(adopt_activation=Path('/fixture/activation'), adopt_workspaces=Path('/fixture/workspaces'))
            events, syncs = [], []
            original_sync = installer.fsync_directory
            def sync(path):
                events.append(('fsync', path)); syncs.append(path)
                target = {'fsync-old-source': 1, 'fsync-old-destination': 2, 'fsync-new-source': 3, 'fsync-new-destination': 4}.get(failure)
                if len(syncs) == target: raise OSError('fixture directory sync failed')
                original_sync(path)
            def save(path, value, mode=0o600):
                if path.name == 'upgrade.json': events.append(('journal', value['phase']))
                Path(path).write_text(json.dumps(value))
            def replace(path, data, expected, uid, gid):
                self.assertEqual(installer.service.sha(path.read_bytes()), expected)
                if failure == 'plist' and path == paths[1] and data == new_data[1]: raise RuntimeError('fixture plist publication failed')
                path.write_bytes(data)
            def launch(*arguments, **kwargs):
                if failure == 'bootstrap' and arguments[:2] == ('bootstrap', 'gui/501'): raise RuntimeError('fixture bootstrap failed')
            mocks = {
                'stop': stack.enter_context(mock.patch.object(installer, 'stop_supervisors', return_value=[])),
                'launch': stack.enter_context(mock.patch.object(installer, 'launchctl', side_effect=launch)),
                'adopt': stack.enter_context(mock.patch.object(installer, 'adoption', return_value=dict(row, phase='different') if drift else row))}
            stack.enter_context(mock.patch.object(installer, 'fsync_directory', side_effect=sync))
            stack.enter_context(mock.patch.object(installer, 'plist_paths', return_value=paths))
            stack.enter_context(mock.patch.object(installer, 'owned_plists', side_effect=lambda c: (paths, [p.read_bytes() for p in paths])))
            stack.enter_context(mock.patch.object(installer, 'replace_plist', side_effect=replace))
            stack.enter_context(mock.patch.object(installer, 'supervisor', return_value=dict(actor={'pid': 10}, argv=[], domain='fixture')))
            stack.enter_context(mock.patch.object(installer, 'wait_supervisors', return_value=[]))
            stack.enter_context(mock.patch.object(installer.pwd, 'getpwuid', return_value=types.SimpleNamespace(pw_gid=os.getgid())))
            stack.enter_context(mock.patch.object(installer.service, 'load_config', side_effect=lambda path: json.loads(path.read_text())))
            stack.enter_context(mock.patch.object(installer.service, 'read', side_effect=lambda path, *a, **kw: path.read_bytes()))
            stack.enter_context(mock.patch.object(installer.service, 'save', side_effect=save))
            stack.enter_context(mock.patch.object(installer.service, 'publish'))
            yield dict(old=old, new=new, base=base, staged=staged, recovery=recovery, old_data=old_data,
                       new_data=new_data, paths=paths, row=row, args=args, mocks=mocks, events=events)

    def execute(self, fixture):
        return installer.upgrade_files(fixture['new'], fixture['staged'], fixture['recovery'], fixture['old'],
                                       fixture['old_data'], fixture['new_data'], fixture['row'], fixture['args'], {})

    def test_success_changes_only_frozen_files_and_supervisors(self):
        with self.transaction() as f:
            journal = self.execute(f)
            self.assertEqual(json.loads(journal.read_text())['phase'], 'complete')
            self.assertEqual((f['base'] / 'graph/identity').read_text(), 'new graph')
            self.assertEqual((f['recovery'] / 'previous-graph/identity').read_text(), 'old graph')
            self.assertEqual(Path(f['old']['manager']).read_bytes(), b'manager')
            self.assertEqual(f['mocks']['stop'].call_count, 1)
            for phase, parents in (('previous-graph-retained', [f['base'], f['recovery']]),
                                   ('graph-published', [f['staged'], f['base']])):
                position = f['events'].index(('journal', phase))
                self.assertEqual(f['events'][position-2:position], [('fsync', parent) for parent in parents])
            self.assertEqual(sum(call.args[0] == 'bootstrap' for call in f['mocks']['launch'].call_args_list), 2)

    def test_each_graph_directory_sync_failure_rolls_back_without_owner_effects(self):
        for boundary in ('fsync-old-source', 'fsync-old-destination', 'fsync-new-source', 'fsync-new-destination'):
            with self.subTest(boundary=boundary), self.transaction(failure=boundary) as f:
                with self.assertRaisesRegex(RuntimeError, 'Supervisor recovery evidence'): self.execute(f)
                journal = json.loads((f['recovery'] / 'upgrade.json').read_text())
                self.assertEqual(journal['phase'], 'recovery-required'); self.assertFalse(journal['rollback_errors'])
                self.assertEqual((f['base'] / 'graph/identity').read_text(), 'old graph')
                self.assertEqual(Path(f['old']['manager']).read_bytes(), b'manager')
                self.assertFalse(f['mocks']['launch'].called)

    def test_generation_drift_refuses_any_supervisor_or_graph_effect(self):
        with self.transaction(drift=True) as f:
            with self.assertRaisesRegex(RuntimeError, 'generation changed'): self.execute(f)
            f['mocks']['stop'].assert_not_called(); f['mocks']['launch'].assert_not_called()
            self.assertEqual((f['base'] / 'graph/identity').read_text(), 'old graph')

    def test_atomic_publication_or_bootstrap_failure_restores_files_without_restarting_old_services(self):
        for failure in ('plist', 'bootstrap'):
            with self.subTest(failure=failure), self.transaction(failure=failure) as f:
                with self.assertRaisesRegex(RuntimeError, 'Supervisor recovery evidence'): self.execute(f)
                journal = json.loads((f['recovery'] / 'upgrade.json').read_text())
                self.assertEqual(journal['phase'], 'recovery-required'); self.assertFalse(journal['rollback_errors'])
                self.assertEqual((f['base'] / 'graph/identity').read_text(), 'old graph')
                self.assertEqual(json.loads((f['base'] / 'config.json').read_text()), f['old'])
                self.assertEqual([path.read_bytes() for path in f['paths']], f['old_data'])
                self.assertEqual(Path(f['old']['manager']).read_bytes(), b'manager')
                self.assertEqual(f['mocks']['stop'].call_count, 2)
                calls = f['mocks']['launch'].call_args_list
                self.assertEqual(sum(call.args[0] == 'bootstrap' for call in calls), 0 if failure == 'plist' else 2)


if __name__ == '__main__':
    unittest.main()
