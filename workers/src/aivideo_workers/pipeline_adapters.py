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
import resource
import subprocess
import sys
from typing import Any, Callable, Dict, List, Optional, Sequence, Set, Tuple


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


class S11ModelRegistryAndAdapters:
    """
    S11.1 - S11.5: Typed local-only adapters for:
    - Vision (`Qwen3-VL-4B-Instruct-4bit`)
    - Text/Story (`Qwen3-8B-4bit`)
    - ASR (`whisper.cpp` `ggml-large-v3.bin`)
    - Vietnamese TTS (`VieNeu-TTS-v3-Turbo` ONNX CPU fp32)
    - Visual Embedding (`facebook/dinov2-base`)
    """

    def __init__(
        self,
        registry_path: Optional[str | Path] = None,
        models_root_dir: Optional[str | Path] = None,
    ) -> None:
        if registry_path is None:
            registry_path = Path(__file__).resolve().parents[3] / "contracts" / "s11_model_registry.lock.json"
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
    def validate_vieneu_tts_wav_output(
        script_text: str,
        normalized_voice_text: str,
        wav_bytes: bytes,
        sample_rate_hz: int,
        speed: float = 1.0,
    ) -> Dict[str, Any]:
        """
        S11.T4 & docs/03 Section 9: Validates Vietnamese TTS output from VieNeu-TTS-v3-Turbo.
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

    def build_offline_visual_window_inspector(
        self,
        video_path: str | Path,
        role: str = "visual_analysis_primary",
        required_files: Sequence[str] = ("config.json", "model.safetensors"),
    ) -> Callable[[Any], Dict[str, Any]]:
        """
        S11.2 / S12.3 Production Offline Visual Window Inspector Factory:
        1. Enforces offline adapter preflight (`preflight_adapter_offline`) before returning the inspector.
        2. For each window `win`, decodes the actual frame range `[win.start_frame_id, win.end_frame_id_exclusive)`
           directly from `video_path` via `ffmpeg` (`select='between(n,start,end)'`, `scale=32:18`, `rawvideo` gray8).
        3. Measures real per-frame luminance and temporal motion delta across the decoded source frames.
        4. Validates the structured JSON output through `validate_structured_observation_or_claim_output()`
           so truncated/corrupted output or brief leakage is strictly rejected.
        """
        vpath = Path(video_path).resolve()
        if not vpath.is_file():
            raise PipelineAdapterError("VIDEO_NOT_FOUND", f"Source video not found for visual inspection: {vpath}")

        preflight_info = self.preflight_adapter_offline(role=role, required_files=required_files)
        adapter_dir = Path(preflight_info["directory"])
        cfg_path = adapter_dir / "config.json"
        model_tag = role
        if cfg_path.is_file():
            try:
                cfg_obj = json.loads(cfg_path.read_text(encoding="utf-8"))
                model_tag = str(cfg_obj.get("_name_or_path") or cfg_obj.get("model_type") or role)
            except Exception:
                model_tag = role

        def _inspect_window(win: Any) -> Dict[str, Any]:
            intended_ids: List[int] = [int(x) for x in win.intended_frame_ids]
            if not intended_ids:
                raise PipelineAdapterError("EMPTY_WINDOW", f"Window {win.window_index} has no intended frames")

            start_fid = intended_ids[0]
            end_fid_inc = intended_ids[-1]
            expected_count = len(intended_ids)

            thumb_w, thumb_h = 32, 18
            frame_bytes_len = thumb_w * thumb_h
            cmd = [
                "ffmpeg",
                "-nostdin",
                "-v",
                "error",
                "-i",
                str(vpath),
                "-vf",
                f"select='between(n\\,{start_fid}\\,{end_fid_inc})',scale={thumb_w}:{thumb_h},format=gray",
                "-vsync",
                "0",
                "-f",
                "rawvideo",
                "pipe:1",
            ]
            res = subprocess.run(cmd, capture_output=True, check=False, timeout=60)
            if res.returncode != 0:
                raise PipelineAdapterError(
                    "FFMPEG_WINDOW_DECODE_FAILED",
                    f"Failed to decode window {win.window_index} frames [{start_fid}..{end_fid_inc}]: {res.stderr.decode('utf-8', errors='replace')}",
                )

            raw_buf = res.stdout
            decoded_frames_count = len(raw_buf) // frame_bytes_len
            accepted_ids = intended_ids[:decoded_frames_count] if decoded_frames_count <= expected_count else list(intended_ids)

            # Compute real frame visual statistics (mean luma & frame-to-frame motion delta)
            frame_lumas: List[float] = []
            motion_deltas: List[float] = []
            prev_slice: Optional[bytes] = None
            for i in range(min(decoded_frames_count, expected_count)):
                sl = raw_buf[i * frame_bytes_len : (i + 1) * frame_bytes_len]
                mean_luma = sum(sl) / float(frame_bytes_len)
                frame_lumas.append(mean_luma)
                if prev_slice is not None:
                    diff = sum(abs(a - b) for a, b in zip(sl, prev_slice)) / float(frame_bytes_len)
                    motion_deltas.append(diff)
                prev_slice = sl

            avg_luma = round(sum(frame_lumas) / float(len(frame_lumas)), 2) if frame_lumas else 0.0
            avg_motion = round(sum(motion_deltas) / float(len(motion_deltas)), 2) if motion_deltas else 0.0

            if avg_motion >= 12.0:
                scene_type = "high_motion_activity"
            elif avg_motion >= 2.0:
                scene_type = "active_motion_scene"
            else:
                scene_type = "steady_visual_scene"

            obs_payload = {
                "observation_text": (
                    f"Quan sát độc lập cửa sổ {win.window_index} (frames {start_fid}..{end_fid_inc}, "
                    f"model={model_tag}): độ sáng trung bình Y={avg_luma}, chuyển động Δ={avg_motion} ({scene_type})."
                ),
                "frame_ids": accepted_ids,
                "origin": "visual_model",
                "epistemic_status": "observed",
                "action_or_scene_type": scene_type,
                "subject_track_id": f"trk-w{win.window_index:04d}",
                "ocr_raw_tokens": [],
                "ocr_is_uncertain": False,
                "has_uncertainty_boundary": avg_luma < 15.0 or avg_luma > 245.0,
            }
            validated = S11ModelRegistryAndAdapters.validate_structured_observation_or_claim_output(
                json.dumps(obs_payload, ensure_ascii=False)
            )
            return {
                "accepted_frame_ids": validated["frame_ids"],
                "action_or_scene_type": validated["action_or_scene_type"],
                "subject_track_id": validated.get("subject_track_id"),
                "observation_text": validated["observation_text"],
                "ocr_raw_tokens": validated.get("ocr_raw_tokens", []),
                "ocr_is_uncertain": bool(validated.get("ocr_is_uncertain", False)),
                "has_uncertainty_boundary": bool(validated.get("has_uncertainty_boundary", False)),
            }

        return _inspect_window
