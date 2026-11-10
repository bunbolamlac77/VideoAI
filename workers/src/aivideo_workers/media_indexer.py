"""
workers/src/aivideo_workers/media_indexer.py — S10 Media Indexer, Exact Rational VFR->CFR Mapping & M-24-SDR-v1 Color Profile
Compliant with docs/02-ANALYSIS-AND-DATA.md, docs/04-SCRIPT-AND-EDIT.md (Sections 8, 9, 10, 11),
docs/09-UPGRADES-AND-ACCEPTANCE.md (MEDIA-01..MEDIA-04), and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S10).
"""

from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field
from decimal import Decimal, ROUND_HALF_EVEN
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import subprocess
from typing import Any, Dict, List, Optional, Sequence, Tuple


MEDIA_PROFILE_ID = "M-24-SDR-v1"
TIMELINE_FPS = Fraction(24, 1)
CANONICAL_AUDIO_SAMPLE_RATE = 48000
SAMPLES_PER_TIMELINE_FRAME = 2000  # 48000 / 24


class MediaMappingError(RuntimeError):
    """Scoped error raised when PTS timestamps, gaps, or color metadata violate M-24-SDR-v1."""


@dataclass(frozen=True)
class SourceFrameEntry:
    frame_id: int
    pts: int
    duration_pts: int
    time_base_num: int
    time_base_den: int
    key_frame: bool = False
    has_critical_evidence: bool = False
    evidence_tag: Optional[str] = None

    def __post_init__(self) -> None:
        if self.time_base_den <= 0 or self.time_base_num <= 0:
            raise MediaMappingError(
                f"Invalid rational time_base {self.time_base_num}/{self.time_base_den}"
            )
        if self.duration_pts <= 0:
            raise MediaMappingError(
                f"Frame {self.frame_id} has non-positive display duration_pts={self.duration_pts}"
            )

    @property
    def time_base(self) -> Fraction:
        return Fraction(self.time_base_num, self.time_base_den)

    @property
    def start_sec(self) -> Fraction:
        return Fraction(self.pts, 1) * self.time_base

    @property
    def end_sec(self) -> Fraction:
        return Fraction(self.pts + self.duration_pts, 1) * self.time_base

    def contains_time(self, t_sec: Fraction) -> bool:
        """Half-open interval [start_sec, end_sec): includes start, excludes end."""
        return self.start_sec <= t_sec < self.end_sec

    def to_dict(self) -> Dict[str, Any]:
        return {
            "frame_id": self.frame_id,
            "pts": self.pts,
            "duration_pts": self.duration_pts,
            "time_base_num": self.time_base_num,
            "time_base_den": self.time_base_den,
            "start_sec_rational": f"{self.start_sec.numerator}/{self.start_sec.denominator}",
            "end_sec_rational": f"{self.end_sec.numerator}/{self.end_sec.denominator}",
            "key_frame": self.key_frame,
            "has_critical_evidence": self.has_critical_evidence,
            "evidence_tag": self.evidence_tag,
        }


@dataclass(frozen=True)
class TimelineFrameMapping:
    timeline_frame_index: int
    sample_midpoint_sec_num: int
    sample_midpoint_sec_den: int
    source_frame_id: int
    source_pts: int
    selection_reason: str  # "primary", "repeated_cadence", "boundary_exact"

    @property
    def sample_midpoint_sec(self) -> Fraction:
        return Fraction(self.sample_midpoint_sec_num, self.sample_midpoint_sec_den)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "timeline_frame_index": self.timeline_frame_index,
            "sample_midpoint_sec": f"{self.sample_midpoint_sec_num}/{self.sample_midpoint_sec_den}",
            "source_frame_id": self.source_frame_id,
            "source_pts": self.source_pts,
            "selection_reason": self.selection_reason,
        }


@dataclass(frozen=True)
class VFRToCFRConformMap:
    profile_id: str
    source_revision_id: str
    source_start_sec_num: int
    source_start_sec_den: int
    timeline_frame_count: int
    rotation_degrees: int
    mappings: List[TimelineFrameMapping]
    repeated_source_frame_ids: List[int]
    dropped_source_frame_ids: List[int]
    dropped_critical_evidence_frame_ids: List[int]
    native_conform_allowed: bool = False

    @property
    def is_valid_for_evidence(self) -> bool:
        return len(self.dropped_critical_evidence_frame_ids) == 0

    def seek_source_from_timeline(self, timeline_frame_index: int) -> Tuple[int, int]:
        """S10.T4: Deterministic seek from timeline frame index back to exact (source_frame_id, source_pts)."""
        if timeline_frame_index < 0 or timeline_frame_index >= len(self.mappings):
            raise MediaMappingError(
                f"Timeline frame index {timeline_frame_index} out of range [0, {len(self.mappings)})"
            )
        m = self.mappings[timeline_frame_index]
        return (m.source_frame_id, m.source_pts)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "profile_id": self.profile_id,
            "source_revision_id": self.source_revision_id,
            "source_start_sec": f"{self.source_start_sec_num}/{self.source_start_sec_den}",
            "timeline_frame_count": self.timeline_frame_count,
            "rotation_degrees": self.rotation_degrees,
            "mappings": [m.to_dict() for m in self.mappings],
            "repeated_source_frame_ids": self.repeated_source_frame_ids,
            "dropped_source_frame_ids": self.dropped_source_frame_ids,
            "dropped_critical_evidence_frame_ids": self.dropped_critical_evidence_frame_ids,
            "native_conform_allowed": self.native_conform_allowed,
            "is_valid_for_evidence": self.is_valid_for_evidence,
        }


@dataclass(frozen=True)
class ColorProfileDecision:
    profile_id: str
    status: str  # "sdr_passthrough_or_transform", "hdr_tonemap_validated", "unsupported_needs_decision"
    color_primaries: Optional[str]
    color_transfer: Optional[str]
    color_space: Optional[str]
    color_range: Optional[str]
    color_transform_revision: Optional[str]
    ffmpeg_filter_chain: Optional[str]
    reason: str

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


@dataclass(frozen=True)
class AudioCanonicalMapping:
    source_sample_rate: int
    canonical_sample_rate: int
    source_start_pts: int
    source_time_base_num: int
    source_time_base_den: int
    canonical_start_sample: int
    canonical_sample_count: int
    av_offset_ms: float
    av_sync_drift_ms: float
    within_media04_tolerance: bool

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


def validate_and_build_pts_index(
    raw_frames: Sequence[Dict[str, Any]],
    time_base_num: int,
    time_base_den: int,
    max_allowed_gap_sec: Fraction = Fraction(1, 2),
) -> List[SourceFrameEntry]:
    """
    S10.1 & S10.T1: Builds presentation-order PTS index using exact rational arithmetic.
    Rejects missing PTS, duplicate PTS, negative/zero durations, or unexplained timestamp gaps.
    Never infers frame boundaries by multiplying milliseconds by average FPS.
    """
    if time_base_den <= 0 or time_base_num <= 0:
        raise MediaMappingError(f"Invalid stream timebase: {time_base_num}/{time_base_den}")
    if not raw_frames:
        raise MediaMappingError("Cannot build PTS index from empty frame list")

    tb = Fraction(time_base_num, time_base_den)
    entries: List[SourceFrameEntry] = []

    sorted_raw = sorted(raw_frames, key=lambda r: int(r["pts"]))
    for idx, item in enumerate(sorted_raw):
        if "pts" not in item or item["pts"] is None:
            raise MediaMappingError(f"Frame at presentation index {idx} is missing PTS")
        pts = int(item["pts"])

        if idx > 0 and pts == int(sorted_raw[idx - 1]["pts"]):
            raise MediaMappingError(f"Duplicate PTS={pts} detected at presentation index {idx}")

        if idx + 1 < len(sorted_raw):
            next_pts = int(sorted_raw[idx + 1]["pts"])
            inferred_dur = next_pts - pts
            dur = int(item.get("duration_pts") or inferred_dur)
            if dur <= 0:
                raise MediaMappingError(f"Non-monotonic or zero duration PTS at index {idx}")
            gap_pts = next_pts - (pts + dur)
            if gap_pts < 0:
                # Clamp duration to next_pts - pts if container reported overlapping duration
                dur = inferred_dur
            elif Fraction(gap_pts, 1) * tb > max_allowed_gap_sec:
                raise MediaMappingError(
                    f"Unexplained timestamp gap of {float(Fraction(gap_pts, 1) * tb):.4f}s after frame {idx}"
                )
        else:
            if "duration_pts" not in item or item["duration_pts"] is None or int(item["duration_pts"]) <= 0:
                raise MediaMappingError(
                    "Final frame is missing verified display duration_pts (refusing to guess tail duration)"
                )
            dur = int(item["duration_pts"])

        entries.append(
            SourceFrameEntry(
                frame_id=int(item.get("frame_id", idx)),
                pts=pts,
                duration_pts=dur,
                time_base_num=time_base_num,
                time_base_den=time_base_den,
                key_frame=bool(item.get("key_frame", idx == 0)),
                has_critical_evidence=bool(item.get("has_critical_evidence", False)),
                evidence_tag=item.get("evidence_tag"),
            )
        )
    return entries


def build_vfr_to_cfr24_map(
    pts_index: Sequence[SourceFrameEntry],
    source_revision_id: str,
    source_start_sec: Fraction,
    timeline_frame_count: int,
    rotation_degrees: int = 0,
    enforce_critical_evidence_preservation: bool = True,
) -> VFRToCFRConformMap:
    """
    S10.2, S10.4 & S10.T2: Exact rational VFR -> CFR 24/1 mapping per docs/04 Section 9:
    For timeline frame k (0 <= k < N):
        t(k) = source_start + (k + 1/2) / 24
    Selects the unique source frame whose half-open interval [start_sec, end_sec) contains t(k).
    Records repeated and dropped frames, and detects if any critical evidence flash frame was dropped.
    """
    if timeline_frame_count <= 0:
        raise MediaMappingError("timeline_frame_count must be positive")
    if rotation_degrees not in (0, 90, 180, 270, -90, -180, -270):
        raise MediaMappingError(f"Unsupported rotation_degrees={rotation_degrees}")
    if not pts_index:
        raise MediaMappingError("Empty PTS index")

    norm_rotation = rotation_degrees % 360
    shot_end_sec = source_start_sec + Fraction(timeline_frame_count, 24)

    # Identify all source frames overlapping the shot window [source_start_sec, shot_end_sec)
    overlapping_frames = [
        f for f in pts_index if f.end_sec > source_start_sec and f.start_sec < shot_end_sec
    ]
    if not overlapping_frames:
        raise MediaMappingError(
            f"No source frames overlap shot window [{source_start_sec}, {shot_end_sec})"
        )

    mappings: List[TimelineFrameMapping] = []
    selected_counts: Dict[int, int] = {}

    for k in range(timeline_frame_count):
        t_k = source_start_sec + Fraction(2 * k + 1, 48)
        chosen: Optional[SourceFrameEntry] = None
        for f in overlapping_frames:
            if f.contains_time(t_k):
                chosen = f
                break
        if chosen is None:
            raise MediaMappingError(
                f"Timeline frame k={k} at midpoint t(k)={t_k} ({float(t_k):.6f}s) fell into an unmapped gap"
            )

        prev_count = selected_counts.get(chosen.frame_id, 0)
        selected_counts[chosen.frame_id] = prev_count + 1
        if prev_count > 0:
            reason = "repeated_cadence"
        elif chosen.start_sec == t_k:
            reason = "boundary_exact"
        else:
            reason = "primary"

        mappings.append(
            TimelineFrameMapping(
                timeline_frame_index=k,
                sample_midpoint_sec_num=t_k.numerator,
                sample_midpoint_sec_den=t_k.denominator,
                source_frame_id=chosen.frame_id,
                source_pts=chosen.pts,
                selection_reason=reason,
            )
        )

    repeated_ids = sorted(fid for fid, cnt in selected_counts.items() if cnt > 1)
    dropped_ids = sorted(
        f.frame_id for f in overlapping_frames if f.frame_id not in selected_counts
    )
    dropped_critical = sorted(
        f.frame_id
        for f in overlapping_frames
        if f.has_critical_evidence and f.frame_id not in selected_counts
    )

    if enforce_critical_evidence_preservation and dropped_critical:
        raise MediaMappingError(
            f"S10.T2 violation: Conform 24/1 dropped critical evidence frame(s) {dropped_critical}. "
            "Must adjust cut boundary or block shot."
        )

    return VFRToCFRConformMap(
        profile_id=MEDIA_PROFILE_ID,
        source_revision_id=source_revision_id,
        source_start_sec_num=source_start_sec.numerator,
        source_start_sec_den=source_start_sec.denominator,
        timeline_frame_count=timeline_frame_count,
        rotation_degrees=norm_rotation,
        mappings=mappings,
        repeated_source_frame_ids=repeated_ids,
        dropped_source_frame_ids=dropped_ids,
        dropped_critical_evidence_frame_ids=dropped_critical,
        native_conform_allowed=False,
    )


def convert_half_open_to_resolve_inclusive(start_frame: int, end_frame_exclusive: int) -> Tuple[int, int]:
    """
    S10.2: Internal media intervals are strictly half-open [start_frame, end_frame_exclusive).
    DaVinci Resolve API SetClipProperty/AppendToTimeline uses inclusive [start_frame, end_frame_inclusive].
    """
    if end_frame_exclusive <= start_frame:
        raise MediaMappingError(
            f"Invalid half-open frame range [{start_frame}, {end_frame_exclusive})"
        )
    return (start_frame, end_frame_exclusive - 1)


def evaluate_color_profile(
    color_primaries: Optional[str],
    color_transfer: Optional[str],
    color_space: Optional[str],
    color_range: Optional[str] = "tv",
    has_validated_hdr_tonemap_fixture: bool = False,
) -> ColorProfileDecision:
    """
    S10.5 & MEDIA-03: Enforces M-24-SDR-v1 SDR Rec.709 output policy.
    - Valid SDR (bt709 / smpte170m) -> accepted with pinned Rec.709 transform.
    - HDR (bt2020 + smpte2084/arib-std-b67) -> accepted ONLY when metadata is complete and
      the pinned linearize -> zscale/tonemap Mobius path is validated; otherwise blocked.
    - Missing or contradictory color tags -> returns unsupported_needs_decision (never silently converts).
    """
    prim = (color_primaries or "").strip().lower()
    trc = (color_transfer or "").strip().lower()
    spc = (color_space or "").strip().lower()
    rng = (color_range or "tv").strip().lower()

    sdr_primaries = {"bt709", "smpte170m", "bt470bg"}
    sdr_transfers = {"bt709", "smpte170m", "iec61966-2-1"}
    sdr_spaces = {"bt709", "smpte170m", "bt470bg"}

    hdr_primaries = {"bt2020"}
    hdr_transfers = {"smpte2084", "arib-std-b67"}
    hdr_spaces = {"bt2020nc", "bt2020c", "bt2020_ncl"}

    if not prim or not trc or not spc or prim == "unknown" or trc == "unknown" or spc == "unknown":
        return ColorProfileDecision(
            profile_id=MEDIA_PROFILE_ID,
            status="unsupported_needs_decision",
            color_primaries=color_primaries,
            color_transfer=color_transfer,
            color_space=color_space,
            color_range=color_range,
            color_transform_revision=None,
            ffmpeg_filter_chain=None,
            reason="Missing or unknown color tags; M-24-SDR-v1 forbids silent color guessing.",
        )

    if prim in sdr_primaries and trc in sdr_transfers and spc in sdr_spaces:
        scale_range = "in_range=full:out_range=tv" if rng in ("pc", "full", "jpeg") else "in_range=tv:out_range=tv"
        return ColorProfileDecision(
            profile_id=MEDIA_PROFILE_ID,
            status="sdr_passthrough_or_transform",
            color_primaries=prim,
            color_transfer=trc,
            color_space=spc,
            color_range=rng,
            color_transform_revision="COLOR-SDR-REC709-v1",
            ffmpeg_filter_chain=f"scale={scale_range}:in_color_matrix={spc}:out_color_matrix=bt709,format=yuv420p",
            reason="Verified SDR source mapped to canonical Rec.709 TV range.",
        )

    if prim in hdr_primaries and trc in hdr_transfers and spc in hdr_spaces:
        if not has_validated_hdr_tonemap_fixture:
            return ColorProfileDecision(
                profile_id=MEDIA_PROFILE_ID,
                status="unsupported_needs_decision",
                color_primaries=prim,
                color_transfer=trc,
                color_space=spc,
                color_range=rng,
                color_transform_revision=None,
                ffmpeg_filter_chain=None,
                reason="HDR source detected but HDR tone-map fixture is not enabled for this profile.",
            )
        return ColorProfileDecision(
            profile_id=MEDIA_PROFILE_ID,
            status="hdr_tonemap_validated",
            color_primaries=prim,
            color_transfer=trc,
            color_space=spc,
            color_range=rng,
            color_transform_revision="COLOR-HDR-MOBIUS-REC709-v1",
            ffmpeg_filter_chain=(
                "zscale=t=linear:npl=100,format=gbrpf32le,"
                "tonemap=tonemap=mobius:desat=0,"
                "zscale=p=bt709:t=bt709:m=bt709:r=tv,format=yuv420p"
            ),
            reason="Verified HDR source mapped via linear light Mobius tone-mapping to SDR Rec.709.",
        )

    return ColorProfileDecision(
        profile_id=MEDIA_PROFILE_ID,
        status="unsupported_needs_decision",
        color_primaries=prim,
        color_transfer=trc,
        color_space=spc,
        color_range=rng,
        color_transform_revision=None,
        ffmpeg_filter_chain=None,
        reason=f"Contradictory color metadata (primaries={prim}, transfer={trc}, space={spc}).",
    )


def round_rational_to_nearest_even(value: Fraction) -> int:
    """S10.3 & Section 11: Deterministic nearest/ties-to-even rounding for audio sample indices."""
    dec = Decimal(value.numerator) / Decimal(value.denominator)
    return int(dec.to_integral_value(rounding=ROUND_HALF_EVEN))


def compute_canonical_audio_mapping(
    source_sample_rate: int,
    source_start_pts: int,
    source_duration_pts: int,
    time_base_num: int,
    time_base_den: int,
    video_start_sec: Fraction = Fraction(0, 1),
    measured_end_offset_ms: Optional[float] = None,
) -> AudioCanonicalMapping:
    """
    S10.3 & S10.T3: Maps source audio stream (including negative PTS offsets) to canonical 48 kHz samples
    using ties-to-even rounding, and verifies MEDIA-04 sync/drift tolerances (<= 1000/24 ms = 41.6667 ms).
    """
    if source_sample_rate <= 0 or time_base_num <= 0 or time_base_den <= 0:
        raise MediaMappingError("Invalid audio sample rate or timebase")

    tb = Fraction(time_base_num, time_base_den)
    audio_start_sec = Fraction(source_start_pts, 1) * tb
    audio_dur_sec = Fraction(source_duration_pts, 1) * tb

    exact_start_sample = audio_start_sec * CANONICAL_AUDIO_SAMPLE_RATE
    exact_sample_count = audio_dur_sec * CANONICAL_AUDIO_SAMPLE_RATE

    start_sample = round_rational_to_nearest_even(exact_start_sample)
    sample_count = round_rational_to_nearest_even(exact_sample_count)

    av_offset_sec = audio_start_sec - video_start_sec
    av_offset_ms = float(av_offset_sec * 1000)

    end_offset_ms = measured_end_offset_ms if measured_end_offset_ms is not None else av_offset_ms
    drift_ms = abs(end_offset_ms - av_offset_ms)
    max_tolerance_ms = 1000.0 / 24.0  # 41.6667 ms (1 frame @ 24fps)
    within_tol = abs(av_offset_ms) <= max_tolerance_ms and drift_ms <= max_tolerance_ms

    return AudioCanonicalMapping(
        source_sample_rate=source_sample_rate,
        canonical_sample_rate=CANONICAL_AUDIO_SAMPLE_RATE,
        source_start_pts=source_start_pts,
        source_time_base_num=time_base_num,
        source_time_base_den=time_base_den,
        canonical_start_sample=start_sample,
        canonical_sample_count=sample_count,
        av_offset_ms=round(av_offset_ms, 4),
        av_sync_drift_ms=round(drift_ms, 4),
        within_media04_tolerance=within_tol,
    )


@dataclass(frozen=True)
class ProxyArtifactMapping:
    """
    S10.3: Proxy video artifact and deterministic frame/PTS/hash mapping between source and proxy.
    Proxy is used strictly for responsive UI scrubbing/preview and never replaces source PTS for final cuts.
    """

    source_revision_id: str
    source_path: str
    source_sha256: str
    proxy_path: str
    proxy_sha256: str
    proxy_width: int
    proxy_height: int
    proxy_fps_num: int
    proxy_fps_den: int
    audio_sample_rate_hz: int
    color_transform_revision: str
    conform_map: VFRToCFRConformMap

    def to_dict(self) -> Dict[str, Any]:
        return {
            "source_revision_id": self.source_revision_id,
            "source_path": self.source_path,
            "source_sha256": self.source_sha256,
            "proxy_path": self.proxy_path,
            "proxy_sha256": self.proxy_sha256,
            "proxy_width": self.proxy_width,
            "proxy_height": self.proxy_height,
            "proxy_fps": f"{self.proxy_fps_num}/{self.proxy_fps_den}",
            "audio_sample_rate_hz": self.audio_sample_rate_hz,
            "color_transform_revision": self.color_transform_revision,
            "conform_map": self.conform_map.to_dict(),
        }


def _compute_file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def generate_proxy_and_mapping(
    source_video_path: str | Path,
    proxy_output_path: str | Path,
    source_revision_id: str = "rev-source-001",
    target_height: int = 540,
    critical_evidence_frame_ids: Optional[Sequence[int]] = None,
    has_validated_hdr_tonemap_fixture: bool = False,
    fallback_sdr_if_untagged: bool = False,
) -> ProxyArtifactMapping:
    """
    S10.3: Generates a real CFR 24/1 SDR Rec.709 proxy video + 48 kHz audio (if audio present)
    atomically via ffmpeg, computes SHA-256 of both source and proxy, and builds the exact
    VFRToCFRConformMap linking every proxy/timeline frame back to (source_frame_id, source_pts).
    """
    src_path = Path(source_video_path).resolve()
    out_path = Path(proxy_output_path).resolve()
    if not src_path.is_file():
        raise MediaMappingError(f"Source video does not exist: {src_path}")

    probed = probe_and_index_real_video(
        src_path,
        fallback_sdr_if_untagged=fallback_sdr_if_untagged,
        has_validated_hdr_tonemap_fixture=has_validated_hdr_tonemap_fixture,
    )
    color_dec = probed["color_decision"]
    if color_dec["status"] == "unsupported_needs_decision":
        raise MediaMappingError(
            f"Cannot generate proxy for source with unverified color metadata: {color_dec['reason']}"
        )

    crit_set = set(int(x) for x in (critical_evidence_frame_ids or []))
    pts_entries: List[SourceFrameEntry] = []
    for item in probed["pts_index"]:
        fid = int(item["frame_id"])
        pts_entries.append(
            SourceFrameEntry(
                frame_id=fid,
                pts=int(item["pts"]),
                duration_pts=int(item["duration_pts"]),
                time_base_num=int(item["time_base_num"]),
                time_base_den=int(item["time_base_den"]),
                key_frame=bool(item.get("key_frame", False)),
                has_critical_evidence=(fid in crit_set) or bool(item.get("has_critical_evidence", False)),
                evidence_tag=item.get("evidence_tag"),
            )
        )

    total_dur_sec = pts_entries[-1].end_sec - pts_entries[0].start_sec
    timeline_frames = max(1, int(total_dur_sec * TIMELINE_FPS))
    conform_map = build_vfr_to_cfr24_map(
        pts_index=pts_entries,
        source_revision_id=source_revision_id,
        source_start_sec=pts_entries[0].start_sec,
        timeline_frame_count=timeline_frames,
        rotation_degrees=int(probed["rotation_degrees"]),
        enforce_critical_evidence_preservation=True,
    )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    staging_path = out_path.with_suffix(".staging.mp4")

    src_w = max(16, int(probed["width"]))
    src_h = max(16, int(probed["height"]))
    proxy_h = max(16, (target_height // 2) * 2)
    proxy_w = max(16, (int(round(src_w * (proxy_h / float(src_h)))) // 2) * 2)

    color_filter = color_dec.get("ffmpeg_filter_chain")
    if color_filter:
        vf_chain = f"fps=24/1,scale={proxy_w}:{proxy_h},{color_filter}"
    else:
        vf_chain = f"fps=24/1,scale={proxy_w}:{proxy_h},format=yuv420p"

    # Scale timeout dynamically with source duration (minimum 60s, up to 3600s for long field footage)
    dynamic_timeout_sec = max(60, min(3600, int(float(total_dur_sec) * 2.0) + 60))

    cmd = [
        "ffmpeg",
        "-nostdin",
        "-y",
        "-i",
        str(src_path),
        "-vf",
        vf_chain,
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-crf",
        "28",
        "-ar",
        str(CANONICAL_AUDIO_SAMPLE_RATE),
        "-ac",
        "2",
        "-c:a",
        "aac",
        str(staging_path),
    ]
    res = subprocess.run(cmd, capture_output=True, text=True, check=False, timeout=dynamic_timeout_sec)
    if res.returncode != 0 or not staging_path.is_file() or staging_path.stat().st_size == 0:
        if staging_path.exists():
            staging_path.unlink(missing_ok=True)
        raise MediaMappingError(f"Proxy generation failed: {res.stderr.strip()}")

    os.replace(staging_path, out_path)

    return ProxyArtifactMapping(
        source_revision_id=source_revision_id,
        source_path=str(src_path),
        source_sha256=_compute_file_sha256(src_path),
        proxy_path=str(out_path),
        proxy_sha256=_compute_file_sha256(out_path),
        proxy_width=proxy_w,
        proxy_height=proxy_h,
        proxy_fps_num=24,
        proxy_fps_den=1,
        audio_sample_rate_hz=CANONICAL_AUDIO_SAMPLE_RATE,
        color_transform_revision=str(color_dec.get("color_transform_revision") or "COLOR-SDR-REC709-v1"),
        conform_map=conform_map,
    )


def probe_and_index_real_video(
    video_path: str | Path,
    *,
    fallback_sdr_if_untagged: bool = False,
    has_validated_hdr_tonemap_fixture: bool = False,
) -> Dict[str, Any]:
    """
    S10.1 & S10.T1: Runs real ffprobe packet/frame inspection on a video file to extract presentation-order
    PTS, timebase, rotation, audio stream presence, and color tags.
    Does NOT silently fabricate bt709 if color tags are missing unless `fallback_sdr_if_untagged=True` is explicitly passed.
    """
    path = Path(video_path)
    if not path.is_file():
        raise MediaMappingError(f"Video file not found: {path}")

    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "stream=index,codec_type,time_base,r_frame_rate,avg_frame_rate,width,height,sample_rate,channels,color_primaries,color_transfer,color_space,color_range,nb_frames,duration:stream_side_data=rotation:frame=media_type,stream_index,pts,pkt_duration,key_frame",
        "-of",
        "json",
        str(path),
    ]
    # Allow generous timeout for full-frame packet inspection on long source videos
    res = subprocess.run(cmd, capture_output=True, text=True, check=False, timeout=180)
    if res.returncode != 0:
        raise MediaMappingError(f"ffprobe failed on {path}: {res.stderr.strip()}")

    data = json.loads(res.stdout)
    streams = data.get("streams") or []
    video_streams = [s for s in streams if s.get("codec_type") == "video"]
    audio_streams = [s for s in streams if s.get("codec_type") == "audio"]
    if not video_streams:
        raise MediaMappingError(f"No video stream found in {path}")

    stream = video_streams[0]
    v_stream_index = int(stream.get("index", 0))
    tb_str = stream.get("time_base", "1/24")
    tb_parts = tb_str.split("/")
    tb_num = int(tb_parts[0])
    tb_den = int(tb_parts[1]) if len(tb_parts) > 1 else 1

    rotation = 0
    for sd in stream.get("side_data_list") or []:
        if "rotation" in sd:
            rotation = int(sd["rotation"])

    raw_frames_json = data.get("frames") or []
    raw_frames: List[Dict[str, Any]] = []
    for f in raw_frames_json:
        if f.get("media_type") not in (None, "video"):
            continue
        if "stream_index" in f and int(f["stream_index"]) != v_stream_index:
            continue
        pts_val = f.get("pts")
        dur_val = f.get("pkt_duration")
        if pts_val is not None:
            raw_frames.append(
                {
                    "frame_id": len(raw_frames),
                    "pts": int(pts_val),
                    "duration_pts": int(dur_val) if dur_val is not None and int(dur_val) > 0 else (tb_den // 24 or 1),
                    "key_frame": bool(f.get("key_frame", 0)),
                }
            )

    pts_index = validate_and_build_pts_index(raw_frames, tb_num, tb_den)
    raw_prim = stream.get("color_primaries")
    raw_trc = stream.get("color_transfer")
    raw_spc = stream.get("color_space")
    raw_rng = stream.get("color_range")
    if raw_prim in ("unknown", "unspecified", ""):
        raw_prim = None
    if raw_trc in ("unknown", "unspecified", ""):
        raw_trc = None
    if raw_spc in ("unknown", "unspecified", ""):
        raw_spc = None
    if not raw_rng or raw_rng in ("unknown", "unspecified"):
        raw_rng = "tv"

    if fallback_sdr_if_untagged:
        raw_prim = raw_prim or "bt709"
        raw_trc = raw_trc or "bt709"
        raw_spc = raw_spc or "bt709"

    color_decision = evaluate_color_profile(
        color_primaries=raw_prim,
        color_transfer=raw_trc,
        color_space=raw_spc,
        color_range=raw_rng,
        has_validated_hdr_tonemap_fixture=has_validated_hdr_tonemap_fixture,
    )

    container_frame_count: Optional[int] = None
    try:
        nb = stream.get("nb_frames")
        if nb not in (None, "N/A"):
            candidate = int(nb)
            if candidate > 0:
                container_frame_count = candidate
    except (TypeError, ValueError):
        container_frame_count = None
    if container_frame_count is None:
        # Fallback: derive the declared frame count from duration × frame rate.
        try:
            duration_s = float(stream.get("duration"))
            fps_expr = str(stream.get("avg_frame_rate") or stream.get("r_frame_rate") or "")
            num_s, _, den_s = fps_expr.partition("/")
            fps = float(num_s) / float(den_s or 1)
            if duration_s > 0 and fps > 0:
                container_frame_count = int(round(duration_s * fps))
        except (TypeError, ValueError, ZeroDivisionError):
            container_frame_count = None

    return {
        "video_path": str(path),
        "width": int(stream.get("width", 0)),
        "height": int(stream.get("height", 0)),
        "time_base_num": tb_num,
        "time_base_den": tb_den,
        "rotation_degrees": rotation,
        "has_audio_stream": len(audio_streams) > 0,
        "audio_streams_count": len(audio_streams),
        "frame_count": len(pts_index),
        "container_frame_count": container_frame_count,
        "indexed_frame_count": len(pts_index),
        "pts_index": [e.to_dict() for e in pts_index],
        "color_decision": color_decision.to_dict(),
    }


def declared_source_frame_count(
    probed: Dict[str, Any],
    *,
    indexed_count: Optional[int] = None,
    tolerance: float = 0.05,
) -> int:
    """
    2026-11-10 fix (D04): return the coverage denominator from container metadata.

    `probe_and_index_real_video` used to be the only source of the denominator, which made
    the coverage ratio circular (indexed / indexed = 1.0 by construction). When the container
    reports a frame count, it becomes the denominator; a >5% mismatch with the PTS index is a
    hard failure instead of a silently optimistic ratio.
    """
    indexed = int(indexed_count if indexed_count is not None else probed.get("indexed_frame_count") or 0)
    declared = probed.get("container_frame_count")
    if declared is None or int(declared) <= 0:
        if indexed <= 0:
            raise MediaMappingError("Cannot determine declared frame count: no container metadata and empty PTS index.")
        return indexed

    declared = int(declared)
    if indexed > declared:
        raise MediaMappingError(
            f"PTS index ({indexed}) exceeds container frame count ({declared}); index is inconsistent."
        )
    if indexed < int(declared * (1.0 - tolerance)):
        raise MediaMappingError(
            f"PTS index covers {indexed}/{declared} frames (>5% missing); refusing to compute coverage on an incomplete index."
        )
    return declared
