"""
tests/test_worker_child_process.py — D17: every ffmpeg/ffprobe child is tracked.

A killed worker used to leave ffmpeg encoders behind because adapters called
`subprocess.run`, which bypasses the worker's child registry.
"""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from aivideo_workers.child_process import run_tracked, tracked_child_count


class TestTrackedChildren(unittest.TestCase):
    def test_successful_child_is_unregistered_after_exit(self) -> None:
        result = run_tracked(["/bin/echo", "hello"], timeout=10, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("hello", result.stdout)
        self.assertEqual(tracked_child_count(), 0)

    def test_timeout_kills_the_child_and_unregisters(self) -> None:
        with self.assertRaises(subprocess.TimeoutExpired):
            run_tracked(["/bin/sleep", "5"], timeout=0.2)
        self.assertEqual(tracked_child_count(), 0)

    def test_ffprobe_paths_use_the_tracked_runner(self) -> None:
        source = (_ROOT / "workers" / "src" / "aivideo_workers" / "media_indexer.py").read_text(encoding="utf-8")
        self.assertNotIn("subprocess.run(", source, "media_indexer must not bypass the child registry")
        adapter = (_ROOT / "workers" / "src" / "aivideo_workers" / "pipeline_adapters.py").read_text(encoding="utf-8")
        self.assertNotIn("subprocess.run(", adapter, "pipeline_adapters must not bypass the child registry")


if __name__ == "__main__":
    unittest.main()
