import importlib.util
import json
import sys
import time
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

MODULE_PATH = Path(__file__).resolve().parents[1] / 'bridge.py'
spec = importlib.util.spec_from_file_location('videoai_bridge', MODULE_PATH)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'repo'
        self.root.mkdir()
        (self.root / 'tests').mkdir()
        (self.root / 'PROGRESS_TRACKER.md').write_text('S06 IN_PROGRESS\n')
        self.state = Path(self.tmp.name) / 'state'
        self.state.mkdir()

    def test_parse_and_exact_content(self):
        content = 'intro\n```FILE: tests/x.py\na=1\nprint(a)\n```\n'
        blocks = bridge.prepare_files(self.root, content)
        self.assertEqual(blocks[0][2], b'a=1\nprint(a)\n')
        written = bridge.apply_files(self.root, self.state, 'goodjob', content)
        self.assertEqual(written, ['tests/x.py'])
        self.assertEqual((self.root/'tests/x.py').read_text(), 'a=1\nprint(a)\n')

    def test_reject_path_traversal_and_symlink(self):
        for path in ['../unsafe.py', '/tmp/unsafe.py', 'tests/../../unsafe.py',
                     '.git/config', 'tools/autobridge/bridge.py', 'tests/run.exe',
                     'tests//broken.py']:
            with self.subTest(path=path):
                with self.assertRaises(ValueError):
                    bridge.checked_path(self.root, path)
        (self.root/'tests'/'link.py').symlink_to(self.root/'PROGRESS_TRACKER.md')
        with self.assertRaises(ValueError):
            bridge.checked_path(self.root, 'tests/link.py')

    def test_reject_duplicate_and_non_code(self):
        with self.assertRaises(ValueError):
            bridge.blocks_from_text('No FILE blocks')
        with self.assertRaises(ValueError):
            bridge.blocks_from_text('```FILE: tests/x.py\n1\n```\n```FILE: tests/x.py\n2\n```')

    def test_backup_and_persist_idempotent(self):
        existing = self.root/'tests'/'x.py'
        existing.write_text('before\n')
        content = '```FILE: tests/x.py\nafter\n```'
        bridge.apply_files(self.root, self.state, 'backup1', content)
        self.assertEqual((self.state/'backups'/'backup1'/'tests'/'x.py').read_text(), 'before\n')
        store = bridge.Store(self.state/'jobs.db')
        first = store.submit(content, ['tests/x.py'])
        second = store.submit(content, ['tests/x.py'])
        self.assertEqual(first, second)
        self.assertEqual(store.claim()['id'], first['id'])
        self.assertIsNone(store.claim())
        store.complete(first['id'], 'done', 'PASS')
        self.assertEqual(store.latest()['state'], 'done')
        self.assertEqual(store.latest()['result'], 'PASS')

    def test_crash_is_not_auto_retried(self):
        db = self.state/'jobs.db'
        store = bridge.Store(db)
        store.submit('```FILE: tests/x.py\nprint(1)\n```', ['tests/x.py'])
        store.claim()
        restarted = bridge.Store(db)
        self.assertEqual(restarted.latest()['state'], 'interrupted')
        self.assertIsNone(restarted.claim())

    def test_invalid_second_file_is_not_partially_written(self):
        contents = ('```FILE: tests/safe.py\nprint(1)\n```\n'
                    '```FILE: ../escape.py\nprint(2)\n```')
        with self.assertRaises(ValueError):
            bridge.apply_files(self.root, self.state, 'invalid2', contents)
        self.assertFalse((self.root/'tests'/'safe.py').exists())

    def test_worker_failed_check_reports_failure_not_fake_pass(self):
        store = bridge.Store(self.state/'jobs.db')
        store.submit('```FILE: tests/new.py\nprint(4)\n```', ['tests/new.py'])
        stop = threading.Event()
        worker_thread = threading.Thread(
            target=bridge.worker,
            args=(store, self.root, self.state,
                  [[sys.executable, '-c', 'raise SystemExit(7)']], stop),
            daemon=True,
        )
        worker_thread.start()
        try:
            for _ in range(50):
                row = store.latest()
                if row['state'] in ('failed', 'done'):
                    break
                time.sleep(.05)
            self.assertEqual(store.latest()['state'], 'failed')
            self.assertIn('exit=7', store.latest()['result'])
            self.assertTrue((self.root/'tests'/'new.py').exists())
        finally:
            stop.set()
            worker_thread.join(timeout=2)

    def test_http_auth_and_submit(self):
        from http.server import ThreadingHTTPServer
        store = bridge.Store(self.state/'jobs.db')
        server = ThreadingHTTPServer(('127.0.0.1', 0), bridge.make_handler(self.root, 'secret-test', store))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        base = f'http://127.0.0.1:{server.server_port}'
        with self.assertRaises(HTTPError) as ex:
            urlopen(base+'/api/status', timeout=2)
        self.assertEqual(ex.exception.code, 401)
        content = '```FILE: tests/example.py\nprint(3)\n```'
        r = Request(base+'/api/submit', method='POST',
                    data=json.dumps({'content': content}).encode(),
                    headers={'X-Bridge-Token':'secret-test', 'Content-Type':'application/json'})
        with urlopen(r,timeout=2) as response:
            self.assertEqual(json.load(response)['state'], 'queued')
        r = Request(base+'/api/status', headers={'X-Bridge-Token':'secret-test'})
        with urlopen(r,timeout=2) as response:
            self.assertEqual(json.load(response)['latest']['files'], ['tests/example.py'])


if __name__ == '__main__':
    unittest.main()
