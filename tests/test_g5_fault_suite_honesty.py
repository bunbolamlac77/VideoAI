"""
tests/test_g5_fault_suite_honesty.py — Regression for audit P0-04 (2026-11-11).

`g5.fault.run_suite` was displayed in the app as "S25: Tiêm lỗi" and returned
`{"status": "PASS"}` after exercising four boundaries against a throw-away SQLite file in a
temp directory. It never touched the canonical store, Resolve or the real disk, so it could
PASS on a machine where every real recovery path was broken.

The suite is now reported as `SELF_TEST_ONLY`, never as release evidence, and S25 can only
be certified by an externally produced real fault run. This test pins both halves:
the self-test cannot promote itself, and fabricated/partial evidence is rejected.
"""

from __future__ import annotations

from pathlib import Path
import sys
import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from workers.src.aivideo_workers import g5_release_audit


def _real_evidence(**overrides):
    evidence = {
        "schema": g5_release_audit.REAL_FAULT_SUITE_EVIDENCE_SCHEMA,
        "status": "PASS",
        "run_id": "run-2026-11-11-real-fault-01",
        "database_path": "project_store.db",
        "boundaries_tested": [
            {"boundary_id": "B1_PRE_DB_COMMIT_CRASH", "passed": True},
            {"boundary_id": "B2_DISK_FULL_BEFORE_FINAL_RENDER", "passed": True},
            {"boundary_id": "B3_RESOLVE_MID_OPERATION_UNCERTAIN_INTENT", "passed": True},
            {"boundary_id": "B4_ONLINE_BACKUP_RESTORE_INTEGRITY", "passed": True},
        ],
    }
    evidence.update(overrides)
    return evidence


class TestFaultSuiteIsSelfTestOnly(unittest.TestCase):
    def test_status_is_not_pass(self):
        result = g5_release_audit.run_commit_boundary_fault_suite()
        self.assertEqual(result["status"], "SELF_TEST_ONLY")
        self.assertNotEqual(result["status"], "PASS")

    def test_self_test_never_certifies_s25(self):
        result = g5_release_audit.run_commit_boundary_fault_suite()
        self.assertFalse(result["release_evidence"])
        self.assertFalse(result["s25_certified"])
        self.assertEqual(result["certification_source"], "self_test_only")

    def test_calling_it_many_times_never_promotes(self):
        for _ in range(3):
            result = g5_release_audit.run_commit_boundary_fault_suite({})
            self.assertFalse(result["s25_certified"])


class TestRealEvidenceValidation(unittest.TestCase):
    def test_complete_real_evidence_is_accepted(self):
        self.assertTrue(g5_release_audit.validate_real_fault_suite_evidence(_real_evidence()))

    def test_fabricated_and_partial_evidence_is_rejected(self):
        cases = {
            "not a dict": None,
            "wrong schema": _real_evidence(schema="g5-s25-fault-injection-report-v1"),
            "self-test status": _real_evidence(status="SELF_TEST_ONLY"),
            "missing run id": _real_evidence(run_id=""),
            "missing database": _real_evidence(database_path=""),
            "too few boundaries": _real_evidence(boundaries_tested=[{"passed": True}]),
            "a failed boundary": _real_evidence(
                boundaries_tested=_real_evidence()["boundaries_tested"][:3] + [{"boundary_id": "B4", "passed": False}]
            ),
        }
        for name, evidence in cases.items():
            with self.subTest(case=name):
                self.assertFalse(g5_release_audit.validate_real_fault_suite_evidence(evidence))

    def test_self_test_result_passed_as_evidence_is_rejected(self):
        """Feeding the suite's own output back in must not certify anything."""
        suite_output = g5_release_audit.run_commit_boundary_fault_suite()
        self.assertFalse(g5_release_audit.validate_real_fault_suite_evidence(suite_output))

    def test_valid_evidence_promotes_when_supplied_explicitly(self):
        result = g5_release_audit.run_commit_boundary_fault_suite(
            {"real_fault_evidence": _real_evidence()}
        )
        self.assertTrue(result["s25_certified"])
        self.assertEqual(result["certification_source"], "real_fault_evidence")


class TestReleaseManifestDisclosesS25(unittest.TestCase):
    def test_manifest_marks_self_test_as_not_certifying(self):
        manifest = g5_release_audit.generate_release_handover_manifest(
            {"s25_evidence_status": "no_real_fault_run_available"}
        )
        block = manifest["s25_fault_evidence"]
        self.assertFalse(block["certified"])
        self.assertTrue(block["self_test_is_not_evidence"])
        self.assertEqual(block["evidence_status"], "no_real_fault_run_available")

    def test_manifest_certifies_only_with_valid_real_evidence(self):
        manifest = g5_release_audit.generate_release_handover_manifest(
            {"real_fault_evidence": _real_evidence()}
        )
        self.assertTrue(manifest["s25_fault_evidence"]["certified"])

    def test_manifest_rejects_forged_real_evidence(self):
        manifest = g5_release_audit.generate_release_handover_manifest(
            {"real_fault_evidence": _real_evidence(run_id="")}
        )
        self.assertFalse(manifest["s25_fault_evidence"]["certified"])


if __name__ == "__main__":
    unittest.main()
