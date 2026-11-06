#!/usr/bin/env python3
"""
tests/test_package_review_fault_injection.py — Verification for Patch 3 Runner Failure Immunity
Verifies that injecting exit 44 with stdout containing PASS markers NEVER accepts PASS for any automated/integration test.
"""

import os
import sys
import json
import tempfile
import unittest
from unittest.mock import patch
import subprocess

sys.path.insert(0, os.path.abspath("tools"))
import package_review

class TestPackageReviewFaultInjection(unittest.TestCase):
    def test_runner_exit_44_rejects_all_pass_markers(self):
        """Simulate runner exiting with code 44 while stdout contains PASS markers."""
        fake_stdout = """
        S02.IPC.1: Worker Start & Initialize Handshake ... ✅ PASS: Worker initialized
        S02.IPC.2: system.ping Heartbeat ... ✅ PASS: Ping returned pong
        ✅ PASS: Connected to DaVinci Resolve Studio v21.2.0.5
        ✅ PASS: Real Resolve Spike executed successfully: 2160x3840 @ 24.0fps, Total Frames: 240
        """
        fake_completed_process = subprocess.CompletedProcess(
            args=["tools/run_tests.sh"],
            returncode=44,
            stdout=fake_stdout,
            stderr="Simulated crash during test execution"
        )

        with tempfile.TemporaryDirectory() as tmp_report_dir:
            # Create a fake jsonl record that previously claimed PASS
            fake_ipc_record = {
                "testcase_id": "S02.IPC.1",
                "requirement_id": "JOB-04",
                "suite": "worker_ipc",
                "status": "PASS",
                "exit_status": 0,
                "test_type": "automated",
                "expected": "Init worker",
                "observed": "Worker connected"
            }
            with open(os.path.join(tmp_report_dir, "worker_ipc_records.jsonl"), "w") as f:
                f.write(json.dumps(fake_ipc_record) + "\n")

            with patch("subprocess.run", return_value=fake_completed_process), \
                 patch.object(package_review, "REPORTS_DIR", tmp_report_dir):
                records = package_review.execute_regression_tests()

        self.assertTrue(len(records) > 0, "Must return test records")
        for rec in records:
            if rec["test_type"] in ("automated", "integration"):
                self.assertNotEqual(
                    rec["status"],
                    "PASS",
                    f"Testcase {rec.get('testcase_id')} falsely marked PASS despite runner exit 44!"
                )
                self.assertEqual(
                    rec["exit_status"],
                    44,
                    f"Testcase {rec.get('testcase_id')} did not record runner exit 44!"
                )
                self.assertIn("Runner failed with exit=44", rec.get("observed", ""))

if __name__ == "__main__":
    unittest.main()
