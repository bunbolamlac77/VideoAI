"""
tests/test_g2_prefilter.py — ECC add-feature: cheap motion prefilter.

Rules under test:
  * a static source yields near-zero motion scores and can skip windows;
  * a moving source is not skipped;
  * skipped windows are recorded, produce no observation and never count as analyzed;
  * decisions survive checkpoint resume;
  * the feature is off unless explicitly requested.
"""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile

import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from aivideo_workers.full_frame_pipeline import (
    BoundedPipelineConfig,
    FullFrameAnalysisPipeline,
    generate_overlapping_windows,
)
from aivideo_workers.media_indexer import SourceFrameEntry
from aivideo_workers.prefilter import (
    PrefilterConfig,
    PrefilterError,
    build_window_prefilter,
    config_from_params,
    scan_motion_profile,
    window_motion_scores,
)


def _make_clip(path: Path, *, static: bool, seconds: float = 3.0, fps: int = 24) -> None:
    source = "color=c=black:s=320x240:r=24" if static else "testsrc=size=320x240:rate=24"
    subprocess.run(
        [
            "ffmpeg", "-nostdin", "-y",
            "-f", "lavfi", "-i", source,
            "-t", str(seconds),
            "-pix_fmt", "yuv420p",
            "-c:v", "libx264",
            str(path),
        ],
        check=True,
        capture_output=True,
        timeout=60,
    )


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


def _stub_inspector(window):
    return {
        "accepted_frame_ids": list(window.intended_frame_ids),
        "action_or_scene_type": "scenic_or_motion",
        "observation_text": f"stub observation for window {window.window_index}",
    }


class TestPrefilterConfig(unittest.TestCase):
    def test_disabled_by_default(self) -> None:
        self.assertFalse(PrefilterConfig().enabled)
        self.assertFalse(config_from_params(None).enabled)

    def test_rejects_invalid_threshold(self) -> None:
        with self.assertRaises(PrefilterError):
            PrefilterConfig(motion_threshold=1.5)
        with self.assertRaises(PrefilterError):
            PrefilterConfig(sample_fps=0)

    def test_rejects_unknown_keys(self) -> None:
        with self.assertRaises(PrefilterError):
            config_from_params({"enabled": True, "magic": 1})

    def test_parses_rpc_params(self) -> None:
        config = config_from_params({"enabled": True, "sample_fps": 1.0, "motion_threshold": 0.05})
        self.assertTrue(config.enabled)
        self.assertEqual(config.sample_fps, 1.0)
        self.assertEqual(config.motion_threshold, 0.05)


class TestMotionScan(unittest.TestCase):
    def test_static_clip_has_near_zero_motion(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            clip = Path(tmp) / "static.mp4"
            _make_clip(clip, static=True)
            profile = scan_motion_profile(
                clip, config=PrefilterConfig(sample_fps=2.0), source_fps=24.0
            )
        self.assertGreater(profile["sample_count"], 0)
        self.assertLessEqual(max(s["mean_abs_diff"] for s in profile["samples"]), 0.01)

    def test_moving_clip_exceeds_threshold(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            clip = Path(tmp) / "moving.mp4"
            _make_clip(clip, static=False)
            profile = scan_motion_profile(
                clip, config=PrefilterConfig(sample_fps=2.0), source_fps=24.0
            )
        self.assertGreater(max(s["mean_abs_diff"] for s in profile["samples"]), 0.02)

    def test_scores_are_mapped_into_windows(self) -> None:
        windows = generate_overlapping_windows(_pts_index(72), window_size=16, overlap=4)
        profile = {
            "samples": [
                {"sample_index": i, "frame_id": i * 12, "mean_abs_diff": 0.0 if i < 2 else 0.5}
                for i in range(6)
            ]
        }
        scores = window_motion_scores(windows, profile)
        self.assertEqual(set(scores), set(range(len(windows))))

    def test_decisions_skip_static_windows_but_keep_first(self) -> None:
        windows = generate_overlapping_windows(_pts_index(72), window_size=16, overlap=4)
        profile = {"samples": [{"sample_index": i, "frame_id": i * 12, "mean_abs_diff": 0.0} for i in range(8)]}
        decide = build_window_prefilter(windows, profile, PrefilterConfig(enabled=True))
        decisions = [decide(w) for w in windows]
        self.assertTrue(decisions[0]["analyze"])
        self.assertFalse(decisions[1]["analyze"])

    def test_moving_windows_are_analyzed(self) -> None:
        windows = generate_overlapping_windows(_pts_index(72), window_size=16, overlap=4)
        profile = {"samples": [{"sample_index": i, "frame_id": i * 12, "mean_abs_diff": 0.9} for i in range(8)]}
        decide = build_window_prefilter(windows, profile, PrefilterConfig(enabled=True))
        self.assertTrue(all(decide(w)["analyze"] for w in windows))


class TestPipelineIntegration(unittest.TestCase):
    def _skip_all_but_first(self, window):
        if window.window_index == 0:
            return {"analyze": True, "score": 0.0, "reason": "first_window"}
        return {"analyze": False, "score": 0.0, "reason": "static_below_threshold"}

    def test_skipped_windows_are_recorded_not_fabricated(self) -> None:
        pipeline = FullFrameAnalysisPipeline(BoundedPipelineConfig())
        with tempfile.TemporaryDirectory() as tmp:
            ledger, observations, _, _ = pipeline.run_or_resume_analysis(
                source_revision_id="src-prefilter-001",
                source_sha256="a" * 64,
                pts_index=_pts_index(48),
                total_declared_source_frames=48,
                checkpoint_path=Path(tmp) / "ckpt.json",
                window_inspector_fn=_stub_inspector,
                window_prefilter=self._skip_all_but_first,
            )

        self.assertEqual(len(observations), 1)
        self.assertEqual(ledger.skipped_window_indices, [1, 2, 3])
        self.assertEqual(ledger.prefilter_skipped_count, 3)
        self.assertEqual(ledger.detailed_pass_status, "completed_prefiltered")
        # Only the first 16-frame window was actually submitted.
        self.assertAlmostEqual(ledger.frame_input_coverage, 16.0 / 48.0, places=5)

    def test_without_prefilter_status_is_completed(self) -> None:
        pipeline = FullFrameAnalysisPipeline(BoundedPipelineConfig())
        with tempfile.TemporaryDirectory() as tmp:
            ledger, observations, _, _ = pipeline.run_or_resume_analysis(
                source_revision_id="src-prefilter-002",
                source_sha256="b" * 64,
                pts_index=_pts_index(48),
                total_declared_source_frames=48,
                checkpoint_path=Path(tmp) / "ckpt.json",
                window_inspector_fn=_stub_inspector,
            )
        self.assertEqual(ledger.detailed_pass_status, "completed")
        self.assertEqual(ledger.skipped_window_indices, [])
        self.assertEqual(len(observations), 4)

    def test_skip_decisions_survive_resume(self) -> None:
        pipeline = FullFrameAnalysisPipeline(BoundedPipelineConfig())
        with tempfile.TemporaryDirectory() as tmp:
            checkpoint = Path(tmp) / "ckpt.json"
            first, _, _, _ = pipeline.run_or_resume_analysis(
                source_revision_id="src-prefilter-003",
                source_sha256="c" * 64,
                pts_index=_pts_index(48),
                total_declared_source_frames=48,
                checkpoint_path=checkpoint,
                window_inspector_fn=_stub_inspector,
                window_prefilter=self._skip_all_but_first,
                stop_after_window_index=0,
            )
            self.assertEqual(first.detailed_pass_status, "paused_checkpoint")

            resumed, observations, _, _ = pipeline.run_or_resume_analysis(
                source_revision_id="src-prefilter-003",
                source_sha256="c" * 64,
                pts_index=_pts_index(48),
                total_declared_source_frames=48,
                checkpoint_path=checkpoint,
                window_inspector_fn=_stub_inspector,
                window_prefilter=self._skip_all_but_first,
            )

        self.assertEqual(resumed.skipped_window_indices, [1, 2, 3])
        self.assertEqual(len(observations), 1)
        self.assertEqual(resumed.detailed_pass_status, "completed_prefiltered")


class TestRPCIntegration(unittest.TestCase):
    def _call(self, clip: Path, tmp: Path, prefilter=None):
        from workers.src.aivideo_workers.main import handle_g2_analyze_source

        params = {
            "file_path": str(clip),
            "source_revision_id": "00000000-0000-4000-8000-000000000901",
            "workday_id": "00000000-0000-4000-8000-000000000902",
            "checkpoint_dir": str(tmp / "ckpt"),
        }
        if prefilter is not None:
            params["prefilter"] = prefilter
        return handle_g2_analyze_source(
            params,
            inspector_factory=lambda _path: _stub_inspector,
        )

    def test_prefilter_is_off_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            clip = root / "static.mp4"
            _make_clip(clip, static=True)
            result = self._call(clip, root)
        self.assertFalse(result["prefilter"]["enabled"])
        self.assertEqual(result["prefilter"]["skipped_count"], 0)
        self.assertEqual(result["coverage_ledger"]["detailed_pass_status"], "completed")

    def test_prefilter_skips_static_windows_and_reports_them(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            clip = root / "static.mp4"
            _make_clip(clip, static=True)
            result = self._call(
                clip,
                root,
                prefilter={"enabled": True, "motion_threshold": 0.02},
            )
        self.assertTrue(result["prefilter"]["enabled"])
        self.assertGreater(result["prefilter"]["skipped_count"], 0)
        self.assertEqual(result["prefilter"]["analyzed_count"], 1)
        self.assertEqual(
            result["coverage_ledger"]["detailed_pass_status"], "completed_prefiltered"
        )
        # Skipped windows must not fabricate observations.
        self.assertEqual(result["raw_observations_count"], 1)

    def test_invalid_prefilter_params_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            clip = root / "static.mp4"
            _make_clip(clip, static=True)
            with self.assertRaises(PrefilterError):
                self._call(clip, root, prefilter={"enabled": True, "motion_threshold": 9})


if __name__ == "__main__":
    unittest.main()
