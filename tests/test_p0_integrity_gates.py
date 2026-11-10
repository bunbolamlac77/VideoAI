"""Adversarial regression for false AI provenance and forged G5 release certificates."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from aivideo_workers import main
from aivideo_workers.g5_capabilities import load_capability_registry
from aivideo_workers.g5_release_audit import (
    compute_field_manifest_signature,
    evaluate_e0_e1_accounting,
    validate_signed_field_manifest,
)
from aivideo_workers.pipeline_adapters import PipelineAdapterError, S11ModelRegistryAndAdapters
from tools.check_readiness import check_field_corpus_and_certification


class P0IntegrityTests(unittest.TestCase):
    def test_capability_registry_override_rejected_through_rpc(self):
        registry = load_capability_registry()
        registry["capabilities"]["exact_photo_shutter_match"]["status"] = "enabled"
        with tempfile.TemporaryDirectory() as td:
            malicious = Path(td) / "registry.json"
            malicious.write_text(json.dumps(registry), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "REGISTRY_OVERRIDE_FORBIDDEN"):
                main.METHODS["g5.capability.evaluate"]({
                    "capability_id": "exact_photo_shutter_match",
                    "registry_path": str(malicious),
                })
            with self.assertRaisesRegex(ValueError, "REGISTRY_OVERRIDE_FORBIDDEN"):
                main.METHODS["g5.photo.match"]({
                    "photo_id": "1", "shot_id": "1", "registry_path": str(malicious)
                })
        ordinary = main.METHODS["g5.capability.evaluate"]({
            "capability_id": "exact_photo_shutter_match"
        })
        self.assertFalse(ordinary["production_claim_allowed"])

    def test_self_attested_corpus_cannot_certify(self):
        records = [
            {"trip_id": f"t{i}", "outcome": "completed", "total_emitted_claims": 1,
             "verified_supported_claims": 1}
            for i in range(5)
        ]
        value = evaluate_e0_e1_accounting({
            "is_synthetic_fixture": False,
            "corpus_kind": "E0_5_HELD_OUT_TRIPS",
            "runs": records,
            "signed_field_manifest": {"bogus": "unverified"},
        })
        self.assertFalse(value["live_field_corpus_certified"])
        self.assertNotEqual(value["certification_status"], "CERTIFIED_FIELD_CORPUS")

    def test_manifest_presence_alone_cannot_certify(self):
        self.assertFalse(check_field_corpus_and_certification()["live_field_corpus_certified"])

    def test_safetensors_presence_does_not_fake_visual_model(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            video = root / "video.mp4"
            video.write_bytes(b"fixture")
            weights_dir = root / "models" / "visual_analysis_primary"
            weights_dir.mkdir(parents=True)
            (weights_dir / "config.json").write_text('{"model_type":"qwen3_vl"}')
            header = json.dumps({
                "fake_tensor": {"dtype": "F32", "shape": [262144],
                                "data_offsets": [0, 1048576]}
            }).encode("utf-8")
            with (weights_dir / "model.safetensors").open("wb") as f:
                f.write(len(header).to_bytes(8, "little"))
                f.write(header)
                f.write(b"\x00" * 1048576)
            adapter = S11ModelRegistryAndAdapters(models_root_dir=root / "models")
            with self.assertRaises(PipelineAdapterError) as ctx:
                adapter.build_offline_visual_window_inspector(video)
            self.assertEqual(ctx.exception.code, "VLM_INFERENCE_BACKEND_NOT_CONNECTED")

    def test_tampered_manifest_signature_fails_verification(self):
        valid_manifest = {
            "schema": "aivideo-signed-field-corpus-manifest-v1",
            "corpus_scope": {
                "held_out_trips": [
                    {"trip_id": f"t{i}", "sha256": "0" * 64} for i in range(5)
                ]
            },
            "signing_authority": {
                "key_id": "aivideo-field-qa-signing-key-v1",
                "algorithm": "hmac-sha256",
                "signature": "bad_signature_" * 4,
            },
        }
        self.assertFalse(validate_signed_field_manifest(valid_manifest, enforce_signature=True))

    def test_tampered_video_hash_fails_verification(self):
        with tempfile.TemporaryDirectory() as td:
            cdir = Path(td)
            trips = []
            for i in range(5):
                vfile = cdir / f"t{i}.mp4"
                vfile.write_bytes(f"video_bytes_{i}".encode("utf-8"))
                trips.append({"trip_id": f"t{i}", "sha256": "1" * 64})  # Incorrect hash
            manifest = {
                "schema": "aivideo-signed-field-corpus-manifest-v1",
                "corpus_scope": {"held_out_trips": trips},
                "signing_authority": {
                    "key_id": "aivideo-field-qa-signing-key-v1",
                    "algorithm": "hmac-sha256",
                    "signature": "",
                },
            }
            manifest["signing_authority"]["signature"] = compute_field_manifest_signature(manifest)
            self.assertFalse(validate_signed_field_manifest(manifest, corpus_dir=cdir, enforce_signature=True))

    def test_forged_hmac_manifest_strictly_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            cdir = Path(td)
            trips = [{"trip_id": f"t{i}", "sha256": "0" * 64} for i in range(5)]
            manifest = {
                "schema": "aivideo-signed-field-corpus-manifest-v1",
                "corpus_scope": {"held_out_trips": trips},
                "signing_authority": {
                    "key_id": "aivideo-field-qa-signing-key-v1",
                    "algorithm": "hmac-sha256",
                    "signature": "fake",
                },
            }
            manifest["signing_authority"]["signature"] = compute_field_manifest_signature(manifest)
            # Even with mathematically correct HMAC signature, it must be rejected!
            self.assertFalse(validate_signed_field_manifest(manifest, corpus_dir=cdir, enforce_signature=True))

    def test_validly_signed_field_manifest_passes_verification(self):
        try:
            from cryptography.hazmat.primitives.asymmetric import ed25519
            from cryptography.hazmat.primitives import serialization
        except ImportError:
            self.skipTest("cryptography not installed in current Python environment")

        with tempfile.TemporaryDirectory() as td:
            cdir = Path(td)
            import hashlib
            from unittest import mock
            import base64
            from aivideo_workers.g5_release_audit import canon

            trips = []
            for i in range(5):
                vfile = cdir / f"t{i}.mp4"
                data = f"genuine_field_video_{i}".encode("utf-8")
                vfile.write_bytes(data)
                h = hashlib.sha256(data).hexdigest()
                trips.append({"trip_id": f"t{i}", "sha256": h})

            manifest = {
                "schema": "aivideo-signed-field-corpus-manifest-v1",
                "corpus_scope": {"held_out_trips": trips},
                "signing_authority": {
                    "key_id": "field_qa_ed25519_public_key.pem",
                    "algorithm": "ed25519",
                    "signature": "",
                },
            }

            priv_key = ed25519.Ed25519PrivateKey.generate()
            pub_key = priv_key.public_key()
            pub_pem = pub_key.public_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PublicFormat.SubjectPublicKeyInfo,
            )
            key_path = cdir / "field_qa_ed25519_public_key.pem"
            key_path.write_bytes(pub_pem)
            pin = hashlib.sha256(pub_pem).hexdigest()
            manifest["signing_authority"]["key_id"] = "aivideo-field-qa-v1"

            payload = {k: v for k, v in manifest.items() if k != "signing_authority"}
            sig_bytes = priv_key.sign(canon(payload))
            manifest["signing_authority"]["signature"] = base64.b64encode(sig_bytes).decode("ascii")

            from aivideo_workers import g5_release_audit as audit
            with mock.patch.object(audit, "_QA_PUBLIC_KEY_PATH", key_path), \
                 mock.patch.object(audit, "PINNED_FIELD_QA_KEY_SHA256", pin):
                self.assertTrue(validate_signed_field_manifest(manifest, corpus_dir=cdir, enforce_signature=True))

            # No pinned anchor -> certification unavailable (production default).
            with mock.patch.object(audit, "_QA_PUBLIC_KEY_PATH", key_path), \
                 mock.patch.object(audit, "PINNED_FIELD_QA_KEY_SHA256", ""):
                self.assertFalse(validate_signed_field_manifest(manifest, corpus_dir=cdir, enforce_signature=True))

            # A substituted but valid key must not certify.
            other_pem = ed25519.Ed25519PrivateKey.generate().public_key().public_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PublicFormat.SubjectPublicKeyInfo,
            )
            key_path.write_bytes(other_pem)
            with mock.patch.object(audit, "_QA_PUBLIC_KEY_PATH", key_path), \
                 mock.patch.object(audit, "PINNED_FIELD_QA_KEY_SHA256", pin):
                self.assertFalse(validate_signed_field_manifest(manifest, corpus_dir=cdir, enforce_signature=True))


if __name__ == "__main__":
    unittest.main()
