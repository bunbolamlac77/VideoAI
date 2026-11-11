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
    """(P1-45) Map a test to the requirement it verifies.

    This used to be a handful of if-statements with a catch-all of `JOB-04`, which parked
    ~half the suite under one id and made traceability meaningless. The mapping is now table
    driven and the fallback distinguishes *known but unmapped* modules from genuinely
    generic tests, so a new module shows up as unmapped instead of hiding in JOB-04.
    """
    for marker, requirement in REQUIREMENT_MARKERS:
        if marker in test_id:
            return requirement
    module = test_id.split(".")[1] if test_id.startswith("tests.") and test_id.count(".") > 1 else ""
    return UNTRACED_REQUIREMENT if module in KNOWN_MODULES else GENERIC_REQUIREMENT


# Order matters: the first matching marker wins (most specific first).
REQUIREMENT_MARKERS = (
    ("test_rpc_strict_json", "INV-03"),
    ("test_s11_install_and_release_preflight", "OFF-01"),
    ("test_s05_snapshot", "DATA-01"),
    ("test_g1_contracts", "DATA-04"),
    ("test_model_setup", "OFF-01"),
    ("test_s10_media_indexer", "MEDIA-01"),
    ("test_s11_model_adapters", "AI-01"),
    ("test_s12_full_frame_pipeline", "AI-01"),
    ("test_s13_semantic_verifier", "AI-03"),
    ("test_s14_review_workflow", "AI-09"),
    ("test_s15_g2_benchmark", "AI-05"),
    ("test_s16_to_s19_g3", "STORY-01"),
    ("test_g3_security_rpc", "INV-03"),
    ("test_s20_s21_g4", "RES-02"),
    ("test_s22_to_s26_g5", "RES-03"),
    ("test_readiness_security", "SEC-01"),
    ("test_p0_integrity_gates", "SEC-02"),
    # 2026-11-11 audit regressions
    ("test_g2_checkpoint_integrity", "AI-01"),
    ("test_g2_window_audit", "AI-01"),
    ("test_g2_window_contract", "AI-01"),
    ("test_g2_prefilter", "AI-05"),
    ("test_g3_voice_gate", "STORY-01"),
    ("test_g3_story", "STORY-01"),
    ("test_g5_fault_suite_honesty", "REL-03"),
    ("test_g5_final_and_release", "RES-03"),
    ("test_package_review_gate", "REL-03"),
    ("test_smoke_corpus_honesty", "AI-05"),
    ("test_corpus_labels", "AI-05"),
    ("test_p1_", "INV-05"),
    ("test_wedding_scenes", "AI-03"),
    ("test_script_brief_parser", "STORY-01"),
    ("test_s16_story_llm", "STORY-01"),
    ("test_s17_", "AUD-01"),
    ("test_s20_native_render", "RES-03"),
    ("test_artifact_schema", "DATA-04"),
    ("test_source_hygiene", "INV-03"),
    ("test_single_writer_invariants", "INV-03"),
    ("test_qa_anchor_invariants", "SEC-01"),
    ("test_audit_hardening", "SEC-02"),
    ("test_runner_records", "JOB-04"),
    ("test_framing_resilience", "AI-01"),
    ("test_s11_vision_pixel_budget", "OFF-01"),
    ("test_model_installation", "OFF-01"),
    ("test_package_review_fault_injection", "REL-03"),
    ("test_s11_real_vlm_inference", "AI-01"),
    ("test_source_revision_identity", "DATA-01"),
    ("test_worker_", "INV-03"),
    ("test_contracts", "DATA-04"),
    ("test_p0_", "SEC-02"),
)

# Modules whose requirements are declared above; a test from one of these that matches no
# marker is a traceability gap, not a "JOB-04" test.
KNOWN_MODULES = (
    "test_g1_contracts",
    "test_g2_coverage_dto",
    "test_g3_story_request",
    "test_source_revision_identity",
    "test_g5_native_provenance",
    "test_s02_manual_verification",
    "test_g5_receipt_binding",
    "test_g3_llm_approval",
    "test_g3_story_scope",
)
UNTRACED_REQUIREMENT = "UNTRACED"
GENERIC_REQUIREMENT = "JOB-04"


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


def _maybe_reexec_with_mlx_runtime() -> None:
    if os.environ.get("AIVIDEO_PYTHON_REEXEC") == "1":
        return
    try:
        import mlx  # noqa: F401
        import mlx_lm  # noqa: F401
        return
    except Exception as exc:
        from aivideo_workers.diagnostics import note_suppressed
        note_suppressed("run_python_tests.py:197", exc)
        pass
    candidate = Path.home() / "Library" / "Application Support" / "AIVideo" / "Runtimes" / "g0-mlx-runtime" / "bin" / "python3"
    if candidate.is_file() and os.access(candidate, os.X_OK):
        env = dict(os.environ)
        env["AIVIDEO_PYTHON_REEXEC"] = "1"
        os.execve(str(candidate), [str(candidate), *sys.argv], env)


def main():
    _maybe_reexec_with_mlx_runtime()
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
