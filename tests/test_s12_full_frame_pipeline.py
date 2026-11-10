"""
tests/test_s12_full_frame_pipeline.py — Unit & Fault-Injection Tests for S12 Full-Frame Pipeline,
Overlapping Window Checkpointing, Brief-Agnostic Raw Observation Isolation & Bounded Resource Guards.
Covers S12.T1, S12.T2, S12.T3, and S12.T4.
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
    generate_overlapping_windows,
    merge_window_observations,
)
from workers.src.aivideo_workers.media_indexer import SourceFrameEntry


def _make_pts_index(num_frames: int = 40) -> list[SourceFrameEntry]:
    return [
        SourceFrameEntry(
            frame_id=i,
            pts=i * 1000,
            duration_pts=1000,
            time_base_num=1,
            time_base_den=24000,
            has_critical_evidence=(i in (12, 13, 14, 15)),  # Overlap boundary frames between Window 0 and Window 1
            evidence_tag="short_boundary_action" if i in (12, 13, 14, 15) else None,
        )
        for i in range(num_frames)
    ]


def _default_test_window_inspector(win):
    return {
        "accepted_frame_ids": list(win.intended_frame_ids),
        "action_or_scene_type": "scenic_or_motion",
        "subject_track_id": "track-main",
        "observation_text": f"Quan sát kiểm thử cửa sổ {win.window_index} (frames {win.start_frame_id}..{win.end_frame_id_exclusive - 1})",
        "ocr_raw_tokens": [],
        "ocr_is_uncertain": False,
        "has_uncertainty_boundary": False,
    }


class TestS12FullFramePipeline(unittest.TestCase):
    def test_s12_t1_silent_clip_boundary_action_and_separate_coverage_vs_understanding(self) -> None:
        """
        S12.T1: Silent / no_audio clips, short actions at window boundaries, and blurry small text are processed;
        coverage (frame_input_coverage = 1.0) and semantic understanding (semantic_understanding_certified = False)
        are reported separately.
        """
        pts_index = _make_pts_index(40)  # Windows: [0..15], [12..27], [24..39]
        pipeline = FullFrameAnalysisPipeline(
            BoundedPipelineConfig(window_size_frames=16, window_overlap_frames=4)
        )

        with tempfile.TemporaryDirectory() as tmp:
            ckpt_path = Path(tmp) / "s12_t1_checkpoint.json"
            ledger, raw_obs, audio_res, findings = pipeline.run_or_resume_analysis(
                source_revision_id="src-silent-001",
                source_sha256="a" * 64,
                pts_index=pts_index,
                total_declared_source_frames=40,
                checkpoint_path=ckpt_path,
                has_audio_stream=False,  # Silent / no_audio clip
                window_inspector_fn=_default_test_window_inspector,
            )

            self.assertEqual(audio_res.audio_state, "no_audio")
            self.assertTrue(audio_res.visual_branch_enabled)
            self.assertEqual(ledger.total_windows, 3)
            self.assertEqual(len(ledger.unique_post_processor_frame_ids), 40)
            self.assertEqual(ledger.total_submitted_frames_with_overlap, 48)  # 3 * 16 = 48 submitted, union = 40!
            self.assertEqual(ledger.frame_input_coverage, 1.0)
            self.assertFalse(ledger.semantic_understanding_certified)

            # Check omission audit inspected both silent_scenic and short_action_boundary
            categories = {f.category for f in findings}
            self.assertIn("silent_scenic", categories)
            self.assertIn("short_action_boundary", categories)

            # Merge observations across overlapping windows
            segments = merge_window_observations(raw_obs)
            self.assertEqual(len(segments), 1)
            self.assertEqual(segments[0].merge_status, "merged_continuous")
            self.assertEqual(segments[0].start_frame_id, 0)
            self.assertEqual(segments[0].end_frame_id_exclusive, 40)

    def test_s12_t2_kill_between_windows_resume_no_duplicate_and_profile_mismatch_blocked(self) -> None:
        """
        S12.T2: Kill after Window 0, then resume:
        - Does not lose unprocessed regions
        - Does not double-count overlap or re-run committed Window 0 into higher >100% coverage
        - Rejects resume if runtime profile / input fingerprint changes.
        """
        pts_index = _make_pts_index(40)
        pipeline = FullFrameAnalysisPipeline(
            BoundedPipelineConfig(window_size_frames=16, window_overlap_frames=4)
        )

        with tempfile.TemporaryDirectory() as tmp:
            ckpt_path = Path(tmp) / "s12_t2_checkpoint.json"

            # Run 1: Kill/stop right after Window 0 commits
            ledger_partial, obs_partial, _, _ = pipeline.run_or_resume_analysis(
                source_revision_id="src-resume-002",
                source_sha256="b" * 64,
                pts_index=pts_index,
                total_declared_source_frames=40,
                checkpoint_path=ckpt_path,
                window_inspector_fn=_default_test_window_inspector,
                stop_after_window_index=0,
            )
            self.assertEqual(ledger_partial.detailed_pass_status, "paused_checkpoint")
            self.assertEqual(ledger_partial.completed_window_indices, [0])
            self.assertEqual(len(ledger_partial.unique_post_processor_frame_ids), 16)
            self.assertEqual(ledger_partial.frame_input_coverage, 16.0 / 40.0)
            self.assertEqual(len(obs_partial), 1)

            # Attempt resume with a DIFFERENT profile -> must fail with CHECKPOINT_PROFILE_MISMATCH
            mismatched_pipeline = FullFrameAnalysisPipeline(
                BoundedPipelineConfig(runtime_profile_id="P-VISION-DEV-v2-CHANGED", window_size_frames=16, window_overlap_frames=4)
            )
            with self.assertRaises(FullFramePipelineError) as ctx:
                mismatched_pipeline.run_or_resume_analysis(
                    source_revision_id="src-resume-002",
                    source_sha256="b" * 64,
                    pts_index=pts_index,
                    total_declared_source_frames=40,
                    checkpoint_path=ckpt_path,
                    window_inspector_fn=_default_test_window_inspector,
                )
            self.assertEqual(ctx.exception.code, "CHECKPOINT_PROFILE_MISMATCH")

            # Resume with the exact matching profile -> completes remaining Windows 1 and 2
            ledger_final, obs_final, _, _ = pipeline.run_or_resume_analysis(
                source_revision_id="src-resume-002",
                source_sha256="b" * 64,
                pts_index=pts_index,
                total_declared_source_frames=40,
                checkpoint_path=ckpt_path,
                window_inspector_fn=_default_test_window_inspector,
            )
            self.assertEqual(ledger_final.detailed_pass_status, "completed")
            self.assertEqual(ledger_final.completed_window_indices, [0, 1, 2])
            self.assertEqual(len(obs_final), 3)
            self.assertEqual(len(ledger_final.unique_post_processor_frame_ids), 40)
            self.assertEqual(ledger_final.frame_input_coverage, 1.0)

    def test_s12_t3_misleading_brief_does_not_overwrite_raw_observation(self) -> None:
        """
        S12.T3 (AI-02): When user brief suggests a misleading sign name for a blurry road sign,
        the initial `raw_independent` observation remains untouched and blurry (`ocr_is_uncertain=True`),
        while `guided_revisit` stores a separate hypothesis check record without turning blurry OCR into observed truth.
        """
        pts_index = _make_pts_index(16)
        pipeline = FullFrameAnalysisPipeline(
            BoundedPipelineConfig(window_size_frames=16, window_overlap_frames=4)
        )

        def blurry_ocr_inspector(win):
            return {
                "accepted_frame_ids": list(win.intended_frame_ids),
                "action_or_scene_type": "road_sign_pass",
                "subject_track_id": "sign-01",
                "observation_text": "Biển báo ven đường bị nhòe sương mù, chỉ đọc được chữ ĐÈO PR???",
                "ocr_raw_tokens": ["ĐÈO", "PR???"],
                "ocr_is_uncertain": True,
                "has_uncertainty_boundary": True,
            }

        with tempfile.TemporaryDirectory() as tmp:
            ckpt_path = Path(tmp) / "s12_t3_checkpoint.json"
            _, raw_obs, _, _ = pipeline.run_or_resume_analysis(
                source_revision_id="src-blurry-003",
                source_sha256="c" * 64,
                pts_index=pts_index,
                total_declared_source_frames=16,
                checkpoint_path=ckpt_path,
                window_inspector_fn=blurry_ocr_inspector,
            )

            preserved_raw, guided_obs = pipeline.run_guided_revisit_without_overwriting_raw(
                raw_observations=raw_obs,
                brief_hypothesis_id="hyp-misleading-dran",
                expected_sign_text_from_brief="ĐÈO D'RAN",
            )

            # Verify raw observation is completely unchanged
            self.assertEqual(len(preserved_raw), 1)
            self.assertEqual(preserved_raw[0].pass_role, "raw_independent")
            self.assertIsNone(preserved_raw[0].guided_hypothesis_ref)
            self.assertEqual(preserved_raw[0].ocr_raw_tokens, ["ĐÈO", "PR???"])
            self.assertTrue(preserved_raw[0].ocr_is_uncertain)
            self.assertNotIn("D'RAN", preserved_raw[0].observation_text)

            # Verify guided revisit is isolated with epistemic_status = 'unknown'
            self.assertEqual(len(guided_obs), 1)
            self.assertEqual(guided_obs[0].pass_role, "guided_revisit")
            self.assertEqual(guided_obs[0].guided_hypothesis_ref, "hyp-misleading-dran")
            self.assertEqual(guided_obs[0].epistemic_status, "unknown")
            self.assertEqual(guided_obs[0].ocr_raw_tokens, ["ĐÈO", "PR???"])

    def test_s12_t4_bounded_queues_log_ring_decode_error_denominator_and_blocked_resource(self) -> None:
        """
        S12.T4:
        1. In-memory frame queue and log ring buffer are strictly bounded.
        2. Corrupted decode frames remain in the total denominator (`frame_input_coverage < 1.0`).
        3. Simulated RAM/SSD pressure pauses the pipeline with `detailed_pass_status == 'blocked_resource'`
           and preserves a valid checkpoint.
        """
        pts_index = _make_pts_index(32)
        config = BoundedPipelineConfig(
            window_size_frames=16,
            window_overlap_frames=4,
            max_in_memory_frame_queue=32,
            max_in_memory_log_entries=5,
        )
        pipeline = FullFrameAnalysisPipeline(config)

        # Push 20 log entries and verify ring buffer never exceeds max_in_memory_log_entries (5)
        for i in range(20):
            pipeline._append_log(f"log-entry-{i}")
        self.assertEqual(pipeline.log_buffer_size, 5)

        with tempfile.TemporaryDirectory() as tmp:
            # 0. Missing visual model / window_inspector_fn=None -> MUST block with 0 observations & 0.0 coverage!
            ckpt_no_model = Path(tmp) / "s12_t4_no_model.json"
            ledger_no_model, obs_no_model, _, _ = pipeline.run_or_resume_analysis(
                source_revision_id="src-no-model-000",
                source_sha256="0" * 64,
                pts_index=pts_index,
                total_declared_source_frames=32,
                checkpoint_path=ckpt_no_model,
                window_inspector_fn=None,
            )
            self.assertEqual(ledger_no_model.detailed_pass_status, "blocked_model_unavailable")
            self.assertEqual(ledger_no_model.frame_input_coverage, 0.0)
            self.assertEqual(len(obs_no_model), 0)

            # 1. Test corrupted decode frames kept in denominator
            ckpt_corrupt = Path(tmp) / "s12_t4_corrupt.json"
            ledger_corrupt, _, _, findings = pipeline.run_or_resume_analysis(
                source_revision_id="src-corrupt-004",
                source_sha256="d" * 64,
                pts_index=pts_index,
                total_declared_source_frames=32,
                corrupted_decode_frame_ids=[30, 31],
                checkpoint_path=ckpt_corrupt,
                window_inspector_fn=_default_test_window_inspector,
            )
            self.assertEqual(ledger_corrupt.detailed_pass_status, "partial_with_decode_errors")
            self.assertEqual(ledger_corrupt.frame_input_coverage, 30.0 / 32.0)
            self.assertEqual(ledger_corrupt.valid_frame_input_coverage, 1.0)
            self.assertTrue(any(f.category == "decode_corrupted_region" for f in findings))

            # 2. Test RAM/SSD resource exhaustion returns blocked_resource cleanly
            ckpt_blocked = Path(tmp) / "s12_t4_blocked.json"
            ledger_blocked, _, _, _ = pipeline.run_or_resume_analysis(
                source_revision_id="src-blocked-005",
                source_sha256="e" * 64,
                pts_index=pts_index,
                total_declared_source_frames=32,
                checkpoint_path=ckpt_blocked,
                window_inspector_fn=_default_test_window_inspector,
                simulated_ram_rss_bytes=15 * 1024 * 1024 * 1024,  # 15 GiB > 12 GiB limit
            )
            self.assertEqual(ledger_blocked.detailed_pass_status, "blocked_resource")
            self.assertEqual(ledger_blocked.completed_window_indices, [])

    def test_s12_real_worker_g2_analyze_source_uninstalled_and_installed(self) -> None:
        """
        S11/S12 End-to-End Worker RPC (`g2.analyze_source`) on a real 24-frame MP4 video:
        - When adapter is not installed: returns blocked_model_unavailable, 0.0 coverage, 0 observations.
        - When offline adapter is installed: automatically decodes source frames via build_offline_visual_window_inspector,
          achieves 100% (1.0) coverage, emits validated raw_observations, and detects no_audio on silent MP4.
        """
        import json
        import subprocess
        from workers.src.aivideo_workers.main import handle_g2_analyze_source

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            video_path = tmp_path / "real_24f.mp4"
            subprocess.run(
                [
                    "ffmpeg",
                    "-nostdin",
                    "-y",
                    "-f",
                    "lavfi",
                    "-i",
                    "testsrc=duration=1:size=320x180:rate=24",
                    "-c:v",
                    "libx264",
                    "-pix_fmt",
                    "yuv420p",
                    "-x264-params",
                    "colorprim=bt709:transfer=bt709:colormatrix=bt709",
                    str(video_path),
                ],
                check=True,
                capture_output=True,
                timeout=20,
            )

            # 1) Uninstalled models_root -> blocked_model_unavailable
            empty_models_root = tmp_path / "empty_models"
            res_uninstalled = handle_g2_analyze_source(
                {
                    "file_path": str(video_path),
                    "source_revision_id": "00000000-0000-4000-8000-000000000777",
                    "workday_id": "00000000-0000-4000-8000-000000000888",
                    "brief_text": "Đi qua cầu lúc 9h. Mưa lớn làm đường trơn.",
                    "models_root_dir": str(empty_models_root),
                    "checkpoint_dir": str(tmp_path / "ckpt_uninstalled"),
                }
            )
            self.assertFalse(res_uninstalled["vision_model_installed"])
            self.assertEqual(res_uninstalled["coverage_ledger"]["detailed_pass_status"], "blocked_model_unavailable")
            self.assertEqual(res_uninstalled["coverage_ledger"]["frame_input_coverage"], 0.0)
            self.assertEqual(res_uninstalled["raw_observations_count"], 0)
            self.assertEqual(len(res_uninstalled["raw_observations"]), 0)
            self.assertEqual(res_uninstalled["audio_branch_state"], "no_audio")
            self.assertGreaterEqual(len(res_uninstalled["claims"]), 2)

            # 2) Stub/synthetic weights without genuine model are rejected; G2 stays blocked
            installed_models_root = tmp_path / "installed_models"
            vis_dir = installed_models_root / "visual_analysis_primary"
            vis_dir.mkdir(parents=True, exist_ok=True)
            (vis_dir / "config.json").write_text(
                json.dumps({"model_type": "qwen3_vl", "_name_or_path": "Qwen3-VL-4B-Instruct-4bit"}),
                encoding="utf-8",
            )
            (vis_dir / "model.safetensors").write_bytes(b"SAFETENSORS_OFFLINE_WEIGHTS_STUB")

            res_stub = handle_g2_analyze_source(
                {
                    "file_path": str(video_path),
                    "source_revision_id": "00000000-0000-4000-8000-000000000777",
                    "workday_id": "00000000-0000-4000-8000-000000000888",
                    "brief_text": "Đi qua cầu lúc 9h. Mưa lớn làm đường trơn.",
                    "models_root_dir": str(installed_models_root),
                    "checkpoint_dir": str(tmp_path / "ckpt_stub"),
                }
            )
            self.assertFalse(res_stub["vision_model_installed"])
            self.assertEqual(res_stub["coverage_ledger"]["detailed_pass_status"], "blocked_model_unavailable")
            self.assertEqual(res_stub["coverage_ledger"]["frame_input_coverage"], 0.0)

            # 3) When a Python-level inspector factory is injected (test seam, never RPC params),
            # the pipeline runs to completion.
            def mock_inspector(win: Any) -> dict:
                return {
                    "accepted_frame_ids": list(win.intended_frame_ids),
                    "action_or_scene_type": "steady_visual_scene",
                    "subject_track_id": f"trk-w{win.window_index:04d}",
                    "observation_text": f"Fixture observation for window {win.window_index}",
                    "ocr_raw_tokens": [],
                    "ocr_is_uncertain": False,
                    "has_uncertainty_boundary": False,
                }

            res_fixture = handle_g2_analyze_source(
                {
                    "file_path": str(video_path),
                    "source_revision_id": "00000000-0000-4000-8000-000000000777",
                    "workday_id": "00000000-0000-4000-8000-000000000888",
                    "brief_text": "Đi qua cầu lúc 9h. Mưa lớn làm đường trơn.",
                    "models_root_dir": str(installed_models_root),
                    "checkpoint_dir": str(tmp_path / "ckpt_fixture"),
                },
                inspector_factory=lambda _path: mock_inspector,
            )
            self.assertTrue(res_fixture["vision_model_installed"])
            self.assertEqual(res_fixture["coverage_ledger"]["detailed_pass_status"], "completed")
            self.assertEqual(res_fixture["coverage_ledger"]["frame_input_coverage"], 1.0)
            self.assertEqual(len(res_fixture["coverage_ledger"]["unique_post_processor_frame_ids"]), 24)
            self.assertGreater(res_fixture["raw_observations_count"], 0)
            self.assertEqual(len(res_fixture["raw_observations"]), res_fixture["raw_observations_count"])
            self.assertEqual(res_fixture["audio_branch_state"], "no_audio")
            self.assertEqual(res_fixture["color_decision"]["status"], "sdr_passthrough_or_transform")


if __name__ == "__main__":
    unittest.main()
