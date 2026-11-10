"""
workers/src/aivideo_workers/full_frame_pipeline.py — S12 Full-Frame Multi-Scale Analysis Pipeline,
Sliding Window Checkpointing, Brief-Agnostic Raw Observation Isolation & Real Coverage Ledger.
Compliant with docs/02-ANALYSIS-AND-DATA.md (Sections 9, 10), docs/07-OPTIMIZATION.md (Sections 2, 3, 4),
docs/08-ACCURACY-FIRST.md (Sections 3..9, 13), docs/09-UPGRADES-AND-ACCEPTANCE.md (AI-01, AI-02, JOB-03, JOB-05),
and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S12).
"""

from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field
import hashlib
import json
from pathlib import Path
import re
import shutil
from typing import Any, Callable, Dict, List, Optional, Sequence, Set, Tuple

from .media_indexer import SourceFrameEntry
from .pipeline_adapters import (
    PipelineAdapterError,
    PostProcessorFrameAudit,
    audit_vision_processor_coverage,
    measure_current_process_memory,
)


class FullFramePipelineError(RuntimeError):
    """Scoped error raised by S12 full-frame analysis pipeline."""

    def __init__(self, code: str, message: str, details: Optional[Dict[str, Any]] = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}


@dataclass(frozen=True)
class SlidingWindowSpec:
    """
    S12.1: Overlapping sliding window specification.
    Default P-VISION-DEV-v1 uses window_size=16 frames, overlap=4 frames (stride=12).
    """

    window_index: int
    start_frame_id: int
    end_frame_id_exclusive: int
    intended_frame_ids: List[int]
    start_pts_ticks: int
    end_pts_ticks: int
    time_base_num: int
    time_base_den: int
    is_boundary_padded: bool = False

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


@dataclass(frozen=True)
class RawObservationRecord:
    """
    S12.3 & AI-02: Immutable first-pass observation record.
    - `pass_role = 'raw_independent'` NEVER receives user brief/story expectations.
    - `pass_role = 'guided_revisit'` stores brief-guided hypothesis checks separately without overwriting raw observations.
    """

    observation_id: str
    source_revision_id: str
    window_index: int
    pass_role: str  # 'raw_independent' | 'guided_revisit' | 'omission_audit'
    origin: str  # 'visual_model' | 'ocr' | 'asr'
    epistemic_status: str  # 'observed' | 'unknown'
    frame_ids: List[int]
    start_pts_ticks: int
    end_pts_ticks: int
    time_base_num: int
    time_base_den: int
    action_or_scene_type: str
    subject_track_id: Optional[str]
    observation_text: str
    ocr_raw_tokens: List[str]
    ocr_is_uncertain: bool
    has_uncertainty_boundary: bool
    guided_hypothesis_ref: Optional[str] = None

    def __post_init__(self) -> None:
        if self.pass_role not in ("raw_independent", "guided_revisit", "omission_audit"):
            raise FullFramePipelineError("INVALID_PASS_ROLE", f"Invalid pass_role: {self.pass_role}")
        if self.origin not in ("visual_model", "ocr", "asr"):
            raise FullFramePipelineError("INVALID_ORIGIN", f"Invalid observation origin: {self.origin}")
        if self.epistemic_status not in ("observed", "unknown"):
            raise FullFramePipelineError("INVALID_EPISTEMIC", f"Invalid epistemic_status: {self.epistemic_status}")
        if self.pass_role == "raw_independent" and self.guided_hypothesis_ref is not None:
            raise FullFramePipelineError(
                "BRIEF_LEAKAGE_IN_RAW_PASS",
                "raw_independent pass cannot reference a guided brief hypothesis.",
            )

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


@dataclass(frozen=True)
class MergedSegmentCandidate:
    """
    S12.4 & docs/07 Section 3: Merged event/segment candidate across overlapping windows.
    Preserves references to underlying immutable RawObservationRecords and marks competing hypotheses
    instead of majority-vote deletion.
    """

    segment_id: str
    source_revision_id: str
    start_frame_id: int
    end_frame_id_exclusive: int
    start_pts_ticks: int
    end_pts_ticks: int
    action_or_scene_type: str
    subject_track_id: Optional[str]
    supporting_observation_ids: List[str]
    competing_observation_ids: List[str]
    merge_status: str  # 'merged_continuous' | 'kept_separate_repetition' | 'conflicting_hypotheses'
    boundary_uncertain: bool
    summary_text: str

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


@dataclass(frozen=True)
class AudioBranchAnalysisResult:
    """
    S12.5 & docs/02 Section 9: Independent audio analysis branch.
    `no_audio` and `no_speech` are distinct states and NEVER disable the visual analysis branch.
    """

    source_revision_id: str
    audio_state: str  # 'no_audio' | 'no_speech' | 'speech_detected'
    speech_segments: List[Dict[str, Any]]
    visual_branch_enabled: bool = True
    # 2026-11-10 fix (D16): ASR is not wired into the runtime yet, so the ledger must
    # report 'not_configured' instead of a hard-coded 'completed'.
    asr_status: str = "not_configured"

    def __post_init__(self) -> None:
        if self.audio_state not in ("no_audio", "no_speech", "speech_detected"):
            raise FullFramePipelineError("INVALID_AUDIO_STATE", f"Invalid audio_state: {self.audio_state}")
        if self.asr_status not in ("no_audio", "completed", "not_configured"):
            raise FullFramePipelineError("INVALID_ASR_STATUS", f"Invalid asr_status: {self.asr_status}")
        if not self.visual_branch_enabled:
            raise FullFramePipelineError(
                "VISUAL_BRANCH_DISABLED_BY_AUDIO",
                "Audio state must never disable visual analysis branch (AI-01).",
            )

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


@dataclass(frozen=True)
class OmissionAuditFinding:
    """S12.5 & docs/08 Section 13: Targeted omission audit returning to source and batch boundaries."""

    finding_id: str
    source_revision_id: str
    category: str  # 'silent_scenic' | 'short_action_boundary' | 'small_text_ocr' | 'hand_interaction' | 'decode_corrupted_region'
    inspected_frame_ids: List[int]
    status: str  # 'recovered_evidence' | 'confirmed_not_seen_in_scope' | 'remained_uncertain'
    description: str
    linked_observation_id: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


@dataclass(frozen=True)
class AssetCoverageLedger:
    """
    S12.2, S12.6 & docs/08 Section 4:
    Explicit multi-layer coverage ledger.
    Separates decode coverage, post-processor model input coverage, and semantic understanding.
    Never drops decode-corrupted frames from total denominator to fake 100% coverage.
    """

    source_revision_id: str
    runtime_profile_id: str
    input_fingerprint: str
    total_declared_source_frames: int
    valid_decoded_frame_ids: List[int]
    corrupted_decode_frame_ids: List[int]
    unique_post_processor_frame_ids: List[int]
    total_submitted_frames_with_overlap: int
    decode_coverage_ratio: float
    frame_input_coverage: float  # Unique_Processed_Frames / Total_Declared_Source_Frames (AI-01)
    valid_frame_input_coverage: float  # Unique_Processed_Frames / Valid_Decoded_Frames
    completed_window_indices: List[int]
    total_windows: int
    visual_scan_status: str  # 'completed' | 'partial_with_decode_errors' | 'paused_checkpoint' | 'blocked_resource'
    detailed_pass_status: str
    audio_analysis_status: str
    omission_audit_status: str
    semantic_understanding_certified: bool = False  # Always False at S12: frame input != semantic truth!
    # 2026-11-10 fix: frames actually submitted to the vision model / total declared source frames.
    # Bounded vision models only see a declared sample of each window, so this must be
    # reported separately from decode coverage instead of being called "100% input coverage".
    vlm_frame_coverage: float = 0.0
    # 2026-11-10 prefilter: windows deliberately not sent to the vision model. They are
    # recorded with a score and reason and never counted as analyzed.
    skipped_window_indices: List[int] = field(default_factory=list)
    prefilter_skipped_count: int = 0

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


@dataclass(frozen=True)
class BoundedPipelineConfig:
    """
    S12.1 & S12.T4: Bounded memory/queue configuration for P-VISION-DEV-v1.
    Never dumps all 4K frames to SSD; decodes in bounded streaming windows.
    """

    runtime_profile_id: str = "P-VISION-DEV-v1"
    window_size_frames: int = 16
    window_overlap_frames: int = 4
    temporal_patch_size: int = 2
    max_in_memory_frame_queue: int = 32  # Strict upper bound on in-memory decoded frames
    max_in_memory_log_entries: int = 256  # Ring buffer bound for runtime logs
    ram_budget_limit_bytes: int = 12 * 1024 * 1024 * 1024  # 12 GiB on 16 GB Unified Memory
    min_free_ssd_bytes: int = 2 * 1024 * 1024 * 1024  # 2 GiB minimum free disk guard


def generate_overlapping_windows(
    pts_index: Sequence[SourceFrameEntry],
    window_size: int = 16,
    overlap: int = 4,
) -> List[SlidingWindowSpec]:
    """
    S12.1: Generates overlapping windows over the PTS index.
    Stride = window_size - overlap. Ensures every frame in pts_index is included in at least one window,
    and boundary frames are covered by two adjacent windows so short boundary actions are not split/lost.
    """
    if window_size <= 0 or overlap < 0 or overlap >= window_size:
        raise FullFramePipelineError(
            "INVALID_WINDOW_CONFIG",
            f"Invalid window_size={window_size}, overlap={overlap}. Must satisfy 0 <= overlap < window_size.",
        )
    if not pts_index:
        return []

    stride = window_size - overlap
    n = len(pts_index)
    windows: List[SlidingWindowSpec] = []
    w_idx = 0
    pos = 0

    while pos < n:
        slice_records = list(pts_index[pos : pos + window_size])
        frame_ids = [r.frame_id for r in slice_records]
        start_f = frame_ids[0]
        end_f = frame_ids[-1] + 1
        start_pts = slice_records[0].pts
        last_rec = slice_records[-1]
        end_pts = last_rec.pts + last_rec.duration_pts

        windows.append(
            SlidingWindowSpec(
                window_index=w_idx,
                start_frame_id=start_f,
                end_frame_id_exclusive=end_f,
                intended_frame_ids=frame_ids,
                start_pts_ticks=start_pts,
                end_pts_ticks=end_pts,
                time_base_num=slice_records[0].time_base_num,
                time_base_den=slice_records[0].time_base_den,
                is_boundary_padded=(len(frame_ids) % 2 != 0),
            )
        )
        w_idx += 1
        if pos + window_size >= n:
            break
        pos += stride

    return windows


def compute_pipeline_input_fingerprint(
    source_revision_id: str,
    source_sha256: str,
    runtime_profile_id: str,
    window_size: int,
    overlap: int,
    total_declared_frames: int,
    prefilter_signature: Optional[Dict[str, Any]] = None,
) -> str:
    """Canonical SHA-256 fingerprint for S12 checkpoint validation (prevents mixing old/new profiles on resume)."""
    payload: Dict[str, Any] = {
            "analysis_contract": "declared-sampling-v2",
            "overlap": overlap,
            "runtime_profile_id": runtime_profile_id,
            "schema_version": 2,
            "source_revision_id": source_revision_id,
            "source_sha256": source_sha256,
            "total_declared_frames": total_declared_frames,
            "window_size": window_size,
        }
    if prefilter_signature is not None:
        payload["prefilter"] = prefilter_signature
    canonical = json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def encode_frame_id_ranges(frame_ids: Sequence[int]) -> List[List[int]]:
    """Compact a sorted frame-id list into inclusive [start, end] ranges."""
    ordered = sorted({int(x) for x in frame_ids})
    if not ordered:
        return []
    ranges: List[List[int]] = []
    start = prev = ordered[0]
    for fid in ordered[1:]:
        if fid == prev + 1:
            prev = fid
            continue
        ranges.append([start, prev])
        start = prev = fid
    ranges.append([start, prev])
    return ranges


def compact_coverage_ledger_payload(
    payload: Dict[str, Any],
    *,
    max_inline_ids: int = 4096,
) -> Dict[str, Any]:
    """
    Keep `g2.analyze_source` under the 1 MiB JSON-RPC frame for long sources.

    Frame-id lists are always mirrored as inclusive ranges. When a list exceeds
    `max_inline_ids` it is replaced by an empty list plus an explicit
    `frame_ids_truncated = True` flag and a `*_count`, so no consumer can mistake
    an omitted list for "zero frames processed".
    """
    compact = dict(payload)
    unique_ids = list(compact.get("unique_post_processor_frame_ids") or [])
    valid_ids = list(compact.get("valid_decoded_frame_ids") or [])
    truncated = len(unique_ids) > max_inline_ids or len(valid_ids) > max_inline_ids

    compact["frame_ids_truncated"] = truncated
    compact["frame_id_ranges"] = {
        "unique_post_processor": encode_frame_id_ranges(unique_ids),
        "valid_decoded": encode_frame_id_ranges(valid_ids),
    }
    compact["unique_post_processor_frame_count"] = len(unique_ids)
    compact["valid_decoded_frame_count"] = len(valid_ids)

    if truncated:
        compact["unique_post_processor_frame_ids"] = []
        compact["valid_decoded_frame_ids"] = []

    return compact


def merge_window_observations(
    raw_observations: Sequence[RawObservationRecord],
) -> List[MergedSegmentCandidate]:
    """
    S12.4 & docs/07 Section 3:
    Merges raw observations across overlapping windows without deleting underlying observations:
    1. Groups adjacent observations with overlapping frame intervals and matching action_or_scene_type + subject_track_id.
    2. Keeps separate events if there is a clear gap or distinct repetition (same scene, different action turn).
    3. Records `conflicting_hypotheses` when overlapping windows produce contradictory descriptions for the same frames.
    """
    raw_only = [obs for obs in raw_observations if obs.pass_role == "raw_independent"]
    if not raw_only:
        return []

    sorted_obs = sorted(raw_only, key=lambda o: (o.frame_ids[0], o.window_index, o.observation_id))
    segments: List[MergedSegmentCandidate] = []

    current_group: List[RawObservationRecord] = [sorted_obs[0]]

    for nxt in sorted_obs[1:]:
        prev = current_group[-1]
        prev_set = set(prev.frame_ids)
        nxt_set = set(nxt.frame_ids)
        has_frame_overlap = len(prev_set.intersection(nxt_set)) > 0

        same_action = prev.action_or_scene_type == nxt.action_or_scene_type
        same_subject = prev.subject_track_id == nxt.subject_track_id

        if has_frame_overlap and same_action and same_subject:
            current_group.append(nxt)
        elif has_frame_overlap and same_subject and not same_action:
            # Contradictory or competing descriptions on the exact same overlapping frames
            current_group.append(nxt)
        else:
            segments.append(_build_merged_segment(len(segments), current_group))
            current_group = [nxt]

    if current_group:
        segments.append(_build_merged_segment(len(segments), current_group))

    return segments


def _build_merged_segment(idx: int, group: Sequence[RawObservationRecord]) -> MergedSegmentCandidate:
    first = group[0]
    all_frames = sorted({fid for obs in group for fid in obs.frame_ids})
    start_pts = min(obs.start_pts_ticks for obs in group)
    end_pts = max(obs.end_pts_ticks for obs in group)
    actions = list(dict.fromkeys(obs.action_or_scene_type for obs in group))

    if len(actions) > 1:
        primary_action = actions[0]
        supporting = [obs.observation_id for obs in group if obs.action_or_scene_type == primary_action]
        competing = [obs.observation_id for obs in group if obs.action_or_scene_type != primary_action]
        status = "conflicting_hypotheses"
        summary = " / [CONFLICT] ".join(obs.observation_text for obs in group)
    elif len(group) > 1:
        supporting = [obs.observation_id for obs in group]
        competing = []
        status = "merged_continuous"
        summary = group[0].observation_text
    else:
        supporting = [first.observation_id]
        competing = []
        status = "kept_separate_repetition"
        summary = first.observation_text

    return MergedSegmentCandidate(
        segment_id=f"seg-{first.source_revision_id[:8]}-{idx:04d}",
        source_revision_id=first.source_revision_id,
        start_frame_id=all_frames[0],
        end_frame_id_exclusive=all_frames[-1] + 1,
        start_pts_ticks=start_pts,
        end_pts_ticks=end_pts,
        action_or_scene_type=actions[0],
        subject_track_id=first.subject_track_id,
        supporting_observation_ids=supporting,
        competing_observation_ids=competing,
        merge_status=status,
        boundary_uncertain=any(obs.has_uncertainty_boundary for obs in group),
        summary_text=summary,
    )


class FullFrameAnalysisPipeline:
    """
    S12.1 - S12.6: Full-Frame Multi-Scale Analysis Pipeline with Window Checkpointing,
    Brief-Agnostic First Pass, Guided Revisit Isolation, Omission Audit, and Bounded Resource Guards.
    """

    def __init__(self, config: Optional[BoundedPipelineConfig] = None) -> None:
        self.config = config or BoundedPipelineConfig()
        self._in_memory_log_ring: List[str] = []

    def _append_log(self, msg: str) -> None:
        self._in_memory_log_ring.append(msg)
        if len(self._in_memory_log_ring) > self.config.max_in_memory_log_entries:
            # Evict oldest to strictly bound in-memory log buffer (S12.T4)
            del self._in_memory_log_ring[0 : len(self._in_memory_log_ring) - self.config.max_in_memory_log_entries]

    @property
    def log_buffer_size(self) -> int:
        return len(self._in_memory_log_ring)

    def run_or_resume_analysis(
        self,
        *,
        source_revision_id: str,
        source_sha256: str,
        pts_index: Sequence[SourceFrameEntry],
        total_declared_source_frames: int,
        corrupted_decode_frame_ids: Sequence[int] = (),
        checkpoint_path: Path,
        has_audio_stream: bool = True,
        raw_audio_transcript_segments: Optional[Sequence[Dict[str, Any]]] = None,
        window_inspector_fn: Optional[Callable[[SlidingWindowSpec], Dict[str, Any]]] = None,
        window_prefilter: Optional[Callable[[SlidingWindowSpec], Dict[str, Any]]] = None,
        prefilter_signature: Optional[Dict[str, Any]] = None,
        stop_after_window_index: Optional[int] = None,
        simulated_ram_rss_bytes: Optional[int] = None,
        simulated_free_ssd_bytes: Optional[int] = None,
    ) -> Tuple[AssetCoverageLedger, List[RawObservationRecord], AudioBranchAnalysisResult, List[OmissionAuditFinding]]:
        """
        Executes or resumes full-frame window analysis:
        1. Validates or initializes checkpoint file on disk. Rejects profile/fingerprint mismatch on resume (S12.T2).
        2. Processes each uncommitted window within bounded frame queue limits (`<= max_in_memory_frame_queue`).
        3. Runs post-processor coverage audit for each window and commits window checkpoint atomically.
        4. Runs independent audio branch (`no_audio` / `no_speech` / `speech_detected`) without blocking visual pass (S12.T1).
        5. Runs boundary & silent-scenic omission audit after windows complete (S12.5).
        """
        expected_fp = compute_pipeline_input_fingerprint(
            source_revision_id=source_revision_id,
            source_sha256=source_sha256,
            runtime_profile_id=self.config.runtime_profile_id,
            window_size=self.config.window_size_frames,
            overlap=self.config.window_overlap_frames,
            total_declared_frames=total_declared_source_frames,
            prefilter_signature=prefilter_signature,
        )

        corrupted_set = {int(x) for x in corrupted_decode_frame_ids}
        valid_pts_records = [r for r in pts_index if r.frame_id not in corrupted_set]

        # 2026-11-10 fix (D04): the coverage denominator must be the container's declared
        # frame count, not the length of the very list we are about to divide by.
        if total_declared_source_frames <= 0:
            raise FullFramePipelineError(
                "INVALID_DECLARED_FRAME_COUNT",
                "total_declared_source_frames must be positive.",
            )
        if len(pts_index) > total_declared_source_frames:
            raise FullFramePipelineError(
                "INDEX_DENOMINATOR_MISMATCH",
                f"PTS index has {len(pts_index)} frames but the container declares only "
                f"{total_declared_source_frames}; refusing to compute a coverage ratio above 100%.",
                {"indexed_frames": len(pts_index), "declared_frames": total_declared_source_frames},
            )
        if len(pts_index) < int(total_declared_source_frames * 0.95):
            raise FullFramePipelineError(
                "INDEX_DENOMINATOR_MISMATCH",
                f"PTS index covers {len(pts_index)}/{total_declared_source_frames} declared frames "
                "(more than 5% missing); the media index is incomplete.",
                {"indexed_frames": len(pts_index), "declared_frames": total_declared_source_frames},
            )
        windows = generate_overlapping_windows(
            valid_pts_records,
            window_size=self.config.window_size_frames,
            overlap=self.config.window_overlap_frames,
        )

        # Load existing checkpoint if present
        committed_windows: Dict[int, Dict[str, Any]] = {}
        skipped_windows: Dict[int, Dict[str, Any]] = {}
        raw_observations: List[RawObservationRecord] = []

        if checkpoint_path.is_file():
            ckpt = json.loads(checkpoint_path.read_text(encoding="utf-8"))
            saved_fp = ckpt.get("input_fingerprint")
            if saved_fp != expected_fp:
                raise FullFramePipelineError(
                    "CHECKPOINT_PROFILE_MISMATCH",
                    f"Cannot resume checkpoint: fingerprint mismatch (saved={saved_fp}, expected={expected_fp}).",
                    {"saved_fingerprint": saved_fp, "expected_fingerprint": expected_fp},
                )
            for w_entry in ckpt.get("committed_windows", []):
                w_idx = int(w_entry["window_index"])
                committed_windows[w_idx] = w_entry
            for skip_entry in ckpt.get("skipped_windows", []):
                skipped_windows[int(skip_entry["window_index"])] = skip_entry
            for obs_dict in ckpt.get("raw_observations", []):
                raw_observations.append(RawObservationRecord(**obs_dict))
            self._append_log(f"Resumed checkpoint with {len(committed_windows)}/{len(windows)} committed windows.")

        paused_by_resource = False
        paused_by_caller = False
        blocked_model_unavailable = False

        for win in windows:
            if win.window_index in committed_windows:
                continue

            # 2026-11-10 prefilter: decide BEFORE doing any decode/memory work. A skipped
            # window is persisted with its score/reason and produces no observation.
            if window_prefilter is not None:
                decision = window_prefilter(win) or {}
                if decision.get("analyze") is False:
                    skipped_windows[win.window_index] = {
                        "window_index": win.window_index,
                        "score": float(decision.get("score", 0.0)),
                        "reason": str(decision.get("reason", "prefilter")),
                    }
                    committed_windows[win.window_index] = {
                        "window_index": win.window_index,
                        "prefilter_skipped": True,
                        "actual_processed_frame_ids": [],
                    }
                    self._write_checkpoint_atomic(
                        checkpoint_path=checkpoint_path,
                        input_fingerprint=expected_fp,
                        source_revision_id=source_revision_id,
                        committed_windows=committed_windows,
                        skipped_windows=skipped_windows,
                        raw_observations=raw_observations,
                    )
                    self._append_log(
                        f"Skipped window {win.window_index} by prefilter "
                        f"(score={skipped_windows[win.window_index]['score']:.4f}, "
                        f"reason={skipped_windows[win.window_index]['reason']})."
                    )
                    continue

            # Check bounded in-memory frame queue guard (S12.1 & S12.T4)
            if len(win.intended_frame_ids) > self.config.max_in_memory_frame_queue:
                raise FullFramePipelineError(
                    "FRAME_QUEUE_OVERFLOW",
                    f"Window {win.window_index} frame count ({len(win.intended_frame_ids)}) exceeds max_in_memory_frame_queue ({self.config.max_in_memory_frame_queue}).",
                )

            # Check RAM & real SSD resource pressure before processing window (S12.T4 & JOB-05)
            mem_snap = measure_current_process_memory(
                phase_name=f"s12_window_{win.window_index}",
                budget_limit_bytes=self.config.ram_budget_limit_bytes,
            )
            effective_rss = simulated_ram_rss_bytes if simulated_ram_rss_bytes is not None else mem_snap.rss_bytes
            if simulated_free_ssd_bytes is not None:
                effective_ssd = simulated_free_ssd_bytes
            else:
                checkpoint_path.parent.mkdir(parents=True, exist_ok=True)
                effective_ssd = int(shutil.disk_usage(checkpoint_path.parent).free)

            if effective_rss > self.config.ram_budget_limit_bytes or effective_ssd < self.config.min_free_ssd_bytes:
                paused_by_resource = True
                self._append_log(
                    f"Resource pressure at window {win.window_index} (rss={effective_rss}, ssd={effective_ssd}). Pausing with valid checkpoint."
                )
                break

            # Execute brief-agnostic raw visual inspection on the window:
            # NEVER fabricate default 'visual_model' observations or 100% coverage when no visual model / inspector is available!
            if window_inspector_fn is None:
                blocked_model_unavailable = True
                self._append_log(
                    f"Blocked at window {win.window_index}: visual model / window_inspector_fn is unavailable (refusing to fabricate observations)."
                )
                break

            insp = window_inspector_fn(win)
            if not isinstance(insp, dict):
                raise FullFramePipelineError(
                    "INVALID_VISUAL_PAYLOAD",
                    f"Window {win.window_index} inspector returned {type(insp).__name__}, expected a mapping.",
                )

            # Enforce S12.3 / AI-02: raw pass must never inject brief hypothesis
            if insp.get("guided_hypothesis_ref") is not None:
                raise FullFramePipelineError(
                    "BRIEF_LEAKAGE_IN_RAW_PASS",
                    "Window inspector attempted to inject brief hypothesis during raw_independent pass.",
                )

            # 2026-11-10 fix (D02): never default to the full window. The inspector must
            # declare the exact frames it planned to submit; missing/empty evidence is a
            # hard failure, not a fabricated observation at 100% coverage.
            planned_raw = insp.get("planned_frame_ids")
            if planned_raw is None:
                planned_raw = insp.get("accepted_frame_ids")
            accepted_raw = insp.get("accepted_frame_ids")
            if not planned_raw or not accepted_raw:
                raise FullFramePipelineError(
                    "INVALID_VISUAL_PAYLOAD",
                    f"Window {win.window_index} inspector returned no planned/accepted frame ids.",
                )
            planned_ids = [int(x) for x in planned_raw]
            accepted_ids = [int(x) for x in accepted_raw]
            if not set(accepted_ids).issubset(set(planned_ids)):
                raise FullFramePipelineError(
                    "VISUAL_COVERAGE_MISMATCH",
                    f"Window {win.window_index} accepted frames {sorted(set(accepted_ids) - set(planned_ids))} "
                    "were never declared as planned samples.",
                    {"window_index": win.window_index},
                )

            observation_text = str(insp.get("observation_text") or "").strip()
            scene_type = insp.get("action_or_scene_type")
            if not observation_text:
                raise FullFramePipelineError(
                    "INVALID_VISUAL_PAYLOAD",
                    f"Window {win.window_index} inspector returned an empty observation_text.",
                )
            if not isinstance(scene_type, str) or not re.fullmatch(r"[a-z0-9_]{1,64}", scene_type):
                raise FullFramePipelineError(
                    "INVALID_VISUAL_PAYLOAD",
                    f"Window {win.window_index} inspector returned invalid action_or_scene_type {scene_type!r}.",
                )

            audit: PostProcessorFrameAudit = audit_vision_processor_coverage(
                runtime_profile_id=self.config.runtime_profile_id,
                intended_frame_ids=planned_ids,
                processor_accepted_frame_ids=accepted_ids,
                temporal_patch_size=self.config.temporal_patch_size,
                input_width=1920,
                input_height=1080,
                pixel_budget=512 * 28 * 28,
            )
            if audit.truncation_detected:
                raise FullFramePipelineError(
                    "POST_PROCESSOR_TRUNCATION",
                    f"Window {win.window_index} dropped declared frames {audit.dropped_or_truncated_frame_ids} after processor.",
                    {"window_index": win.window_index, "dropped": audit.dropped_or_truncated_frame_ids},
                )

            obs = RawObservationRecord(
                observation_id=f"obs-{source_revision_id[:8]}-w{win.window_index:04d}",
                source_revision_id=source_revision_id,
                window_index=win.window_index,
                pass_role="raw_independent",
                origin="visual_model",
                epistemic_status="observed",
                frame_ids=list(audit.actual_processed_frame_ids),
                start_pts_ticks=win.start_pts_ticks,
                end_pts_ticks=win.end_pts_ticks,
                time_base_num=win.time_base_num,
                time_base_den=win.time_base_den,
                action_or_scene_type=scene_type,
                subject_track_id=insp.get("subject_track_id"),
                observation_text=observation_text,
                ocr_raw_tokens=list(insp.get("ocr_raw_tokens", [])),
                ocr_is_uncertain=bool(insp.get("ocr_is_uncertain", False)),
                has_uncertainty_boundary=bool(insp.get("has_uncertainty_boundary", False)),
                guided_hypothesis_ref=None,
            )
            raw_observations.append(obs)
            committed_windows[win.window_index] = {
                "window_index": win.window_index,
                "planned_frame_ids": list(planned_ids),
                "actual_processed_frame_ids": list(audit.actual_processed_frame_ids),
                "post_processor_audit": audit.to_dict(),
            }

            # Persist checkpoint atomically after each committed window (S12.6)
            self._write_checkpoint_atomic(
                checkpoint_path=checkpoint_path,
                input_fingerprint=expected_fp,
                source_revision_id=source_revision_id,
                committed_windows=committed_windows,
                skipped_windows=skipped_windows,
                raw_observations=raw_observations,
            )
            self._append_log(f"Committed window {win.window_index} ({len(audit.actual_processed_frame_ids)} frames).")

            if stop_after_window_index is not None and win.window_index >= stop_after_window_index:
                paused_by_caller = True
                break

        # S12.5: Independent Audio Branch (never disables visual branch)
        if not has_audio_stream:
            audio_res = AudioBranchAnalysisResult(
                source_revision_id=source_revision_id,
                audio_state="no_audio",
                speech_segments=[],
                visual_branch_enabled=True,
                asr_status="no_audio",
            )
        elif not raw_audio_transcript_segments:
            audio_res = AudioBranchAnalysisResult(
                source_revision_id=source_revision_id,
                audio_state="no_speech",
                speech_segments=[],
                visual_branch_enabled=True,
                asr_status="not_configured",
            )
        else:
            audio_res = AudioBranchAnalysisResult(
                source_revision_id=source_revision_id,
                audio_state="speech_detected",
                speech_segments=list(raw_audio_transcript_segments),
                visual_branch_enabled=True,
                asr_status="completed",
            )

        # Compute union of unique processed frame IDs (never double-counting overlap!)
        unique_processed: Set[int] = set()
        total_submitted_with_overlap = 0
        for w_data in committed_windows.values():
            fids = [int(x) for x in w_data.get("actual_processed_frame_ids", [])]
            total_submitted_with_overlap += len(fids)
            unique_processed.update(fids)

        valid_decoded_ids = sorted(r.frame_id for r in valid_pts_records)
        corrupted_ids_sorted = sorted(corrupted_set)
        unique_sorted = sorted(unique_processed)

        denom_total = max(1, total_declared_source_frames)
        # 2026-11-10 fix (D04): clamp every ratio to [0, 1]. The declared denominator is
        # the container frame count, so a partial or corrupt index can no longer inflate it.
        decode_cov = min(1.0, len(valid_decoded_ids) / float(denom_total))
        frame_input_cov = min(1.0, len(unique_sorted) / float(denom_total))
        valid_input_cov = min(1.0, len(unique_sorted) / float(max(1, len(valid_decoded_ids))))
        vlm_cov = min(1.0, len(unique_sorted) / float(denom_total))

        all_windows_done = len(committed_windows) == len(windows)
        skipped_sorted = sorted(skipped_windows.keys())
        if blocked_model_unavailable:
            detailed_status = "blocked_model_unavailable"
        elif paused_by_resource:
            detailed_status = "blocked_resource"
        elif paused_by_caller or not all_windows_done:
            detailed_status = "paused_checkpoint"
        elif corrupted_ids_sorted:
            detailed_status = "partial_with_decode_errors"
        elif skipped_sorted:
            detailed_status = "completed_prefiltered"
        else:
            detailed_status = "completed"

        # Run targeted omission audit on window boundaries, silent scenic clips & corrupted regions
        omission_findings = self._run_omission_audit(
            source_revision_id=source_revision_id,
            windows=windows,
            raw_observations=raw_observations,
            audio_res=audio_res,
            corrupted_frame_ids=corrupted_ids_sorted,
            all_windows_done=all_windows_done,
        )

        ledger = AssetCoverageLedger(
            source_revision_id=source_revision_id,
            runtime_profile_id=self.config.runtime_profile_id,
            input_fingerprint=expected_fp,
            total_declared_source_frames=total_declared_source_frames,
            valid_decoded_frame_ids=valid_decoded_ids,
            corrupted_decode_frame_ids=corrupted_ids_sorted,
            unique_post_processor_frame_ids=unique_sorted,
            total_submitted_frames_with_overlap=total_submitted_with_overlap,
            decode_coverage_ratio=round(decode_cov, 6),
            frame_input_coverage=round(frame_input_cov, 6),
            valid_frame_input_coverage=round(valid_input_cov, 6),
            vlm_frame_coverage=round(vlm_cov, 6),
            skipped_window_indices=skipped_sorted,
            prefilter_skipped_count=len(skipped_sorted),
            completed_window_indices=sorted(committed_windows.keys()),
            total_windows=len(windows),
            visual_scan_status=detailed_status,
            detailed_pass_status=detailed_status,
            audio_analysis_status=audio_res.asr_status,
            omission_audit_status="completed" if all_windows_done else "pending",
            semantic_understanding_certified=False,
        )

        return ledger, raw_observations, audio_res, omission_findings

    def run_guided_revisit_without_overwriting_raw(
        self,
        *,
        raw_observations: Sequence[RawObservationRecord],
        brief_hypothesis_id: str,
        expected_sign_text_from_brief: str,
    ) -> Tuple[List[RawObservationRecord], List[RawObservationRecord]]:
        """
        S12.3 & S12.T3 (AI-02):
        Runs a brief-guided revisit pass over existing raw observations.
        Invariants:
        1. The original `raw_observations` list is NEVER mutated or overwritten.
        2. If the raw observation had uncertain/blurry OCR (e.g. `['ĐÈO', 'PR???']`), the guided revisit
           creates a SEPARATE `guided_revisit` record that notes the brief hypothesis without falsifying
           the blurry OCR into an `observed` certainty.
        """
        preserved_raw = list(raw_observations)
        guided_records: List[RawObservationRecord] = []

        for raw in preserved_raw:
            if raw.pass_role != "raw_independent":
                continue
            if raw.ocr_is_uncertain or raw.ocr_raw_tokens:
                guided_obs = RawObservationRecord(
                    observation_id=f"{raw.observation_id}-guided-{brief_hypothesis_id[:6]}",
                    source_revision_id=raw.source_revision_id,
                    window_index=raw.window_index,
                    pass_role="guided_revisit",
                    origin=raw.origin,
                    epistemic_status="unknown" if raw.ocr_is_uncertain else "observed",
                    frame_ids=list(raw.frame_ids),
                    start_pts_ticks=raw.start_pts_ticks,
                    end_pts_ticks=raw.end_pts_ticks,
                    time_base_num=raw.time_base_num,
                    time_base_den=raw.time_base_den,
                    action_or_scene_type=raw.action_or_scene_type,
                    subject_track_id=raw.subject_track_id,
                    observation_text=(
                        f"Đối chiếu giả thuyết brief '{expected_sign_text_from_brief}': "
                        f"chữ trên hình còn mờ ({raw.ocr_raw_tokens}), giữ nguyên trạng thái chưa rõ, không tự sửa OCR gốc."
                    ),
                    ocr_raw_tokens=list(raw.ocr_raw_tokens),
                    ocr_is_uncertain=raw.ocr_is_uncertain,
                    has_uncertainty_boundary=raw.has_uncertainty_boundary,
                    guided_hypothesis_ref=brief_hypothesis_id,
                )
                guided_records.append(guided_obs)

        return preserved_raw, guided_records

    def _run_omission_audit(
        self,
        *,
        source_revision_id: str,
        windows: Sequence[SlidingWindowSpec],
        raw_observations: Sequence[RawObservationRecord],
        audio_res: AudioBranchAnalysisResult,
        corrupted_frame_ids: Sequence[int],
        all_windows_done: bool,
    ) -> List[OmissionAuditFinding]:
        findings: List[OmissionAuditFinding] = []
        if not all_windows_done:
            return findings

        # 1. Silent scenic check (AI-01: silent or no_audio clips still retain scenic/action candidates)
        if audio_res.audio_state in ("no_audio", "no_speech") and raw_observations:
            all_fids = sorted({fid for obs in raw_observations for fid in obs.frame_ids})
            findings.append(
                OmissionAuditFinding(
                    finding_id=f"omit-{source_revision_id[:8]}-silent",
                    source_revision_id=source_revision_id,
                    category="silent_scenic",
                    inspected_frame_ids=all_fids,
                    status="recovered_evidence",
                    description=f"Clip '{audio_res.audio_state}' vẫn được phân tích đầy đủ {len(all_fids)} frame hình và giữ làm ứng viên dựng.",
                    linked_observation_id=raw_observations[0].observation_id,
                )
            )

        # 2. Window overlap boundary audit (short actions across window boundaries)
        for i in range(len(windows) - 1):
            w_curr = windows[i]
            w_next = windows[i + 1]
            overlap_fids = sorted(set(w_curr.intended_frame_ids).intersection(w_next.intended_frame_ids))
            if overlap_fids:
                findings.append(
                    OmissionAuditFinding(
                        finding_id=f"omit-{source_revision_id[:8]}-bound-{i:03d}",
                        source_revision_id=source_revision_id,
                        category="short_action_boundary",
                        inspected_frame_ids=overlap_fids,
                        status="recovered_evidence",
                        description=f"Đã kiểm vùng chồng lấn biên cửa sổ {i}->{i+1} (frames {overlap_fids[0]}..{overlap_fids[-1]}).",
                    )
                )

        # 3. Corrupted decode region audit (never silently dropped from denominator)
        if corrupted_frame_ids:
            findings.append(
                OmissionAuditFinding(
                    finding_id=f"omit-{source_revision_id[:8]}-corrupt",
                    source_revision_id=source_revision_id,
                    category="decode_corrupted_region",
                    inspected_frame_ids=list(corrupted_frame_ids),
                    status="remained_uncertain",
                    description=f"Phát hiện {len(corrupted_frame_ids)} frame lỗi giải mã; giữ nguyên trong mẫu số coverage.",
                )
            )

        return findings

    @staticmethod
    def _write_checkpoint_atomic(
        *,
        checkpoint_path: Path,
        input_fingerprint: str,
        source_revision_id: str,
        committed_windows: Dict[int, Dict[str, Any]],
        raw_observations: Sequence[RawObservationRecord],
        skipped_windows: Optional[Dict[int, Dict[str, Any]]] = None,
    ) -> None:
        checkpoint_path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = checkpoint_path.with_suffix(".tmp")
        payload = {
            "source_revision_id": source_revision_id,
            "input_fingerprint": input_fingerprint,
            "committed_windows": [committed_windows[k] for k in sorted(committed_windows.keys())],
            "skipped_windows": [skipped_windows[k] for k in sorted(skipped_windows.keys())] if skipped_windows else [],
            "raw_observations": [obs.to_dict() for obs in raw_observations],
        }
        tmp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp_path.replace(checkpoint_path)
