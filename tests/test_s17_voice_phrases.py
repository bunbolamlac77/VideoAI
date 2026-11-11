"""
tests/test_s17_voice_phrases.py — per-phrase TTS with exact cue offsets.

Why: the old flow guessed caption timing from word count (`words * 0.45 s`), so
subtitles drifted away from the voice. Voicing each phrase separately makes the
cue offsets exact by construction: the cue start/end are the real sample offsets
of that phrase inside the beat narration.

Rules under test:
  * cue offsets are derived from measured samples, not estimates;
  * gaps between phrases are counted exactly once;
  * the concatenated narration length equals the last cue end plus gaps;
  * bad phrase lists / speed / gap values are rejected;
  * real Kokoro synthesis is opt-in (`AIVIDEO_RUN_HEAVY_TTS=1`).
"""

from __future__ import annotations

import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import wave

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if _p.as_posix() not in sys.path:
        sys.path.insert(0, _p.as_posix())

from aivideo_workers.g3_engine import SAMPLES_PER_FRAME, voice_phrases
from aivideo_workers.tts_engine import TTS_PROFILE_ID

REAL_MODEL_DIR = Path.home() / "Library/Application Support/AIVideo/Models/tts_kokoro_vi"


class _FixedLengthTTS:
    """Each phrase becomes a deterministic, known number of samples."""

    def __init__(self, samples_per_phrase: int = 24_000) -> None:
        self.samples_per_phrase = samples_per_phrase

    def list_preset_voices(self):
        return [("Mai Linh", "mai_linh")]

    def infer(self, text, voice):
        return text

    def save(self, audio, path):
        with wave.open(path, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(48_000)
            wf.writeframes(struct.pack("<h", 512) * self.samples_per_phrase)


class TestExactPhraseOffsets(unittest.TestCase):
    def test_cue_offsets_come_from_real_sample_lengths(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            # 0.5 s per phrase => 12 frames per phrase at 24 fps.
            result = voice_phrases(
                {
                    "script_revision_id": "script-rev-1",
                    "beat_id": "beat-01",
                    "voice_id": "Mai Linh",
                    "phrases": ["Câu một.", "Câu hai.", "Câu ba."],
                    "staging_dir": tmp,
                },
                tts_factory=lambda: _FixedLengthTTS(samples_per_phrase=24_000),
            )
            self.assertEqual(result["status"], "staged_pending_core_publication_and_speech_review")
            self.assertEqual(result["model_profile_id"], TTS_PROFILE_ID)
            self.assertEqual(result["alignment_status"], "exact_phrase_sample_offsets")

            phrases = result["phrases"]
            self.assertEqual(len(phrases), 3)
            self.assertEqual(phrases[0]["start_sample"], 0)
            self.assertEqual(phrases[0]["end_sample"], 24_000)
            self.assertEqual(phrases[1]["start_sample"], 24_000)
            self.assertEqual(phrases[2]["end_sample"], 72_000)
            # 24 000 samples / 2 000 samples-per-frame = 12 frames
            self.assertEqual(phrases[2]["end_frame"], 72_000 // SAMPLES_PER_FRAME)
            self.assertEqual(result["total_frames"], 36)

    def test_gap_between_phrases_is_counted_once(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            result = voice_phrases(
                {
                    "script_revision_id": "s",
                    "beat_id": "b",
                    "voice_id": "Mai Linh",
                    "phrases": ["Một.", "Hai."],
                    "staging_dir": tmp,
                    "gap_frames": 6,
                },
                tts_factory=lambda: _FixedLengthTTS(samples_per_phrase=24_000),
            )
            gap_samples = 6 * SAMPLES_PER_FRAME
            self.assertEqual(result["phrases"][1]["start_sample"], 24_000 + gap_samples)
            self.assertEqual(result["combined_wav"]["samples"], 48_000 + gap_samples)
            with wave.open(result["combined_path"], "rb") as wf:
                self.assertEqual(wf.getnframes(), 48_000 + gap_samples)
                self.assertEqual(wf.getframerate(), 48_000)

    def test_rejects_bad_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = {
                "script_revision_id": "s",
                "beat_id": "b",
                "voice_id": "Mai Linh",
                "staging_dir": tmp,
            }
            with self.assertRaises(ValueError):
                voice_phrases({**base, "phrases": []}, tts_factory=_FixedLengthTTS)
            with self.assertRaises(ValueError):
                voice_phrases({**base, "phrases": ["  "]}, tts_factory=_FixedLengthTTS)
            with self.assertRaises(ValueError):
                voice_phrases({**base, "phrases": ["x"], "speed": 1.2},
                              tts_factory=_FixedLengthTTS)
            with self.assertRaises(ValueError):
                voice_phrases({**base, "phrases": ["x"], "gap_frames": 99},
                              tts_factory=_FixedLengthTTS)
            with self.assertRaises(ValueError):
                voice_phrases({**base, "phrases": ["x"], "voice_id": "Không Có"},
                              tts_factory=_FixedLengthTTS)

    def test_blocks_honestly_when_engine_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            previous = os.environ.get("AIVIDEO_TTS_MODEL_DIR")
            os.environ["AIVIDEO_TTS_MODEL_DIR"] = str(Path(tmp) / "absent")
            try:
                result = voice_phrases({
                    "script_revision_id": "s",
                    "beat_id": "b",
                    "voice_id": "Mai Linh",
                    "phrases": ["Một câu."],
                    "staging_dir": tmp,
                })
            finally:
                if previous is None:
                    os.environ.pop("AIVIDEO_TTS_MODEL_DIR", None)
                else:
                    os.environ["AIVIDEO_TTS_MODEL_DIR"] = previous
            self.assertEqual(result["status"], "blocked_tts_runtime_unavailable")
            self.assertEqual(list(Path(tmp).glob("g3_voice_phrases_*.wav")), [])


class TestRealPhraseSynthesis(unittest.TestCase):
    def test_real_kokoro_per_phrase_offsets(self) -> None:
        if os.environ.get("AIVIDEO_RUN_HEAVY_TTS") != "1":
            self.skipTest("Heavy real TTS synthesis; set AIVIDEO_RUN_HEAVY_TTS=1 to execute")
        if not (REAL_MODEL_DIR / "kokoro_vi.pth").is_file():
            self.skipTest(f"Kokoro-Vietnamese weights not installed at {REAL_MODEL_DIR}")
        with tempfile.TemporaryDirectory() as tmp:
            result = voice_phrases({
                "script_revision_id": "script-real",
                "beat_id": "beat-01",
                "voice_id": "Mai Linh",
                "phrases": [
                    "Tôi đi qua con đèo uốn lượn.",
                    "Hai bên là rừng thông.",
                ],
                "staging_dir": tmp,
            })
            self.assertEqual(result["status"], "staged_pending_core_publication_and_speech_review")
            phrases = result["phrases"]
            self.assertEqual(len(phrases), 2)
            self.assertEqual(phrases[0]["start_sample"], 0)
            self.assertEqual(phrases[1]["start_sample"], phrases[0]["end_sample"])
            self.assertGreater(phrases[0]["end_sample"], 48_000 * 0.5)
            self.assertEqual(result["combined_wav"]["samples"], phrases[1]["end_sample"])
            for path in result["phrase_paths"]:
                self.assertTrue(Path(path).is_file())
            self.assertTrue(Path(result["combined_path"]).is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
