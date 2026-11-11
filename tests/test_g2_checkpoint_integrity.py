"""
tests/test_g2_checkpoint_integrity.py — Regression for audit P0-01 (2026-11-11).

The 2026-11-11 review found a complete fabrication path on the JSON-RPC surface:

  * `g2.analyze_source` accepted `checkpoint_dir` from the caller
    (`main_g2.py:470`) and resumed `raw_observations` verbatim from any JSON file
    found there (`full_frame_pipeline.py:542-558`). Any client that knew the
    source content hash could pre-write a checkpoint containing
    `origin="visual_model"` observations and receive them back as model output
    without the model ever running, and without decoding a single frame.
  * The checkpoint carried no provenance, so observations produced by a *different*
    inspector (or by no inspector at all) could be donated to a new run whenever
    the window list happened to be fully committed.

Every test below fails against the pre-fix code and passes with the fix.
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
    BoundedPipelineConfig,
    FullFrameAnalysisPipeline,
    FullFramePipelineError,
    compute_pipeline_input_fingerprint,
)
from workers.src.aivideo_workers.media_indexer import SourceFrameEntry

REVISION_ID = "00000000-0000-4000-8000-000000007701"
SOURCE_SHA = "a" * 64


def _pts_index(frame_count: int) -> list[SourceFrameEntry]:
    return [
        SourceFrameEntry(
            frame_id=i,
            pts=i * 512,
            duration_pts=512,
            time_base_num=1,
            time_base_den=12288,
            key_frame=i == 0,
        )
        for i in range(frame_count)
    ]


def _stub_inspector(win) -> dict:
    planned = list(win.intended_frame_ids)[:2]
    return {
        "planned_frame_ids": planned,
        "accepted_frame_ids": planned,
        "observation_text": "a real model observation",
        "action_or_scene_type": "steady_visual_scene",
    }


def _provenance() -> dict:
    return {"inspector": "test_seam", "profile": BoundedPipelineConfig().runtime_profile_id}


def _write_forged_checkpoint(path: Path, frame_count: int) -> None:
    fingerprint = compute_pipeline_input_fingerprint(
        source_revision_id=REVISION_ID,
        source_sha256=SOURCE_SHA,
        runtime_profile_id=BoundedPipelineConfig().runtime_profile_id,
        window_size=BoundedPipelineConfig().window_size_frames,
        overlap=BoundedPipelineConfig().window_overlap_frames,
        total_declared_frames=frame_count,
    )
    path.write_text(
        json.dumps(
            {
                "source_revision_id": REVISION_ID,
                "input_fingerprint": fingerprint,
                "committed_windows": [
                    {
                        "window_index": 0,
                        "planned_frame_ids": [0, 1],
                        "actual_processed_frame_ids": [0, 1],
                        "post_processor_audit": {},
                    }
                ],
                "skipped_windows": [],
                "raw_observations": [
                    {
                        "observation_id": "obs-forged-0000",
                        "source_revision_id": REVISION_ID,
                        "window_index": 0,
                        "pass_role": "raw_independent",
                        "origin": "visual_model",
                        "epistemic_status": "observed",
                        "frame_ids": [0, 1],
                        "start_pts_ticks": 0,
                        "end_pts_ticks": 512 * frame_count,
                        "time_base_num": 1,
                        "time_base_den": 12288,
                        "action_or_scene_type": "scenic_or_motion",
                        "subject_track_id": None,
                        "observation_text": "CẢNH BỊA DO CALLER VIẾT",
                        "ocr_raw_tokens": [],
                        "ocr_is_uncertain": False,
                        "has_uncertainty_boundary": False,
                        "guided_hypothesis_ref": None,
                    }
                ],
            }
        ),
        encoding="utf-8",
    )


class TestRpcCheckpointSurface(unittest.TestCase):
    def test_rpc_rejects_caller_supplied_checkpoint_dir(self) -> None:
        """P0-01: `checkpoint_dir` must not exist on the RPC surface at all."""
        from workers.src.aivideo_workers.main import handle_g2_analyze_source

        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "caller-chosen"
            with self.assertRaises(ValueError) as ctx:
                handle_g2_analyze_source(
                    {
                        "file_path": "/tmp/not-used.mp4",
                        "checkpoint_dir": str(target),
                    }
                )
        self.assertIn("CHECKPOINT_DIR_FORBIDDEN", str(ctx.exception))
        self.assertFalse(target.exists(), "rejected request must not create the directory")


class TestCheckpointProvenance(unittest.TestCase):
    def test_resume_without_inspector_is_refused(self) -> None:
        """P0-01: a run with no inspector may never replay checkpoint observations."""
        pipeline = FullFrameAnalysisPipeline()
        with tempfile.TemporaryDirectory() as tmp:
            ckpt = Path(tmp) / "ckpt.json"
            _write_forged_checkpoint(ckpt, frame_count=16)
            with self.assertRaises(FullFramePipelineError) as ctx:
                pipeline.run_or_resume_analysis(
                    source_revision_id=REVISION_ID,
                    source_sha256=SOURCE_SHA,
                    pts_index=_pts_index(16),
                    total_declared_source_frames=16,
                    checkpoint_path=ckpt,
                    window_inspector_fn=None,
                )
        self.assertEqual(ctx.exception.code, "CHECKPOINT_RESUME_WITHOUT_INSPECTOR")

    def test_checkpoint_without_provenance_is_refused(self) -> None:
        """P0-01: checkpoints written by a run that recorded no provenance are foreign."""
        pipeline = FullFrameAnalysisPipeline()
        with tempfile.TemporaryDirectory() as tmp:
            ckpt = Path(tmp) / "ckpt.json"
            _write_forged_checkpoint(ckpt, frame_count=16)
            with self.assertRaises(FullFramePipelineError) as ctx:
                pipeline.run_or_resume_analysis(
                    source_revision_id=REVISION_ID,
                    source_sha256=SOURCE_SHA,
                    pts_index=_pts_index(16),
                    total_declared_source_frames=16,
                    checkpoint_path=ckpt,
                    window_inspector_fn=_stub_inspector,
                )
        self.assertEqual(ctx.exception.code, "CHECKPOINT_PROVENANCE_MISMATCH")

    def test_checkpoint_with_foreign_provenance_is_refused(self) -> None:
        """P0-01: observations from another model/profile must not be replayable."""
        pipeline = FullFrameAnalysisPipeline()
        with tempfile.TemporaryDirectory() as tmp:
            ckpt = Path(tmp) / "ckpt.json"
            _write_forged_checkpoint(ckpt, frame_count=16)
            data = json.loads(ckpt.read_text(encoding="utf-8"))
            data["provenance"] = {"inspector": "offline_visual_model", "model_role": "other"}
            ckpt.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaises(FullFramePipelineError) as ctx:
                pipeline.run_or_resume_analysis(
                    source_revision_id=REVISION_ID,
                    source_sha256=SOURCE_SHA,
                    pts_index=_pts_index(16),
                    total_declared_source_frames=16,
                    checkpoint_path=ckpt,
                    window_inspector_fn=_stub_inspector,
                    checkpoint_provenance=_provenance(),
                )
        self.assertEqual(ctx.exception.code, "CHECKPOINT_PROVENANCE_MISMATCH")

    def test_own_checkpoint_resumes_with_matching_provenance(self) -> None:
        """The fix must not break genuine resume: our own inspector reuses its cache."""
        pipeline = FullFrameAnalysisPipeline()
        with tempfile.TemporaryDirectory() as tmp:
            ckpt = Path(tmp) / "ckpt.json"
            first = pipeline.run_or_resume_analysis(
                source_revision_id=REVISION_ID,
                source_sha256=SOURCE_SHA,
                pts_index=_pts_index(16),
                total_declared_source_frames=16,
                checkpoint_path=ckpt,
                window_inspector_fn=_stub_inspector,
                checkpoint_provenance=_provenance(),
            )
            self.assertGreaterEqual(len(first[1]), 1)
            saved = json.loads(ckpt.read_text(encoding="utf-8"))
            self.assertEqual(saved["provenance"], _provenance())
            second = pipeline.run_or_resume_analysis(
                source_revision_id=REVISION_ID,
                source_sha256=SOURCE_SHA,
                pts_index=_pts_index(16),
                total_declared_source_frames=16,
                checkpoint_path=ckpt,
                window_inspector_fn=_stub_inspector,
                checkpoint_provenance=_provenance(),
            )
        self.assertEqual(len(second[1]), len(first[1]))


if __name__ == "__main__":
    unittest.main()
