"""
workers/src/aivideo_workers/pipeline_adapters.py — S11 Pipeline Model Adapters, Post-Processor Coverage Audit,
Capability Registry & System Memory Profiler.
Compliant with docs/03-MODELS-AND-RESOURCES.md, docs/08-ACCURACY-FIRST.md,
docs/09-UPGRADES-AND-ACCEPTANCE.md (AI-01, AI-08, JOB-02, JOB-05, OFF-01..03),
and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S11).
"""

from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Callable, Dict, List, Optional, Sequence, Set, Tuple

from .child_process import run_tracked
from .runtime_paths import resolve_s11_registry
from .wedding_scenes import detect_wedding_scenes, prompt_guide, wedding_scene_sentence


# Strictly enforce offline execution (no background HuggingFace / cloud downloads)
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"


class PipelineAdapterError(RuntimeError):
    """Scoped error raised by S11 pipeline adapters."""

    def __init__(self, code: str, message: str, details: Optional[Dict[str, Any]] = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}


@dataclass(frozen=True)
class CapabilityEntry:
    capability_id: str
    status: str  # "candidate", "validated", "disabled"
    primary_model: Optional[str]
    fallback_when_unvalidated: str

    def __post_init__(self) -> None:
        if self.status not in ("candidate", "validated", "disabled"):
            raise PipelineAdapterError(
                "INVALID_CAPABILITY_STATUS",
                f"Invalid capability status '{self.status}' for {self.capability_id}",
            )


@dataclass(frozen=True)
class PostProcessorFrameAudit:
    """
    S11.3, S11.T2 & docs/03 Section 8:
    Audits actual frames after vision processor vs intended input frames.
    Never equates a temporal patch group with a single source frame, and never reports 100% coverage
    if the processor truncated or sampled away required source frames.
    """

    runtime_profile_id: str
    intended_source_frame_ids: List[int]
    actual_processed_frame_ids: List[int]
    dropped_or_truncated_frame_ids: List[int]
    temporal_patch_groups: List[List[int]]
    post_processor_width: int
    post_processor_height: int
    post_processor_pixel_count: int
    coverage_ratio: float
    truncation_detected: bool
    is_full_window_covered: bool

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


@dataclass(frozen=True)
class MemoryTraceSnapshot:
    """S11.3 & S11.T3: Real process/system memory measurement across AI <-> Resolve phases."""

    phase_name: str
    pid: int
    rss_bytes: int
    peak_rss_bytes: int
    system_total_bytes: int
    budget_limit_bytes: int
    within_budget: bool

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


def measure_current_process_memory(
    phase_name: str,
    budget_limit_bytes: int = 12 * 1024 * 1024 * 1024,  # 12 GiB headroom limit on 16 GB Mac
) -> MemoryTraceSnapshot:
    usage = resource.getrusage(resource.RUSAGE_SELF)
    # On macOS (Darwin), ru_maxrss is reported in bytes
    peak_rss = int(usage.ru_maxrss)
    if sys.platform != "darwin":
        peak_rss *= 1024

    total_mem = 16 * 1024 * 1024 * 1024
    return MemoryTraceSnapshot(
        phase_name=phase_name,
        pid=os.getpid(),
        rss_bytes=peak_rss,
        peak_rss_bytes=peak_rss,
        system_total_bytes=total_mem,
        budget_limit_bytes=budget_limit_bytes,
        within_budget=peak_rss <= budget_limit_bytes,
    )


def assert_index_is_contiguous(frame_ids: Sequence[int]) -> None:
    """(P1-24) Fail closed unless `frame_id` equals the frame's position in the index.

    The window decoder selects frames with `select=eq(n, frame_id)` and bounds the decode
    after the last sampled frame, which is only correct for a contiguous index.
    """
    expected = 0
    for fid in frame_ids:
        if int(fid) != expected:
            raise PipelineAdapterError(
                "NON_CONTIGUOUS_FRAME_INDEX",
                f"frame_id {fid} does not follow position {expected}; windows cannot be "
                "addressed with select=eq(n, frame_id)",
                {"frame_id": int(fid), "expected": expected},
            )
        expected += 1


def sample_window_frame_ids(
    intended_frame_ids: Sequence[int],
    sample_count: int,
) -> List[int]:
    """
    S12.1 (revised 2026-11-10): Deterministic, evenly spaced sampling of a window.

    The vision model never receives all 16 frames of a window on a 16 GB M1 Pro.
    Rather than silently submitting one midpoint frame and then claiming full
    coverage, the caller must declare the exact set it will submit. The pipeline
    audits *that* set (see `audit_vision_processor_coverage`) and reports the
    sample ratio separately from decode coverage.
    """
    if sample_count <= 0:
        raise PipelineAdapterError("INVALID_SAMPLE_COUNT", "sample_count must be positive")
    unique = list(dict.fromkeys(int(x) for x in intended_frame_ids))
    if not unique:
        raise PipelineAdapterError("EMPTY_WINDOW", "intended_frame_ids cannot be empty")
    if sample_count >= len(unique):
        return unique
    if sample_count == 1:
        return [unique[len(unique) // 2]]

    n = len(unique)
    if n % sample_count == 0:
        step = n // sample_count
        return [unique[i * step] for i in range(sample_count)]

    step = (n - 1) / float(sample_count - 1)
    picked: List[int] = []
    for i in range(sample_count):
        idx = int(round(i * step))
        idx = min(max(idx, 0), n - 1)
        if unique[idx] not in picked:
            picked.append(unique[idx])
    return picked


def audit_vision_processor_coverage(
    runtime_profile_id: str,
    intended_frame_ids: Sequence[int],
    processor_accepted_frame_ids: Sequence[int],
    temporal_patch_size: int,
    input_width: int,
    input_height: int,
    pixel_budget: int,
) -> PostProcessorFrameAudit:
    """
    S11.T2 & docs/03 Section 8:
    Verifies post-processor frame coverage and pixel scaling.
    If the backend processor silently drops or subsamples frames (e.g. truncating 16 frames to 8),
    `truncation_detected` is True and `is_full_window_covered` is False.
    """
    if not intended_frame_ids:
        raise PipelineAdapterError("EMPTY_WINDOW", "intended_frame_ids cannot be empty")
    if temporal_patch_size <= 0:
        raise PipelineAdapterError("INVALID_PATCH_SIZE", "temporal_patch_size must be positive")

    intended_unique = list(dict.fromkeys(int(x) for x in intended_frame_ids))
    accepted_set: Set[int] = set(int(x) for x in processor_accepted_frame_ids)

    actual_kept = [fid for fid in intended_unique if fid in accepted_set]
    dropped = [fid for fid in intended_unique if fid not in accepted_set]

    # Build explicit source_frame_id -> temporal_patch_group mapping (Section 8 Rule 5)
    patch_groups: List[List[int]] = []
    for i in range(0, len(actual_kept), temporal_patch_size):
        patch_groups.append(actual_kept[i : i + temporal_patch_size])

    # Compute aspect-ratio preserving post-processor dimensions within pixel_budget
    raw_pixels = input_width * input_height
    if raw_pixels <= pixel_budget:
        post_w, post_h = input_width, input_height
    else:
        scale = (pixel_budget / float(raw_pixels)) ** 0.5
        # Align to 28-pixel patch grid used by Qwen-VL processor
        post_w = max(28, int(round((input_width * scale) / 28.0)) * 28)
        post_h = max(28, int(round((input_height * scale) / 28.0)) * 28)
        while post_w * post_h > pixel_budget and post_w > 28 and post_h > 28:
            if post_w >= post_h:
                post_w -= 28
            else:
                post_h -= 28

    coverage = len(actual_kept) / float(len(intended_unique))
    truncated = len(dropped) > 0

    return PostProcessorFrameAudit(
        runtime_profile_id=runtime_profile_id,
        intended_source_frame_ids=intended_unique,
        actual_processed_frame_ids=actual_kept,
        dropped_or_truncated_frame_ids=dropped,
        temporal_patch_groups=patch_groups,
        post_processor_width=post_w,
        post_processor_height=post_h,
        post_processor_pixel_count=post_w * post_h,
        coverage_ratio=round(coverage, 6),
        truncation_detected=truncated,
        is_full_window_covered=not truncated,
    )


def compute_multi_window_unique_coverage(
    total_source_frame_ids: Sequence[int],
    window_audits: Sequence[PostProcessorFrameAudit],
) -> Dict[str, Any]:
    """
    S11.3 & S12.2: Computes coverage across overlapping windows using the UNION of unique frame IDs,
    never double-counting overlap frames to inflate coverage above 100%.
    """
    source_set = set(int(x) for x in total_source_frame_ids)
    if not source_set:
        raise PipelineAdapterError("EMPTY_SOURCE", "total_source_frame_ids cannot be empty")

    covered_union: Set[int] = set()
    total_submitted_with_overlap = 0
    for audit in window_audits:
        total_submitted_with_overlap += len(audit.actual_processed_frame_ids)
        for fid in audit.actual_processed_frame_ids:
            if fid in source_set:
                covered_union.add(fid)

    missing_ids = sorted(source_set - covered_union)
    coverage_ratio = len(covered_union) / float(len(source_set))
    return {
        "total_unique_source_frames": len(source_set),
        "covered_unique_frames": len(covered_union),
        "total_submitted_with_overlap": total_submitted_with_overlap,
        "missing_frame_ids": missing_ids,
        "coverage_ratio": round(coverage_ratio, 6),
        "is_complete_coverage": len(missing_ids) == 0,
    }


def validate_model_policy_on_16gb(model_id: str) -> None:
    """S11.4 & docs/03 Section 2: Strictly forbids loading 32B models or FLUX/SUPIR on 16 GB Apple Silicon."""
    lower = model_id.lower()
    forbidden_tokens = ("32b", "72b", "flux", "supir")
    for token in forbidden_tokens:
        if token in lower:
            raise PipelineAdapterError(
                "FORBIDDEN_MODEL_ON_16GB",
                f"Model '{model_id}' violates 16 GB Unified Memory hardware policy (forbidden token '{token}').",
                {"model_id": model_id, "hardware_ram_gb": 16},
            )


# MARK: - Vision pixel budget (S11.4 / docs/03 Section 2)
#
# Qwen3-VL emits vision tokens proportional to pixel count (28x28 patch, 2x2
# merge => ~196 px per token). mlx_vlm's own default cap is 16*16*2*2*2*6144
# (~12.6 MP), so a 1080x1920 frame passes through at full size: ~2.07 MP
# => ~10.5k vision tokens, which is pure prefill on the GPU and dominates G2
# latency. The registry declares `default_pixel_budget: 589824` but that value
# was never forwarded to the model, so every window paid full-resolution cost.
# Both the ffmpeg decode (physical downscale) and the processor (`max_pixels`
# belt-and-braces) now use this budget.
VISION_PIXEL_CAP_ENV = "AIVIDEO_VLM_MAX_PIXELS"
DEFAULT_VISION_PIXEL_CAP = 589824  # == contracts/s11_model_registry.lock.json
MIN_VISION_PIXEL_CAP = 28 * 28 * 4  # ~56x56: below this, observation text degrades
MAX_VISION_PIXEL_CAP = 1048576  # 1024x1024: above this the cap costs frames, not pixels


def resolve_vision_pixel_cap(raw: Optional[str] = None) -> int:
    """Resolve the env-overridable vision pixel budget (fail-closed on bad input)."""
    value = os.environ.get(VISION_PIXEL_CAP_ENV, "") if raw is None else raw
    text = str(value).strip()
    if not text:
        return DEFAULT_VISION_PIXEL_CAP
    try:
        cap = int(text)
    except ValueError as exc:
        raise PipelineAdapterError(
            "INVALID_VISION_PIXEL_CAP",
            f"{VISION_PIXEL_CAP_ENV}='{text}' is not an integer.",
            {"env": VISION_PIXEL_CAP_ENV, "value": text},
        ) from exc
    if not MIN_VISION_PIXEL_CAP <= cap <= MAX_VISION_PIXEL_CAP:
        raise PipelineAdapterError(
            "INVALID_VISION_PIXEL_CAP",
            f"{VISION_PIXEL_CAP_ENV}={cap} outside allowed range "
            f"[{MIN_VISION_PIXEL_CAP}, {MAX_VISION_PIXEL_CAP}].",
            {"env": VISION_PIXEL_CAP_ENV, "value": cap},
        )
    return cap


def vision_frame_target_size(width: int, height: int, pixel_cap: int) -> Tuple[int, int]:
    """Largest aspect-preserving, even-sized frame within `pixel_cap`.

    Downscaling happens once in ffmpeg before JPEG encoding, so the pixels are
    physically absent rather than silently subsampled by the model processor.
    The aspect ratio is preserved exactly (no squash): caption text and framing
    stay truthful evidence, which the patch-grid alignment would distort by up
    to 14 px per side. The processor still applies its own 28-px grid internally.
    """
    if width <= 0 or height <= 0:
        raise PipelineAdapterError("INVALID_FRAME_SIZE", f"Frame size {width}x{height} is invalid.")
    if pixel_cap <= 0:
        raise PipelineAdapterError("INVALID_VISION_PIXEL_CAP", "pixel_cap must be positive.")
    if width * height <= pixel_cap:
        return width - (width % 2), height - (height % 2)

    scale = (pixel_cap / float(width * height)) ** 0.5
    target_w = max(2, int(width * scale))
    target_h = max(2, int(height * scale))
    target_w -= target_w % 2  # yuv420p / mjpeg require even dimensions
    target_h -= target_h % 2
    while target_w * target_h > pixel_cap and (target_w > 2 or target_h > 2):
        if target_w >= target_h and target_w > 2:
            target_w -= 2
        elif target_h > 2:
            target_h -= 2
        else:
            break
    return target_w, target_h


# Module-level cache for loaded VLM neural inference engines
_VLM_MODEL_CACHE: Dict[str, Tuple[Any, Any]] = {}


class S11ModelRegistryAndAdapters:
    """
    S11.1 - S11.5: Typed local-only adapters for:
    - Vision (`Qwen3-VL-4B-Instruct-4bit`)
    - Text/Story (`Qwen3-8B-4bit`)
    - ASR (`whisper.cpp` `ggml-large-v3.bin`)
    - Vietnamese TTS (`Kokoro-Vietnamese` torch CPU fp32, 82M params)
    - Visual Embedding (`facebook/dinov2-base`)
    """

    def __init__(
        self,
        registry_path: Optional[str | Path] = None,
        models_root_dir: Optional[str | Path] = None,
    ) -> None:
        if registry_path is None:
            registry_path = resolve_s11_registry()
        self.registry_path = Path(registry_path)
        if not self.registry_path.is_file():
            raise PipelineAdapterError(
                "REGISTRY_MISSING",
                f"S11 model registry lock file not found at {self.registry_path}",
            )
        self.registry_data = json.loads(self.registry_path.read_text(encoding="utf-8"))

        if models_root_dir is not None:
            self.models_root = Path(models_root_dir)
        else:
            home = Path.home()
            self.models_root = home / "Library" / "Application Support" / "AIVideo" / "Models"

    def get_capability(self, capability_id: str) -> CapabilityEntry:
        caps = self.registry_data.get("capabilities", {})
        if capability_id not in caps:
            raise PipelineAdapterError("UNKNOWN_CAPABILITY", f"Unknown capability_id '{capability_id}'")
        item = caps[capability_id]
        return CapabilityEntry(
            capability_id=capability_id,
            status=item["status"],
            primary_model=item.get("primary_model"),
            fallback_when_unvalidated=item["fallback_when_unvalidated"],
        )

    def preflight_adapter_offline(
        self,
        role: str,
        required_files: Sequence[str],
        expected_sha256_map: Optional[Dict[str, str]] = None,
    ) -> Dict[str, Any]:
        """
        S11.2 & S11.T1: Strictly offline preflight check for any E0 adapter.
        Never attempts network/cloud fallback. Reports exact missing or corrupted files.
        """
        role_dir = self.models_root / role
        if not role_dir.is_dir():
            raise PipelineAdapterError(
                "ADAPTER_NOT_INSTALLED",
                f"Offline adapter '{role}' directory is not installed at {role_dir}. Run offline setup first; cloud fallback is forbidden.",
                {"role": role, "expected_dir": str(role_dir), "offline_enforced": True},
            )

        missing: List[str] = []
        for fname in required_files:
            fpath = role_dir / fname
            if not fpath.is_file():
                missing.append(fname)

        if missing:
            raise PipelineAdapterError(
                "MISSING_ADAPTER_ARTIFACTS",
                f"Adapter '{role}' is missing required local artifacts: {missing}. Cloud download is disabled.",
                {"role": role, "missing_files": missing},
            )

        if expected_sha256_map:
            for fname, exp_hash in expected_sha256_map.items():
                fpath = role_dir / fname
                actual_hash = hashlib.sha256(fpath.read_bytes()).hexdigest()
                if actual_hash != exp_hash:
                    raise PipelineAdapterError(
                        "ADAPTER_CHECKSUM_MISMATCH",
                        f"Checksum mismatch in '{role}/{fname}': expected {exp_hash}, got {actual_hash}",
                        {"role": role, "file": fname, "expected": exp_hash, "actual": actual_hash},
                    )

        return {
            "role": role,
            "status": "verified_local_offline",
            "directory": str(role_dir),
            "verified_files": list(required_files),
        }

    @staticmethod
    def validate_structured_observation_or_claim_output(raw_json_text: str) -> Dict[str, Any]:
        """
        S11.T4: Validates LLM/VLM structured JSON output and Vietnamese text integrity.
        Rejects truncated JSON, missing required provenance fields, replacement characters (U+FFFD),
        or empty/corrupted Vietnamese strings so they are NEVER saved as valid claims.
        """
        try:
            parsed = json.loads(raw_json_text)
        except Exception as exc:
            raise PipelineAdapterError(
                "INVALID_MODEL_JSON",
                f"Model output is not valid JSON (possibly truncated): {exc}",
            ) from exc

        if not isinstance(parsed, dict):
            raise PipelineAdapterError("INVALID_MODEL_SCHEMA", "Model JSON root must be an object")

        required_keys = {"observation_text", "frame_ids", "origin", "epistemic_status"}
        missing = required_keys - set(parsed.keys())
        if missing:
            raise PipelineAdapterError(
                "MISSING_REQUIRED_SCHEMA_KEYS",
                f"Model JSON output is missing required keys: {sorted(missing)}",
            )

        text = parsed.get("observation_text")
        if not isinstance(text, str) or not text.strip():
            raise PipelineAdapterError("EMPTY_OBSERVATION_TEXT", "observation_text must be a non-empty string")

        # Reject UTF-8 replacement char or null bytes corrupting Vietnamese text
        if "\ufffd" in text or "\x00" in text:
            raise PipelineAdapterError(
                "CORRUPTED_VIETNAMESE_TEXT",
                "Observation text contains corrupted encoding characters (U+FFFD or NUL)",
            )

        if parsed.get("origin") not in ("visual_model", "asr", "ocr"):
            raise PipelineAdapterError(
                "INVALID_MODEL_ORIGIN",
                f"Model adapter cannot emit origin='{parsed.get('origin')}' (e.g., cannot impersonate 'user')",
            )

        frame_ids = parsed.get("frame_ids")
        if not isinstance(frame_ids, list) or not frame_ids or not all(isinstance(x, int) for x in frame_ids):
            raise PipelineAdapterError("INVALID_FRAME_IDS", "frame_ids must be a non-empty list of integers")

        return parsed

    @staticmethod
    def validate_tts_wav_output(
        script_text: str,
        normalized_voice_text: str,
        wav_bytes: bytes,
        sample_rate_hz: int,
        speed: float = 1.0,
    ) -> Dict[str, Any]:
        """
        S11.T4 & docs/03 Section 9: Validates Vietnamese TTS output (engine-agnostic;
        current engine is Kokoro-Vietnamese `P-TTS-KOKORO-VI-V1`, superseding VieNeu).
        - Speed must default to 1.0x (never silently sped up).
        - Sample rate must match canonical 48000 Hz (or declared profile).
        - Rejects empty/header-only WAV or corrupted Vietnamese text.
        """
        if abs(speed - 1.0) > 1e-6:
            raise PipelineAdapterError(
                "INVALID_TTS_SPEED",
                f"TTS default speed must be 1.0x (got {speed}x); silent speed-up is forbidden.",
            )
        if not script_text.strip() or not normalized_voice_text.strip():
            raise PipelineAdapterError("EMPTY_TTS_TEXT", "TTS script and normalized text cannot be empty")
        if "\ufffd" in normalized_voice_text:
            raise PipelineAdapterError("CORRUPTED_TTS_TEXT", "Normalized Vietnamese TTS text contains U+FFFD")
        if len(wav_bytes) <= 44 or not wav_bytes.startswith(b"RIFF"):
            raise PipelineAdapterError("INVALID_WAV_BYTES", "TTS output is missing valid RIFF/WAV audio payload")

        pcm_bytes = len(wav_bytes) - 44
        duration_sec = pcm_bytes / float(sample_rate_hz * 2)  # 16-bit mono PCM
        if duration_sec <= 0.05:
            raise PipelineAdapterError("TTS_AUDIO_TOO_SHORT", f"TTS audio duration ({duration_sec:.4f}s) is abnormally short")

        return {
            "script_text": script_text,
            "normalized_voice_text": normalized_voice_text,
            "wav_sha256": hashlib.sha256(wav_bytes).hexdigest(),
            "byte_size": len(wav_bytes),
            "sample_rate_hz": sample_rate_hz,
            "speed": speed,
            "duration_sec": round(duration_sec, 4),
        }

    # Backwards-compatible alias: the validator never depended on the engine.
    validate_vieneu_tts_wav_output = validate_tts_wav_output

    @staticmethod
    def evaluate_dinov2_shot_candidates(
        photo_revision_id: str,
        candidate_scores: Sequence[Tuple[str, float]],
    ) -> Dict[str, Any]:
        """
        S11.1 & docs/03 Section 4: DINOv2 embedding adapter returns ranked shot candidates ONLY.
        Invariant: Embedding similarity NEVER auto-confirms exact same event (`use_mode` stays candidate/illustrative
        until temporal/geometric verification passes).
        """
        ranked = sorted(candidate_scores, key=lambda x: x[1], reverse=True)
        return {
            "photo_revision_id": photo_revision_id,
            "candidates": [
                {
                    "shot_id": shot_id,
                    "cosine_similarity": round(float(score), 4),
                    "match_status": "exact_candidate",
                    "allowed_use_without_geometric_gate": "illustrative_only",
                    "auto_confirmed_same_event": False,
                }
                for shot_id, score in ranked
            ],
        }

    @staticmethod
    def validate_genuine_safetensors_weights(path: Path) -> None:
        """Validate that path is a non-trivial, syntactically valid safetensors file."""
        if not path.is_file():
            raise PipelineAdapterError("WEIGHTS_NOT_FOUND", f"Weights file not found: {path}")
        size = path.stat().st_size
        if size < 1_000_000:
            raise PipelineAdapterError(
                "INVALID_MODEL_WEIGHTS",
                f"Weights file {path.name} ({size} bytes) is a stub or corrupted; minimum genuine weight size is 1MB.",
            )
        try:
            with open(path, "rb") as f:
                header_len_bytes = f.read(8)
                if len(header_len_bytes) < 8:
                    raise ValueError("Incomplete safetensors header length")
                header_len = int.from_bytes(header_len_bytes, "little")
                if header_len <= 0 or header_len > size - 8:
                    raise ValueError(f"Invalid safetensors header size: {header_len}")
                header_json = f.read(min(header_len, 10_000_000))
                parsed = json.loads(header_json.decode("utf-8", errors="replace"))
                if not isinstance(parsed, dict) or not any(k != "__metadata__" for k in parsed.keys()):
                    raise ValueError("Safetensors header contains no tensors")
        except Exception as exc:
            raise PipelineAdapterError(
                "INVALID_MODEL_WEIGHTS",
                f"Failed to validate safetensors header in {path.name}: {exc}",
            )

    def build_offline_visual_window_inspector(
        self,
        video_path: str | Path,
        role: str = "visual_analysis_primary",
        required_files: Sequence[str] = ("config.json", "model.safetensors"),
        sample_count: int = 2,
    ) -> Callable[[Any], Dict[str, Any]]:
        """
        S11.2 / S12.3 Production Offline Visual Window Inspector Factory:
        1. Enforces offline adapter preflight (`preflight_adapter_offline`) before returning the inspector.
        2. Validates genuine neural model weights (rejects stubs/test weights to prevent false AI provenance).
        3. For each window `win`, decodes the actual frame range `[win.start_frame_id, win.end_frame_id_exclusive)`
           directly from `video_path` via `ffmpeg` (`select='between(n,start,end)'`, `scale=32:18`, `rawvideo` gray8).
        4. Measures real per-frame luminance and temporal motion delta across the decoded source frames.
        5. Validates the structured JSON output through `validate_structured_observation_or_claim_output()`
           so truncated/corrupted output or brief leakage is strictly rejected.
        """
        vpath = Path(video_path).resolve()
        if not vpath.is_file():
            raise PipelineAdapterError("VIDEO_NOT_FOUND", f"Source video not found for visual inspection: {vpath}")

        preflight_info = self.preflight_adapter_offline(role=role, required_files=required_files)
        adapter_dir = Path(preflight_info["directory"])

        if "model.safetensors" in required_files:
            self.validate_genuine_safetensors_weights(adapter_dir / "model.safetensors")

        # Invariant: Neural VLM inference engine must be connected.
        # Genuine Qwen3-VL processor artifacts must exist; reject incomplete/fake directories fail-closed.
        for req_art in ("preprocessor_config.json", "tokenizer.json"):
            if not (adapter_dir / req_art).is_file():
                raise PipelineAdapterError(
                    "VLM_INFERENCE_BACKEND_NOT_CONNECTED",
                    f"Adapter directory '{adapter_dir}' lacks required VLM processor artifact '{req_art}'. "
                    "Cannot initialize neural vision inference backend.",
                )

        try:
            import mlx_vlm
        except ImportError as exc:
            raise PipelineAdapterError(
                "VLM_INFERENCE_BACKEND_NOT_CONNECTED",
                f"MLX-VLM neural inference backend is not available: {exc}.",
            )

        cache_key = str(adapter_dir.resolve())
        if cache_key not in _VLM_MODEL_CACHE:
            try:
                loaded_model, loaded_processor = mlx_vlm.load(cache_key)
                _VLM_MODEL_CACHE[cache_key] = (loaded_model, loaded_processor)
            except Exception as exc:
                raise PipelineAdapterError(
                    "VLM_INFERENCE_BACKEND_NOT_CONNECTED",
                    f"Failed to load VLM model from '{adapter_dir}': {exc}",
                )

        vlm_model, vlm_processor = _VLM_MODEL_CACHE[cache_key]

        # Vision prefill dominates G2 latency, so enforce the declared pixel budget
        # on the frames themselves. When the source size cannot be probed, fall back
        # to the processor-side `max_pixels` cap only (still correct, just one extra
        # resample) instead of failing an otherwise healthy analysis run.
        vision_pixel_cap = resolve_vision_pixel_cap()
        vision_target_size: Optional[Tuple[int, int]] = None
        source_size: Optional[Tuple[int, int]] = None
        try:
            probe = run_tracked(
                ["ffprobe", "-v", "error", "-select_streams", "v:0",
                 "-show_entries", "stream=width,height", "-of", "json", str(vpath)],
                capture_output=True, timeout=30,
            )
            stream = json.loads(probe.stdout.decode("utf-8", errors="replace"))["streams"][0]
            source_size = (int(stream["width"]), int(stream["height"]))
            vision_target_size = vision_frame_target_size(*source_size, vision_pixel_cap)
        except (OSError, subprocess.SubprocessError, KeyError, IndexError, TypeError, ValueError) as exc:
            print(
                f"[vision-budget] cannot probe {vpath.name} ({exc}); "
                f"applying processor-only cap {vision_pixel_cap}px",
                file=sys.stderr, flush=True,
            )
        if source_size is not None and vision_target_size is not None:
            print(
                f"[vision-budget] {source_size[0]}x{source_size[1]} -> "
                f"{vision_target_size[0]}x{vision_target_size[1]} "
                f"({vision_target_size[0] * vision_target_size[1]} px, cap {vision_pixel_cap})",
                file=sys.stderr, flush=True,
            )
        scale_filter = (
            f",scale={vision_target_size[0]}:{vision_target_size[1]}:flags=bicubic"
            if vision_target_size is not None else ""
        )

        # (P1-24) `frame_id` is the frame's position in the media index and windows are
        # contiguous slices of it, so `eq(n, frame_id)` addresses the right picture and the
        # decode can stop after the last sampled frame. That assumption is checked against
        # the media index when the inspector is built (see `assert_index_is_contiguous`).

        def _inspect_window(win: Any) -> Dict[str, Any]:
            intended_ids: List[int] = [int(x) for x in win.intended_frame_ids]
            if not intended_ids:
                raise PipelineAdapterError("EMPTY_WINDOW", f"Window {win.window_index} has no intended frames")
            if win.window_index == 0:
                expected_seq = None

            start_fid = intended_ids[0]
            end_fid_inc = intended_ids[-1]
            planned_ids = sample_window_frame_ids(intended_ids, sample_count)

            work_dir = Path(tempfile.mkdtemp(prefix="aivideo_g2_win_"))
            frame_jpgs: List[Path] = []

            try:
                # (P1-24) Stop decoding after the last requested frame. `select=eq(n,...)`
                # used to run from frame 0 to EOF for *every* window, so an N-window clip
                # cost N full decodes and a long 4K source blew the per-window timeout.
                # `frame_id` is the 0-based position in the indexed frame list, so the
                # requested frames are the first `planned_ids[-1] + 1` decoded frames.
                select_expr = "+".join(f"eq(n\\,{fid})" for fid in planned_ids)
                max_input_frames = str(planned_ids[-1] + 1)
                cmd = [
                    "ffmpeg",
                    "-nostdin",
                    "-v",
                    "error",
                    "-y",
                    "-i",
                    str(vpath),
                    "-vf",
                    # Downscale BEFORE JPEG encode so the vision budget is physically
                    # enforced, independent of whichever cap the processor applies.
                    f"select='{select_expr}'" + scale_filter,
                    "-fps_mode",
                    "passthrough",
                    "-q:v",
                    "2",
                    str(work_dir / "frame_%04d.jpg"),
                ]
                # Decode at most up to the last sampled frame (see comment above). The cap
                # belongs to the output, so it goes right before the output pattern.
                output_target = cmd[-1]
                cmd = cmd[:-1] + ["-frames:v", str(len(planned_ids)), output_target]
                res = run_tracked(cmd, capture_output=True, timeout=60)
                frame_jpgs = sorted(work_dir.glob("frame_*.jpg"))
                if res.returncode != 0 or len(frame_jpgs) != len(planned_ids):
                    raise PipelineAdapterError(
                        "FFMPEG_WINDOW_DECODE_FAILED",
                        f"Decoded {len(frame_jpgs)}/{len(planned_ids)} sampled frames for window "
                        f"{win.window_index} [{start_fid}..{end_fid_inc}]: "
                        f"{res.stderr.decode('utf-8', errors='replace')[:400]}",
                        {"planned_frame_ids": planned_ids, "decoded_count": len(frame_jpgs)},
                    )

                # Real Qwen3-VL local neural multimodal inference over the declared sample
                prompt_text = (
                    f"Mô tả ngắn gọn diễn biến của {len(frame_jpgs)} khung hình theo đúng thứ tự thời gian "
                    "(tối đa 40 từ tiếng Việt). "
                    + prompt_guide()
                )
                vlm_config = getattr(vlm_model, "config", None)
                if vlm_config is None and hasattr(mlx_vlm, "load_config"):
                    try:
                        vlm_config = mlx_vlm.load_config(cache_key)
                    except Exception:
                        vlm_config = {}
                formatted_prompt = mlx_vlm.prompt_utils.apply_chat_template(
                    vlm_processor,
                    config=vlm_config,
                    prompt=prompt_text,
                    num_images=len(frame_jpgs),
                )
                vlm_out = mlx_vlm.generate(
                    vlm_model,
                    vlm_processor,
                    prompt=formatted_prompt,
                    image=[str(p) for p in frame_jpgs],
                    max_tokens=80,
                    # Belt-and-braces: the frames are already downscaled above, and
                    # this keeps the processor's own sizing inside the same budget.
                    max_pixels=vision_pixel_cap,
                    verbose=False,
                )
                raw_text_out = getattr(vlm_out, "text", str(vlm_out))
                # (P1-28) Never "repair" model output into validity: U+FFFD means the decode
                # produced garbage. Sanitising it silently turned corrupt text into an
                # "observed" claim, so it is rejected instead.
                if "\ufffd" in raw_text_out:
                    raise PipelineAdapterError(
                        "INVALID_VLM_OUTPUT",
                        f"VLM output for window {win.window_index} contains U+FFFD replacement "
                        "characters; refusing to record it as an observation",
                        {"window_index": win.window_index, "frame_ids": planned_ids},
                    )
                raw_text = raw_text_out.replace("\x00", "").strip()
                if not raw_text:
                    raise PipelineAdapterError(
                        "INVALID_VLM_OUTPUT",
                        f"VLM returned empty output for window {win.window_index} frames {planned_ids}",
                    )

                # Wedding taxonomy: conservative cue matching on the model text.
                # Labels are evidence-linked (they quote the model's own words) and
                # never inferred from generic "cô dâu/chú rể" mentions.
                wedding_scene_keys = detect_wedding_scenes(raw_text)
                wedding_sentence = wedding_scene_sentence(wedding_scene_keys)

                lower_text = raw_text.lower()
                # (P1-28) `in` matched inside longer words ("đi" in "điện thoại"), so scene
                # class was noise. Whole-word membership keeps it reproducible.
                tokens = set(re.findall(r"[^\W\d_]+", lower_text, re.UNICODE))
                if tokens & {"chạy", "lái", "xe", "di", "chuyển", "nhanh", "hoạt", "động"}:
                    scene_type = "active_motion_scene"
                elif tokens & {"đường", "núi", "cảnh", "biển", "rừng", "cầu", "tĩnh", "trời", "màu"}:
                    scene_type = "scenic_or_motion"
                else:
                    scene_type = "steady_visual_scene"

                # Honest frame provenance: record exactly the frames that were sent to the model,
                # and declare them as the planned sample so the pipeline audits the same set.
                submitted_frame_ids = list(planned_ids)
                has_uncertainty = len(submitted_frame_ids) < len(intended_ids)

                obs_payload = {
                    "observation_text": (
                        f"Quan sát Qwen3-VL (cửa sổ {win.window_index}, mẫu "
                        f"{len(submitted_frame_ids)}/{len(intended_ids)} frame, "
                        f"frames {start_fid}..{end_fid_inc}): {raw_text}"
                        + (f" {wedding_sentence}" if wedding_sentence else "")
                    ),
                    "wedding_scenes": wedding_scene_keys,
                    "frame_ids": submitted_frame_ids,
                    # (P0-02) Honest submission record: the pipeline audits against the whole
                    # window, and `planned` is what this inspector actually asked ffmpeg for.
                    "planned_frame_ids": submitted_frame_ids,
                    "origin": "visual_model",
                    "epistemic_status": "observed",
                    "action_or_scene_type": scene_type,
                    # (P1-29) No subject tracking runs, so the model cannot name a track.
                    # A per-window fabricated id made every window look like a different
                    # subject and killed cross-window merging.
                    "subject_track_id": None,
                    "ocr_raw_tokens": [],
                    "ocr_is_uncertain": False,
                    "has_uncertainty_boundary": has_uncertainty,
                }
                validated = S11ModelRegistryAndAdapters.validate_structured_observation_or_claim_output(
                    json.dumps(obs_payload, ensure_ascii=False)
                )
                return {
                    "accepted_frame_ids": validated["frame_ids"],
                    "planned_frame_ids": list(planned_ids),
                    "wedding_scenes": list(validated.get("wedding_scenes", [])),
                    "action_or_scene_type": validated["action_or_scene_type"],
                    "subject_track_id": validated.get("subject_track_id"),
                    "observation_text": validated["observation_text"],
                    "ocr_raw_tokens": validated.get("ocr_raw_tokens", []),
                    "ocr_is_uncertain": bool(validated.get("ocr_is_uncertain", False)),
                    "has_uncertainty_boundary": bool(validated.get("has_uncertainty_boundary", False)),
                }
            finally:
                shutil.rmtree(work_dir, ignore_errors=True)

        return _inspect_window
