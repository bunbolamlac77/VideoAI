"""
tests/test_g2_window_audit.py — Regression for audit P0-02 (2026-11-11).

Before the fix the per-window audit was a tautology:

  * `full_frame_pipeline.py` called `audit_vision_processor_coverage(intended_frame_ids=planned_ids, ...)`
    and `planned_ids == submitted_frame_ids` by construction, so the audit's coverage was
    always 1.0 no matter how little of the 16-frame window the model actually saw.
  * `accepted ⊆ planned` was already enforced a few lines earlier, so
    `truncation_detected` could never become True and `POST_PROCESSOR_TRUNCATION` was dead code.
  * A sample the inspector "planned" but the model never produced (a silent drop) passed
    unless it was also missing from `planned`.

The audit must now measure the whole window and must fail closed on dropped samples.
"""

from __future__ import annotations

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
)
from workers.src.aivideo_workers.media_indexer import SourceFrameEntry


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


def _inspector(sample_take: int, accepted_take: int | None = None):
    """Return an inspector that plans `sample_take` frames and hands `accepted_take` to the model."""

    def inspect(win) -> dict:
        planned = list(win.intended_frame_ids)[:sample_take]
        accepted = planned if accepted_take is None else planned[:accepted_take]
        return {
            "planned_frame_ids": planned,
            "accepted_frame_ids": accepted,
            "observation_text": "ok",
            "action_or_scene_type": "steady_visual_scene",
        }

    return inspect


def _run(inspector, frame_count: int = 16):
    pipeline = FullFrameAnalysisPipeline()
    with tempfile.TemporaryDirectory() as tmp:
        return pipeline.run_or_resume_analysis(
            source_revision_id="00000000-0000-4000-8000-000000008801",
            source_sha256="b" * 64,
            pts_index=_pts_index(frame_count),
            total_declared_source_frames=frame_count,
            checkpoint_path=Path(tmp) / "ckpt.json",
            window_inspector_fn=inspector,
            checkpoint_provenance={"inspector": "test_seam"},
        )


class TestWindowAudit(unittest.TestCase):
    def test_window_coverage_is_sample_over_window_not_always_one(self) -> None:
        """P0-02: 2/16 sampled frames must be reported as 0.125, not 1.0."""
        ledger, observations, _, _ = _run(_inspector(sample_take=2))
        self.assertEqual(ledger.analysed_window_count, 1)
        self.assertAlmostEqual(ledger.window_frame_coverage, 2 / 16, places=6)
        self.assertEqual(len(observations), 1)
        # The pipeline records the frames the model actually saw, never the "planned" claim.
        self.assertEqual(sorted(observations[0].frame_ids), [0, 1])

    def test_full_window_sample_reports_one(self) -> None:
        ledger, _, _, _ = _run(_inspector(sample_take=16))
        self.assertAlmostEqual(ledger.window_frame_coverage, 1.0, places=6)

    def test_silently_dropped_sample_fails_closed(self) -> None:
        """P0-02: a planned sample the model never produced is a truncation, not coverage."""
        with self.assertRaises(FullFramePipelineError) as ctx:
            _run(_inspector(sample_take=4, accepted_take=1))
        self.assertEqual(ctx.exception.code, "POST_PROCESSOR_TRUNCATION")

    def test_sample_outside_the_window_fails_closed(self) -> None:
        """P0-02: an inspector may not declare frames it was never asked to look at."""

        def inspect(win) -> dict:
            planned = [999]
            return {
                "planned_frame_ids": planned,
                "accepted_frame_ids": planned,
                "observation_text": "ok",
                "action_or_scene_type": "steady_visual_scene",
            }

        with self.assertRaises(FullFramePipelineError) as ctx:
            _run(inspect)
        self.assertEqual(ctx.exception.code, "VISUAL_SAMPLE_OUTSIDE_WINDOW")

    def test_runtime_profile_is_the_one_being_run(self) -> None:
        """Guard against drifting profile ids in the audit payload."""
        profile = BoundedPipelineConfig()
        self.assertEqual(profile.runtime_profile_id, "P-VISION-DEV-v1")


if __name__ == "__main__":
    unittest.main()
