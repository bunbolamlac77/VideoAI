"""Security regression tests for the G2/G5 release gates."""
from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from aivideo_workers.runtime_paths import resolve_s11_registry
from aivideo_workers.pipeline_adapters import (
    PipelineAdapterError,
    S11ModelRegistryAndAdapters,
)
from aivideo_workers.g5_capabilities import (
    evaluate_capability_gate,
    evaluate_photo_moment_match,
    load_capability_registry,
)
from aivideo_workers.g5_release_audit import evaluate_e0_e1_accounting


class TestReadinessSecurity(unittest.TestCase):
    def test_registry_resolution_prefers_app_provided_contracts_dir(self):
        with tempfile.TemporaryDirectory() as td:
            bundle = Path(td)
            source = resolve_s11_registry()
            (bundle / source.name).write_bytes(source.read_bytes())
            with patch.dict(
                os.environ,
                {"AIVIDEO_CONTRACTS_DIR": str(bundle)},
            ):
                self.assertEqual(
                    resolve_s11_registry().parent,
                    bundle.resolve(),
                )
                self.assertIn(
                    "capabilities",
                    load_capability_registry(),
                )
                registry = S11ModelRegistryAndAdapters()
                self.assertEqual(
                    registry.registry_path,
                    (bundle / source.name).resolve(),
                )

    def test_fake_e0_e1_rows_never_certify_field_corpus(self):
        runs = [
            {
                "trip_id": f"trip-{i}",
                "outcome": "completed",
                "total_emitted_claims": 0,
                "verified_supported_claims": 0,
            }
            for i in range(10)
        ]
        report = evaluate_e0_e1_accounting({
            "runs": runs,
            "corpus_kind": "E1_10_WORKDAYS",
            "is_synthetic_fixture": False,
        })
        self.assertFalse(
            report["live_field_corpus_certified"]
        )
        self.assertEqual(
            report["certification_status"],
            "UNVERIFIED_INPUT_REQUIRES_SIGNED_FIELD_CORPUS",
        )
        self.assertIsNone(
            report["fact_precision"]
        )

    def test_fake_safetensors_do_not_create_neural_observations(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            fake_video = root / "source.mp4"
            fake_video.write_bytes(
                b"test input path, no decode should run"
            )
            vis_dir = root / "models" / "visual_analysis_primary"
            vis_dir.mkdir(parents=True)
            (vis_dir / "config.json").write_text(
                json.dumps({"model_type": "qwen3_vl", "_name_or_path": "Qwen3-VL-4B-Instruct-4bit"}),
                encoding="utf-8",
            )
            (vis_dir / "model.safetensors").write_bytes(b"SAFETENSORS_FAKE_STUB")
            reg = S11ModelRegistryAndAdapters(models_root_dir=root / "models")
            with self.assertRaises(PipelineAdapterError) as ctx:
                reg.build_offline_visual_window_inspector(fake_video)
            self.assertIn(
                ctx.exception.code,
                ("INVALID_MODEL_WEIGHTS", "ADAPTER_NOT_INSTALLED", "FAKE_WEIGHTS_REJECTED"),
            )

    def test_capability_gate_rpc_cannot_enable_disabled_feature(self):
        gate = evaluate_capability_gate(
            "exact_photo_shutter_match",
            benchmark_evidence={
                "passed_all_thresholds": True,
                "held_out_sample_size": 999,
                "zero_leakage_verified": True,
            },
        )
        self.assertEqual(gate["declared_status"], "disabled")
        self.assertEqual(gate["effective_status"], "disabled")
        self.assertFalse(gate["production_claim_allowed"])

        photo_match = evaluate_photo_moment_match({
            "photo_id": "PHOTO_01",
            "shot_id": "SHOT_01",
            "embedding_cosine": 0.99,
            "temporal_consistent": True,
            "geometric_inlier_ratio": 0.95,
            "requested_use_mode": "exact",
            "benchmark_evidence": {
                "passed_all_thresholds": True,
                "held_out_sample_size": 999,
                "zero_leakage_verified": True,
            },
        })
        self.assertEqual(photo_match["use_mode"], "illustrative_only")
        self.assertIn("blocked_by_capability_gate", photo_match["decision_reason"])


if __name__ == "__main__":
    unittest.main()
