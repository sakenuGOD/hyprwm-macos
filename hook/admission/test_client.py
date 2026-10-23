"""Own private UDS + Foundation probe only; no AppKit or desktop input."""
import ctypes
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest


class TransportTests(unittest.TestCase):
    def exercise(self, *, delay=0, corrupt=False, close=False, mode=0o600,
                 expected_server=None, configured=True):
        probe = Path(os.environ['ADMISSION_CLIENT_PROBE']).resolve()
        lib = ctypes.CDLL('/usr/lib/libproc.dylib')
        pathbuf = ctypes.create_string_buffer(4096)
        self.assertGreater(lib.proc_pidpath(os.getpid(), pathbuf, len(pathbuf)), 0)
        with tempfile.TemporaryDirectory(prefix='ha-client-') as folder:
            path = str(Path(folder) / 's')
            server = socket.socket(socket.AF_UNIX)
            server.bind(path)
            os.chmod(path, mode)
            server.listen(1)
            server.settimeout(.2)
            errors = []

            def serve():
                try:
                    try:
                        conn, _ = server.accept()
                    except TimeoutError:
                        return
                    with conn:
                        if close:
                            return
                        data = conn.makefile('rb').readline(8192)
                        if not data:
                            return
                        req = json.loads(data)
                        offer = dict(schema=1, transport='fixture-uds-v1', status='offer',
                                     key=req['key'], service='owned', revision=0, lease='owned',
                                     deadline=req['deadline'], expires=time.monotonic()+.25,
                                     rect=[10, 20, 300, 400])
                        if corrupt:
                            offer['key']['wid'] += 1
                        if delay:
                            time.sleep(delay)
                        try:
                            conn.sendall(json.dumps(offer).encode()+b'\n')
                        except BrokenPipeError:
                            pass
                except Exception as error:
                    errors.append(str(error))

            thread = threading.Thread(target=serve)
            thread.start()
            args = [str(probe), path, '12']
            if configured:
                args.append(expected_server or pathbuf.value.decode())
            result = subprocess.run(args, capture_output=True, text=True, timeout=3)
            thread.join(1)
            server.close()
            self.assertFalse(thread.is_alive())
            self.assertFalse(errors, errors)
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

    def test_valid_identity_and_timely_offer(self):
        self.assertTrue(self.exercise()['apply'])

    def test_expired_and_corrupt_offer_refused(self):
        for args in ({'delay': .08}, {'corrupt': True}):
            with self.subTest(args=args):
                result = self.exercise(**args)
                self.assertFalse(result['apply'])
                self.assertLess(result['elapsed_ms'], 60)

    def test_unconfigured_wrong_executable_and_public_socket_refused(self):
        for args in ({'configured': False}, {'expected_server': '/not-the-manager'}, {'mode': 0o644}):
            with self.subTest(args=args):
                self.assertFalse(self.exercise(**args)['apply'])

    def test_early_disconnect_with_default_sigpipe_is_fail_open(self):
        for index in range(20):
            with self.subTest(index=index):
                self.assertFalse(self.exercise(close=True)['apply'])


if __name__ == '__main__':
    unittest.main()
