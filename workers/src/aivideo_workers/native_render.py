"""Native ffmpeg renderer for G4/G5 (replaces the DaVinci Resolve render path).

Why this exists: the final video is a concatenation of already-approved,
already-captioned 1080x1920 beats plus their narration WAVs. Resolve was used
only to splice them and export 4K, which cost a full NLE install and a multi-GB
resident app. ffmpeg is already a hard dependency of this project and renders
2160x3840 24fps in 5.3 s for 11.5 s of output with **762 MB** peak RSS
(h264_videotoolbox) or **1.49 GB** (libx264 veryfast, threads=4).

Contract kept identical to the Resolve path so gates/QC stay meaningful:
  * 24/1 CFR, bt709 tags, yuv420p, 48 kHz audio;
  * decoded frame count must equal the planned length;
  * captions are raster burn-in of the approved phrase cues (no invented text);
  * photos are `illustrative_only` inserts, never evidence for a claim.

New capabilities (the four confirmed editing requirements):
  1. Vietnamese captions burned in, plus an `.srt` sidecar;
  2. narration WAV per beat, padded/truncated to the beat length so picture and
     voice stay locked (per-phrase timing comes from `g3.engine.voice_phrases`);
  3. optional crossfade / dip-to-black between beats. Overlaps *shorten* the
     timeline, so the expected frame count is `sum(frames) - sum(overlaps)`;
  4. optional photo insert beats rendered as stills with a slow Ken Burns move.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence
import json
import math
import os
import re
import shutil
import subprocess
import tempfile
import textwrap

from .child_process import run_tracked

FPS = 24
DEFAULT_FONT = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
VALID_TRANSITIONS = ("crossfade", "dip_to_black")
ENCODERS = ("libx264", "h264_videotoolbox")


class NativeRenderError(RuntimeError):
    def __init__(self, code: str, message: str, *, detail: str = "") -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.detail = detail


@dataclass(frozen=True)
class CaptionCue:
    text: str
    start_frame: int
    end_frame: int

    def validate(self, beat_frames: int) -> None:
        if not isinstance(self.text, str) or not self.text.strip():
            raise NativeRenderError("EMPTY_CUE", "Caption cue text is empty")
        if "\n" in self.text or "\r" in self.text:
            raise NativeRenderError("CUE_NEWLINE", "Caption cue must be a single line")
        if not (0 <= self.start_frame < self.end_frame <= beat_frames):
            raise NativeRenderError(
                "CUE_OUT_OF_RANGE",
                f"Cue [{self.start_frame},{self.end_frame}) is outside beat length {beat_frames}",
            )


@dataclass
class RenderBeat:
    """One timeline item: a captioned video beat or an illustrative photo insert."""

    beat_id: str
    kind: str  # "video" | "photo"
    media_path: str
    frames: int
    voice_path: Optional[str] = None
    cues: List[CaptionCue] = field(default_factory=list)
    transition_in: Optional[str] = None  # None | "crossfade" | "dip_to_black"
    transition_frames: int = 0
    ken_burns: bool = True
    claim_refs: List[str] = field(default_factory=list)

    def validate(self) -> None:
        if self.kind not in ("video", "photo"):
            raise NativeRenderError("INVALID_BEAT_KIND", f"Beat {self.beat_id}: kind '{self.kind}'")
        if self.frames <= 0:
            raise NativeRenderError("INVALID_BEAT_LENGTH", f"Beat {self.beat_id}: frames must be > 0")
        if not Path(self.media_path).is_file():
            raise NativeRenderError(
                "MEDIA_MISSING", f"Beat {self.beat_id}: media not found: {self.media_path}"
            )
        if self.voice_path is not None and not Path(self.voice_path).is_file():
            raise NativeRenderError(
                "VOICE_MISSING", f"Beat {self.beat_id}: narration not found: {self.voice_path}"
            )
        if self.transition_in is not None:
            if self.transition_in not in VALID_TRANSITIONS:
                raise NativeRenderError(
                    "INVALID_TRANSITION",
                    f"Beat {self.beat_id}: transition must be one of {VALID_TRANSITIONS}",
                )
            if not 1 <= self.transition_frames <= self.frames // 2:
                raise NativeRenderError(
                    "INVALID_TRANSITION_LENGTH",
                    f"Beat {self.beat_id}: transition_frames must be 1..{self.frames // 2}",
                )
        for cue in self.cues:
            cue.validate(self.frames)


def expected_total_frames(beats: Sequence[RenderBeat]) -> int:
    """Timeline length after overlaps are removed by the transitions."""
    total = sum(b.frames for b in beats)
    total -= sum(b.transition_frames for b in beats if b.transition_in)
    return total


# (P1-33) Characters that end or split a filter graph token inside an option value.
# `;` starts a new filter chain and a raw newline splits the argument itself, so both were
# able to inject a second chain (e.g. through a caller-supplied beat id or staging path).
_FILTERGRAPH_UNSAFE = re.compile(r"[;\r\n]")


def _escape(path: str) -> str:
    if _FILTERGRAPH_UNSAFE.search(path):
        # Escaping works for a few characters, but a caller-controlled token that needs to
        # escape a chain separator is a sign of a bad path/name, not of valid input.
        raise NativeRenderError(
            "UNSAFE_FILTERGRAPH_TOKEN",
            f"value contains a filtergraph separator (; or newline): {path!r}",
        )
    return (
        path.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'")
        .replace(",", "\\,").replace("[", "\\[").replace("]", "\\]")
    )


_SAFE_BEAT_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def _safe_beat_id(raw: object) -> str:
    value = str(raw or "")
    if not _SAFE_BEAT_ID.match(value):
        raise NativeRenderError(
            "INVALID_BEAT_ID",
            f"beat_id must match [A-Za-z0-9_-]{{1,64}} (got {value!r})",
        )
    return value


def _wrap(text: str, width: int = 32) -> List[str]:
    return textwrap.wrap(" ".join(text.split()), width=width, break_long_words=False) or [""]


def resolve_font(font_path: Optional[str] = None) -> Path:
    candidate = font_path or os.environ.get("AIVIDEO_G4_CAPTION_FONT", "") or DEFAULT_FONT
    path = Path(candidate).expanduser()
    if not path.is_file():
        raise NativeRenderError("FONT_MISSING", f"Caption font not found: {path}")
    return path


def _caption_filters(beat: RenderBeat, font: Path, work_dir: Path) -> List[str]:
    filters: List[str] = []
    for index, cue in enumerate(beat.cues):
        caption_file = work_dir / f"cue_{beat.beat_id}_{index:03d}.txt"
        caption_file.write_text("\n".join(_wrap(cue.text)), encoding="utf-8")
        start = cue.start_frame / FPS
        end = cue.end_frame / FPS
        filters.append(
            "drawtext=" + ":".join((
                f"fontfile='{_escape(str(font))}'",
                f"textfile='{_escape(str(caption_file))}'",
                "fontsize=h/42",
                "line_spacing=8",
                "fontcolor=white",
                "borderw=2",
                "bordercolor=black",
                "box=1",
                "boxcolor=black@0.55",
                "boxborderw=12",
                # (P1-33) The approved text is burned literally; `%{...}` must not expand.
                "expansion=none",
                "x=(w-text_w)/2",
                "y=h-340-text_h",
                f"enable='between(t,{start:.4f},{end:.4f})'",
            ))
        )
    return filters


def _beat_filter(beat: RenderBeat, width: int, height: int, font: Path, work_dir: Path) -> str:
    duration = beat.frames / FPS
    if beat.kind == "video":
        chain = [
            "fps=24",
            f"scale={width}:{height}:force_original_aspect_ratio=decrease",
            f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=black",
            "setsar=1",
        ]
    else:
        # Fit first (never crop the photographer's framing), then a subtle push-in.
        if beat.ken_burns:
            chain = [
                f"scale={width * 2}:{height * 2}:force_original_aspect_ratio=decrease",
                f"pad={width * 2}:{height * 2}:(ow-iw)/2:(oh-ih)/2:color=black",
                "setsar=1",
                (
                    "zoompan=z='min(1.0+0.0009*on,1.10)'"
                    ":x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'"
                    f":d=1:s={width}x{height}:fps=24"
                ),
                "trim=duration=" + f"{duration:.6f}",
                "setpts=PTS-STARTPTS",
            ]
        else:
            chain = [
                f"scale={width}:{height}:force_original_aspect_ratio=decrease",
                f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=black",
                "setsar=1",
            ]
    chain += ["format=yuv420p"]
    chain += _caption_filters(beat, font, work_dir)
    chain += ["trim=duration=" + f"{duration:.6f}", "setpts=PTS-STARTPTS"]
    return ",".join(chain)


def _run(cmd: Sequence[str], *, timeout: float, what: str) -> None:
    try:
        result = run_tracked(list(cmd), capture_output=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as exc:
        raise NativeRenderError("FFMPEG_FAILED", f"{what}: could not run ffmpeg: {exc}") from exc
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", errors="replace") if result.stderr else ""
        raise NativeRenderError("FFMPEG_FAILED", f"{what}: {stderr[-700:]}")


def _probe(path: Path, *, count_frames: bool = True) -> Dict[str, Any]:
    cmd = ["ffprobe", "-v", "error"]
    if count_frames:
        cmd.append("-count_frames")
    cmd += ["-show_streams", "-show_format", "-of", "json", str(path)]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if result.returncode != 0:
        raise NativeRenderError("FFPROBE_FAILED", f"Cannot probe {path.name}: {result.stderr[-400:]}")
    return json.loads(result.stdout)


def _render_segment(
    beat: RenderBeat,
    out_path: Path,
    *,
    width: int,
    height: int,
    font: Path,
    work_dir: Path,
    encoder: str,
    preset: str,
    crf: int,
    threads: int,
    bitrate: str,
) -> None:
    duration = beat.frames / FPS
    inputs: List[str] = []
    if beat.kind == "photo":
        inputs += ["-loop", "1", "-framerate", "24", "-t", f"{duration:.6f}", "-i", beat.media_path]
    else:
        inputs += ["-i", beat.media_path]

    silent = beat.voice_path is None
    if silent:
        inputs += ["-f", "lavfi", "-t", f"{duration:.6f}", "-i", "anullsrc=r=48000:cl=mono"]
    else:
        inputs += ["-i", str(beat.voice_path)]

    audio_chain = (
        f"[1:a]aresample=48000,aformat=sample_fmts=s16:channel_layouts=mono,"
        f"apad,atrim=0:{duration:.6f},asetpts=PTS-STARTPTS[a]"
    )
    filter_complex = f"[0:v]{_beat_filter(beat, width, height, font, work_dir)}[v];{audio_chain}"

    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y", *inputs,
           "-filter_complex", filter_complex, "-map", "[v]", "-map", "[a]",
           "-r", "24", "-fps_mode", "cfr", "-t", f"{duration:.6f}",
           "-c:v", encoder, "-pix_fmt", "yuv420p",
           "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
    if encoder == "libx264":
        cmd += ["-preset", preset, "-crf", str(crf), "-threads", str(threads)]
    else:
        cmd += ["-b:v", bitrate]
    cmd += ["-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "1", str(out_path)]
    _run(cmd, timeout=max(120.0, duration * 8 + 90), what=f"segment {beat.beat_id}")


def _join_hard_cut(segments: Sequence[Path], out_path: Path, work_dir: Path) -> None:
    listing = work_dir / "segments.txt"
    listing.write_text(
        "".join(f"file '{Path(s).resolve()}'\n" for s in segments), encoding="utf-8"
    )
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
           "-f", "concat", "-safe", "0", "-i", str(listing), "-c", "copy",
           "-movflags", "+faststart", str(out_path)]
    _run(cmd, timeout=600.0, what="hard-cut concat")


def _join_with_transitions(
    beats: Sequence[RenderBeat],
    segments: Sequence[Path],
    out_path: Path,
    *,
    encoder: str,
    preset: str,
    crf: int,
    threads: int,
    bitrate: str,
) -> None:
    inputs: List[str] = []
    for segment in segments:
        inputs += ["-r", "24", "-i", str(segment)]

    graph: List[str] = []
    current_v = "0:v"
    current_a = "0:a"
    length = beats[0].frames / FPS  # seconds in the accumulated result
    for index in range(1, len(beats)):
        beat = beats[index]
        overlap = beat.transition_frames / FPS if beat.transition_in else 0.0
        out_v = f"v{index}"
        out_a = f"a{index}"
        if beat.transition_in == "crossfade":
            graph.append(
                f"[{current_v}][{index}:v]xfade=transition=fade:duration={overlap:.6f}"
                f":offset={max(0.0, length - overlap):.6f}[{out_v}]"
            )
            graph.append(
                f"[{current_a}][{index}:a]acrossfade=d={overlap:.6f}:c1=tri:c2=tri[{out_a}]"
            )
        elif beat.transition_in == "dip_to_black":
            graph.append(
                f"[{current_v}][{index}:v]xfade=transition=fadeblack:duration={overlap:.6f}"
                f":offset={max(0.0, length - overlap):.6f}[{out_v}]"
            )
            graph.append(
                f"[{current_a}][{index}:a]acrossfade=d={overlap:.6f}:c1=tri:c2=tri[{out_a}]"
            )
        else:
            graph.append(
                f"[{current_v}][{index}:v]concat=n=2:v=1:a=0[{out_v}]"
            )
            graph.append(
                f"[{current_a}][{index}:a]concat=n=2:v=0:a=1[{out_a}]"
            )
        current_v, current_a = out_v, out_a
        length = length - overlap + beat.frames / FPS

    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y", *inputs,
           "-filter_complex", ";".join(graph),
           "-map", f"[{current_v}]", "-map", f"[{current_a}]",
           "-r", "24", "-fps_mode", "cfr",
           "-c:v", encoder, "-pix_fmt", "yuv420p",
           "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
    if encoder == "libx264":
        cmd += ["-preset", preset, "-crf", str(crf), "-threads", str(threads)]
    else:
        cmd += ["-b:v", bitrate]
    cmd += ["-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "1",
            "-movflags", "+faststart", str(out_path)]
    _run(cmd, timeout=1800.0, what="transition join")


def render_timeline(
    beats: Sequence[RenderBeat],
    out_path: str | Path,
    *,
    width: int,
    height: int,
    font_path: Optional[str] = None,
    encoder: str = "libx264",
    preset: str = "veryfast",
    crf: int = 18,
    threads: int = 4,
    bitrate: str = "45M",
) -> Dict[str, Any]:
    """Render `beats` to a single MP4 and verify the output against the contract."""
    if not beats:
        raise NativeRenderError("NO_BEATS", "Nothing to render")
    if encoder not in ENCODERS:
        raise NativeRenderError("INVALID_ENCODER", f"encoder must be one of {ENCODERS}")
    if width % 2 or height % 2:
        raise NativeRenderError("INVALID_DIMENSIONS", "Width and height must be even")
    for beat in beats:
        beat.validate()
    if beats[0].transition_in:
        raise NativeRenderError("TRANSITION_ON_FIRST_BEAT", "The first beat cannot transition in")

    font = resolve_font(font_path)
    target = Path(out_path).expanduser()
    target.parent.mkdir(parents=True, exist_ok=True)
    work_dir = Path(tempfile.mkdtemp(prefix="aivideo_native_"))
    try:
        segments = []
        for index, beat in enumerate(beats):
            segment = work_dir / f"seg_{index:03d}.mp4"
            _render_segment(
                beat, segment, width=width, height=height, font=font, work_dir=work_dir,
                encoder=encoder, preset=preset, crf=crf, threads=threads, bitrate=bitrate,
            )
            segments.append(segment)

        if any(b.transition_in for b in beats[1:]):
            _join_with_transitions(
                beats, segments, target, encoder=encoder, preset=preset,
                crf=crf, threads=threads, bitrate=bitrate,
            )
        else:
            _join_hard_cut(segments, target, work_dir)

        expected = expected_total_frames(beats)
        probe = verify_output(target, expected, width=width, height=height)
        return {
            "status": "RENDERED_VERIFIED",
            "output_path": str(target),
            "expected_frames": expected,
            "probe": probe,
            "transitions": sum(1 for b in beats if b.transition_in),
            "photos": sum(1 for b in beats if b.kind == "photo"),
            "encoder": encoder,
        }
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


def verify_output(path: Path, expected_frames: int, *, width: int, height: int) -> Dict[str, Any]:
    data = _probe(path)
    video = [s for s in data.get("streams", []) if s.get("codec_type") == "video"]
    audio = [s for s in data.get("streams", []) if s.get("codec_type") == "audio"]
    if len(video) != 1 or len(audio) != 1:
        raise NativeRenderError("STREAM_COUNT", "Output must have exactly one video and one audio stream")
    v = video[0]
    if int(v.get("width", 0)) != width or int(v.get("height", 0)) != height:
        raise NativeRenderError(
            "WRONG_RESOLUTION", f"Expected {width}x{height}, got {v.get('width')}x{v.get('height')}"
        )
    if v.get("r_frame_rate") != "24/1" or v.get("avg_frame_rate") != "24/1":
        raise NativeRenderError("WRONG_FRAME_RATE", f"Expected CFR 24, got {v.get('r_frame_rate')}")
    if v.get("pix_fmt") != "yuv420p":
        raise NativeRenderError("WRONG_PIXEL_FORMAT", f"Expected yuv420p, got {v.get('pix_fmt')}")
    for tag in ("color_primaries", "color_transfer", "color_space"):
        if v.get(tag) != "bt709":
            raise NativeRenderError("WRONG_COLOR_TAGS", f"{tag} must be bt709, got {v.get(tag)}")
    frames = int(v.get("nb_read_frames") or 0)
    if frames != expected_frames:
        raise NativeRenderError(
            "FRAME_COUNT_MISMATCH",
            f"Decoded {frames} frames, planned {expected_frames}",
        )
    if int(audio[0].get("sample_rate", 0)) != 48000:
        raise NativeRenderError("WRONG_AUDIO_RATE", "Audio must be 48 kHz")
    return {
        "frames": frames,
        "width": width,
        "height": height,
        "fps": 24,
        "duration_sec": round(frames / FPS, 3),
        "video_codec": v.get("codec_name"),
        "audio_codec": audio[0].get("codec_name"),
        "color": "bt709",
    }


def _srt_time(frames: int) -> str:
    total_ms = round(frames / FPS * 1000)
    hours, rest = divmod(total_ms, 3_600_000)
    minutes, rest = divmod(rest, 60_000)
    seconds, millis = divmod(rest, 1000)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d},{millis:03d}"


def write_srt(beats: Sequence[RenderBeat], path: str | Path) -> Dict[str, Any]:
    """Emit an .srt that matches the rendered timeline, overlaps included.

    Cue times shift by the same overlap that shortens the picture, so the
    subtitle timeline stays glued to the narration instead of drifting.
    """
    entries: List[str] = []
    offset = 0
    index = 0
    for beat in beats:
        offset -= beat.transition_frames if beat.transition_in else 0
        for cue in beat.cues:
            index += 1
            start = offset + cue.start_frame
            end = offset + cue.end_frame
            entries.append(f"{index}\n{_srt_time(start)} --> {_srt_time(end)}\n{cue.text}\n")
        offset += beat.frames
    target = Path(path).expanduser()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("\n".join(entries), encoding="utf-8")
    return {"status": "SRT_WRITTEN", "path": str(target), "cues": index}


# MARK: - RPC entry point


_ALLOWED_SIZES = {(1080, 1920), (2160, 3840)}


def _resolve_within(root: Path, raw: str, label: str) -> Path:
    path = Path(str(raw)).expanduser()
    if not path.is_absolute():
        path = root / path
    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise NativeRenderError("PATH_MISSING", f"{label} does not exist: {raw}") from exc
    if root != resolved and root not in resolved.parents:
        raise NativeRenderError("PATH_OUTSIDE_ROOT", f"{label} escapes the managed root: {resolved}")
    return resolved


def render_native(params: dict) -> Dict[str, Any]:
    """RPC handler: render an explicit beat list to MP4 + .srt.

    Explicit beats (rather than a DB plan) let the renderer be exercised and
    reused by both the preview and the final path while the gate wiring is still
    owned by `g4_core.approved_plan` / `g5_final.approved_final_plan`.
    """
    if not isinstance(params, dict):
        raise ValueError("RPC params must be an object")
    # (P1-15) Overwriting an approved artifact is never a remote option: reject it before
    # any path or media validation so the refusal is the documented one.
    if "allow_overwrite" in params:
        raise NativeRenderError(
            "OVERWRITE_FORBIDDEN",
            "allow_overwrite is not accepted over RPC; an existing artifact needs manual reconciliation",
        )
    # (P1-15) Same rule as the plan-based renderers: the root is provisioned by the app.
    if params.get("staging_root"):
        raise NativeRenderError(
            "STAGING_ROOT_FORBIDDEN",
            "staging_root is provisioned by the app (AIVIDEO_RENDER_ROOT), not by the request",
        )
    root_value = (
        os.environ.get("AIVIDEO_RENDER_ROOT")
        or os.environ.get("AIVIDEO_G4_WORK_ROOT")
        or os.environ.get("AIVIDEO_G5_WORK_ROOT")
        or ""
    )
    if not root_value:
        return {
            "status": "blocked_untrusted_render_root",
            "required_env": "AIVIDEO_RENDER_ROOT (or AIVIDEO_G4_WORK_ROOT / AIVIDEO_G5_WORK_ROOT)",
        }
    root = Path(str(root_value)).expanduser().resolve(strict=True)

    raw_beats = params.get("beats")
    if not isinstance(raw_beats, list) or not 1 <= len(raw_beats) <= 64:
        raise ValueError("beats must be a list of 1..64 items")
    beats: List[RenderBeat] = []
    for item in raw_beats:
        if not isinstance(item, dict):
            raise ValueError("each beat must be an object")
        cues = []
        for cue in item.get("cues", []) or []:
            if not isinstance(cue, dict):
                raise ValueError("each cue must be an object")
            cues.append(CaptionCue(
                text=str(cue.get("text", "")),
                start_frame=int(cue.get("start_frame", 0)),
                end_frame=int(cue.get("end_frame", 0)),
            ))
        beats.append(RenderBeat(
            # (P1-33) beat ids become caption file names inside the filter graph.
            beat_id=_safe_beat_id(item.get("beat_id")),
            kind=str(item.get("kind", "video")),
            media_path=str(_resolve_within(root, item.get("media_path", ""), "media_path")),
            frames=int(item.get("frames", 0)),
            voice_path=(
                str(_resolve_within(root, item["voice_path"], "voice_path"))
                if item.get("voice_path") else None
            ),
            cues=cues,
            transition_in=item.get("transition_in") or None,
            transition_frames=int(item.get("transition_frames", 0) or 0),
            ken_burns=bool(item.get("ken_burns", True)),
            claim_refs=[str(c) for c in item.get("claim_refs", []) or []],
        ))

    width = int(params.get("width", 1080))
    height = int(params.get("height", 1920))
    if (width, height) not in _ALLOWED_SIZES:
        raise ValueError(f"width/height must be one of {sorted(_ALLOWED_SIZES)}")

    out_raw = params.get("output_path")
    if not out_raw:
        raise ValueError("output_path is required")
    out_path = Path(str(out_raw)).expanduser()
    if not out_path.is_absolute():
        out_path = root / out_path
    out_path = out_path.resolve()
    if root not in out_path.parents:
        raise NativeRenderError("PATH_OUTSIDE_ROOT", f"output_path escapes the managed root: {out_path}")
    # (P1-15) Overwriting is never a remote option: `allow_overwrite` in the request could
    # replace an approved preview/final, so the guard is unconditional. Reconciliation of an
    # existing artifact is a manual, app-side operation.
    if "allow_overwrite" in params:
        raise NativeRenderError(
            "OVERWRITE_FORBIDDEN",
            "allow_overwrite is not accepted over RPC; an existing artifact needs manual reconciliation",
        )
    if out_path.exists():
        raise NativeRenderError(
            "OUTPUT_EXISTS",
            f"Refusing to overwrite {out_path.name}; manual reconciliation required",
        )

    encoder = str(params.get("encoder", "libx264"))
    result = render_timeline(
        beats, out_path,
        width=width, height=height,
        font_path=params.get("font_path"),
        encoder=encoder,
        preset=str(params.get("preset", "veryfast")),
        crf=int(params.get("crf", 18)),
        threads=int(params.get("threads", 4)),
        bitrate=str(params.get("bitrate", "45M")),
    )

    srt_info = None
    if params.get("write_srt", True):
        srt_info = write_srt(beats, out_path.with_suffix(".srt"))

    import hashlib

    # (P1-34) A 4K master can be ~1 GB; hash it by streaming, never into memory.
    digest = _sha256_file(out_path)
    result.update({
        "output_sha256": digest,
        "srt": srt_info,
        "width": width,
        "height": height,
        "beats": len(beats),
    })
    return result


# MARK: - Plan-based rendering (G4 preview / G5 final)

import hashlib as _hashlib


def _sha256_bytes(data: bytes) -> str:
    return _hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = _hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _normalized(text: str) -> str:
    return " ".join(str(text).split())


def build_beats_from_plan(
    plan: Dict[str, Any],
    params: Dict[str, Any],
    *,
    staging_root: Path,
) -> tuple[List[RenderBeat], List[Dict[str, Any]]]:
    """Turn an approved G4/G5 plan into render beats, verifying every binding.

    The plan already passed `approved_plan()` / `approved_final_plan()` (seals,
    hashes, mapping). What is verified here is the *editorial* layer the user
    supplies: narration text per beat must hash to the approved
    `caption_text_sha256`, cue phrases must reproduce that text, and any photo
    insert must live inside the managed root and is tagged `illustrative_only`.
    """
    entries = plan.get("entries") or []
    if not entries:
        raise NativeRenderError("EMPTY_PLAN", "Plan has no beat entries")

    voice_texts = params.get("voice_texts") or {}
    cue_map = params.get("cues") or {}
    transitions = params.get("transitions") or {}
    photo_inserts = params.get("photo_inserts") or []

    if not isinstance(voice_texts, dict) or not isinstance(cue_map, dict):
        raise ValueError("voice_texts and cues must be objects keyed by beat_id")

    photos_after: Dict[str, List[Dict[str, Any]]] = {}
    for item in photo_inserts:
        if not isinstance(item, dict):
            raise ValueError("each photo insert must be an object")
        anchor = _safe_beat_id(item.get("after_beat_id") or "")
        if not anchor:
            raise ValueError("photo insert requires after_beat_id")
        photos_after.setdefault(anchor, []).append(item)

    beats: List[RenderBeat] = []
    evidence: List[Dict[str, Any]] = []
    for entry in entries:
        beat_id = _safe_beat_id(entry["beat_id"])
        verdict = params.get("voice_texts", {}).get(beat_id)
        if not isinstance(verdict, str) or not verdict.strip():
            raise NativeRenderError(
                "MISSING_VOICE_TEXT",
                f"Beat {beat_id}: voice_text is required to verify the caption binding",
            )
        text_sha = _sha256_bytes(verdict.encode("utf-8"))
        if text_sha != entry.get("caption_text_sha256"):
            raise NativeRenderError(
                "VOICE_TEXT_CHANGED",
                f"Beat {beat_id}: narration text no longer matches the approved G3 text",
            )
        raw_cues = cue_map.get(beat_id) or []
        cues = [
            CaptionCue(
                text=str(c.get("text", "")),
                start_frame=int(c.get("start_frame", 0)),
                end_frame=int(c.get("end_frame", 0)),
            )
            for c in raw_cues
        ]
        if cues:
            # Re-burn at the target resolution only when the caller supplies cues.
            joined = _normalized(" ".join(c.text for c in cues))
            if joined != _normalized(verdict):
                raise NativeRenderError(
                    "CAPTION_TEXT_MISMATCH",
                    f"Beat {beat_id}: caption phrases must reproduce the approved narration exactly",
                )
            caption_mode = "reburned_from_cues"
        else:
            # The approved G4 clip already carries its burned-in captions; do not
            # draw them twice, just upscale the pixels.
            caption_mode = "preburned_in_segment"

        transition = transitions.get(beat_id) or {}
        transition_in = transition.get("type") if transition else None
        transition_frames = int(transition.get("frames", 0) or 0) if transition else 0

        beat = RenderBeat(
            beat_id=beat_id,
            kind="video",
            media_path=str(entry["video_path"]),
            frames=int(entry["duration_frames"]),
            voice_path=str(entry["voice_path"]),
            cues=cues,
            transition_in=transition_in,
            transition_frames=transition_frames,
        )
        beats.append(beat)
        evidence.append({
            "beat_id": beat_id,
            "video_sha256": entry.get("video_sha256"),
            "voice_sha256": entry.get("voice_sha256"),
            "caption_text_sha256": entry.get("caption_text_sha256"),
            # 2026-11-11 fix (P0-03): a receipt must say *which* published artifacts each
            # beat was assembled from, otherwise any MP4 with the right shape could be
            # dressed up with a self-written receipt.
            "video_publication_id": entry.get("video_publication_id"),
            "voice_publication_id": entry.get("voice_publication_id"),
            "mapping_publication_id": entry.get("mapping_publication_id"),
            "receipt_publication_id": entry.get("receipt_publication_id"),
            "frames": beat.frames,
            "transition_in": transition_in,
            "transition_frames": transition_frames,
            "caption_mode": caption_mode,
        })

        for photo in photos_after.get(beat_id, []):
            photo_path = _resolve_within(
                staging_root, str(photo.get("path", "")), "photo_insert.path"
            )
            photo_cues = [
                CaptionCue(
                    text=str(c.get("text", "")),
                    start_frame=int(c.get("start_frame", 0)),
                    end_frame=int(c.get("end_frame", 0)),
                )
                for c in (photo.get("cues") or [])
            ]
            # (P1-32) An inserted photo is editorial evidence: the caller must declare the
            # SHA-256 of the (already published) photo, and the bytes on disk must match it.
            expected_photo_sha = str(photo.get("photo_sha256") or "").lower()
            if not re.fullmatch(r"[0-9a-f]{64}", expected_photo_sha):
                raise NativeRenderError(
                    "PHOTO_HASH_REQUIRED",
                    f"Photo insert after {beat_id} must declare photo_sha256 of the approved photo",
                )
            actual_photo_sha = _sha256_file(photo_path)
            if actual_photo_sha != expected_photo_sha:
                raise NativeRenderError(
                    "PHOTO_BYTES_CHANGED",
                    f"Photo insert after {beat_id} does not match the approved photo hash",
                )
            # (P1-32) A photo used on the timeline must be a committed S08 publication, and
            # the receipt has to cite it. Without this, `illustrative_only` was the only
            # requirement: any file the caller could write became editorial evidence.
            photo_publication_id = str(photo.get("photo_publication_id") or "")
            if not _UUID_RE.match(photo_publication_id):
                raise NativeRenderError(
                    "PHOTO_PUBLICATION_REQUIRED",
                    f"Photo insert after {beat_id} must cite photo_publication_id of the "
                    "published photo (S08)",
                )
            photo_frames = int(photo.get("frames", 60))
            beats.append(RenderBeat(
                beat_id=f"{beat_id}__photo",
                kind="photo",
                media_path=str(photo_path),
                frames=photo_frames,
                cues=photo_cues,
                transition_in="crossfade",
                transition_frames=int(photo.get("transition_frames", 6) or 0),
                ken_burns=bool(photo.get("ken_burns", True)),
                claim_refs=["illustrative_only"],
            ))
            evidence.append({
                "beat_id": f"{beat_id}__photo",
                "kind": "photo_insert",
                "photo_sha256": actual_photo_sha,
                "photo_publication_id": photo_publication_id,
                "frames": photo_frames,
                "usage": "illustrative_only",
                "source_claim": None,
            })

    # A photo can never be the first item: it must follow the beat it illustrates.
    if beats and beats[0].kind == "photo":
        raise NativeRenderError("PHOTO_FIRST", "Photo insert cannot be the first timeline item")
    return beats, evidence


def render_from_plan(
    plan: Dict[str, Any],
    params: Dict[str, Any],
    *,
    width: int,
    height: int,
    staging_root: Path,
    out_path: Path,
) -> Dict[str, Any]:
    beats, evidence = build_beats_from_plan(plan, params, staging_root=staging_root)
    if "allow_overwrite" in params:
        raise NativeRenderError(
            "OVERWRITE_FORBIDDEN",
            "allow_overwrite is not accepted over RPC; an existing artifact needs manual reconciliation",
        )
    if out_path.exists():
        raise NativeRenderError(
            "OUTPUT_EXISTS", f"Refusing to overwrite {out_path.name}; manual reconciliation required"
        )
    encoder = str(params.get("encoder", "libx264"))
    result = render_timeline(
        beats, out_path,
        width=width, height=height,
        font_path=params.get("font_path"),
        encoder=encoder,
        preset=str(params.get("preset", "veryfast")),
        crf=int(params.get("crf", 18)),
        threads=int(params.get("threads", 4)),
        bitrate=str(params.get("bitrate", "45M")),
    )
    # (P1-31) The plan's `total_frames` is the approved timeline length. A transition that
    # shortens the timeline (or a photo insert that lengthens it) would otherwise produce a
    # render whose length disagrees with the plan it claims to implement — and the receipt
    # reported the mismatch as if it were fine.
    approved_total = plan.get("total_frames")
    if approved_total is not None:
        rendered_total = result["expected_frames"]
        if int(approved_total) != int(rendered_total):
            raise NativeRenderError(
                "PLAN_FRAME_MISMATCH",
                f"Rendered timeline is {rendered_total} frames but the approved plan is "
                f"{approved_total}; transitions/inserts must not change the approved length",
                {
                    "approved_frames": int(approved_total),
                    "rendered_frames": int(rendered_total),
                    "transition_overlap_frames": sum(
                        b.transition_frames for b in beats if b.transition_in
                    ),
                    "photo_insert_frames": sum(
                        b.frames for b in beats if b.kind == "photo_insert"
                    ),
                },
            )

    srt_info = write_srt(beats, out_path.with_suffix(".srt")) if params.get("write_srt", True) else None
    receipt = {
        "schema": "native-render-receipt-v1",
        "engine": "ffmpeg_native",
        "encoder": encoder,
        # (P0-03) Bind the receipt to the approved G3/G4 chain it was rendered from.
        "plan_sha256": plan.get("plan_sha256"),
        "g3_approval_id": plan.get("g3_approval_id"),
        "g3_manifest_sha256": plan.get("g3_manifest_sha256"),
        "g4_approval_id": plan.get("g4_approval_id"),
        "g4_preview_sha256": plan.get("g4_preview_sha256"),
        # Overlap is measured from the beats that were actually built (0 for a G3 hard-cut
        # plan), never assumed.
        "transition_overlap_frames": sum(b.transition_frames for b in beats if b.transition_in),
        "profile": plan.get("profile"),
        "width": width,
        "height": height,
        "fps": FPS,
        "total_frames": result["expected_frames"],
        "sum_beat_frames": sum(b.frames for b in beats),
        "beats": evidence,
        "output": {
            "path": str(out_path),
            "sha256": _sha256_file(out_path),
            "probe": result["probe"],
        },
        "srt": (
            {"path": srt_info["path"], "sha256": _sha256_file(Path(srt_info["path"])),
             "cues": srt_info["cues"]}
            if srt_info else None
        ),
    }
    return {"status": "NATIVE_RENDER_VERIFIED", "receipt": receipt, "render": result}


def _render_root(params: dict) -> Optional[Path]:
    # (P1-15) The render root is provisioned by the app; a request may not redirect output
    # files into an arbitrary directory the worker happens to be able to write.
    if params.get("staging_root"):
        raise NativeRenderError(
            "STAGING_ROOT_FORBIDDEN",
            "staging_root is provisioned by the app (AIVIDEO_RENDER_ROOT), not by the request",
        )
    value = (
        os.environ.get("AIVIDEO_RENDER_ROOT")
        or os.environ.get("AIVIDEO_G4_WORK_ROOT")
        or os.environ.get("AIVIDEO_G5_WORK_ROOT")
        or ""
    )
    if not value:
        return None
    root = Path(str(value)).expanduser()
    if not root.is_dir():
        raise NativeRenderError("RENDER_ROOT_MISSING", f"Render root does not exist: {root}")
    return root.resolve()


def render_g4_native(params: dict) -> Dict[str, Any]:
    """S21: render the approved G4 plan with ffmpeg instead of Resolve."""
    from .g4_core import approved_plan

    if not isinstance(params, dict):
        raise ValueError("RPC params must be an object")
    root = _render_root(params)
    if root is None:
        return {
            "status": "blocked_untrusted_render_root",
            "required_env": "AIVIDEO_RENDER_ROOT (or AIVIDEO_G4_WORK_ROOT)",
        }
    plan = approved_plan(params["db_path"], params["project_id"], params["assets"])
    outputs = root / "renders"
    outputs.mkdir(exist_ok=True)
    out_path = outputs / ("G4_NATIVE_" + plan["plan_sha256"][:20] + ".mp4")
    result = render_from_plan(
        plan, params, width=1080, height=1920, staging_root=root, out_path=out_path
    )
    native = result["receipt"]
    native["profile"] = "G4_PREVIEW_1080x1920"
    native["plan_sha256"] = plan["plan_sha256"]
    native["g3_approval_id"] = plan["g3_approval_id"]
    native["g3_manifest_sha256"] = plan["g3_manifest_sha256"]
    native["required_publication_ids"] = sorted(
        {plan["cut_publication_id"]}
        | {
            e[field]
            for e in plan["entries"]
            for field in (
                "video_publication_id",
                "receipt_publication_id",
                "mapping_publication_id",
                "voice_publication_id",
            )
        }
    )
    timeline_signature = _sha256_bytes(
        json.dumps(
            {"plan": plan["plan_sha256"], "beats": native["beats"], "engine": "ffmpeg_native"},
            sort_keys=True, ensure_ascii=False,
        ).encode("utf-8")
    )
    receipt = {
        "status": "PREVIEW_TECHNICAL_PASS_CONTENT_REVIEW_REQUIRED",
        "preview_path": str(out_path),
        "preview_sha256": native["output"]["sha256"],
        "g3_approval_id": plan["g3_approval_id"],
        "g3_manifest_sha256": plan["g3_manifest_sha256"],
        "plan_sha256": plan["plan_sha256"],
        "timeline_uid": "ffmpeg-native:" + plan["plan_sha256"][:20],
        "timeline_signature": timeline_signature,
        "render_job_id": "ffmpeg-native:" + timeline_signature[:16],
        "required_publication_ids": native["required_publication_ids"],
        "qc": {
            "status": "TECHNICAL_PASS_CONTENT_REVIEW_REQUIRED",
            "sha256": native["output"]["sha256"],
            "semantic_verified": False,
            "verified": {
                "width": 1080, "height": 1920, "fps": 24, "color": "bt709",
                "frames": native["total_frames"],
                "duration_sec": native["output"]["probe"]["duration_sec"],
            },
        },
        "engine": "ffmpeg_native",
        "native": native,
        "approved": False,
    }
    receipt_path = out_path.with_suffix(".receipt.json")
    receipt_path.write_text(json.dumps(receipt, ensure_ascii=False, indent=1), encoding="utf-8")
    receipt_sha = _sha256_file(receipt_path)
    receipt["plan_sha256"] = plan["plan_sha256"]
    receipt["g3_approval_id"] = plan["g3_approval_id"]
    receipt["g3_manifest_sha256"] = plan["g3_manifest_sha256"]
    receipt["required_publication_ids"] = sorted(
        {plan["cut_publication_id"]}
        | {
            e[field]
            for e in plan["entries"]
            for field in (
                "video_publication_id",
                "receipt_publication_id",
                "mapping_publication_id",
                "voice_publication_id",
            )
        }
    )
    return {
        "status": "NATIVE_PREVIEW_VERIFIED",
        "receipt": receipt,
        "receipt_path": str(receipt_path),
        "receipt_sha256": receipt_sha,
        "preview_path": str(out_path),
        "preview_sha256": receipt["preview_sha256"],
        "srt_path": (native.get("srt") or {}).get("path"),
        "render": result["render"],
    }


def render_g5_native(params: dict) -> Dict[str, Any]:
    """S22: render the approved G5 plan at 2160x3840 with ffmpeg instead of Resolve."""
    from .g5_final import approved_final_plan

    if not isinstance(params, dict):
        raise ValueError("RPC params must be an object")
    root = _render_root(params)
    if root is None:
        return {
            "status": "blocked_untrusted_render_root",
            "required_env": "AIVIDEO_RENDER_ROOT (or AIVIDEO_G5_WORK_ROOT)",
        }
    plan = approved_final_plan(params["db_path"], params["project_id"], params["assets"])
    outputs = root / "g5_renders"
    outputs.mkdir(exist_ok=True)
    out_path = outputs / ("G5_NATIVE_" + plan["plan_sha256"][:20] + ".mp4")
    result = render_from_plan(
        plan, params, width=2160, height=3840, staging_root=root, out_path=out_path
    )
    native = result["receipt"]
    native["profile"] = "G5_FINAL_2160x3840"
    native["plan_sha256"] = plan["plan_sha256"]
    native["g3_approval_id"] = plan["g3_approval_id"]
    native["g3_manifest_sha256"] = plan["g3_manifest_sha256"]
    native["g4_approval_id"] = plan["g4_approval_id"]
    native["g4_preview_sha256"] = plan["g4_preview_sha256"]
    native["required_publication_ids"] = sorted(
        {plan["cut_publication_id"], plan["g4_preview_publication_id"]}
        | {
            e[field]
            for e in plan["entries"]
            for field in (
                "video_publication_id",
                "receipt_publication_id",
                "mapping_publication_id",
                "voice_publication_id",
            )
        }
    )
    timeline_signature = _sha256_bytes(
        json.dumps(
            {"plan": plan["plan_sha256"], "beats": native["beats"], "engine": "ffmpeg_native"},
            sort_keys=True, ensure_ascii=False,
        ).encode("utf-8")
    )
    receipt_path = out_path.with_suffix(".receipt.json")
    receipt = {
        "status": "FINAL_TECHNICAL_PASS_HUMAN_RELEASE_REVIEW_REQUIRED",
        "final_path": str(out_path),
        "final_sha256": native["output"]["sha256"],
        "drp_path": str(receipt_path),
        "drp_sha256": "",
        "g3_approval_id": plan["g3_approval_id"],
        "g3_manifest_sha256": plan["g3_manifest_sha256"],
        "g4_approval_id": plan["g4_approval_id"],
        "g4_preview_sha256": plan["g4_preview_sha256"],
        "plan_sha256": plan["plan_sha256"],
        "timeline_uid": "ffmpeg-native:" + plan["plan_sha256"][:20],
        "timeline_signature": timeline_signature,
        "render_job_id": "ffmpeg-native:" + timeline_signature[:16],
        "required_publication_ids": native["required_publication_ids"],
        "qc": {
            "status": "FINAL_TECHNICAL_PASS_HUMAN_RELEASE_REVIEW_REQUIRED",
            "sha256": native["output"]["sha256"],
            "semantic_verified": False,
            "verified": {
                "width": 2160, "height": 3840, "fps": 24, "color": "bt709",
                "frames": native["total_frames"],
                "duration_sec": native["output"]["probe"]["duration_sec"],
            },
        },
        "engine": "ffmpeg_native",
        "native": native,
        "approved": False,
    }
    receipt_path.write_text(json.dumps(receipt, ensure_ascii=False, indent=1), encoding="utf-8")
    receipt_sha = _sha256_file(receipt_path)
    receipt["drp_sha256"] = receipt_sha
    receipt_path.write_text(json.dumps(receipt, ensure_ascii=False, indent=1), encoding="utf-8")
    receipt_sha = _sha256_file(receipt_path)
    return {
        "status": "NATIVE_FINAL_VERIFIED",
        "receipt": receipt,
        # `drp_path` keeps the provenance slot name so the existing S08
        # publish/approve flow works unchanged; the file is the native receipt.
        "drp_path": str(receipt_path),
        "drp_sha256": receipt_sha,
        "final_path": str(out_path),
        "final_sha256": receipt["final_sha256"],
        "srt_path": (native.get("srt") or {}).get("path"),
        "receipt_path": str(receipt_path),
        "receipt_sha256": receipt_sha,
        "render": result["render"],
    }
