"""
tests/test_p1_evidence_trust.py — Regression for audit P1-12/14/16/17/20/21/22 (2026-11-11).

Each case pins one rule that used to be self-declared or fail-open:

  P1-12  the visual model root / weights identity could be chosen by the caller
  P1-14  the fixture-graded benchmark emitted a bare "PASS" decision
  P1-16  `g5.preferences.manage` wrote to any path the caller named
  P1-17  the disk-full simulation hook was honoured in production
  P1-20  `AIVIDEO_CONTRACTS_DIR` could substitute the runtime capability registry
  P1-21  a corrupt label file was skipped silently and the corpus still looked eligible
  P1-22  an ad-hoc signed app passed the release preflight
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from aivideo_workers import corpus_labels, g5_capabilities, g5_final, model_installation
from aivideo_workers.corpus_labels import (
    load_clip_labels_with_problems,
    summarize_label_eligibility,
)
from aivideo_workers.g5_capabilities import manage_preference_profile

PREFERENCE_PATH_REFUSED = "PREFERENCE_PATH_REFUSED"
from tools import check_readiness


class TestModelIdentityIsPinned(unittest.TestCase):
    """P1-12: a manifest that describes self-written weights is not "verified"."""

    def _fake_install(self, root: Path, declared_weights_sha: str) -> Path:
        directory = root / model_installation.VISUAL_ROLE
        directory.mkdir(parents=True)
        files = {}
        for index, name in enumerate(model_installation.REQUIRED_ARTIFACTS):
            payload = b"self-written" + bytes([index])
            (directory / name).write_bytes(payload)
            import hashlib

            files[name] = {
                "size_bytes": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
            }
        files["model.safetensors"]["sha256"] = declared_weights_sha
        (directory / model_installation.INSTALL_MANIFEST).write_text(
            json.dumps({"schema": "x", "model_id": "x", "revision": "r", "files": files}),
            encoding="utf-8",
        )
        return directory

    def test_self_written_weights_are_not_verified(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._fake_install(Path(tmp), declared_weights_sha="f" * 64)
            status = model_installation.inspect_model_installation(Path(tmp))
        self.assertEqual(status["state"], "present_unverified")
        self.assertIn("PINNED_WEIGHT_SHA256_MISMATCH", status["reason"])

    def test_pinned_identity_is_accepted_without_hashing(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._fake_install(Path(tmp), declared_weights_sha=model_installation.PINNED_VISUAL_WEIGHTS_SHA256)
            status = model_installation.inspect_model_installation(Path(tmp))
        self.assertEqual(status["state"], "verified")

    def _rpc(self, params):
        from aivideo_workers.main import handle_g2_analyze_source

        return handle_g2_analyze_source(params)

    def test_rpc_rejects_models_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            clip = Path(tmp) / "clip.mp4"
            clip.write_bytes(b"not a real video")
            with self.assertRaisesRegex(ValueError, "MODELS_ROOT_FORBIDDEN"):
                self._rpc({"file_path": str(clip), "models_root_dir": "/tmp/models"})

    def test_rpc_rejects_models_root_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            clip = Path(tmp) / "clip.mp4"
            clip.write_bytes(b"not a real video")
            with mock.patch.dict(os.environ, {"AIVIDEO_MODELS_ROOT": "/tmp/models"}):
                with self.assertRaisesRegex(ValueError, "MODELS_ROOT_FORBIDDEN"):
                    self._rpc({"file_path": str(clip)})


class TestBenchmarkDecisionIsHonest(unittest.TestCase):
    """P1-14: the decision-table harness names its own decision."""

    def test_harness_decision_is_not_a_bare_pass(self):
        from aivideo_workers.g2_benchmark_runner import (
            build_canonical_g2_benchmark_fixture,
            run_g2_analysis_eligible_benchmark,
        )

        fix = build_canonical_g2_benchmark_fixture()
        report = run_g2_analysis_eligible_benchmark(
            manifest=fix["manifest"],
            asset_to_group_map=fix["asset_to_group_map"],
            dev_asset_ids=fix["dev_assets"],
            holdout_asset_ids=fix["holdout_assets"],
            claim_opportunities=fix["claim_opportunities"],
            observable_events=fix["observable_events"],
            verifier_adversarial_suite=fix["verifier_suite"],
            frame_coverage_by_group=fix["synthetic_coverage_by_group"],
        )
        self.assertEqual(report["decision_kind"], "decision_harness_fixture")
        self.assertIn(report["harness_decision"], ("HARNESS_PASS", "HARNESS_FAIL"))
        self.assertEqual(report["g2_gate_decision"], report["harness_decision"])
        self.assertNotIn(report["harness_decision"], ("PASS", "FAIL"))


class TestPreferencesStayInsideTheApp(unittest.TestCase):
    """P1-16: the preference profile path is not caller-controlled."""

    def test_relative_path_resolves_under_app_support(self):
        result = manage_preference_profile({"action": "edit", "profile_path": "mine.json",
                                            "updates": {"pacing_style": "calm"}})
        self.assertEqual(result["status"], "OK")
        self.assertIn("Application Support/AIVideo/Preferences", result["profile_path"])

    def test_outside_path_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "victim.json"
            with self.assertRaisesRegex(Exception, PREFERENCE_PATH_REFUSED):
                manage_preference_profile({"action": "reset", "profile_path": str(target)})
            self.assertFalse(target.exists(), "a refused path must never create files")

    def test_dotdot_escape_is_refused(self):
        with self.assertRaisesRegex(Exception, PREFERENCE_PATH_REFUSED):
            manage_preference_profile({"action": "reset", "profile_path": "../../../tmp/escape.json"})


class TestSimulationHookIsTestOnly(unittest.TestCase):
    """P1-17: the disk-full simulation only works under the test harness."""

    def test_override_ignored_in_production(self):
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.dict(os.environ, {g5_final.SIMULATE_FREE_BYTES_ENV: "1"},
                                 clear=False):
                os.environ.pop(g5_final.TEST_HARNESS_ENV, None)
                info = g5_final._preflight_disk_space(Path(tmp), min_bytes=1)
        self.assertGreater(info["free_bytes"], 1_000_000, "production must measure the real disk")

    def test_override_honoured_under_harness(self):
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.dict(os.environ, {
                g5_final.SIMULATE_FREE_BYTES_ENV: "1024",
                g5_final.TEST_HARNESS_ENV: "1",
            }):
                with self.assertRaisesRegex(Exception, "DISK_SPACE_INSUFFICIENT"):
                    g5_final._preflight_disk_space(Path(tmp), min_bytes=512 * 1024 * 1024)


class TestContractsDirCannotBeRedirected(unittest.TestCase):
    """P1-20: runtime contracts come from the package, never from the environment."""

    def test_env_variable_is_refused(self):
        from aivideo_workers import runtime_paths

        with mock.patch.dict(os.environ, {"AIVIDEO_CONTRACTS_DIR": "/tmp/attacker"}):
            with self.assertRaisesRegex(RuntimeError, "CONTRACTS_DIR_FORBIDDEN"):
                runtime_paths.resolve_s11_registry()


class TestCorruptLabelsAreBlockers(unittest.TestCase):
    """P1-21: an unreadable label file must not shrink the corpus silently."""

    def test_corrupt_file_is_reported_and_blocks_eligibility(self):
        with tempfile.TemporaryDirectory() as tmp:
            labels_dir = Path(tmp)
            (labels_dir / "broken.json").write_text("{not json", encoding="utf-8")
            good = {"schema": corpus_labels.LABEL_SCHEMA, "trip_id": "t1",
                    "labeler_type": "human", "source_kind": "field_footage"}
            (labels_dir / "t1.json").write_text(json.dumps(good), encoding="utf-8")
            labels, problems = load_clip_labels_with_problems(labels_dir)
            summary = summarize_label_eligibility(labels, problems)
        self.assertEqual(list(labels), ["t1"])
        self.assertTrue(problems)
        self.assertFalse(summary["acceptance_eligible"], "one broken label must block eligibility")
        self.assertTrue(summary["label_problems"])

    def test_clean_labels_are_eligible(self):
        with tempfile.TemporaryDirectory() as tmp:
            labels_dir = Path(tmp)
            good = {"schema": corpus_labels.LABEL_SCHEMA, "trip_id": "t1",
                    "labeler_type": "human", "source_kind": "field_footage"}
            (labels_dir / "t1.json").write_text(json.dumps(good), encoding="utf-8")
            labels, problems = load_clip_labels_with_problems(labels_dir)
            summary = summarize_label_eligibility(labels, problems)
        self.assertEqual(problems, [])
        self.assertTrue(summary["acceptance_eligible"])


class TestAdHocSignatureIsNotARelease(unittest.TestCase):
    """P1-22: an ad-hoc signature is a blocker even without a configured team id."""

    def _bundle(self, signature_line: str):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("AIVIDEO_RELEASE_TEAM_ID", None)
            with mock.patch("tools.check_readiness.command") as mock_cmd, \
                 mock.patch("pathlib.Path.is_dir", return_value=True), \
                 mock.patch("pathlib.Path.is_file", return_value=True):
                mock_cmd.side_effect = [
                    (True, "Mach-O 64-bit executable arm64"),
                    (True, "valid on disk"),
                    (True, signature_line),
                ]
                return check_readiness.check_app_bundle()

    def test_adhoc_without_team_is_blocked(self):
        bundle = self._bundle("Identifier=com.phuthanh.aivideo\nSignature=adhoc\nTeamIdentifier=not set")
        self.assertTrue(bundle["is_adhoc"])
        self.assertFalse(bundle["passed"])
        self.assertIn("Ad-hoc signed", bundle["codesign_detail"])

    def test_explicit_development_opt_in_allows_adhoc(self):
        with mock.patch("tools.check_readiness.command") as mock_cmd, \
             mock.patch("pathlib.Path.is_dir", return_value=True), \
             mock.patch("pathlib.Path.is_file", return_value=True):
            mock_cmd.side_effect = [
                (True, "Mach-O 64-bit executable arm64"),
                (True, "valid on disk"),
                (True, "Identifier=com.phuthanh.aivideo\nSignature=adhoc\nTeamIdentifier=not set"),
            ]
            bundle = check_readiness.check_app_bundle(allow_adhoc=True)
        self.assertTrue(bundle["passed"])


if __name__ == "__main__":
    unittest.main()
