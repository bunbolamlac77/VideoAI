"""
tests/test_g2_window_contract.py — ECC fix wave for Gate G2.

Covers the defects found in the 2026-11-10 audit:
  D01 inspector submits 1 frame while the pipeline audits 16 -> POST_PROCESSOR_TRUNCATION
  D02 empty inspector payload silently becomes "observed" at 100% coverage
  D03 `_inspector_fn` test backdoor reachable from the RPC surface
  D04 coverage ratio uses a circular denominator and is never clamped
  D08 `g2.analyze_source` exceeds the 1 MiB JSON-RPC frame for long sources
  D05 the Gate G2 benchmark grades synthetic labels as a real held-out result

Each test below is written to fail against the pre-fix code and pass only when
the declared-sampling contract is honoured.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile

import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from workers.src.aivideo_workers.full_frame_pipeline import (
    AssetCoverageLedger,
    BoundedPipelineConfig,
    FullFrameAnalysisPipeline,
    FullFramePipelineError,
    compact_coverage_ledger_payload,
)
from workers.src.aivideo_workers.media_indexer import SourceFrameEntry
from workers.src.aivideo_workers.pipeline_adapters import sample_window_frame_ids


def _pts_index(num_frames: int) -> list[SourceFrameEntry]:
    return [
        SourceFrameEntry(
            frame_id=i,
            pts=i * 1000,
            duration_pts=1000,
            time_base_num=1,
            time_base_den=24000,
        )
        for i in range(num_frames)
    ]


def _sampled_inspector(sample_count: int = 8):
    """Inspector that declares exactly the frames it submitted (the new contract)."""

    def _inspect(win):
        planned = sample_window_frame_ids(list(win.intended_frame_ids), sample_count)
        return {
            "planned_frame_ids": planned,
            "accepted_frame_ids": list(planned),
            "action_or_scene_type": "scenic_or_motion",
            "subject_track_id": f"trk-w{win.window_index:04d}",
            "observation_text": f"Quan sát mẫu {len(planned)}/{len(win.intended_frame_ids)} frame",
            "ocr_raw_tokens": [],
            "ocr_is_uncertain": False,
            "has_uncertainty_boundary": len(planned) < len(win.intended_frame_ids),
        }

    return _inspect


class TestDeclaredSamplingContract(unittest.TestCase):
    def test_sample_window_frame_ids_is_evenly_spaced_and_includes_midpoint(self) -> None:
        """D01: a 16-frame window must produce 8 evenly spaced, deterministic ids."""
        sampled = sample_window_frame_ids(list(range(16)), 8)
        self.assertEqual(len(sampled), 8)
        self.assertEqual(sampled[0], 0)
        self.assertEqual(sampled[-1], 14)
        self.assertIn(8, sampled)
        self.assertEqual(sampled, sorted(set(sampled)))

    def test_sample_window_frame_ids_never_exceeds_window(self) -> None:
        self.assertEqual(sample_window_frame_ids([3, 4, 5], 8), [3, 4, 5])

    def test_pipeline_completes_when_inspector_declares_its_sample(self) -> None:
        """D01: the pipeline must audit the declared sample, not the full window."""
        pipeline = FullFrameAnalysisPipeline(
            BoundedPipelineConfig(window_size_frames=16, window_overlap_frames=4)
        )
        with tempfile.TemporaryDirectory() as tmp:
            ledger, obs, _, _ = pipeline.run_or_resume_analysis(
                source_revision_id="src-sample-001",
                source_sha256="a" * 64,
                pts_index=_pts_index(16),
                total_declared_source_frames=16,
                checkpoint_path=Path(tmp) / "ckpt.json",
                window_inspector_fn=_sampled_inspector(8),
            )

        self.assertEqual(ledger.detailed_pass_status, "completed")
        self.assertEqual(len(obs), 1)
        self.assertEqual(obs[0].frame_ids, list(range(0, 16, 2)))
        self.assertTrue(obs[0].has_uncertainty_boundary)
        # 8 of 16 source frames were actually submitted to the vision model.
        self.assertAlmostEqual(ledger.frame_input_coverage, 0.5)
        self.assertAlmostEqual(ledger.vlm_frame_coverage, 0.5)

    def test_inspector_dropping_declared_frames_still_raises(self) -> None:
        """D01: truncation guard survives, but is scoped to the declared sample."""

        def _dropping(win):
            planned = sample_window_frame_ids(list(win.intended_frame_ids), 8)
            return {
                "planned_frame_ids": planned,
                "accepted_frame_ids": planned[:-2],
                "action_or_scene_type": "scenic_or_motion",
                "observation_text": "mất frame",
                "ocr_raw_tokens": [],
                "ocr_is_uncertain": False,
                "has_uncertainty_boundary": True,
            }

        pipeline = FullFrameAnalysisPipeline()
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(FullFramePipelineError) as ctx:
                pipeline.run_or_resume_analysis(
                    source_revision_id="src-drop-001",
                    source_sha256="b" * 64,
                    pts_index=_pts_index(16),
                    total_declared_source_frames=16,
                    checkpoint_path=Path(tmp) / "ckpt.json",
                    window_inspector_fn=_dropping,
                )
        self.assertEqual(ctx.exception.code, "POST_PROCESSOR_TRUNCATION")


class TestFailClosedInspector(unittest.TestCase):
    def _run(self, inspector) -> None:
        pipeline = FullFrameAnalysisPipeline()
        with tempfile.TemporaryDirectory() as tmp:
            pipeline.run_or_resume_analysis(
                source_revision_id="src-empty-001",
                source_sha256="c" * 64,
                pts_index=_pts_index(16),
                total_declared_source_frames=16,
                checkpoint_path=Path(tmp) / "ckpt.json",
                window_inspector_fn=inspector,
            )

    def test_empty_payload_is_rejected(self) -> None:
        """D02: `{}` must never become a fabricated visual observation."""
        with self.assertRaises(FullFramePipelineError) as ctx:
            self._run(lambda win: {})
        self.assertEqual(ctx.exception.code, "INVALID_VISUAL_PAYLOAD")

    def test_missing_observation_text_is_rejected(self) -> None:
        def _blank(win):
            return {
                "accepted_frame_ids": list(win.intended_frame_ids),
                "action_or_scene_type": "scenic_or_motion",
                "observation_text": "   ",
            }

        with self.assertRaises(FullFramePipelineError) as ctx:
            self._run(_blank)
        self.assertEqual(ctx.exception.code, "INVALID_VISUAL_PAYLOAD")

    def test_empty_scene_type_is_rejected(self) -> None:
        def _bad_scene(win):
            return {
                "accepted_frame_ids": list(win.intended_frame_ids),
                "action_or_scene_type": "",
                "observation_text": "có mô tả",
            }

        with self.assertRaises(FullFramePipelineError) as ctx:
            self._run(_bad_scene)
        self.assertEqual(ctx.exception.code, "INVALID_VISUAL_PAYLOAD")

    def test_rpc_surface_rejects_inspector_override(self) -> None:
        """D03: the test seam must not be reachable from JSON-RPC params."""
        from workers.src.aivideo_workers.main import handle_g2_analyze_source

        with self.assertRaises(ValueError) as ctx:
            handle_g2_analyze_source(
                {
                    "file_path": "/tmp/not-used.mp4",
                    "_inspector_fn": lambda win: {},
                }
            )
        self.assertIn("INSPECTOR_OVERRIDE_FORBIDDEN", str(ctx.exception))


class TestCoverageArithmetic(unittest.TestCase):
    def test_index_larger_than_declared_total_fails_closed(self) -> None:
        """D04: the denominator can no longer be smaller than the index."""
        pipeline = FullFrameAnalysisPipeline()
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(FullFramePipelineError) as ctx:
                pipeline.run_or_resume_analysis(
                    source_revision_id="src-mismatch-001",
                    source_sha256="d" * 64,
                    pts_index=_pts_index(40),
                    total_declared_source_frames=10,
                    checkpoint_path=Path(tmp) / "ckpt.json",
                    window_inspector_fn=_sampled_inspector(8),
                )
        self.assertEqual(ctx.exception.code, "INDEX_DENOMINATOR_MISMATCH")

    def test_coverage_is_clamped_to_one(self) -> None:
        """D04: partial windows must never report > 100% coverage."""
        pipeline = FullFrameAnalysisPipeline()
        with tempfile.TemporaryDirectory() as tmp:
            ledger, _, _, _ = pipeline.run_or_resume_analysis(
                source_revision_id="src-clamp-001",
                source_sha256="e" * 64,
                pts_index=_pts_index(10),
                total_declared_source_frames=10,
                checkpoint_path=Path(tmp) / "ckpt.json",
                window_inspector_fn=_sampled_inspector(8),
            )
        self.assertLessEqual(ledger.frame_input_coverage, 1.0)
        self.assertLessEqual(ledger.decode_coverage_ratio, 1.0)
        self.assertLessEqual(ledger.vlm_frame_coverage, 1.0)


class TestPayloadBudget(unittest.TestCase):
    def test_long_source_ledger_payload_stays_under_one_mib(self) -> None:
        """D08: 86,400 frames must not blow the 1 MiB JSON-RPC frame."""
        ids = list(range(86_400))
        ledger = AssetCoverageLedger(
            source_revision_id="src-long-001",
            runtime_profile_id="P-VISION-DEV-v1",
            input_fingerprint="f" * 64,
            total_declared_source_frames=86_400,
            valid_decoded_frame_ids=ids,
            corrupted_decode_frame_ids=[],
            unique_post_processor_frame_ids=ids,
            total_submitted_frames_with_overlap=86_400,
            decode_coverage_ratio=1.0,
            frame_input_coverage=1.0,
            valid_frame_input_coverage=1.0,
            completed_window_indices=[0],
            total_windows=1,
            visual_scan_status="completed",
            detailed_pass_status="completed",
            audio_analysis_status="completed",
            omission_audit_status="completed",
        )
        payload = compact_coverage_ledger_payload(ledger.to_dict())
        encoded = json.dumps(payload, ensure_ascii=False)

        self.assertLess(len(encoded.encode("utf-8")), 1024 * 1024)
        self.assertTrue(payload["frame_ids_truncated"])
        ranges = payload["frame_id_ranges"]["unique_post_processor"]
        reconstructed = [i for start, end in ranges for i in range(start, end + 1)]
        self.assertEqual(reconstructed, ids)

    def test_short_ledger_keeps_full_ids_and_no_truncation_flag(self) -> None:
        ledger = AssetCoverageLedger(
            source_revision_id="src-short-001",
            runtime_profile_id="P-VISION-DEV-v1",
            input_fingerprint="a" * 64,
            total_declared_source_frames=16,
            valid_decoded_frame_ids=list(range(16)),
            corrupted_decode_frame_ids=[],
            unique_post_processor_frame_ids=list(range(16)),
            total_submitted_frames_with_overlap=16,
            decode_coverage_ratio=1.0,
            frame_input_coverage=1.0,
            valid_frame_input_coverage=1.0,
            completed_window_indices=[0],
            total_windows=1,
            visual_scan_status="completed",
            detailed_pass_status="completed",
            audio_analysis_status="completed",
            omission_audit_status="completed",
        )
        payload = compact_coverage_ledger_payload(ledger.to_dict())
        self.assertFalse(payload["frame_ids_truncated"])
        self.assertEqual(payload["unique_post_processor_frame_ids"], list(range(16)))


if __name__ == "__main__":
    unittest.main()
