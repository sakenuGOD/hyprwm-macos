"""Fake Unix-socket and recovery retry checks; no daemon or window operations."""
import importlib.util
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
PENDING = 'error: Lite restoration pending: 1; retry restore-all'
SUCCESS = 'restored every Lite window; tiling paused'
spec = importlib.util.spec_from_file_location('hyprwm_install', ROOT / 'scripts/install_app.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class RestoreRetryTests(unittest.TestCase):
    def client(self, replies):
        with tempfile.TemporaryDirectory(prefix='hypr-retry-', dir='/tmp') as directory:
            path = str(Path(directory) / 'ctl')
            requests, errors = [], []
            stop = threading.Event()
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(path); server.listen(1); server.settimeout(0.05)
                def serve():
                    while not stop.is_set():
                        try:
                            connection, _ = server.accept()
                        except socket.timeout:
                            continue
                        try:
                            with connection:
                                requests.append(connection.recv(1024).decode().strip())
                                response = replies[min(len(requests)-1, len(replies)-1)]
                                connection.sendall((response+'\n').encode())
                        except Exception as error:
                            errors.append(error)
                thread = threading.Thread(target=serve)
                thread.start()
                try:
                    started = time.monotonic()
                    result = subprocess.run([str(ROOT/'scripts/hyprwmctl'), 'restore-all'],
                        env=dict(os.environ, HYPRWM_CTL=path), capture_output=True, text=True, timeout=8)
                    elapsed = time.monotonic()-started
                finally:
                    stop.set(); thread.join(timeout=1)
            self.assertFalse(thread.is_alive()); self.assertEqual(errors, [])
            return result, requests, elapsed

    def test_ctl_retries_only_pending_until_restoration_is_acknowledged(self):
        result, requests, _ = self.client([PENDING, PENDING, SUCCESS])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, SUCCESS+'\n')
        self.assertEqual(requests, ['restore-all']*3)

    def test_ctl_generic_refusal_is_not_retried(self):
        result, requests, _ = self.client(['error: Accessibility is missing'])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(requests, ['restore-all'])

    def test_ctl_pending_budget_is_bounded_and_reports_last_refusal(self):
        result, requests, elapsed = self.client([PENDING])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, PENDING+'\n')
        self.assertGreater(len(requests), 1)
        self.assertLess(len(requests), 60)
        self.assertLess(elapsed, 5.5)

    def test_uninstaller_waits_for_pending_but_does_not_retry_generic_errors(self):
        with patch.object(installer, 'request', side_effect=[PENDING, SUCCESS]) as request, \
                patch.object(installer.time, 'sleep'):
            self.assertEqual(installer.restore_all(), SUCCESS)
            self.assertEqual(request.call_count, 2)
        with patch.object(installer, 'request', return_value='error: permission missing') as request:
            self.assertEqual(installer.restore_all(), 'error: permission missing')
            request.assert_called_once_with('restore-all')

    def test_uninstaller_preserves_pending_refusal_after_deadline(self):
        with patch.object(installer, 'request', return_value=PENDING) as request, \
                patch.object(installer.time, 'monotonic', side_effect=[0, 0, 4]), \
                patch.object(installer.time, 'sleep'):
            self.assertEqual(installer.restore_all(), PENDING)
            self.assertEqual(request.call_count, 2)


if __name__ == '__main__':
    unittest.main()
