#!/usr/bin/env python3
"""Structured Python test runner with explicit PASS/FAIL/NOT_RUN evidence."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import time
import unittest

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

TESTS_DIRECTORY = PROJECT_ROOT / "tests"
DISCOVERY_PATTERN = "test_*.py"


def requirement_id(test_id: str) -> str:
    if "test_s05_snapshot" in test_id:
        return "DATA-01"
    if "test_g1_contracts" in test_id:
        return "DATA-04"
    if "test_model_setup" in test_id:
        return "OFF-01"
    if "test_s10_media_indexer" in test_id:
        return "MEDIA-01"
    if "test_s11_model_adapters" in test_id:
        return "AI-01"
    return "JOB-04"


def record_test(records_file, test_id, req_id, status, exit_status, expected, observed,
                *, outcome=None, command_id=None):
    path = Path(records_file)
    path.parent.mkdir(parents=True, exist_ok=True)
    rec = {
        "testcase_id": test_id,
        "requirement_id": req_id,
        "suite": "python_tests",
        "command": f"{sys.executable} -m unittest {command_id or test_id}",
        "status": status,
        "exit_status": exit_status,
        "expected": expected,
        "observed": observed,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if outcome is not None:
        rec["outcome"] = outcome
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


class StructuredJSONLTestResult(unittest.TextTestResult):
    def __init__(self, stream, descriptions, verbosity, records_file):
        super().__init__(stream, descriptions, verbosity)
        self.records_file = records_file

    def _emit(self, test, status, exit_status, expected, observed, *, outcome=None,
              command_id=None):
        identifier = test.id()
        record_test(
            self.records_file, identifier, requirement_id(identifier), status,
            exit_status, expected, observed, outcome=outcome,
            command_id=command_id,
        )

    def addSuccess(self, test):
        super().addSuccess(test)
        self._emit(test, "PASS", 0,
                   test.shortDescription() or "Test expected to pass",
                   "Test passed", outcome="SUCCESS")

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self._emit(test, "FAIL", 1,
                   test.shortDescription() or "Test expected to pass",
                   f"Assertion failed: {err[1]}", outcome="FAILURE")

    def addError(self, test, err):
        super().addError(test, err)
        self._emit(test, "FAIL", 1,
                   test.shortDescription() or "Test expected to run",
                   f"Error raised: {err[1]}", outcome="ERROR")

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self._emit(test, "NOT_RUN", 0,
                   test.shortDescription() or "Test expected to run",
                   f"Skipped: {reason}", outcome="SKIPPED")

    def addExpectedFailure(self, test, err):
        super().addExpectedFailure(test, err)
        self._emit(test, "NOT_RUN", 0,
                   "Known expected failure until repaired",
                   f"Expected failure: {err[1]}", outcome="EXPECTED_FAILURE")

    def addUnexpectedSuccess(self, test):
        super().addUnexpectedSuccess(test)
        self._emit(test, "FAIL", 1,
                   "Expected-failure test should not unexpectedly pass",
                   "Unexpected success; review test expectation",
                   outcome="UNEXPECTED_SUCCESS")

    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)
        # A successful method has its own PASS; failing subtests need a
        # separate FAIL record or the JSONL could misleadingly be empty.
        if err is not None:
            self._emit(subtest, "FAIL", 1,
                       "Every subtest must satisfy its assertion",
                       f"Subtest failed: {err[1]}", outcome="SUBTEST_FAILURE",
                       command_id=test.id())


def main():
    os.chdir(PROJECT_ROOT)
    report_dir = PROJECT_ROOT / "build" / "reports"
    report_dir.mkdir(parents=True, exist_ok=True)
    records_file = report_dir / "python_test_records.jsonl"
    summary_file = report_dir / "python_test_summary.json"
    records_file.write_text("", encoding="utf-8")

    loader = unittest.TestLoader()
    # Discover every current and future tests/test_*.py module, rather than
    # silently ignoring modules that were not added to a hard-coded list.
    if not TESTS_DIRECTORY.is_dir():
        print(f"ERROR: Missing tests directory: {TESTS_DIRECTORY}", file=sys.stderr)
        return 2
    # Preserve existing fully qualified `tests.test_*` IDs and package-relative
    # imports, while still discovering newly added modules automatically.
    modules = sorted(f"tests.{p.stem}" for p in TESTS_DIRECTORY.glob(DISCOVERY_PATTERN))
    suite = unittest.TestSuite()
    for module in modules:
        suite.addTests(loader.loadTestsFromName(module))

    if suite.countTestCases() == 0:
        print("ERROR: No Python tests were discovered", file=sys.stderr)
        return 2

    runner = unittest.TextTestRunner(
        verbosity=2,
        resultclass=lambda stream, descriptions, verbosity: StructuredJSONLTestResult(
            stream, descriptions, verbosity, records_file
        ),
    )
    result = runner.run(suite)
    summary = {
        "suite": "python_tests",
        "modules": modules,
        "discovery_pattern": DISCOVERY_PATTERN,
        "discovery_errors": list(loader.errors),
        "tests_run": result.testsRun,
        "failures": len(result.failures),
        "errors": len(result.errors),
        "skipped": len(result.skipped),
        "expected_failures": len(result.expectedFailures),
        "unexpected_successes": len(result.unexpectedSuccesses),
        "successful": result.wasSuccessful(),
        "records_file": str(records_file.relative_to(PROJECT_ROOT)),
    }
    # Summary is separate: every JSONL line remains a real testcase result.
    staged = summary_file.with_suffix(".json.tmp")
    staged.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(staged, summary_file)
    print(f"Evidence: {records_file}", file=sys.stderr)
    print(f"Summary: {summary_file}", file=sys.stderr)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
