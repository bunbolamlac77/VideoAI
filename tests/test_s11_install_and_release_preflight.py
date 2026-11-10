"""Regression tests for offline model integrity and release-readiness honesty.

All tests use tiny synthetic model files and mock the download. No network or
actual model weights are accessed by this suite.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import check_readiness as readiness
import setup_s11_model as s11
import setup_g0_model as g0


def synthetic_model(staging: Path) -> str:
    header = json.dumps({"t": {"dtype": "U8", "shape": [64], "data_offsets": [0, 64]}}).encode()
    weights = len(header).to_bytes(8, "little") + header + b"x" * 64
    for name in s11.REQUIRED_FILES:
        (staging / name).write_bytes(weights if name == "model.safetensors" else f"synthetic:{name}".encode())
    return hashlib.sha256(weights).hexdigest()


class TestS11ModelInstaller(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.parent = Path(self.tmp.name) / "models"
        self.parent.mkdir()
        self.target = self.parent / s11.S11_ROLE
        self.patches = [
            mock.patch.object(s11, "get_target_dir", return_value=self.target),
            mock.patch.object(s11, "REQUIRED_DISK_FREE_BYTES", 0),
            mock.patch.object(s11, "MIN_WEIGHTS_SIZE_BYTES", 16),
        ]
        for p in self.patches:
            p.start()
            self.addCleanup(p.stop)

    def _fake_download(self, staging):
        checksum = synthetic_model(staging)
        self.assertEqual(checksum, self.checksum)

    def test_download_error_cannot_delete_preexisting_install(self):
        self.target.mkdir()
        (self.target / "precious.txt").write_text("do not delete")
        with mock.patch.object(s11, "download_snapshot", side_effect=RuntimeError("offline")):
            result = s11.cmd_install(force=True)
        self.assertNotEqual(result, 0)
        self.assertEqual((self.target / "precious.txt").read_text(), "do not delete")
        self.assertFalse(list(self.parent.glob(".aivideo-s11-staging-*")))

    def test_new_install_verification_and_tamper_detection(self):
        with tempfile.TemporaryDirectory() as fixture:
            self.checksum = synthetic_model(Path(fixture))
        with mock.patch.object(s11, "S11_PINNED_WEIGHTS_SHA256", self.checksum), \
             mock.patch.object(s11, "download_snapshot", side_effect=self._fake_download):
            self.assertEqual(s11.cmd_install(), 0)
            verified = s11.verify_model_directory(self.target)
            self.assertEqual(verified["artifact_count"], len(s11.REQUIRED_FILES))
            self.assertEqual(verified["revision"], s11.S11_REVISION)
            (self.target / "config.json").write_text("modified")
            with self.assertRaisesRegex(s11.ModelValidationError, "installation manifest"):
                s11.verify_model_directory(self.target)

    def test_malformed_manifest_object_is_rejected_without_crashing(self):
        with tempfile.TemporaryDirectory() as fixture:
            self.checksum = synthetic_model(Path(fixture))
        with mock.patch.object(s11, "S11_PINNED_WEIGHTS_SHA256", self.checksum), \
             mock.patch.object(s11, "download_snapshot", side_effect=self._fake_download):
            self.assertEqual(s11.cmd_install(), 0)
            (self.target / s11.INSTALL_MANIFEST).write_text("[1, 2, 3]")
            with self.assertRaisesRegex(s11.ModelValidationError, "must be a JSON object"):
                s11.verify_model_directory(self.target)

    def test_safetensors_header_must_be_an_object(self):
        self.target.mkdir()
        bogus = json.dumps(["not", "an", "object"]).encode()
        file_path = self.target / "weights.safetensors"
        file_path.write_bytes(len(bogus).to_bytes(8, "little") + bogus + b"rest" * 16)
        ok, err = s11.verify_safetensors(file_path)
        self.assertFalse(ok)
        self.assertIn("JSON object", err)

    def test_weights_must_match_upstream_pinned_sha(self):
        self.target.mkdir()
        synthetic_model(self.target)
        with self.assertRaisesRegex(s11.ModelValidationError, "PINNED_WEIGHT_SHA256_MISMATCH"):
            s11.verify_model_directory(self.target, require_manifest=False)

    def test_second_rename_error_restores_previous_install(self):
        self.target.mkdir()
        (self.target / "precious.txt").write_text("old-good-copy")
        with tempfile.TemporaryDirectory() as fixture:
            self.checksum = synthetic_model(Path(fixture))
        native_replace = s11.os.replace
        raised = [False]

        def fail_publish(src, dst):
            if not raised[0] and str(src).find(".aivideo-s11-staging-") >= 0 and dst == self.target:
                raised[0] = True
                raise OSError("simulated publish failure")
            return native_replace(src, dst)

        with mock.patch.object(s11, "S11_PINNED_WEIGHTS_SHA256", self.checksum), \
             mock.patch.object(s11, "download_snapshot", side_effect=self._fake_download), \
             mock.patch.object(s11.os, "replace", side_effect=fail_publish):
            self.assertEqual(s11.cmd_install(force=True), 1)
        self.assertTrue(raised[0])
        self.assertEqual((self.target / "precious.txt").read_text(), "old-good-copy")

    def test_existing_unverified_directory_not_silently_replaced(self):
        self.target.mkdir()
        (self.target / "precious.txt").write_text("previous data")
        with mock.patch.object(s11, "download_snapshot") as download:
            self.assertEqual(s11.cmd_install(force=False), 1)
            download.assert_not_called()
        self.assertEqual((self.target / "precious.txt").read_text(), "previous data")


class TestG0NonDestructiveInstall(unittest.TestCase):
    def test_plan_does_not_create_any_directories(self):
        with tempfile.TemporaryDirectory() as td:
            missing = Path(td) / "does-not-exist" / "AIVideo"
            self.assertEqual(g0.execute_plan(str(missing)), 0)
            self.assertFalse(missing.parent.exists())

    def test_force_download_error_cannot_delete_previous_install(self):
        with tempfile.TemporaryDirectory() as td:
            app_support = Path(td) / "AIVideo"
            target = app_support / "Models" / "g0-text" / g0.G0_MODEL_REVISION
            target.mkdir(parents=True)
            (target / "unique-old-weight.bin").write_bytes(b"critical-old-data")

            fake_hub = types.SimpleNamespace(snapshot_download=mock.Mock(side_effect=RuntimeError("network down")))
            with mock.patch.object(g0, "check_system_environment", return_value={"is_arm64": True}), \
                 mock.patch.object(g0, "verify_existing_pinned_install", return_value=False), \
                 mock.patch.dict(sys.modules, {"huggingface_hub": fake_hub}):
                self.assertEqual(g0.execute_install(str(app_support), force=True), 1)
            self.assertEqual((target / "unique-old-weight.bin").read_bytes(), b"critical-old-data")

    def test_g0_force_rejects_symlink_model_target(self):
        with tempfile.TemporaryDirectory() as td:
            app_support = Path(td) / "AIVideo"
            external = Path(td) / "external"
            external.mkdir()
            target = app_support / "Models" / "g0-text" / g0.G0_MODEL_REVISION
            target.parent.mkdir(parents=True)
            target.symlink_to(external, target_is_directory=True)
            self.assertEqual(g0.execute_install(str(app_support), force=True), 2)
            self.assertTrue(target.is_symlink())


class TestReleaseReadiness(unittest.TestCase):
    def test_python_incompatible_worker_runtime_is_not_accepted(self):
        with mock.patch.object(readiness.platform, "system", return_value="Darwin"), \
             mock.patch.object(readiness.platform, "machine", return_value="arm64"), \
             mock.patch.object(readiness, "command", side_effect=lambda args: (True, "3.13.5") if "-c" in args else (True, "ok")), \
             mock.patch.object(readiness.shutil, "which", return_value="/some/program"):
            state = readiness.check_toolchain()
            self.assertFalse(state["python_ok"])
            self.assertFalse(state["passed"])

    def test_model_gate_rejects_unverified_weights(self):
        from aivideo_workers import model_installation

        unverified = {
            "role": "visual_analysis_primary",
            "models_root": "/tmp/models",
            "directory": "/tmp/models/visual_analysis_primary",
            "state": "present_unverified",
            "reason": "INSTALL_MANIFEST_MISSING: weights exist but integrity is unproven",
            "verified": False,
            "deep": True,
        }
        with mock.patch.object(model_installation, "inspect_model_installation", return_value=unverified):
            state = readiness.check_models_presence()
            self.assertFalse(state["visual_model_installed"])
            self.assertEqual(state["status"], "NOT_VERIFIED")
            self.assertEqual(state["installation_state"], "present_unverified")

    def test_disabled_capability_is_a_required_release_gate(self):
        from aivideo_workers import g5_capabilities
        fake = {"capabilities": {"exact_photo_shutter_match": {"status": "validated"}}}
        with mock.patch.object(g5_capabilities, "load_capability_registry", return_value=fake):
            self.assertFalse(readiness.check_contracts_and_registry()["passed"])

    def test_missing_resolve_blocks_release_even_when_other_gates_pass(self):
        success = {"passed": True}
        with tempfile.TemporaryDirectory() as tmp, \
             mock.patch.object(readiness, "REPORT", Path(tmp) / "report.json"), \
             mock.patch.object(readiness, "check_toolchain", return_value=success), \
             mock.patch.object(readiness, "check_app_bundle", return_value={"passed": True}), \
             mock.patch.object(readiness, "check_contracts_and_registry", return_value=success), \
             mock.patch.object(readiness, "check_models_presence", return_value={"visual_model_installed": True, "status": "VERIFIED_PINNED_LOCAL"}), \
             mock.patch.object(readiness, "check_resolve_installation", return_value={"installed": False}), \
             mock.patch.object(readiness, "check_field_corpus_and_certification", return_value={"live_field_corpus_certified": True, "certification_status": "CERTIFIED_FIELD_CORPUS"}):
            self.assertEqual(readiness.run_preflight(), 2)
            report = json.loads(readiness.REPORT.read_text())
        self.assertTrue(any("DAVINCI_RESOLVE_NOT_INSTALLED" in b for b in report["blockers"]))
        self.assertTrue(report["timestamp"].endswith("+00:00"))
        self.assertFalse(report["ready_for_production_release"])


if __name__ == "__main__":
    unittest.main()
