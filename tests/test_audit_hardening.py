"""Adversarial regression for G2 frame provenance and G5 release trust."""
from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "workers" / "src"))

from aivideo_workers import main, pipeline_adapters, g5_release_audit
from aivideo_workers.pipeline_adapters import PipelineAdapterError, S11ModelRegistryAndAdapters


class AuditGateTests(unittest.TestCase):
    def test_vlm_one_image_never_covers_16_frames(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            models = root / "models" / "visual_analysis_primary"
            models.mkdir(parents=True)
            (models / "config.json").write_text("{}")
            (models / "preprocessor_config.json").write_text("{}")
            (models / "tokenizer.json").write_text("{}")
            header = json.dumps({"w": {"dtype": "F32", "shape": [1], "data_offsets": [0, 4]}}).encode()
            (models / "model.safetensors").write_bytes(len(header).to_bytes(8, "little") + header + b"\0" * 1_000_100)
            video = root / "clip.mp4"
            video.write_bytes(b"mock-video")
            calls = []
            backend = types.ModuleType("mlx_vlm")
            backend.load = lambda _: (types.SimpleNamespace(config={}), object())
            backend.prompt_utils = types.SimpleNamespace(apply_chat_template=lambda *a, **kw: "prompt")
            backend.generate = lambda *a, **kw: calls.append(kw["image"]) or types.SimpleNamespace(text="Duong deo va xe may")

            def fake_decode(cmd, **kwargs):
                Path(cmd[-1]).write_bytes(b"fake-jpeg")
                return types.SimpleNamespace(returncode=0)

            pipeline_adapters._VLM_MODEL_CACHE.clear()
            with mock.patch.dict(sys.modules, {"mlx_vlm": backend}), mock.patch.object(pipeline_adapters.subprocess, "run", fake_decode):
                inspector = S11ModelRegistryAndAdapters(models_root_dir=root / "models").build_offline_visual_window_inspector(video)
                output = inspector(types.SimpleNamespace(window_index=0, intended_frame_ids=list(range(16))))
                self.assertEqual(output["accepted_frame_ids"], [8])
                self.assertEqual(len(calls), 1)
                self.assertEqual(len(calls[0]), 1)
                self.assertTrue(output["has_uncertainty_boundary"])
                backend.generate = lambda *a, **kw: types.SimpleNamespace(text="")
                with self.assertRaises(PipelineAdapterError) as raised:
                    inspector(types.SimpleNamespace(window_index=1, intended_frame_ids=list(range(16))))
                self.assertEqual(raised.exception.code, "INVALID_VLM_OUTPUT")

    def test_public_hmac_signature_cannot_certify_release(self):
        manifest = {
            "schema": "aivideo-signed-field-corpus-manifest-v1",
            "corpus_scope": {"held_out_trips": [{"trip_id": f"fake-{i}", "sha256": "0" * 64} for i in range(5)]},
            "signing_authority": {"algorithm": "sha256-rsa-pss", "key_id": "aivideo-field-qa-signing-key-v1", "signature": ""},
        }
        manifest["signing_authority"]["signature"] = g5_release_audit.compute_field_manifest_signature(manifest)
        result = main.METHODS["g5.eval.e0_e1_accounting"]({
            "runs": [{"outcome": "completed", "total_emitted_claims": 1, "verified_supported_claims": 1} for _ in range(5)],
            "is_synthetic_fixture": False,
            "signed_field_manifest": manifest,
        })
        self.assertFalse(result["live_field_corpus_certified"])
        self.assertFalse(g5_release_audit.validate_signed_field_manifest(manifest))

    def test_release_manifest_rejects_registry_override(self):
        with self.assertRaisesRegex(ValueError, "REGISTRY_OVERRIDE_FORBIDDEN"):
            main.METHODS["g5.release.manifest"]({"registry_path": "/tmp/forged.json"})
        with self.assertRaisesRegex(ValueError, "APP_BINARY_OVERRIDE_FORBIDDEN"):
            main.METHODS["g5.release.manifest"]({"app_binary_path": "/tmp/fake-app"})

    def test_ed25519_trusted_manifest_and_actual_video_hashes(self):
        try:
            from cryptography.hazmat.primitives import serialization
            from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        except ImportError:
            self.skipTest("cryptography not installed")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "contracts").mkdir()
            corpus = root / "corpus"
            corpus.mkdir()
            private = Ed25519PrivateKey.generate()
            public_pem = private.public_key().public_bytes(
                serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
            )
            (root / "contracts" / "field_qa_ed25519_public_key.pem").write_bytes(public_pem)
            trips = []
            for i in range(5):
                content = f"heldout-sample-{i}".encode()
                tid = f"trip-{i}"
                (corpus / f"{tid}.mp4").write_bytes(content)
                trips.append({"trip_id": tid, "sha256": hashlib.sha256(content).hexdigest()})
            payload = {"schema": "aivideo-signed-field-corpus-manifest-v1", "corpus_scope": {"held_out_trips": trips}}
            manifest = dict(payload)
            manifest["signing_authority"] = {
                "algorithm": "ed25519",
                "signature": base64.b64encode(private.sign(g5_release_audit.canon(payload))).decode("ascii"),
            }
            with mock.patch("aivideo_workers.runtime_paths.resolve_s11_registry", return_value=root / "contracts" / "s11_model_registry.lock.json"):
                self.assertTrue(g5_release_audit.validate_signed_field_manifest(manifest, corpus_dir=corpus))
                (corpus / "trip-0.mp4").write_bytes(b"changed")
                self.assertFalse(g5_release_audit.validate_signed_field_manifest(manifest, corpus_dir=corpus))

    def test_untrusted_team_id_rejected_in_release_preflight(self):
        import os
        from tools import check_readiness
        with mock.patch.dict(os.environ, {"AIVIDEO_RELEASE_TEAM_ID": "TEAM999999"}):
            with mock.patch("tools.check_readiness.command") as mock_cmd, \
                 mock.patch("pathlib.Path.is_dir", return_value=True), \
                 mock.patch("pathlib.Path.is_file", return_value=True):
                mock_cmd.side_effect = [
                    (True, "Mach-O 64-bit executable arm64"),
                    (True, "valid on disk"),
                    (True, "Executable=/path/AIVideo\nIdentifier=com.phuthanh.aivideo\nSignature=adhoc\nTeamIdentifier=not set"),
                ]
                bundle = check_readiness.check_app_bundle()
                self.assertFalse(bundle["passed"])
                self.assertIn("Release requires Apple Developer signature", bundle["codesign_detail"])

    def test_forged_hmac_manifest_fails_check_readiness(self):
        from tools import check_readiness
        with tempfile.TemporaryDirectory() as td:
            man_path = Path(td) / "forged_manifest.json"
            manifest = {
                "schema": "aivideo-signed-field-corpus-manifest-v1",
                "corpus_scope": {"held_out_trips": [{"trip_id": f"t{i}", "sha256": "0" * 64} for i in range(5)]},
                "signing_authority": {
                    "algorithm": "hmac-sha256",
                    "key_id": "aivideo-field-qa-signing-key-v1",
                    "signature": g5_release_audit.compute_field_manifest_signature({}),
                },
            }
            man_path.write_text(json.dumps(manifest), encoding="utf-8")
            res = check_readiness.check_field_corpus_and_certification(manifest_path=man_path)
            self.assertFalse(res["live_field_corpus_certified"])
            self.assertEqual(res["certification_status"], "UNVERIFIED_INPUT_REQUIRES_SIGNED_FIELD_CORPUS")

    def test_vfr_rational_boundaries_and_extreme_frame_ranges(self):
        from aivideo_workers.media_indexer import (
            SourceFrameEntry,
            build_vfr_to_cfr24_map,
        )
        from fractions import Fraction
        # High PTS / 64-bit boundary timestamps (e.g. multi-day continuous camera recording)
        base_pts = 2**40
        entries = [
            SourceFrameEntry(frame_id=i, pts=base_pts + i * 3000, duration_pts=3000, time_base_num=1, time_base_den=90000)
            for i in range(30)
        ]
        start_sec = Fraction(base_pts, 90000)
        cmap = build_vfr_to_cfr24_map(
            pts_index=entries,
            source_revision_id="rev-64bit",
            source_start_sec=start_sec,
            timeline_frame_count=24,
        )
        self.assertEqual(len(cmap.mappings), 24)
        self.assertEqual(cmap.mappings[0].source_frame_id, 0)
        # Seeking must work deterministically without precision loss
        fid, pts = cmap.seek_source_from_timeline(0)
        self.assertEqual(fid, 0)
        self.assertEqual(pts, base_pts)


if __name__ == "__main__":
    unittest.main()
