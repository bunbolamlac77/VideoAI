#!/usr/bin/env python3
"""Regression tests: JSONL evidence must not invent PASS outcomes."""

import io
import json
from pathlib import Path
import tempfile
import unittest

from tools.run_python_tests import (
    DISCOVERY_PATTERN,
    TESTS_DIRECTORY,
    StructuredJSONLTestResult,
    record_test,
    requirement_id,
)


class TestRunnerRecords(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.records = Path(self.temp.name) / "reports" / "records.jsonl"

    def entries(self):
        return [json.loads(line) for line in self.records.read_text(encoding="utf-8").splitlines()]

    def run_nested(self, case):
        nested = unittest.TextTestRunner(
            stream=io.StringIO(),
            verbosity=0,
            resultclass=lambda stream, descriptions, verbosity: StructuredJSONLTestResult(
                stream, descriptions, verbosity, self.records
            ),
        )
        return nested.run(case)

    def test_discovery_includes_new_s05_module(self):
        paths = [p.name for p in TESTS_DIRECTORY.glob(DISCOVERY_PATTERN)]
        self.assertIn("test_s05_snapshot.py", paths)
        self.assertIn("test_runner_records.py", paths)

    def test_expected_failure_is_not_misreported_as_pass(self):
        class ExpectedFailure(unittest.TestCase):
            @unittest.expectedFailure
            def runTest(self):
                self.assertEqual(1, 2)

        result = self.run_nested(ExpectedFailure())
        self.assertTrue(result.wasSuccessful())
        self.assertEqual(self.entries()[0]["status"], "NOT_RUN")
        self.assertEqual(self.entries()[0]["outcome"], "EXPECTED_FAILURE")

    def test_requirement_mapping_for_s05(self):
        self.assertEqual(requirement_id("tests.test_s05_snapshot.TestS05Snapshots.test_x"), "DATA-01")
        self.assertEqual(requirement_id("tests.test_g1_contracts.X.test_x"), "DATA-04")

    def test_records_are_strict_jsonl_with_required_fields(self):
        record_test(self.records, "tests.Case.test_a", "DATA-01", "PASS", 0,
                    "expected", "observed")
        entries = self.entries()
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["status"], "PASS")
        self.assertEqual(entries[0]["requirement_id"], "DATA-01")
        self.assertIn("timestamp", entries[0])

    def test_failed_subtest_is_fail_not_omitted(self):
        class FailureInSubTest(unittest.TestCase):
            def runTest(self):
                with self.subTest(case="failure"):
                    self.assertEqual(1, 2)

        result = self.run_nested(FailureInSubTest())
        self.assertFalse(result.wasSuccessful())
        entries = self.entries()
        self.assertTrue(any(x["status"] == "FAIL" for x in entries))
        self.assertTrue(any(x.get("outcome") == "SUBTEST_FAILURE" for x in entries))

    def test_unexpected_success_is_fail(self):
        class UnexpectedSuccess(unittest.TestCase):
            @unittest.expectedFailure
            def runTest(self):
                self.assertEqual(1, 1)

        result = self.run_nested(UnexpectedSuccess())
        self.assertFalse(result.wasSuccessful())
        self.assertEqual(self.entries()[0]["outcome"], "UNEXPECTED_SUCCESS")
        self.assertEqual(self.entries()[0]["status"], "FAIL")

    def test_skipped_test_is_not_run(self):
        class Skipped(unittest.TestCase):
            def runTest(self):
                self.skipTest("external model is not installed")

        result = self.run_nested(Skipped())
        self.assertTrue(result.wasSuccessful())
        entry = self.entries()[0]
        self.assertEqual(entry["status"], "NOT_RUN")
        self.assertIn("not installed", entry["observed"])


if __name__ == "__main__":
    unittest.main()
