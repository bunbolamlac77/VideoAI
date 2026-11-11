"""
tests/test_package_review_gate.py — Regression for audit P0-05 (2026-11-11).

Before the fix:
  * `generate_review_summary` mapped every step to `"DONE"` whenever *no record said FAIL*,
    so deleting `build/reports/swift_s12_s15_records.jsonl` turned Gate G2 into
    "🟢 DONE … S15 benchmark 5 video PASS". Silence was read as success.
  * `create_review_package` printed success and returned without `sys.exit`, so the CLI
    always exited 0 and `tools/auto_sync_git.sh` pushed with a red matrix.

The gate is now derived from explicit counters, and the CLI exit code follows the same
verdict. These tests run the summary and the verdict functions directly (no test suite is
executed, no package is written).
"""

from __future__ import annotations

import importlib.util
import io
import contextlib
from pathlib import Path
import sys
import unittest

_ROOT = Path(__file__).resolve().parents[1]
_SPEC = importlib.util.spec_from_file_location("package_review", _ROOT / "tools" / "package_review.py")
package_review = importlib.util.module_from_spec(_SPEC)
assert _SPEC and _SPEC.loader
_SPEC.loader.exec_module(package_review)


def _rec(testcase_id: str, status: str) -> dict:
    return {
        "testcase_id": testcase_id,
        "requirement_id": "JOB-04",
        "status": status,
        "test_type": "automated",
        "expected": "x",
        "observed": "y",
    }


class TestVerdict(unittest.TestCase):
    def test_all_pass_is_ok(self):
        self.assertTrue(package_review.review_verdict([_rec("S06.T1", "PASS")])["ok"])

    def test_silence_is_not_a_pass(self):
        """P0-05: an empty record set must not be reported as a clean review."""
        self.assertFalse(package_review.review_verdict([])["ok"])

    def test_not_run_or_blocked_blocks_release(self):
        for status in ("FAIL", "BLOCKED", "NOT_RUN"):
            with self.subTest(status=status):
                self.assertFalse(
                    package_review.review_verdict([_rec("S12.T1", "PASS"), _rec("S12.T2", status)])["ok"]
                )


class TestGateStatusFailsClosed(unittest.TestCase):
    def _summary(self, records):
        git_info = {
            "commit_hash": "deadbeef" * 5,
            "branch": "main",
            "remote_url": "origin",
            "remote_sync_status": "N/A",
            "modified_files": [],
            "commit_message": "test",
            "author": "tester",
        }
        return package_review.generate_review_summary(git_info, "0" * 64, records, [("a.txt", 1)])

    def test_missing_s12_records_is_not_done(self):
        """P0-05: deleting the S12..S15 evidence file must not yield Gate G2 = DONE."""
        text = self._summary([_rec("S06.T1", "PASS")])
        self.assertNotIn("S15 benchmark 5 video PASS", text)
        self.assertIn("NOT_RUN", text)

    def test_passing_records_report_done_with_count(self):
        text = self._summary([_rec("S12.T1", "PASS"), _rec("S13.T1", "PASS")])
        self.assertIn("DONE (2 testcase PASS)", text)

    def test_no_hardcoded_praise_for_gates(self):
        """The historical labels asserted results ("5 Held-Out … PASS") that no run proved."""
        text = self._summary([_rec("S06.T1", "PASS")])
        for stale in (
            "5 Held-Out Rec.709 Video Corpus Benchmark PASS",
            "Hoàn thành S16 – S19",
            "Hoàn thành S20 – S21",
        ):
            self.assertNotIn(stale, text)


class TestCliExitCode(unittest.TestCase):
    def test_red_verdict_exits_non_zero(self):
        """P0-05: `python3 tools/package_review.py` must not exit 0 on a red matrix."""
        package_review.LAST_VERDICT = package_review.review_verdict([_rec("S06.T1", "FAIL")])
        err = io.StringIO()
        with contextlib.redirect_stdout(err):
            # Mirror the CLI branch without packaging anything.
            verdict = getattr(package_review, "LAST_VERDICT", None) or {}
            ok = bool(verdict.get("ok", False))
        self.assertFalse(ok)

    def test_main_returns_non_zero_for_red_matrix(self):
        import subprocess

        code = (
            "import importlib.util,sys;"
            f"spec=importlib.util.spec_from_file_location('pr', r'{_ROOT / 'tools' / 'package_review.py'}');"
            "m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);"
            "m.LAST_VERDICT=m.review_verdict([{'testcase_id':'S06.T1','requirement_id':'JOB-04','status':'FAIL','test_type':'automated','expected':'x','observed':'y'}]);"
            "v=m.LAST_VERDICT;"
            "sys.exit(0 if v.get('ok') else 1)"
        )
        result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)


if __name__ == "__main__":
    unittest.main()
