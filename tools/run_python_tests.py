#!/usr/bin/env python3
"""
tools/run_python_tests.py — Structured Python Test Runner emitting JSONL records
"""

import os
import sys
import json
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

def record_test(records_file, test_id, req_id, status, exit_status, expected, observed):
    os.makedirs(os.path.dirname(records_file), exist_ok=True)
    rec = {
        "testcase_id": test_id,
        "requirement_id": req_id,
        "suite": "python_tests",
        "command": f"{sys.executable} -m unittest {test_id}",
        "status": status,
        "exit_status": exit_status,
        "expected": expected,
        "observed": observed,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    }
    with open(records_file, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")

class StructuredJSONLTestResult(unittest.TextTestResult):
    def __init__(self, stream, descriptions, verbosity, records_file):
        super().__init__(stream, descriptions, verbosity)
        self.records_file = records_file

    def addSuccess(self, test):
        super().addSuccess(test)
        test_id = test.id()
        doc = (test.shortDescription() or "").strip()
        req_id = "DATA-04" if "g1_contracts" in test_id else ("OFF-01" if "model" in test_id else "JOB-04")
        record_test(
            self.records_file,
            test_id,
            req_id,
            "PASS",
            0,
            doc or "Test passed successfully",
            "Observed expected invariant without error"
        )

    def addFailure(self, test, err):
        super().addFailure(test, err)
        test_id = test.id()
        doc = (test.shortDescription() or "").strip()
        record_test(
            self.records_file,
            test_id,
            "OFF-01" if "model" in test_id else "JOB-04",
            "FAIL",
            1,
            doc or "Test expected to pass",
            f"Assertion failed: {str(err[1])[:200]}"
        )

    def addError(self, test, err):
        super().addError(test, err)
        test_id = test.id()
        doc = (test.shortDescription() or "").strip()
        record_test(
            self.records_file,
            test_id,
            "OFF-01" if "model" in test_id else "JOB-04",
            "FAIL",
            1,
            doc or "Test expected to run without error",
            f"Error raised: {str(err[1])[:200]}"
        )

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        test_id = test.id()
        doc = (test.shortDescription() or "").strip()
        record_test(
            self.records_file,
            test_id,
            "OFF-01" if "model" in test_id else "JOB-04",
            "NOT_RUN",
            0,
            doc or "Test skipped by condition",
            f"Skipped: {reason}"
        )

def main():
    records_file = os.path.abspath("build/reports/python_test_records.jsonl")
    if os.path.exists(records_file):
        try:
            os.remove(records_file)
        except OSError:
            pass

    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    suite.addTests(loader.loadTestsFromName("tests.test_framing_resilience"))
    suite.addTests(loader.loadTestsFromName("tests.test_model_setup"))
    suite.addTests(loader.loadTestsFromName("tests.test_package_review_fault_injection"))
    suite.addTests(loader.loadTestsFromName("tests.test_g1_contracts"))

    runner = unittest.TextTestRunner(
        verbosity=2,
        resultclass=lambda stream, descriptions, verbosity: StructuredJSONLTestResult(
            stream, descriptions, verbosity, records_file
        )
    )

    result = runner.run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)

if __name__ == "__main__":
    main()
