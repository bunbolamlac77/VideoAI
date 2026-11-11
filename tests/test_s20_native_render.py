"""
tests/test_s20_native_render.py — ffmpeg native renderer (S20/S21/S22 replacement).

Rules under test:
  * hard cuts keep the exact planned frame count;
  * crossfade/dip-to-black *shorten* the timeline by exactly the overlap, and the
    .srt shifts with it so subtitles stay glued to the narration;
  * a photo insert is rendered as a still with a slow move and keeps its length;
  * captions only ever contain the approved cue text (no invented words);
  * a 2160x3840 24fps bt709 render passes the same technical contract the
    Resolve path had to pass;
  * invalid cues/transitions are rejected before any encoding starts.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if _p.as_posix() not in sys.path:
        sys.path.insert(0, _p.as_posix())

from aivideo_workers.native_render import (
    CaptionCue,
    NativeRenderError,
    RenderBeat,
    expected_total_frames,
    render_timeline,
    write_srt,
)

CORPUS = _ROOT / "fixtures" / "smoke"
CLIP_A = str(CORPUS / "trip-holdout-01-dalat.mp4")
CLIP_B = str(CORPUS / "trip-holdout-02-halong.mp4")


def _make_photo(directory: Path) -> str:
    path = directory / "photo.png"
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-f", "lavfi", "-i", "testsrc=size=1600x1200:duration=1",
         "-frames:v", "1", str(path)],
        check=True,
    )
    return str(path)


def _make_voice(directory: Path, seconds: float) -> str:
    path = directory / f"voice_{seconds}.wav"
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
         "-f", "lavfi", "-i", f"sine=frequency=220:duration={seconds}",
         "-ar", "48000", "-ac", "1", "-c:a", "pcm_s16le", str(path)],
        check=True,
    )
    return str(path)


class TestTimelineMath(unittest.TestCase):
    def test_expected_frames_subtract_only_transition_overlaps(self) -> None:
        beats = [
            RenderBeat("b1", "video", CLIP_A, 36),
            RenderBeat("b2", "video", CLIP_B, 36, transition_in="crossfade", transition_frames=12),
            RenderBeat("b3", "video", CLIP_A, 24, transition_in="dip_to_black", transition_frames=6),
        ]
        self.assertEqual(expected_total_frames(beats), 36 + 36 + 24 - 12 - 6)

    def test_validation_rejects_bad_cue(self) -> None:
        beat = RenderBeat("b1", "video", CLIP_A, 24, cues=[CaptionCue("x", 10, 99)])
        with self.assertRaises(NativeRenderError) as ctx:
            beat.validate()
        self.assertEqual(ctx.exception.code, "CUE_OUT_OF_RANGE")

    def test_validation_rejects_transition_longer_than_half_the_beat(self) -> None:
        beat = RenderBeat("b1", "video", CLIP_A, 24, transition_in="crossfade", transition_frames=20)
        with self.assertRaises(NativeRenderError) as ctx:
            beat.validate()
        self.assertEqual(ctx.exception.code, "INVALID_TRANSITION_LENGTH")

    def test_validation_rejects_missing_media(self) -> None:
        beat = RenderBeat("b1", "video", "/nope/missing.mp4", 24)
        with self.assertRaises(NativeRenderError) as ctx:
            beat.validate()
        self.assertEqual(ctx.exception.code, "MEDIA_MISSING")


class TestRenderOutput(unittest.TestCase):
    def test_hard_cut_keeps_exact_frame_count(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            voice = _make_voice(work, 1.2)
            beats = [
                RenderBeat("b1", "video", CLIP_A, 36, voice_path=voice,
                           cues=[CaptionCue("Tôi đi qua con đèo uốn lượn", 0, 20)]),
                RenderBeat("b2", "video", CLIP_B, 36,
                           cues=[CaptionCue("Hai bên là rừng thông", 0, 24)]),
            ]
            result = render_timeline(beats, work / "preview.mp4", width=540, height=960)
            self.assertEqual(result["status"], "RENDERED_VERIFIED")
            self.assertEqual(result["probe"]["frames"], 72)
            self.assertEqual(result["probe"]["width"], 540)
            self.assertEqual(result["probe"]["fps"], 24)
            self.assertEqual(result["transitions"], 0)

    def test_crossfade_shortens_timeline_and_srt_follows(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            beats = [
                RenderBeat("b1", "video", CLIP_A, 36,
                           cues=[CaptionCue("Cảnh một", 0, 24)]),
                RenderBeat("b2", "video", CLIP_B, 36, transition_in="crossfade",
                           transition_frames=8, cues=[CaptionCue("Cảnh hai", 0, 24)]),
            ]
            result = render_timeline(beats, work / "crossfade.mp4", width=540, height=960)
            self.assertEqual(result["probe"]["frames"], 64)
            self.assertEqual(result["transitions"], 1)

            srt = write_srt(beats, work / "crossfade.srt")
            self.assertEqual(srt["cues"], 2)
            lines = (work / "crossfade.srt").read_text(encoding="utf-8").splitlines()
            # beat 2 starts after 36 - 8 = 28 frames = 1.167 s
            self.assertIn("00:00:01,167 --> 00:00:02,167", lines)
            self.assertIn("Cảnh hai", lines)

    def test_photo_insert_renders_as_illustration(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            beats = [
                RenderBeat("b1", "video", CLIP_A, 36,
                           cues=[CaptionCue("Trước khi chụp", 0, 24)]),
                RenderBeat("b2", "photo", _make_photo(work), 24, transition_in="crossfade",
                           transition_frames=6,
                           cues=[CaptionCue("Ảnh chụp thung lũng", 2, 22)],
                           claim_refs=["illustrative_only"]),
            ]
            result = render_timeline(beats, work / "with_photo.mp4", width=540, height=960)
            self.assertEqual(result["probe"]["frames"], 36 + 24 - 6)
            self.assertEqual(result["photos"], 1)

    def test_srt_contains_only_approved_cue_text(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            beats = [
                RenderBeat("b1", "video", CLIP_A, 24,
                           cues=[CaptionCue("Câu đã duyệt thứ nhất", 0, 12),
                                 CaptionCue("Câu đã duyệt thứ hai", 12, 24)]),
            ]
            write_srt(beats, work / "a.srt")
            body = (work / "a.srt").read_text(encoding="utf-8")
            self.assertIn("Câu đã duyệt thứ nhất", body)
            self.assertIn("Câu đã duyệt thứ hai", body)
            self.assertEqual(body.count("-->"), 2)

    def test_4k_final_passes_the_resolve_contract(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            beats = [
                RenderBeat("b1", "video", CLIP_A, 36,
                           cues=[CaptionCue("Tôi đi qua con đèo uốn lượn", 0, 24)]),
                RenderBeat("b2", "video", CLIP_B, 36, transition_in="crossfade",
                           transition_frames=8, cues=[CaptionCue("Hai bên là rừng thông", 0, 24)]),
            ]
            result = render_timeline(beats, work / "final_4k.mp4", width=2160, height=3840)
            self.assertEqual(result["probe"]["frames"], 64)
            self.assertEqual(result["probe"]["width"], 2160)
            self.assertEqual(result["probe"]["height"], 3840)
            self.assertEqual(result["probe"]["color"], "bt709")
            self.assertEqual(result["probe"]["audio_codec"], "aac")


class TestRenderRPC(unittest.TestCase):
    """The worker RPC the app will call: explicit beats, guarded paths."""

    def _beats_payload(self, work: Path):
        voice = _make_voice(work, 1.2)
        return [
            {
                "beat_id": "b1", "kind": "video",
                "media_path": CLIP_A, "frames": 36, "voice_path": voice,
                "cues": [{"text": "Tôi đi qua con đèo", "start_frame": 0, "end_frame": 20}],
            },
            {
                "beat_id": "b2", "kind": "video",
                "media_path": CLIP_B, "frames": 36,
                "transition_in": "crossfade", "transition_frames": 8,
                "cues": [{"text": "Hai bên là rừng thông", "start_frame": 0, "end_frame": 24}],
            },
        ]

    def test_rpc_renders_and_writes_srt(self) -> None:
        from aivideo_workers import main

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            # Clips must live inside the managed root for the path guard.
            for src in (CLIP_A, CLIP_B):
                subprocess.run(["cp", src, str(work / Path(src).name)], check=True)
            payload = self._beats_payload(work)
            for beat in payload:
                beat["media_path"] = str(work / Path(beat["media_path"]).name)
            # (P1-15) the render root comes from the app environment
            with mock.patch.dict(os.environ, {"AIVIDEO_RENDER_ROOT": str(work)}):
                out = main.METHODS["video.render.native"]({
                    "beats": payload,
                    "output_path": str(work / "rpc_out.mp4"),
                    "width": 1080, "height": 1920,
                })
            self.assertEqual(out["status"], "RENDERED_VERIFIED")
            self.assertEqual(out["probe"]["frames"], 64)
            self.assertEqual(len(out["output_sha256"]), 64)
            self.assertTrue(Path(out["srt"]["path"]).is_file())

    def test_width_height_must_be_vertical_1080_or_4k(self) -> None:
        from aivideo_workers import main

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            subprocess.run(["cp", CLIP_A, str(work / "a.mp4")], check=True)
            with mock.patch.dict(os.environ, {"AIVIDEO_RENDER_ROOT": str(work)}):
                with self.assertRaises(ValueError):
                    main.METHODS["video.render.native"]({
                        "beats": [{"beat_id": "b1", "media_path": str(work / "a.mp4"), "frames": 12}],
                        "output_path": str(work / "x.mp4"),
                        "width": 1920, "height": 1080,
                    })

    def test_media_outside_root_is_refused(self) -> None:
        from aivideo_workers import main

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            with mock.patch.dict(os.environ, {"AIVIDEO_RENDER_ROOT": str(work)}):
                with self.assertRaises(NativeRenderError) as ctx:
                    main.METHODS["video.render.native"]({
                        "beats": [{"beat_id": "b1", "media_path": CLIP_A, "frames": 12}],
                        "output_path": str(work / "x.mp4"),
                        "width": 1080, "height": 1920,
                    })
            self.assertEqual(ctx.exception.code, "PATH_OUTSIDE_ROOT")

    def test_refuses_to_overwrite_existing_output(self) -> None:
        from aivideo_workers import main

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            subprocess.run(["cp", CLIP_A, str(work / "a.mp4")], check=True)
            (work / "taken.mp4").write_bytes(b"existing")
            with mock.patch.dict(os.environ, {"AIVIDEO_RENDER_ROOT": str(work)}):
                with self.assertRaises(NativeRenderError) as ctx:
                    main.METHODS["video.render.native"]({
                        "beats": [{"beat_id": "b1", "media_path": str(work / "a.mp4"), "frames": 12}],
                        "output_path": str(work / "taken.mp4"),
                        "width": 1080, "height": 1920,
                    })
            self.assertEqual(ctx.exception.code, "OUTPUT_EXISTS")

    def test_missing_render_root_blocks(self) -> None:
        from aivideo_workers import main

        previous = {k: os.environ.pop(k, None) for k in
                    ("AIVIDEO_RENDER_ROOT", "AIVIDEO_G4_WORK_ROOT", "AIVIDEO_G5_WORK_ROOT")}
        try:
            result = main.METHODS["video.render.native"]({"beats": []})
        finally:
            for key, value in previous.items():
                if value is not None:
                    os.environ[key] = value
        self.assertEqual(result["status"], "blocked_untrusted_render_root")


class TestPlanRendering(unittest.TestCase):
    """`render_from_plan` is what the G4/G5 RPCs use: plan bindings + cues."""

    def _plan(self, work: Path, *, text_a: str, text_b: str):
        import hashlib

        def sha(text: str) -> str:
            return hashlib.sha256(text.encode("utf-8")).hexdigest()

        clip_a = work / "clip_a.mp4"
        clip_b = work / "clip_b.mp4"
        subprocess.run(["cp", CLIP_A, str(clip_a)], check=True)
        subprocess.run(["cp", CLIP_B, str(clip_b)], check=True)
        voice_a = Path(_make_voice(work, 1.2))
        return {
            "plan_sha256": "a" * 64,
            "profile": "M-24-SDR-v1",
            "entries": [
                {"beat_id": "b1", "video_path": str(clip_a), "voice_path": str(voice_a),
                 "duration_frames": 36, "video_sha256": "1" * 64,
                 "voice_sha256": "2" * 64, "caption_text_sha256": sha(text_a)},
                {"beat_id": "b2", "video_path": str(clip_b), "voice_path": str(voice_a),
                 "duration_frames": 36, "video_sha256": "3" * 64,
                 "voice_sha256": "4" * 64, "caption_text_sha256": sha(text_b)},
            ],
        }

    def test_receipt_binds_plan_hashes_and_cue_text(self) -> None:
        from aivideo_workers.native_render import render_from_plan

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            text_a, text_b = "Tôi qua đèo Prenn.", "Hai bên là rừng thông."
            plan = self._plan(work, text_a=text_a, text_b=text_b)
            plan["transitions"] = {"b2": {"type": "crossfade", "frames": 8}}
            result = render_from_plan(
                plan,
                {
                    "voice_texts": {"b1": text_a, "b2": text_b},
                    "cues": {
                        "b1": [{"text": text_a, "start_frame": 0, "end_frame": 20}],
                        "b2": [{"text": text_b, "start_frame": 0, "end_frame": 24}],
                    },
                    "transitions": {"b2": {"type": "crossfade", "frames": 8}},
                },
                width=1080, height=1920, staging_root=work, out_path=work / "plan_out.mp4",
            )
            receipt = result["receipt"]
            self.assertEqual(result["status"], "NATIVE_RENDER_VERIFIED")
            self.assertEqual(receipt["schema"], "native-render-receipt-v1")
            self.assertEqual(receipt["plan_sha256"], "a" * 64)
            self.assertEqual(receipt["sum_beat_frames"], 72)
            self.assertEqual(receipt["transition_overlap_frames"], 8)
            self.assertEqual(receipt["total_frames"], 64)
            self.assertEqual(receipt["output"]["probe"]["frames"], 64)
            self.assertEqual(len(receipt["output"]["sha256"]), 64)
            self.assertEqual(receipt["beats"][0]["caption_text_sha256"],
                             plan["entries"][0]["caption_text_sha256"])
            self.assertIsNotNone(receipt["srt"])

    def test_altered_narration_is_refused(self) -> None:
        from aivideo_workers.native_render import NativeRenderError, render_from_plan

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            plan = self._plan(work, text_a="Câu gốc.", text_b="Câu hai.")
            with self.assertRaises(NativeRenderError) as ctx:
                render_from_plan(
                    plan,
                    {
                        "voice_texts": {"b1": "Câu đã bị sửa.", "b2": "Câu hai."},
                        "cues": {"b1": [{"text": "Câu đã bị sửa.", "start_frame": 0, "end_frame": 20}],
                                 "b2": [{"text": "Câu hai.", "start_frame": 0, "end_frame": 20}]},
                    },
                    width=1080, height=1920, staging_root=work,
                    out_path=work / "altered.mp4",
                )
            self.assertEqual(ctx.exception.code, "VOICE_TEXT_CHANGED")

    def test_caption_must_reproduce_narration(self) -> None:
        from aivideo_workers.native_render import NativeRenderError, render_from_plan

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            plan = self._plan(work, text_a="Câu gốc một hai ba.", text_b="Câu hai.")
            with self.assertRaises(NativeRenderError) as ctx:
                render_from_plan(
                    plan,
                    {
                        "voice_texts": {"b1": "Câu gốc một hai ba.", "b2": "Câu hai."},
                        "cues": {"b1": [{"text": "Câu gốc một.", "start_frame": 0, "end_frame": 20}],
                                 "b2": [{"text": "Câu hai.", "start_frame": 0, "end_frame": 20}]},
                    },
                    width=1080, height=1920, staging_root=work,
                    out_path=work / "bad_caption.mp4",
                )
            self.assertEqual(ctx.exception.code, "CAPTION_TEXT_MISMATCH")

    def test_photo_insert_is_labelled_illustrative(self) -> None:
        from aivideo_workers.native_render import render_from_plan

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            text_a, text_b = "Tôi qua đèo Prenn.", "Hai bên là rừng thông."
            plan = self._plan(work, text_a=text_a, text_b=text_b)
            photo = Path(_make_photo(work))
            result = render_from_plan(
                plan,
                {
                    "voice_texts": {"b1": text_a, "b2": text_b},
                    "cues": {
                        "b1": [{"text": text_a, "start_frame": 0, "end_frame": 20}],
                        "b2": [{"text": text_b, "start_frame": 0, "end_frame": 24}],
                    },
                    "photo_inserts": [{
                        "after_beat_id": "b1", "path": str(photo), "frames": 24,
                        # (P1-32) the insert cites the approved photo's bytes AND the S08
                        # publication it was committed under
                        "photo_sha256": hashlib.sha256(photo.read_bytes()).hexdigest(),
                        "photo_publication_id": "00000000-0000-4000-8000-000000000321",
                        "cues": [{"text": "Ảnh chụp thung lũng", "start_frame": 2, "end_frame": 22}],
                    }],
                },
                width=1080, height=1920, staging_root=work, out_path=work / "with_photo.mp4",
            )
            receipt = result["receipt"]
            photo_entries = [b for b in receipt["beats"] if b.get("kind") == "photo_insert"]
            self.assertEqual(len(photo_entries), 1)
            self.assertEqual(photo_entries[0]["usage"], "illustrative_only")
            self.assertEqual(receipt["sum_beat_frames"], 36 + 24 + 36)
            self.assertEqual(receipt["transition_overlap_frames"], 6)
            self.assertEqual(receipt["total_frames"], 90)


    def test_preburned_captions_skip_second_burn(self) -> None:
        from aivideo_workers.native_render import render_from_plan

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            text_a, text_b = "Câu một.", "Câu hai."
            plan = self._plan(work, text_a=text_a, text_b=text_b)
            result = render_from_plan(
                plan,
                {"voice_texts": {"b1": text_a, "b2": text_b}},  # no cues
                width=1080, height=1920, staging_root=work, out_path=work / "preburned.mp4",
            )
            receipt = result["receipt"]
            self.assertEqual(receipt["total_frames"], 72)
            self.assertTrue(all(b["caption_mode"] == "preburned_in_segment" for b in receipt["beats"]))
            self.assertIsNotNone(receipt["srt"])  # sidecar still emitted (empty of cues)

    def test_photo_outside_root_is_refused(self) -> None:
        from aivideo_workers.native_render import NativeRenderError, render_from_plan

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            text_a, text_b = "Câu một.", "Câu hai."
            plan = self._plan(work, text_a=text_a, text_b=text_b)
            outside = Path(tempfile.mkdtemp())
            photo = Path(_make_photo(outside))
            with self.assertRaises(NativeRenderError) as ctx:
                render_from_plan(
                    plan,
                    {
                        "voice_texts": {"b1": text_a, "b2": text_b},
                        "cues": {"b1": [{"text": text_a, "start_frame": 0, "end_frame": 20}],
                                 "b2": [{"text": text_b, "start_frame": 0, "end_frame": 20}]},
                        "photo_inserts": [{
                            "after_beat_id": "b1", "path": str(photo), "frames": 24,
                            # (P1-32) a declared hash + publication are required; the path
                            # guard must still win
                            "photo_sha256": "0" * 64,
                            "photo_publication_id": "00000000-0000-4000-8000-000000000322",
                        }],
                    },
                    width=1080, height=1920, staging_root=work, out_path=work / "x.mp4",
                )
            self.assertEqual(ctx.exception.code, "PATH_OUTSIDE_ROOT")


class TestNativeReceiptsMatchStoreContract(unittest.TestCase):
    """The receipts must satisfy `approveG4Preview` / `approveG5Final` checks."""

    def _plan(self, work: Path, *, width_ok: bool = True):
        import hashlib
        import uuid

        text = "Câu đã duyệt."
        clip = work / "clip.mp4"
        subprocess.run(["cp", CLIP_A, str(clip)], check=True)
        voice = Path(_make_voice(work, 1.2))
        return {
            "plan_sha256": "b" * 64,
            "profile": "M-24-SDR-v1",
            "g3_approval_id": str(uuid.uuid4()).upper(),
            "g3_manifest_sha256": "c" * 64,
            "g4_approval_id": str(uuid.uuid4()).upper(),
            "g4_preview_sha256": "d" * 64,
            "cut_publication_id": str(uuid.uuid4()).upper(),
            "g4_preview_publication_id": str(uuid.uuid4()).upper(),
            "total_frames": 36,
            "entries": [{
                "beat_id": "b1", "video_path": str(clip), "voice_path": str(voice),
                "duration_frames": 36, "video_sha256": "1" * 64,
                "voice_sha256": "2" * 64,
                "caption_text_sha256": hashlib.sha256(text.encode()).hexdigest(),
                "video_publication_id": str(uuid.uuid4()).upper(),
                "receipt_publication_id": str(uuid.uuid4()).upper(),
                "mapping_publication_id": str(uuid.uuid4()).upper(),
                "voice_publication_id": str(uuid.uuid4()).upper(),
            }],
            "_voice_text": text,
        }

    def test_g4_receipt_satisfies_preview_approval(self) -> None:
        import uuid
        from unittest import mock
        from aivideo_workers import g4_core, native_render

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            plan = self._plan(work)
            text = plan.pop("_voice_text")
            env = {"AIVIDEO_RENDER_ROOT": str(work)}
            with mock.patch.dict(os.environ, env), \
                 mock.patch.object(g4_core, "approved_plan", return_value=plan):
                out = native_render.render_g4_native({
                    "db_path": str(work / "db.sqlite"),
                    "project_id": str(uuid.uuid4()).upper(),
                    "assets": [],
                    "voice_texts": {"b1": text},
                })
            receipt = out["receipt"]
            self.assertEqual(receipt["status"], "PREVIEW_TECHNICAL_PASS_CONTENT_REVIEW_REQUIRED")
            self.assertEqual(len(receipt["timeline_signature"]), 64)
            self.assertTrue(receipt["timeline_uid"].startswith("ffmpeg-native:"))
            self.assertTrue(receipt["render_job_id"])
            self.assertEqual(receipt["qc"]["status"], "TECHNICAL_PASS_CONTENT_REVIEW_REQUIRED")
            self.assertEqual(receipt["qc"]["sha256"], receipt["preview_sha256"])
            self.assertEqual(receipt["qc"]["verified"]["width"], 1080)
            self.assertEqual(receipt["qc"]["verified"]["height"], 1920)
            self.assertFalse(receipt["qc"]["semantic_verified"])
            self.assertGreaterEqual(len(receipt["required_publication_ids"]), 5)
            for dep in receipt["required_publication_ids"]:
                uuid.UUID(dep)
            self.assertTrue(Path(out["receipt_path"]).is_file())

    def test_g5_receipt_satisfies_final_approval(self) -> None:
        import uuid
        from unittest import mock
        from aivideo_workers import g5_final, native_render

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            plan = self._plan(work)
            text = plan.pop("_voice_text")
            env = {"AIVIDEO_RENDER_ROOT": str(work)}
            with mock.patch.dict(os.environ, env), \
                 mock.patch.object(g5_final, "approved_final_plan", return_value=plan):
                out = native_render.render_g5_native({
                    "db_path": str(work / "db.sqlite"),
                    "project_id": str(uuid.uuid4()).upper(),
                    "assets": [],
                    "voice_texts": {"b1": text},
                })
            receipt = out["receipt"]
            self.assertEqual(receipt["status"], "FINAL_TECHNICAL_PASS_HUMAN_RELEASE_REVIEW_REQUIRED")
            self.assertEqual(receipt["qc"]["verified"]["width"], 2160)
            self.assertEqual(receipt["qc"]["verified"]["height"], 3840)
            self.assertEqual(len(receipt["final_sha256"]), 64)
            self.assertEqual(len(receipt["drp_sha256"]), 64)
            self.assertEqual(receipt["drp_path"], out["receipt_path"])
            self.assertTrue(Path(receipt["drp_path"]).is_file())
            self.assertEqual(out["status"], "NATIVE_FINAL_VERIFIED")


if __name__ == "__main__":
    unittest.main(verbosity=2)
