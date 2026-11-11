"""
tests/test_p31_transition_source.py — Regression for audit P1-31 (2026-11-11).

The 4K renderer used to take its transition list from the request, so a caller could render
a crossfade timeline while the approved G4 preview was a hard-cut timeline. Transitions now
have to exist in the approved plan and match it exactly.
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

from aivideo_workers import native_render
from aivideo_workers.native_render import NativeRenderError


def _plan(work: Path, *, transitions: dict | None = None) -> dict:
    clip = work / "clip.mp4"
    clip.write_bytes(b"video")
    voice = work / "voice.wav"
    voice.write_bytes(b"audio")
    plan = {
        "plan_sha256": "0" * 64,
        "total_frames": 96,
        "entries": [
            {
                "beat_id": "b1",
                "video_path": str(clip),
                "voice_path": str(voice),
                "duration_frames": 48,
                "video_sha256": "1" * 64,
                "voice_sha256": "2" * 64,
                "caption_text_sha256": native_render._sha256_bytes("Xin chào".encode()),
            },
            {
                "beat_id": "b2",
                "video_path": str(clip),
                "voice_path": str(voice),
                "duration_frames": 48,
                "video_sha256": "3" * 64,
                "voice_sha256": "4" * 64,
                "caption_text_sha256": native_render._sha256_bytes("Tạm biệt".encode()),
            },
        ],
    }
    if transitions is not None:
        plan["transitions"] = transitions
    return plan


VOICE = {"b1": "Xin chào", "b2": "Tạm biệt"}


class TestTransitionsComeFromThePlan(unittest.TestCase):
    def test_hard_cut_plan_rejects_any_transition(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            with self.assertRaises(NativeRenderError) as ctx:
                native_render.build_beats_from_plan(
                    _plan(work),
                    {"voice_texts": VOICE,
                     "transitions": {"b2": {"type": "crossfade", "frames": 8}}},
                    staging_root=work,
                )
        self.assertEqual(ctx.exception.code, "TRANSITION_NOT_IN_PLAN")

    def test_plan_transition_is_accepted_when_it_matches(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            plan = _plan(work, transitions={"b2": {"type": "crossfade", "frames": 8}})
            plan["total_frames"] = 88
            beats, _ = native_render.build_beats_from_plan(
                plan,
                {"voice_texts": VOICE,
                 "transitions": {"b2": {"type": "crossfade", "frames": 8}}},
                staging_root=work,
            )
        self.assertEqual(native_render.expected_total_frames(beats), 88)

    def test_mismatched_frames_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            plan = _plan(work, transitions={"b2": {"type": "crossfade", "frames": 8}})
            with self.assertRaises(NativeRenderError) as ctx:
                native_render.build_beats_from_plan(
                    plan,
                    {"voice_texts": VOICE,
                     "transitions": {"b2": {"type": "crossfade", "frames": 12}}},
                    staging_root=work,
                )
        self.assertEqual(ctx.exception.code, "TRANSITION_MISMATCH")

    def test_mismatched_type_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            plan = _plan(work, transitions={"b2": {"type": "crossfade", "frames": 8}})
            with self.assertRaises(NativeRenderError) as ctx:
                native_render.build_beats_from_plan(
                    plan,
                    {"voice_texts": VOICE,
                     "transitions": {"b2": {"type": "dip_to_black", "frames": 8}}},
                    staging_root=work,
                )
        self.assertEqual(ctx.exception.code, "TRANSITION_MISMATCH")


if __name__ == "__main__":
    unittest.main()
