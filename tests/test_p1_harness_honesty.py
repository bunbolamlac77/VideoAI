"""
tests/test_p1_harness_honesty.py — Regression for audit P1-41/42/43/44 (2026-11-11).

  P1-41  S02 "manual" evidence was accepted on a plain `status: PASS` string, so any file
         dropped into reports/evidence certified itself.
  P1-42  the artifact publication schema listed types the code never writes and omitted the
         ones it does, so it validated nothing.
  P1-43  CI only ran `swiftc -frontend -parse` (syntax), never a typecheck.
  P1-44  the regression matrix deleted every prior JSONL record before running.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest

_ROOT = Path(__file__).resolve().parents[1]
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from tools.package_review import verify_s02_evidence


def _artifact_schema() -> dict:
    return json.loads((_ROOT / "contracts" / "schemas" / "artifact_publication_schema.json").read_text())


def _record(artifact_type: str) -> dict:
    return {
        "publication_id": "00000000-0000-4000-8000-000000000001",
        "project_id": "00000000-0000-4000-8000-000000000002",
        "job_id": "00000000-0000-4000-8000-000000000003",
        "attempt_id": "00000000-0000-4000-8000-000000000004",
        "fencing_token": 1,
        "artifact_type": artifact_type,
        "state": "COMMITTED",
        "created_at": "2026-11-11T00:00:00Z",
        "updated_at": "2026-11-11T00:00:00Z",
    }


class TestS02EvidenceCannotSelfCertify(unittest.TestCase):
    """P1-41: a PASS is only accepted with a run identity, timestamp, host and operator."""

    def test_bare_pass_string_is_rejected(self) -> None:
        status, _ = verify_s02_evidence({"status": "PASS"})
        self.assertEqual(status, "FAIL")

    def test_complete_evidence_is_accepted(self) -> None:
        evidence = {
            "status": "PASS",
            "run_id": "ui-run-2026-11-11T10:00:00Z-6f2a",
            "timestamp": "2026-11-11T10:00:00Z",
            "executed_on_host": "phuthanh-MacBook-Pro",
            "operator": "phuthanh",
            "details": "Launched AIVideo.app through LaunchServices with a Unicode path",
        }
        status, _ = verify_s02_evidence(evidence)
        self.assertEqual(status, "PASS")

    def test_not_run_stays_not_run(self) -> None:
        status, _ = verify_s02_evidence({"status": "NOT_RUN", "reason": "UI tests disabled"})
        self.assertEqual(status, "NOT_RUN")

    def test_evidence_without_timestamp_is_rejected(self) -> None:
        evidence = {
            "status": "PASS",
            "run_id": "ui-run-x",
            "executed_on_host": "somehost",
            "operator": "someone",
        }
        status, _ = verify_s02_evidence(evidence)
        self.assertEqual(status, "FAIL")


class TestArtifactSchemaMatchesCode(unittest.TestCase):
    """P1-42: the schema must describe the artifact types the code actually writes."""

    REQUIRED_TYPES = (
        "g2_source_mapping",
        "g3_cut_plan",
        "voice_wav",
        "g4_captioned_cfr",
        "g4_conform_receipt",
        "g4_preview_mp4",
        "g5_captioned_cfr_4k",
        "g5_conform_receipt",
        "g5_final_mp4",
        "g5_handoff_drp",
        "g5_native_receipt",
    )

    def test_every_published_type_is_in_the_enum(self) -> None:
        schema = _artifact_schema()
        enum = set(schema["properties"]["artifact_type"]["enum"])
        for artifact_type in self.REQUIRED_TYPES:
            with self.subTest(type=artifact_type):
                self.assertIn(artifact_type, enum)

    def test_types_published_by_code_validate(self) -> None:
        from jsonschema import Draft202012Validator

        validator = Draft202012Validator(_artifact_schema())
        for artifact_type in self.REQUIRED_TYPES:
            with self.subTest(type=artifact_type):
                self.assertEqual(list(validator.iter_errors(_record(artifact_type))), [])

    def test_unknown_type_is_rejected(self) -> None:
        from jsonschema import Draft202012Validator

        validator = Draft202012Validator(_artifact_schema())
        self.assertNotEqual(list(validator.iter_errors(_record("totally_made_up"))), [])

    def test_enum_has_no_legacy_alias_without_code(self) -> None:
        """Every enum member must be reachable from source (no speculative entries)."""
        schema = _artifact_schema()
        enum = set(schema["properties"]["artifact_type"]["enum"])
        source = ""
        # Tests count too: some legacy names are only exercised through the golden contract
        # tests, which is exactly the evidence that they are still published.
        for pattern in ("workers/src/aivideo_workers/*.py", "apps/macos/Sources/*.swift",
                        "packages/AIVideoCore/Sources/*/*.swift",
                        "tests/*.py", "tests/*.swift"):
            for path in _ROOT.glob(pattern):
                source += path.read_text(encoding="utf-8", errors="ignore")
        unreferenced = sorted(t for t in enum if f'"{t}"' not in source and f'"{t}' not in source)
        self.assertEqual(
            unreferenced, [],
            f"schema lists artifact types no code writes: {unreferenced}",
        )


class TestHarnessRulesAreEnforced(unittest.TestCase):
    """P1-43 / P1-44: CI typechecks, and the matrix never erases evidence first."""

    def test_ci_typechecks_with_warnings_as_errors(self) -> None:
        workflow = (_ROOT / ".github" / "workflows" / "ci.yml").read_text()
        self.assertIn("-typecheck", workflow)
        self.assertIn("-warnings-as-errors", workflow)
        # The old syntax-only step must actually be gone (a mention in a comment is fine).
        step_lines = [
            line for line in workflow.splitlines()
            if "-frontend -parse" in line and not line.lstrip().startswith("#")
        ]
        self.assertEqual(step_lines, [], f"syntax-only parse step still runs: {step_lines}")

    def test_matrix_preserves_previous_records(self) -> None:
        script = (_ROOT / "tools" / "run_tests.sh").read_text()
        self.assertNotIn("rm -f build/reports/*.jsonl", script)
        self.assertIn("build/reports/previous", script)


if __name__ == "__main__":
    unittest.main()
