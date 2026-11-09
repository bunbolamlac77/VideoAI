import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer

BASE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BASE))
import bridge
import auto_loop


class AutoLoopTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / 'repo'
        self.repo.mkdir()
        (self.repo / 'tests').mkdir()
        (self.repo / 'PROGRESS_TRACKER.md').write_text('S06 IN_PROGRESS\n')
        self.state = Path(self.tmp.name) / 'state'
        self.state.mkdir()
        if shutil.which('git') is None:
            self.skipTest('git not installed')
        subprocess.run(['git', 'init', '-q'], cwd=self.repo, check=True)

    def test_will_not_overwrite_dirty_target(self):
        text = '```FILE: tests/x.py\nprint(1)\n```'
        self.assertEqual(auto_loop.protect_user_edits(self.repo, text, {}), ['tests/x.py'])
        (self.repo / 'tests/x.py').write_text('manual\n')
        with self.assertRaisesRegex(RuntimeError, 'dirty/untracked'):
            auto_loop.protect_user_edits(self.repo, text, {})
        with self.assertRaisesRegex(RuntimeError, 'outside the loop'):
            auto_loop.protect_user_edits(self.repo, text, {'tests/x.py': 'bad_hash'})

    def test_traversal_context_rejected(self):
        with self.assertRaises(ValueError):
            auto_loop.safe_file_context(self.repo, '../secret.txt')
        self.assertIn('S06 IN_PROGRESS', auto_loop.safe_file_context(self.repo, 'PROGRESS_TRACKER.md'))

    def test_auto_loop_two_model_turns_one_real_bridge_job(self):
        store = bridge.Store(self.state / 'jobs.db')
        stop = threading.Event()
        worker = threading.Thread(target=bridge.worker, args=(
            store, self.repo, self.state,
            [[sys.executable, '-c', 'print("pass")']], stop
        ), daemon=True)
        http = ThreadingHTTPServer(('127.0.0.1', 0), bridge.make_handler(self.repo, 'test-token', store))
        server = threading.Thread(target=http.serve_forever, daemon=True)
        worker.start()
        server.start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        def shutdown_worker():
            stop.set()
            worker.join(timeout=2)
        self.addCleanup(shutdown_worker)

        prompts = []
        responses = iter([
            '```FILE: tests/hello.py\nassert 1 + 1 == 2\n```',
            'TASK_ALL_COMPLETED: verified job PASS',
        ])
        def fake_gpt(_key, _model, prompt):
            prompts.append(prompt)
            return next(responses)

        report_dir = auto_loop.run_loop(
            self.repo, self.state, 'Write one test', 'mock-model', 2,
            ['PROGRESS_TRACKER.md'], 'fake-key', 'test-token', http.server_port,
            generate=fake_gpt,
        )
        self.assertEqual((self.repo / 'tests/hello.py').read_text(), 'assert 1 + 1 == 2\n')
        self.assertEqual(len(prompts), 2)
        self.assertIn('TESTS: PASS', prompts[1])
        self.assertTrue((report_dir / 'round-1-worker.txt').exists())

    def test_failed_test_feedback_generates_second_patch(self):
        store = bridge.Store(self.state / 'jobs.db')
        stop = threading.Event()
        code = ('import pathlib,sys; p=pathlib.Path("tests/ready.py"); '
                "sys.exit(0 if p.exists() and p.read_text().strip() == '# READY' else 5)")
        worker = threading.Thread(target=bridge.worker, args=(
            store, self.repo, self.state, [[sys.executable, '-c', code]], stop
        ), daemon=True)
        http = ThreadingHTTPServer(('127.0.0.1', 0), bridge.make_handler(self.repo, 'test-token', store))
        server = threading.Thread(target=http.serve_forever, daemon=True)
        worker.start()
        server.start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        def shutdown_worker():
            stop.set()
            worker.join(timeout=2)
        self.addCleanup(shutdown_worker)

        responses = iter([
            '```FILE: tests/ready.py\n# NOT_READY\n```',
            '```FILE: tests/ready.py\n# READY\n```',
        ])
        prompts = []
        def fake_gpt(_key, _model, prompt):
            prompts.append(prompt)
            return next(responses)

        auto_loop.run_loop(self.repo, self.state, 'fix a test', 'mock', 2,
                           ['PROGRESS_TRACKER.md'], 'fake-key', 'test-token',
                           http.server_port, generate=fake_gpt)
        self.assertIn('exit=5', prompts[1])
        self.assertIn('READY', (self.repo / 'tests/ready.py').read_text())
        self.assertEqual(store.latest()['state'], 'done')

    def test_bad_generated_paths_stop_before_writes(self):
        with self.assertRaises(ValueError):
            auto_loop.protect_user_edits(self.repo,
                '```FILE: tools/autobridge/bridge.py\nprint("x")\n```', {})


if __name__ == '__main__':
    unittest.main()
