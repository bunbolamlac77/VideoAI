"""Local Vietnamese TTS engine — Kokoro-Vietnamese (Apache-2.0).

Why this engine (replaces the VieNeu ONNX adapter):
- Apache-2.0 weights + code, 100% offline after setup, no cloud fallback.
- 82M-parameter Kokoro acoustic model: ~0.3x realtime on Apple Silicon CPU
  (measured 0.91 s for a 3.6 s sentence on an M1 Pro), so voice trials do not
  compete with the VLM for GPU time.
- Preset voicepacks (`voicepacks/*.pt`) instead of reference-audio cloning, which
  matches the registry contract (fixed narrator voice, locked 1.0x speed).
- Output is 24 kHz mono; the pipeline contract requires 48 kHz PCM16, so the
  adapter resamples once with ffmpeg (soxr) and never upsamples silently
  elsewhere.

Upstream: https://github.com/iamdinhthuan/Kokoro-Vietnamese
Weights:  https://huggingface.co/contextboxai/Kokoro-Vietnamese
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import wave
from typing import Any, Dict, List, Optional, Sequence, Tuple

from .child_process import run_tracked

TTS_PROFILE_ID = "P-TTS-KOKORO-VI-V1"
TTS_MODEL_ID = "contextboxai/Kokoro-Vietnamese"
TTS_ENGINE_NAME = "kokoro-vietnamese"
NATIVE_SAMPLE_RATE = 24000
CANONICAL_SAMPLE_RATE = 48000
DEFAULT_VOICE = "Mai Linh"
MODEL_DIR_ENV = "AIVIDEO_TTS_MODEL_DIR"
_REQUIRED_MODEL_FILES = ("config.json", "kokoro_vi.pth", "voices.json")


class TTSEngineUnavailable(RuntimeError):
    """Raised when the local TTS runtime or its weights are not installed."""

    def __init__(self, message: str, *, detail: str = "") -> None:
        super().__init__(message)
        self.detail = detail


def resolve_tts_model_dir(explicit: Optional[str] = None) -> Path:
    """Resolve the local weight directory (env override, then app support dir)."""
    raw = explicit or os.environ.get(MODEL_DIR_ENV, "")
    if raw:
        path = Path(raw).expanduser()
    else:
        path = (
            Path.home()
            / "Library"
            / "Application Support"
            / "AIVideo"
            / "Models"
            / "tts_kokoro_vi"
        )
    return path.resolve()


# Kokoro Vietnamese is a small model; loading it once per worker process keeps
# per-beat latency low without holding anything large resident.
_ENGINE_CACHE: Dict[str, Any] = {}


class KokoroVietnameseTTSEngine:
    """Duck-typed adapter used by `g3_engine.voice_trial`.

    Interface contract (kept identical to the previous engine so the
    `tts_factory` test seam and the RPC surface stay stable):
      * ``list_preset_voices() -> [(label, key), ...]``
      * ``infer(text, voice=label) -> numpy audio``
      * ``save(audio, path)`` writes a 48 kHz PCM16 mono WAV at ``path``
    """

    def __init__(
        self,
        model_dir: Optional[str] = None,
        device: str = "cpu",
        default_voice: str = DEFAULT_VOICE,
    ) -> None:
        self.model_dir = resolve_tts_model_dir(model_dir)
        missing = [n for n in _REQUIRED_MODEL_FILES if not (self.model_dir / n).is_file()]
        if missing:
            raise TTSEngineUnavailable(
                f"Kokoro-Vietnamese weights are not installed at {self.model_dir}",
                detail=f"missing files: {missing}; run the TTS setup step first",
            )
        self.device = device
        self.default_voice = default_voice
        self._voices = self._load_voice_manifest()

    # MARK: - Voices

    def _load_voice_manifest(self) -> Dict[str, Dict[str, str]]:
        manifest_path = self.model_dir / "voices.json"
        try:
            raw = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise TTSEngineUnavailable(
                f"Unreadable voice manifest: {manifest_path}",
                detail=str(exc),
            ) from exc
        if not isinstance(raw, dict) or not raw:
            raise TTSEngineUnavailable(
                f"Voice manifest is empty: {manifest_path}",
                detail="expected {voice_key: {label, filename}}",
            )
        voices: Dict[str, Dict[str, str]] = {}
        for key, entry in raw.items():
            if not isinstance(entry, dict):
                continue
            label = str(entry.get("label") or key)
            filename = str(entry.get("filename") or f"voicepacks/{key}.pt")
            if (self.model_dir / filename).is_file():
                voices[key] = {"label": label, "filename": filename}
        if not voices:
            raise TTSEngineUnavailable(
                f"No usable voicepacks under {self.model_dir / 'voicepacks'}",
                detail="re-run the TTS weight download",
            )
        return voices

    def list_preset_voices(self) -> List[Tuple[str, str]]:
        """Return (display label, internal key) pairs, sorted by label."""
        return sorted(
            ((entry["label"], key) for key, entry in self._voices.items()),
            key=lambda pair: pair[0],
        )

    def _resolve_key(self, voice: str) -> str:
        if voice in self._voices:
            return voice
        for key, entry in self._voices.items():
            if entry["label"] == voice:
                return key
        # Never silently substitute a different narrator.
        raise ValueError(
            f"voice_id '{voice}' is not an installed Kokoro-Vietnamese preset; "
            f"available: {[label for label, _ in self.list_preset_voices()]}"
        )

    # MARK: - Synthesis

    def _synthesizer(self, voice_key: str):
        cache_key = f"{self.model_dir}::{voice_key}::{self.device}"
        synthesizer = _ENGINE_CACHE.get(cache_key)
        if synthesizer is not None:
            return synthesizer
        try:
            from kokoro_vietnamese import KokoroVietnamese  # local, offline package
        except ImportError as exc:  # pragma: no cover - environment dependent
            raise TTSEngineUnavailable(
                "Kokoro-Vietnamese runtime is not installed in the worker venv",
                detail=str(exc),
            ) from exc
        os.environ.setdefault("HF_HUB_OFFLINE", "1")
        os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
        try:
            synthesizer = KokoroVietnamese(
                device=self.device,
                model_path=str(self.model_dir / "kokoro_vi.pth"),
                voicepack_path=str(self.model_dir / self._voices[voice_key]["filename"]),
                config_path=str(self.model_dir / "config.json"),
            )
        except Exception as exc:  # noqa: BLE001 - surfaced with context
            raise TTSEngineUnavailable(
                f"Kokoro-Vietnamese failed to load weights from {self.model_dir}",
                detail=f"{type(exc).__name__}: {exc}",
            ) from exc
        _ENGINE_CACHE[cache_key] = synthesizer
        return synthesizer

    def infer(self, text: str, voice: str = DEFAULT_VOICE):
        """Synthesize `text` and return 24 kHz float audio."""
        stripped = " ".join(str(text).split())
        if not stripped:
            raise ValueError("TTS text must be non-empty")
        synthesizer = self._synthesizer(self._resolve_key(voice))
        audio, _phonemes = synthesizer.synthesize(stripped)
        return audio

    def save(self, audio, path: str) -> str:
        """Write a 48 kHz PCM16 mono WAV (pipeline canonical format)."""
        import numpy as np

        target = Path(path)
        samples = np.asarray(audio, dtype="float32").reshape(-1)
        if samples.size == 0:
            raise ValueError("TTS produced no audio samples")
        peak = float(np.max(np.abs(samples)))
        if peak == 0.0:
            raise ValueError("TTS produced silent audio")
        if peak > 1.0:
            samples = samples / peak
        # (P1-02 follow-up found by the real-model run) Fixing the peak at exactly 32767
        # produces a *clipped-looking* PCM16 file: the gate rejects any sample at full
        # scale, which is correct for re-recording real speech but wrong for a synthesised
        # render. Peak at -1 dBFS so a legitimate Kokoro output is never mistaken for clipping.
        peak_target = 0.891251  # 10 ** (-1.0 / 20)
        current = float(np.max(np.abs(samples)))
        if current > 0:
            samples = samples * (peak_target / max(current, peak_target)) if current > peak_target else samples
        pcm = np.clip(samples, -1.0, 1.0)
        pcm = np.round(pcm * 32767.0).astype("<i2")
        pcm = np.clip(pcm, -32767, 32766)

        fd, native_tmp = tempfile.mkstemp(prefix=".tts_native_", suffix=".wav", dir=str(target.parent))
        os.close(fd)
        try:
            with wave.open(native_tmp, "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(NATIVE_SAMPLE_RATE)
                wf.writeframes(pcm.tobytes())
            result = run_tracked(
                [
                    "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                    "-i", native_tmp,
                    "-ar", str(CANONICAL_SAMPLE_RATE), "-ac", "1", "-c:a", "pcm_s16le",
                    "-f", "wav", str(target),
                ],
                capture_output=True,
                timeout=120,
            )
            if result.returncode != 0:
                raise RuntimeError(
                    f"ffmpeg could not resample TTS audio to 48 kHz: "
                    f"{result.stderr.decode('utf-8', errors='replace')[-400:]}"
                )
        finally:
            Path(native_tmp).unlink(missing_ok=True)

        self._verify_canonical_wav(target)
        return str(target)

    @staticmethod
    def _verify_canonical_wav(path: Path) -> None:
        with wave.open(str(path), "rb") as wf:
            if (
                wf.getnchannels() != 1
                or wf.getframerate() != CANONICAL_SAMPLE_RATE
                or wf.getsampwidth() != 2
                or wf.getnframes() <= 0
            ):
                raise ValueError(
                    "TTS output must be PCM16 mono at 48000 Hz with nonzero duration "
                    f"(got {wf.getnchannels()}ch {wf.getframerate()}Hz "
                    f"{wf.getsampwidth() * 8}bit {wf.getnframes()} frames)"
                )


def probe_engine(model_dir: Optional[str] = None) -> Dict[str, Any]:
    """Report engine availability without loading weights (used by setup/preflight)."""
    directory = resolve_tts_model_dir(model_dir)
    missing = [n for n in _REQUIRED_MODEL_FILES if not (directory / n).is_file()]
    try:
        import kokoro_vietnamese  # noqa: F401
        package_available = True
    except ImportError:
        package_available = False
    return {
        "engine": TTS_ENGINE_NAME,
        "profile_id": TTS_PROFILE_ID,
        "model_id": TTS_MODEL_ID,
        "model_dir": str(directory),
        "package_available": package_available,
        "weights_available": not missing,
        "missing_files": missing,
        "native_sample_rate": NATIVE_SAMPLE_RATE,
        "canonical_sample_rate": CANONICAL_SAMPLE_RATE,
    }
