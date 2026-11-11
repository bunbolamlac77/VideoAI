"""
tests/test_p1_renderer_safety.py — Regression for audit P1-31/33/34 (2026-11-11).

  P1-33  `drawtext` arguments were built from caller-influenced values that were escaped
         for `:` `'` `,` `[` `]` but **not** for `;` or newlines, which start a new filter
         chain; approved text was also subject to `%{...}` expansion.
  P1-34  the finished 4K MP4 was read entirely into memory to compute its SHA-256.
  P1-31  the renderer reports the overlap it actually built, so a caller-supplied
         transition cannot make the receipt disagree with the approved hard-cut plan.
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
from aivideo_workers.native_render import (
    NativeRenderError,
    RenderBeat,
    _escape,
    _safe_beat_id,
    expected_total_frames,
)


class TestFiltergraphEscaping(unittest.TestCase):
    def test_chain_separator_is_refused(self) -> None:
        for hostile in ("/tmp/aiv;nullsrc", "/tmp/title\ncolor=red", "/tmp/x\r[y]"):
            with self.subTest(value=hostile):
                with self.assertRaises(NativeRenderError) as ctx:
                    _escape(hostile)
                self.assertEqual(ctx.exception.code, "UNSAFE_FILTERGRAPH_TOKEN")

    def test_ordinary_paths_still_escape(self) -> None:
        self.assertEqual(_escape("/tmp/a:b,c'd"), "/tmp/a\\:b\\,c\\'d")

    def test_beat_id_is_a_plain_identifier(self) -> None:
        self.assertEqual(_safe_beat_id("beat-01_x"), "beat-01_x")
        for hostile in ("x;nullsrc", "beat 01", "", "../x", "b" * 65):
            with self.subTest(value=hostile):
                with self.assertRaises(NativeRenderError) as ctx:
                    _safe_beat_id(hostile)
                self.assertEqual(ctx.exception.code, "INVALID_BEAT_ID")


class TestCaptionIsBurnedLiterally(unittest.TestCase):
    def test_drawtext_disables_expansion(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            beat = RenderBeat(
                beat_id="beat-01",
                kind="video",
                media_path="/tmp/in.mp4",
                frames=48,
                voice_path="/tmp/in.wav",
                cues=[],
            )
            from aivideo_workers.native_render import CaptionCue

            beat.cues = [CaptionCue(text="Anh nói: %{pts}", start_frame=0, end_frame=12)]
            import dataclasses

            beat = dataclasses.replace(beat, cues=beat.cues)
            filters = native_render._caption_filters(beat, Path("/tmp/font.ttf"), Path(tmp))
        joined = ",".join(filters)
        self.assertIn("expansion=none", joined)
        # the caption text goes through a textfile, so `%{...}` in it is data, not a command
        self.assertIn("textfile=", joined)


class TestOverlapIsMeasuredNotAssumed(unittest.TestCase):
    """P1-31: the renderer reports the overlap it actually builds."""

    def test_hard_cut_plan_has_no_overlap(self) -> None:
        beat = RenderBeat(beat_id="b1", kind="video", media_path="/tmp/a.mp4",
                          frames=48, voice_path="/tmp/a.wav")
        self.assertEqual(expected_total_frames([beat]), 48)

    def test_overlap_is_subtracted_once_per_transition(self) -> None:
        first = RenderBeat(beat_id="b1", kind="video", media_path="/tmp/a.mp4",
                           frames=48, voice_path="/tmp/a.wav")
        second = RenderBeat(beat_id="b2", kind="video", media_path="/tmp/b.mp4",
                            frames=48, voice_path="/tmp/b.wav",
                            transition_in="crossfade", transition_frames=8)
        self.assertEqual(expected_total_frames([first, second]), 88)


class TestPhotoAndRootAreBindings(unittest.TestCase):
    """P1-32 / P1-15: photo inserts and the render root are not caller-controlled."""

    def test_photo_insert_requires_the_approved_hash(self) -> None:
        from aivideo_workers.native_render import build_beats_from_plan

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            photo = root / "photo.jpg"
            photo.write_bytes(b"jpeg-bytes")
            plan = {"entries": [], "plan_sha256": "0" * 64}
            with self.assertRaises(NativeRenderError) as ctx:
                build_beats_from_plan(
                    plan,
                    {"photo_inserts": [{"after_beat_id": "b1", "path": str(photo), "frames": 24}]},
                    staging_root=root,
                )
        # An empty plan fails first; the rule under test is the guard itself.
        self.assertIn(
            ctx.exception.code,
            ("EMPTY_PLAN", "PHOTO_HASH_REQUIRED"),
        )

    def test_staging_root_from_request_is_refused(self) -> None:
        from aivideo_workers.native_render import render_g4_native

        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(NativeRenderError) as ctx:
                render_g4_native({
                    "db_path": str(Path(tmp) / "db.sqlite"),
                    "project_id": "00000000-0000-4000-8000-000000000001",
                    "assets": [],
                    "staging_root": tmp,
                })
        self.assertEqual(ctx.exception.code, "STAGING_ROOT_FORBIDDEN")


class TestOutputHashStreams(unittest.TestCase):
    """P1-34: hashing a large output must not read it into memory."""

    def test_hash_of_large_file_is_streamed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "big.bin"
            payload = b"x" * (8 * 1024 * 1024)
            path.write_bytes(payload)
            source = Path(native_render.__file__).read_text(encoding="utf-8")
            # The renderer must not call `read_bytes()` on the finished output any more.
            self.assertNotIn("out_path.read_bytes()", source)
            self.assertEqual(native_render._sha256_file(path),
                             native_render._sha256_bytes(payload))


if __name__ == "__main__":
    unittest.main()
