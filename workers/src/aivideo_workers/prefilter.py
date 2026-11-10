"""
workers/src/aivideo_workers/prefilter.py — cheap motion prefilter for Gate G2.

Why: one 16-frame window costs ~24 s of Qwen3-VL prefill on an M1 Pro. Most POV
footage is static (road, sky, waiting), so running the vision model on every window
makes a 60 s clip cost hours. This module scans a heavily downscaled grayscale
stream (one ffmpeg pass, a few hundred bytes per sample) and decides which windows
are worth sending to the model.

Honesty rules (do not weaken):
  * a skipped window is recorded with its score and reason — it is never counted as
    analyzed, and it produces no observation;
  * coverage still uses "frames actually submitted to the model / declared frames";
  * the decision must be deterministic for the same source + config, because it is
    persisted with the checkpoint.
"""

from __future__ import annotations

import dataclasses
import hashlib
import math
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from .child_process import run_tracked


class PrefilterError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclasses.dataclass(frozen=True)
class PrefilterConfig:
    enabled: bool = False
    sample_fps: float = 2.0
    motion_threshold: float = 0.02
    width: int = 32
    height: int = 18
    always_analyze_first_window: bool = True

    def __post_init__(self) -> None:
        if self.sample_fps <= 0 or self.sample_fps > 10:
            raise PrefilterError("INVALID_SAMPLE_FPS", "sample_fps must be in (0, 10]")
        if not 0.0 <= self.motion_threshold <= 1.0:
            raise PrefilterError("INVALID_MOTION_THRESHOLD", "motion_threshold must be in [0, 1]")
        if self.width <= 0 or self.height <= 0:
            raise PrefilterError("INVALID_SCALE", "width/height must be positive")

    def fingerprint_payload(self) -> Dict[str, Any]:
        return {
            "always_analyze_first_window": self.always_analyze_first_window,
            "height": self.height,
            "motion_threshold": self.motion_threshold,
            "sample_fps": self.sample_fps,
            "width": self.width,
        }


def config_from_params(params: Optional[Dict[str, Any]]) -> PrefilterConfig:
    """Parse the optional `prefilter` RPC object. Disabled when absent."""
    if not params:
        return PrefilterConfig(enabled=False)
    if not isinstance(params, dict):
        raise PrefilterError("INVALID_PREFILTER", "prefilter must be an object")
    allowed = {"enabled", "sample_fps", "motion_threshold", "width", "height", "always_analyze_first_window"}
    unknown = set(params) - allowed
    if unknown:
        raise PrefilterError("INVALID_PREFILTER", f"unknown prefilter keys: {sorted(unknown)}")
    return PrefilterConfig(
        enabled=bool(params.get("enabled", False)),
        sample_fps=float(params.get("sample_fps", 2.0)),
        motion_threshold=float(params.get("motion_threshold", 0.02)),
        width=int(params.get("width", 32)),
        height=int(params.get("height", 18)),
        always_analyze_first_window=bool(params.get("always_analyze_first_window", True)),
    )


def scan_motion_profile(
    video_path: str | Path,
    *,
    config: PrefilterConfig,
    source_fps: float,
    timeout_seconds: float = 180.0,
) -> Dict[str, Any]:
    """Return per-sample mean absolute luminance delta for `video_path`.

    One ffmpeg pass at `sample_fps`, downscaled to `width x height` gray. The raw
    bytes are hashed so a different media file cannot silently reuse decisions.
    """
    path = Path(video_path)
    if not path.is_file():
        raise PrefilterError("VIDEO_NOT_FOUND", f"Source video not found: {path}")

    sample_count = 0
    cmd = [
        "ffmpeg",
        "-nostdin",
        "-v",
        "error",
        "-i",
        str(path),
        "-vf",
        f"fps={config.sample_fps},scale={config.width}:{config.height},format=gray",
        "-f",
        "rawvideo",
        "-",
    ]
    result = run_tracked(cmd, timeout=timeout_seconds, capture_output=True)
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", errors="replace") if result.stderr else ""
        raise PrefilterError("PREFILTER_SCAN_FAILED", f"ffmpeg scan failed: {stderr[:400]}")

    raw = result.stdout or b""
    frame_size = config.width * config.height
    if frame_size <= 0 or len(raw) % frame_size != 0:
        raise PrefilterError(
            "PREFILTER_SCAN_TRUNCATED",
            f"raw scan length {len(raw)} is not a multiple of {frame_size}",
        )
    sample_count = len(raw) // frame_size
    if sample_count == 0:
        raise PrefilterError("PREFILTER_SCAN_EMPTY", "ffmpeg produced no frames")

    samples: List[Dict[str, Any]] = []
    previous: Optional[bytes] = None
    for index in range(sample_count):
        chunk = raw[index * frame_size : (index + 1) * frame_size]
        if previous is None:
            delta = 0.0
        else:
            total = 0
            for a, b in zip(chunk, previous):
                total += a - b if a >= b else b - a
            delta = total / float(frame_size) / 255.0
        samples.append(
            {
                "sample_index": index,
                "frame_id": int(round(index * source_fps / config.sample_fps)),
                "mean_abs_diff": round(delta, 6),
            }
        )
        previous = chunk

    return {
        "sample_fps": config.sample_fps,
        "sample_count": sample_count,
        "source_fps": source_fps,
        "profile_sha256": hashlib.sha256(raw).hexdigest(),
        "samples": samples,
    }


def window_motion_scores(
    windows: Sequence[Any],
    profile: Dict[str, Any],
) -> Dict[int, float]:
    """Map window_index -> max mean_abs_diff of the samples inside that window."""
    samples = profile.get("samples") or []
    scores: Dict[int, float] = {}
    for window in windows:
        start = int(window.start_frame_id)
        end = int(window.end_frame_id_exclusive)
        inside = [
            float(s["mean_abs_diff"])
            for s in samples
            if start <= int(s["frame_id"]) < end
        ]
        scores[int(window.window_index)] = round(max(inside), 6) if inside else 0.0
    return scores


def build_window_prefilter(
    windows: Sequence[Any],
    profile: Dict[str, Any],
    config: PrefilterConfig,
):
    """Return a callable(window) -> decision dict, using a precomputed profile."""
    scores = window_motion_scores(windows, profile)
    first_index = int(windows[0].window_index) if windows else None

    def decide(window: Any) -> Dict[str, Any]:
        index = int(window.window_index)
        score = scores.get(index, 0.0)
        if config.always_analyze_first_window and index == first_index:
            return {"analyze": True, "score": score, "reason": "first_window"}
        if score >= config.motion_threshold:
            return {"analyze": True, "score": score, "reason": "motion_above_threshold"}
        return {"analyze": False, "score": score, "reason": "static_below_threshold"}

    return decide


def summarize_decisions(decisions: Dict[int, Dict[str, Any]]) -> Dict[str, Any]:
    skipped = sorted(i for i, d in decisions.items() if not d.get("analyze", True))
    analyzed = sorted(i for i, d in decisions.items() if d.get("analyze", True))
    return {
        "analyzed_window_indices": analyzed,
        "skipped_window_indices": skipped,
        "analyzed_count": len(analyzed),
        "skipped_count": len(skipped),
        "threshold_applied": True,
    }
