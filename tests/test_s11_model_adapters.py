"""
tests/test_s11_model_adapters.py — Unit & Integration Tests for Gate G2 S11 Model Adapters,
Offline Preflight, Post-Processor Coverage Audit, 16GB Hardware Policy & Vietnamese Output Validation.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from workers.src.aivideo_workers.pipeline_adapters import (
    PipelineAdapterError,
    S11ModelRegistryAndAdapters,
    audit_vision_processor_coverage,
    compute_multi_window_unique_coverage,
    measure_current_process_memory,
    validate_model_policy_on_16gb,
)


def _make_valid_wav_bytes(sample_rate: int = 48000, duration_sec: float = 0.5) -> bytes:
    num_samples = int(sample_rate * duration_sec)
    pcm_data = b"\x10\x00" * num_samples
    byte_rate = sample_rate * 2
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + len(pcm_data),
        b"WAVE",
        b"fmt ",
        16,
        1,
        1,
        sample_rate,
        byte_rate,
        2,
        16,
        b"data",
        len(pcm_data),
    )
    return header + pcm_data


class TestS11ModelAdapters(unittest.TestCase):
    def test_s11_t1_offline_preflight_and_missing_artifact_rejection(self) -> None:
        """S11.T1: Offline check for E0 adapters (Qwen-VL, Whisper, Kokoro-Vietnamese TTS, DINOv2); missing artifacts raise specific errors without cloud fallback."""
        with tempfile.TemporaryDirectory() as tmpdir:
            models_root = Path(tmpdir)
            adapters = S11ModelRegistryAndAdapters(models_root_dir=models_root)

            # 1) Uninstalled adapter role raises ADAPTER_NOT_INSTALLED
            for role in ("qwen3_vl_4b", "whisper_large_v3", "tts_kokoro_vi", "dinov2_base"):
                with self.assertRaises(PipelineAdapterError) as ctx:
                    adapters.preflight_adapter_offline(role, ["config.json", "model.safetensors"])
                self.assertEqual(ctx.exception.code, "ADAPTER_NOT_INSTALLED")
                self.assertTrue(ctx.exception.details.get("offline_enforced"))

            # 2) Partially installed adapter raises MISSING_ADAPTER_ARTIFACTS
            vlm_dir = models_root / "qwen3_vl_4b"
            vlm_dir.mkdir(parents=True)
            cfg_bytes = b'{"model_type": "qwen3_vl"}'
            (vlm_dir / "config.json").write_bytes(cfg_bytes)

            with self.assertRaises(PipelineAdapterError) as ctx_miss:
                adapters.preflight_adapter_offline(
                    "qwen3_vl_4b",
                    ["config.json", "model.safetensors", "preprocessor_config.json"],
                )
            self.assertEqual(ctx_miss.exception.code, "MISSING_ADAPTER_ARTIFACTS")
            self.assertEqual(
                ctx_miss.exception.details["missing_files"],
                ["model.safetensors", "preprocessor_config.json"],
            )

            # 3) Complete local artifacts with verified SHA-256 pass offline preflight
            weights_bytes = b"fake_safetensors_weights"
            preproc_bytes = b'{"size": 589824}'
            (vlm_dir / "model.safetensors").write_bytes(weights_bytes)
            (vlm_dir / "preprocessor_config.json").write_bytes(preproc_bytes)

            res = adapters.preflight_adapter_offline(
                "qwen3_vl_4b",
                ["config.json", "model.safetensors", "preprocessor_config.json"],
                expected_sha256_map={
                    "config.json": hashlib.sha256(cfg_bytes).hexdigest(),
                    "model.safetensors": hashlib.sha256(weights_bytes).hexdigest(),
                },
            )
            self.assertEqual(res["status"], "verified_local_offline")

    def test_s11_t2_post_processor_frame_truncation_and_overlap_union_audit(self) -> None:
        """S11.T2: Backend frame truncation/subsampling is caught by post-processor audit; overlap does not inflate coverage."""
        # Intended 16 frames [0..15], but processor truncated to 8 even frames
        intended = list(range(16))
        subsampled = [0, 2, 4, 6, 8, 10, 12, 14]
        audit_trunc = audit_vision_processor_coverage(
            runtime_profile_id="P-VISION-DEV-v1",
            intended_frame_ids=intended,
            processor_accepted_frame_ids=subsampled,
            temporal_patch_size=2,
            input_width=3840,
            input_height=2160,
            pixel_budget=589824,
        )
        self.assertTrue(audit_trunc.truncation_detected)
        self.assertFalse(audit_trunc.is_full_window_covered)
        self.assertEqual(audit_trunc.coverage_ratio, 0.5)
        self.assertEqual(audit_trunc.dropped_or_truncated_frame_ids, [1, 3, 5, 7, 9, 11, 13, 15])
        self.assertLessEqual(audit_trunc.post_processor_pixel_count, 589824)

        # Full coverage across two overlapping windows: [0..7] and [6..13] (overlap frames 6, 7)
        win1 = audit_vision_processor_coverage("P-VISION-DEV-v1", list(range(0, 8)), list(range(0, 8)), 2, 1920, 1080, 589824)
        win2 = audit_vision_processor_coverage("P-VISION-DEV-v1", list(range(6, 14)), list(range(6, 14)), 2, 1920, 1080, 589824)
        union_cov = compute_multi_window_unique_coverage(list(range(0, 14)), [win1, win2])
        self.assertEqual(union_cov["total_submitted_with_overlap"], 16)
        self.assertEqual(union_cov["covered_unique_frames"], 14)
        self.assertEqual(union_cov["coverage_ratio"], 1.0)
        self.assertTrue(union_cov["is_complete_coverage"])

    def test_s11_t3_memory_trace_and_16gb_32b_ban(self) -> None:
        """S11.T3 & S11.4: Real process memory trace is recorded across phases and 32B models are blocked on 16 GB RAM."""
        trace = measure_current_process_memory("S11_AI_Vision_Probe")
        self.assertGreater(trace.rss_bytes, 0)
        self.assertTrue(trace.within_budget)

        # 4B and 8B 4-bit candidates are allowed
        validate_model_policy_on_16gb("mlx-community/Qwen3-VL-4B-Instruct-4bit")
        validate_model_policy_on_16gb("mlx-community/Qwen3-8B-4bit")

        # 32B or FLUX models are strictly forbidden on 16 GB hardware
        with self.assertRaises(PipelineAdapterError) as ctx:
            validate_model_policy_on_16gb("mlx-community/Qwen2.5-VL-32B-Instruct-4bit")
        self.assertEqual(ctx.exception.code, "FORBIDDEN_MODEL_ON_16GB")

    def test_s11_t4_structured_json_vietnamese_and_tts_validation(self) -> None:
        """S11.T4: Invalid JSON schema, corrupted Vietnamese encoding, or sped-up TTS is rejected."""
        adapters = S11ModelRegistryAndAdapters()

        # Valid Vietnamese observation JSON
        valid_json = json.dumps(
            {
                "observation_text": "Người lái xe dừng trước biển báo đường cụt tại đèo Prenn.",
                "frame_ids": [10, 11, 12],
                "origin": "visual_model",
                "epistemic_status": "observed",
            },
            ensure_ascii=False,
        )
        parsed = adapters.validate_structured_observation_or_claim_output(valid_json)
        self.assertEqual(parsed["origin"], "visual_model")

        # Reject corrupted Vietnamese replacement character U+FFFD
        corrupted_json = json.dumps(
            {
                "observation_text": "Biển báo đư\ufffdng cụt",
                "frame_ids": [10],
                "origin": "visual_model",
                "epistemic_status": "observed",
            }
        )
        with self.assertRaises(PipelineAdapterError) as ctx_utf:
            adapters.validate_structured_observation_or_claim_output(corrupted_json)
        self.assertEqual(ctx_utf.exception.code, "CORRUPTED_VIETNAMESE_TEXT")

        # Reject model impersonating 'user' origin
        impersonate_json = json.dumps(
            {
                "observation_text": "Tôi đi lúc 3 giờ sáng",
                "frame_ids": [1],
                "origin": "user",
                "epistemic_status": "reported",
            }
        )
        with self.assertRaises(PipelineAdapterError) as ctx_orig:
            adapters.validate_structured_observation_or_claim_output(impersonate_json)
        self.assertEqual(ctx_orig.exception.code, "INVALID_MODEL_ORIGIN")

        # TTS validation: 1.0x speed valid WAV passes, 1.25x silent speed-up is rejected
        wav_bytes = _make_valid_wav_bytes(48000, 0.5)
        tts_ok = adapters.validate_vieneu_tts_wav_output(
            "Hôm nay trời mưa lúc 6h.",
            "Hôm nay trời mưa lúc sáu giờ.",
            wav_bytes,
            sample_rate_hz=48000,
            speed=1.0,
        )
        self.assertAlmostEqual(tts_ok["duration_sec"], 0.5, places=2)

        with self.assertRaises(PipelineAdapterError) as ctx_spd:
            adapters.validate_vieneu_tts_wav_output(
                "Hôm nay trời mưa.",
                "Hôm nay trời mưa.",
                wav_bytes,
                sample_rate_hz=48000,
                speed=1.2,
            )
        self.assertEqual(ctx_spd.exception.code, "INVALID_TTS_SPEED")

        # Capability registry & DINOv2 invariant check
        sed_cap = adapters.get_capability("sound_event_detection_sed")
        self.assertEqual(sed_cap.status, "disabled")
        dinov2_res = adapters.evaluate_dinov2_shot_candidates("photo-rev-1", [("shot-A", 0.94), ("shot-B", 0.81)])
        self.assertFalse(dinov2_res["candidates"][0]["auto_confirmed_same_event"])
        self.assertEqual(dinov2_res["candidates"][0]["allowed_use_without_geometric_gate"], "illustrative_only")


if __name__ == "__main__":
    unittest.main()
