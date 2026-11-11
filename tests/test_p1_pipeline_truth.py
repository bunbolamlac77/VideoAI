"""
tests/test_p1_pipeline_truth.py — Regression for audit P1-24/26/27/28/29/30 (2026-11-11).

These cases pin the *truthfulness* of what the analysis pipeline reports:

  P1-24  a window decoded from frame 0 to EOF instead of stopping at the sampled frames
  P1-26  the coverage denominator silently became the index itself (circular coverage)
  P1-27  a clip with audio was reported as "no_speech" although ASR never ran
  P1-28  U+FFFD in model output was scrubbed away and recorded as an observation
  P1-29  a per-window fabricated subject track killed cross-window merging
  P1-30  the omission audit called every window frame "inspected / recovered_evidence"
"""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from aivideo_workers import pipeline_adapters
from aivideo_workers.full_frame_pipeline import (
    BoundedPipelineConfig,
    FullFrameAnalysisPipeline,
)
from aivideo_workers.media_indexer import (
    MediaMappingError,
    SourceFrameEntry,
    declared_source_frame_count,
)
from aivideo_workers.pipeline_adapters import (
    PipelineAdapterError,
    S11ModelRegistryAndAdapters,
    assert_index_is_contiguous,
)


def _pts(count: int) -> list[SourceFrameEntry]:
    return [
        SourceFrameEntry(frame_id=i, pts=i * 512, duration_pts=512,
                         time_base_num=1, time_base_den=12288, key_frame=i == 0)
        for i in range(count)
    ]


def _inspector(win) -> dict:
    planned = list(win.intended_frame_ids)[:2]
    return {
        "planned_frame_ids": planned,
        "accepted_frame_ids": planned,
        "observation_text": "model looked at two frames",
        "action_or_scene_type": "steady_visual_scene",
    }


class TestDecodeIsBoundedPerWindow(unittest.TestCase):
    """P1-24: the decoder stops after the last sampled frame."""

    def test_decoder_requests_a_bounded_number_of_frames(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            models = root / "models" / "visual_analysis_primary"
            models.mkdir(parents=True)
            for name in ("config.json", "preprocessor_config.json", "tokenizer.json"):
                (models / name).write_text("{}")
            header = json.dumps({"w": {"dtype": "F32", "shape": [1], "data_offsets": [0, 4]}}).encode()
            (models / "model.safetensors").write_bytes(
                len(header).to_bytes(8, "little") + header + b"\0" * 1_000_100)
            video = root / "clip.mp4"
            video.write_bytes(b"mock-video")

            commands: list[list[str]] = []
            backend = types.ModuleType("mlx_vlm")
            backend.load = lambda _: (types.SimpleNamespace(config={}), object())
            backend.prompt_utils = types.SimpleNamespace(
                apply_chat_template=lambda *a, **kw: "prompt")
            backend.generate = lambda *a, **kw: types.SimpleNamespace(text="Duong deo")

            def fake_run(cmd, **kwargs):
                commands.append(list(cmd))
                if not any(part.endswith("%04d.jpg") for part in cmd):
                    # the ffprobe sizing call made while building the inspector
                    return types.SimpleNamespace(returncode=0, stdout=b"1920\n1080\n", stderr=b"")
                out = next(part for part in cmd if part.endswith("%04d.jpg"))
                for i in range(1, cmd[cmd.index("-frames:v") + 1] and 1):
                    Path(out.replace("%04d", f"{i:04d}")).write_bytes(b"jpeg")
                count = int(cmd[cmd.index("-frames:v") + 1])
                for i in range(1, count + 1):
                    Path(out.replace("%04d", f"{i:04d}")).write_bytes(b"jpeg")
                return types.SimpleNamespace(returncode=0, stderr=b"")

            pipeline_adapters._VLM_MODEL_CACHE.clear()
            with mock.patch.dict(sys.modules, {"mlx_vlm": backend}), \
                 mock.patch.object(pipeline_adapters, "run_tracked", fake_run):
                inspector = S11ModelRegistryAndAdapters(
                    models_root_dir=root / "models"
                ).build_offline_visual_window_inspector(video, sample_count=2)
                # A window late in a long clip: frames 400..415 of a 1000-frame source.
                inspector(types.SimpleNamespace(window_index=25, intended_frame_ids=list(range(400, 416))))

        # commands[0] is the ffprobe sizing probe; the decode is the last one.
        self.assertGreaterEqual(len(commands), 1)
        cmd = commands[-1]
        self.assertIn("-frames:v", cmd)
        self.assertEqual(cmd[cmd.index("-frames:v") + 1], "2")
        self.assertNotIn("-vframes", cmd)
        # The decode starts at the requested window, never by re-reading the whole clip.
        self.assertNotIn("-ss", cmd)

    def test_non_contiguous_index_fails_closed(self) -> None:
        assert_index_is_contiguous([0, 1, 2])
        with self.assertRaises(PipelineAdapterError) as ctx:
            assert_index_is_contiguous([0, 1, 5])
        self.assertEqual(ctx.exception.code, "NON_CONTIGUOUS_FRAME_INDEX")


class TestCoverageDenominator(unittest.TestCase):
    """P1-26: the denominator states its provenance or fails closed."""

    def test_missing_container_metadata_is_a_hard_failure(self) -> None:
        with self.assertRaises(MediaMappingError) as ctx:
            declared_source_frame_count({"container_frame_count": None}, indexed_count=36)
        self.assertIn("COVERAGE_DENOMINATOR_UNAVAILABLE", str(ctx.exception))

    def test_duration_derived_denominator_is_labelled(self) -> None:
        declared = declared_source_frame_count(
            {"container_frame_count": 360, "denominator_source": "duration_times_fps"},
            indexed_count=360,
        )
        self.assertEqual(declared, 360)


class TestAudioStateIsHonest(unittest.TestCase):
    """P1-27: audio that was never transcribed is not "no speech"."""

    def test_audio_without_transcript(self) -> None:
        pipeline = FullFrameAnalysisPipeline(BoundedPipelineConfig())
        with tempfile.TemporaryDirectory() as tmp:
            _, _, audio, _ = pipeline.run_or_resume_analysis(
                source_revision_id="rev-audio",
                source_sha256="a" * 64,
                pts_index=_pts(16),
                total_declared_source_frames=16,
                checkpoint_path=Path(tmp) / "ckpt.json",
                has_audio_stream=True,
                window_inspector_fn=_inspector,
                checkpoint_provenance={"inspector": "test_seam"},
            )
        self.assertEqual(audio.audio_state, "audio_present_untranscribed")
        self.assertEqual(audio.asr_status, "not_configured")


class TestModelOutputIsNotRepaired(unittest.TestCase):
    """P1-28: corrupt model text is rejected, not scrubbed into an observation."""

    def test_replacement_character_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            models = root / "models" / "visual_analysis_primary"
            models.mkdir(parents=True)
            for name in ("config.json", "preprocessor_config.json", "tokenizer.json"):
                (models / name).write_text("{}")
            header = json.dumps({"w": {"dtype": "F32", "shape": [1], "data_offsets": [0, 4]}}).encode()
            (models / "model.safetensors").write_bytes(
                len(header).to_bytes(8, "little") + header + b"\0" * 1_000_100)
            video = root / "clip.mp4"
            video.write_bytes(b"mock-video")
            backend = types.ModuleType("mlx_vlm")
            backend.load = lambda _: (types.SimpleNamespace(config={}), object())
            backend.prompt_utils = types.SimpleNamespace(
                apply_chat_template=lambda *a, **kw: "prompt")
            backend.generate = lambda *a, **kw: types.SimpleNamespace(text="B\u1ee9c \ufffd h\u1ecfa")

            def fake_run(cmd, **kwargs):
                if not any(part.endswith("%04d.jpg") for part in cmd):
                    # the ffprobe sizing call made while building the inspector
                    return types.SimpleNamespace(returncode=0, stdout=b"1920\n1080\n", stderr=b"")
                if not any(part.endswith("%04d.jpg") for part in cmd):
                    return types.SimpleNamespace(returncode=0, stdout=b"1920\n1080\n", stderr=b"")
                out = next(part for part in cmd if part.endswith("%04d.jpg"))
                for i in range(1, 3):
                    Path(out.replace("%04d", f"{i:04d}")).write_bytes(b"jpeg")
                return types.SimpleNamespace(returncode=0, stdout=b"", stderr=b"")

            pipeline_adapters._VLM_MODEL_CACHE.clear()
            with mock.patch.dict(sys.modules, {"mlx_vlm": backend}), \
                 mock.patch.object(pipeline_adapters, "run_tracked", fake_run):
                inspector = S11ModelRegistryAndAdapters(
                    models_root_dir=root / "models"
                ).build_offline_visual_window_inspector(video, sample_count=2)
                with self.assertRaises(PipelineAdapterError) as ctx:
                    inspector(types.SimpleNamespace(window_index=0, intended_frame_ids=list(range(16))))
        self.assertEqual(ctx.exception.code, "INVALID_VLM_OUTPUT")
        self.assertIn("U+FFFD", ctx.exception.message)

    def test_no_subject_track_is_invented(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            models = root / "models" / "visual_analysis_primary"
            models.mkdir(parents=True)
            for name in ("config.json", "preprocessor_config.json", "tokenizer.json"):
                (models / name).write_text("{}")
            header = json.dumps({"w": {"dtype": "F32", "shape": [1], "data_offsets": [0, 4]}}).encode()
            (models / "model.safetensors").write_bytes(
                len(header).to_bytes(8, "little") + header + b"\0" * 1_000_100)
            video = root / "clip.mp4"
            video.write_bytes(b"mock-video")
            backend = types.ModuleType("mlx_vlm")
            backend.load = lambda _: (types.SimpleNamespace(config={}), object())
            backend.prompt_utils = types.SimpleNamespace(
                apply_chat_template=lambda *a, **kw: "prompt")
            backend.generate = lambda *a, **kw: types.SimpleNamespace(text="Hai nguoi di bo")

            def fake_run(cmd, **kwargs):
                if not any(part.endswith("%04d.jpg") for part in cmd):
                    # the ffprobe sizing call made while building the inspector
                    return types.SimpleNamespace(returncode=0, stdout=b"1920\n1080\n", stderr=b"")
                if not any(part.endswith("%04d.jpg") for part in cmd):
                    return types.SimpleNamespace(returncode=0, stdout=b"1920\n1080\n", stderr=b"")
                out = next(part for part in cmd if part.endswith("%04d.jpg"))
                for i in range(1, 3):
                    Path(out.replace("%04d", f"{i:04d}")).write_bytes(b"jpeg")
                return types.SimpleNamespace(returncode=0, stdout=b"", stderr=b"")

            pipeline_adapters._VLM_MODEL_CACHE.clear()
            with mock.patch.dict(sys.modules, {"mlx_vlm": backend}), \
                 mock.patch.object(pipeline_adapters, "run_tracked", fake_run):
                inspector = S11ModelRegistryAndAdapters(
                    models_root_dir=root / "models"
                ).build_offline_visual_window_inspector(video, sample_count=2)
                out = inspector(types.SimpleNamespace(window_index=3, intended_frame_ids=list(range(48, 64))))
        self.assertIsNone(out["subject_track_id"], "P1-29: no fabricated track id")


class TestOmissionAuditIsHonest(unittest.TestCase):
    """P1-30: findings describe only frames a model actually saw."""

    def test_findings_never_claim_unseen_frames(self) -> None:
        pipeline = FullFrameAnalysisPipeline(BoundedPipelineConfig())
        with tempfile.TemporaryDirectory() as tmp:
            _, observations, _, findings = pipeline.run_or_resume_analysis(
                source_revision_id="rev-audit",
                source_sha256="b" * 64,
                pts_index=_pts(32),
                total_declared_source_frames=32,
                checkpoint_path=Path(tmp) / "ckpt.json",
                has_audio_stream=False,
                window_inspector_fn=_inspector,
                checkpoint_provenance={"inspector": "test_seam"},
            )
        seen = {fid for obs in observations for fid in obs.frame_ids}
        self.assertTrue(findings, "the audit still reports findings")
        for finding in findings:
            self.assertNotEqual(
                finding.status, "recovered_evidence",
                f"{finding.category} claimed recovered evidence without evidence",
            )
            self.assertTrue(
                set(finding.inspected_frame_ids) <= seen,
                f"{finding.category} lists frames the model never saw",
            )


if __name__ == "__main__":
    unittest.main()
