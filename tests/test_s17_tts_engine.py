"""
tests/test_s17_tts_engine.py — Kokoro-Vietnamese TTS integration (S17).

Rules under test:
  * voices come from the local `voices.json` manifest; a missing label is refused
    instead of silently substituting another narrator;
  * `save()` always yields the pipeline's canonical PCM16 mono 48 kHz WAV, even
    though the engine natively emits 24 kHz;
  * a missing weight directory degrades to `blocked_tts_runtime_unavailable`
    rather than inventing audio;
  * real synthesis is opt-in (`AIVIDEO_RUN_HEAVY_TTS=1`) so CI without weights
    records a SKIP instead of a fake PASS.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import wave

import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if _p.as_posix() not in sys.path:
        sys.path.insert(0, _p.as_posix())

from aivideo_workers.g3_engine import voice_trial
from aivideo_workers.tts_engine import (
    CANONICAL_SAMPLE_RATE,
    NATIVE_SAMPLE_RATE,
    TTS_PROFILE_ID,
    KokoroVietnameseTTSEngine,
    TTSEngineUnavailable,
    probe_engine,
    resolve_tts_model_dir,
)

REAL_MODEL_DIR = Path.home() / "Library/Application Support/AIVideo/Models/tts_kokoro_vi"


def _fake_model_dir(root: Path) -> Path:
    """Minimal weight layout: manifest + two voicepacks + placeholder weights."""
    model_dir = root / "tts_kokoro_vi"
    (model_dir / "voicepacks").mkdir(parents=True)
    (model_dir / "config.json").write_text("{}", encoding="utf-8")
    (model_dir / "kokoro_vi.pth").write_bytes(b"not-real-weights")
    for key in ("mai_linh", "my_yen"):
        (model_dir / "voicepacks" / f"{key}.pt").write_bytes(b"voicepack")
    (model_dir / "voices.json").write_text(
        json.dumps({
            "mai_linh": {"label": "Mai Linh", "filename": "voicepacks/mai_linh.pt"},
            "my_yen": {"label": "Mỹ Yến", "filename": "voicepacks/my_yen.pt"},
            "missing": {"label": "Thiếu File", "filename": "voicepacks/absent.pt"},
        }),
        encoding="utf-8",
    )
    return model_dir


class TestTTSVoiceManifest(unittest.TestCase):
    def test_manifest_lists_only_existing_voicepacks(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            model_dir = _fake_model_dir(Path(tmp))
            engine = KokoroVietnameseTTSEngine(model_dir=str(model_dir))
            self.assertEqual(
                engine.list_preset_voices(),
                [("Mai Linh", "mai_linh"), ("Mỹ Yến", "my_yen")],
            )

    def test_label_and_key_both_resolve(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            engine = KokoroVietnameseTTSEngine(model_dir=str(_fake_model_dir(Path(tmp))))
            self.assertEqual(engine._resolve_key("Mai Linh"), "mai_linh")
            self.assertEqual(engine._resolve_key("mai_linh"), "mai_linh")

    def test_unknown_voice_is_refused_not_substituted(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            engine = KokoroVietnameseTTSEngine(model_dir=str(_fake_model_dir(Path(tmp))))
            with self.assertRaises(ValueError) as ctx:
                engine._resolve_key("Giọng Không Có")
            message = str(ctx.exception)
            self.assertIn("not an installed Kokoro-Vietnamese preset", message)
            self.assertIn("Mai Linh", message)  # lists what would be valid

    def test_missing_weights_raise_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(TTSEngineUnavailable):
                KokoroVietnameseTTSEngine(model_dir=str(Path(tmp) / "absent"))
            report = probe_engine(str(Path(tmp) / "absent"))
            self.assertFalse(report["weights_available"])
            self.assertEqual(report["profile_id"], TTS_PROFILE_ID)


class TestCanonicalWavOutput(unittest.TestCase):
    def test_save_resamples_to_48k_pcm16_mono(self) -> None:
        import numpy as np

        with tempfile.TemporaryDirectory() as tmp:
            engine = KokoroVietnameseTTSEngine(model_dir=str(_fake_model_dir(Path(tmp))))
            seconds = 0.5
            t = np.arange(int(NATIVE_SAMPLE_RATE * seconds)) / NATIVE_SAMPLE_RATE
            audio = 0.25 * np.sin(2 * np.pi * 180.0 * t).astype("float32")
            target = Path(tmp) / "beat.wav"
            engine.save(audio, str(target))
            with wave.open(str(target), "rb") as wf:
                self.assertEqual(wf.getframerate(), CANONICAL_SAMPLE_RATE)
                self.assertEqual(wf.getnchannels(), 1)
                self.assertEqual(wf.getsampwidth(), 2)
                self.assertAlmostEqual(wf.getnframes() / CANONICAL_SAMPLE_RATE, seconds, delta=0.02)

    def test_silent_audio_is_rejected(self) -> None:
        import numpy as np

        with tempfile.TemporaryDirectory() as tmp:
            engine = KokoroVietnameseTTSEngine(model_dir=str(_fake_model_dir(Path(tmp))))
            with self.assertRaises(ValueError):
                engine.save(np.zeros(NATIVE_SAMPLE_RATE, dtype="float32"), str(Path(tmp) / "s.wav"))


class TestVoiceTrialBlocking(unittest.TestCase):
    def test_missing_engine_blocks_instead_of_faking_audio(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            previous = os.environ.get("AIVIDEO_TTS_MODEL_DIR")
            os.environ["AIVIDEO_TTS_MODEL_DIR"] = str(Path(tmp) / "absent")
            try:
                result = voice_trial({
                    "script_revision_id": "script-rev-1",
                    "beat_id": "beat-01",
                    "voice_text": "Một câu tiếng Việt.",
                    "voice_id": "Mai Linh",
                    "staging_dir": tmp,
                })
            finally:
                if previous is None:
                    os.environ.pop("AIVIDEO_TTS_MODEL_DIR", None)
                else:
                    os.environ["AIVIDEO_TTS_MODEL_DIR"] = previous
            self.assertEqual(result["status"], "blocked_tts_runtime_unavailable")
            self.assertIn("kokoro-vietnamese", result["required"])
            self.assertFalse(list(Path(tmp).glob("g3_voice_*.wav")))


class TestRealSynthesis(unittest.TestCase):
    def test_real_kokoro_synthesis_end_to_end(self) -> None:
        if os.environ.get("AIVIDEO_RUN_HEAVY_TTS") != "1":
            self.skipTest("Heavy real TTS synthesis; set AIVIDEO_RUN_HEAVY_TTS=1 to execute")
        if not (REAL_MODEL_DIR / "kokoro_vi.pth").is_file():
            self.skipTest(f"Kokoro-Vietnamese weights not installed at {REAL_MODEL_DIR}")
        with tempfile.TemporaryDirectory() as tmp:
            result = voice_trial({
                "script_revision_id": "script-rev-real",
                "beat_id": "beat-01",
                "voice_text": "Hôm nay trời trong xanh, gió thổi nhẹ qua hiên nhà.",
                "voice_id": "Mai Linh",
                "staging_dir": tmp,
            })
            self.assertTrue(result["status"].startswith("staged_pending"), result)
            self.assertEqual(result["model_profile_id"], TTS_PROFILE_ID)
            self.assertEqual(result["speed"], 1.0)
            wav = result["wav"]
            self.assertEqual(wav["sample_rate"], CANONICAL_SAMPLE_RATE)
            self.assertEqual(wav["channels"], 1)
            self.assertGreater(wav["duration_seconds"], 0.5)
            self.assertTrue(Path(result["staging_path"]).is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
