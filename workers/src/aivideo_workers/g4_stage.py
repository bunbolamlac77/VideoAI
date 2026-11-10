"""S21 raster caption/conform staging from a sealed S10 CFR24 proxy.

Output is STAGED only: Swift S08 must publish the MP4 and receipt separately.
The project G4 preview references only those committed S08 publications.
This uses fit/pad to preserve the entire evidence frame; no automatic crop.
"""
from __future__ import annotations

from pathlib import Path
from fractions import Fraction
import json
import os
import re
import subprocess
import uuid
import textwrap

from .g4_core import (_read_db, row, publication, must, G4Blocked,
                      read_json, hash_file, check_video, canon, digest, ffprobe)
from .g4_resolve import _safe_root


def _filter_path(path: Path) -> str:
    # Escape filtergraph, not shell: subprocess is invoked without a shell.
    return (str(path).replace("\\", "\\\\").replace(":", "\\:")
            .replace("'", "\\'").replace(",", "\\,").replace("[", "\\[")
            .replace("]", "\\]"))


def _normalized(text: str) -> str:
    return " ".join(text.split())


def stage_captioned_clip(params: dict) -> dict:
    root = _safe_root()
    project = str(uuid.UUID(params["project_id"])).upper()
    beat_id = params["beat_id"]
    mapping_id = params["mapping_publication_id"]
    cues = params.get("cues", [])
    must(isinstance(cues, list) and 0 < len(cues) <= 64, "Expected 1..64 aligned phrase cues")
    font_value = params.get("font_path") or os.environ.get("AIVIDEO_G4_CAPTION_FONT", "")
    must(font_value, "Set AIVIDEO_G4_CAPTION_FONT to a Vietnamese-capable TTF/OTF")
    font = Path(font_value).expanduser().resolve(strict=True)
    must(font.suffix.lower() in (".ttf", ".otf") and font.is_file(),
         "Caption font must be a verified local TTF/OTF")
    with _read_db(params["db_path"]) as db:
        selected = row(db, "SELECT script_revision_id FROM g3_selected WHERE project_id=?", (project,))[0]
        approved = row(db, """SELECT manifest_json FROM g3_approvals
                             WHERE project_id=? AND script_revision_id=?""", (project, selected))
        manifest = json.loads(approved[0])
        script = json.loads(row(db, "SELECT candidate_json FROM g3_scripts WHERE script_revision_id=?",
                                (selected,))[0])
        beat_pos = next((i for i, b in enumerate(script["beats"]) if b["beat_id"] == beat_id), None)
        must(beat_pos is not None, "Beat not in approved G3 script")
        beat = script["beats"][beat_pos]
        video_text = beat["voice_text"]
        voice = manifest["voice_publications"][beat_pos]
        must(voice["beat_id"] == beat_id and
             digest(video_text.encode()) == voice["text_sha256"], "Voice text no longer matches G3")
        cut_path, _ = publication(db, project, manifest["cut_publication_id"],
                                  "g3_cut_plan", manifest["edit_plan_sha256"], 8 * 1024 * 1024)
        shot = read_json(cut_path.read_bytes())["edit_plan"][beat_pos]
        mapping_path, mapping_sha = publication(db, project, mapping_id, "g2_source_mapping",
                                                shot["mapping_sha256"], 8 * 1024 * 1024)
        mapping = read_json(mapping_path.read_bytes())
        cm = mapping.get("conform_map", {})
        start, end, duration = shot["range_start"], shot["range_end"], shot["duration_frames"]
        must(type(start) is type(end) is type(duration) is int and
             0 <= start < end and duration == end - start,
             "G4 raster stage supports one-to-one hard-cut source frames only")
        must(mapping.get("source_revision_id") == shot["source_revision_id"] and
             mapping.get("source_sha256") == shot["source_sha256"] and
             cm.get("profile_id") == "M-24-SDR-v1" and
             cm.get("dropped_critical_evidence_frame_ids") == [] and
             len(cm.get("mappings", [])) >= end,
             "Invalid S10 source-to-CFR mapping")
        for i in range(start, end):
            must(cm["mappings"][i].get("timeline_frame_index") == i and
                 type(cm["mappings"][i].get("source_frame_id")) is int,
                 "Unverifiable conform frame mapping")
        source = row(db, """SELECT snapshot_path,snapshot_sha256,is_stable FROM source_revisions
                            WHERE source_revision_id=?""", (shot["source_revision_id"],))
        must(source[1] == shot["source_sha256"] and source[2] == 1 and
             hash_file(Path(source[0])) == source[1], "Sealed source changed since S19")
        proxy = Path(mapping["proxy_path"]).expanduser().resolve(strict=True)
        must(hash_file(proxy) == mapping["proxy_sha256"] and
             mapping.get("proxy_fps") == "24/1", "Proxy does not match published S10 mapping")
        index = ffprobe(proxy, count_frames=True)
        visual = [v for v in index.get("streams", []) if v.get("codec_type") == "video"]
        must(len(visual) == 1 and Fraction(visual[0].get("avg_frame_rate", "0/1")) == 24 and
             Fraction(visual[0].get("r_frame_rate", "0/1")) == 24 and
             int(visual[0].get("nb_read_frames", 0)) >= end,
             "S10 proxy decoded frame count differs from published conform map")
        # Merely stamping Rec.709 tags on HDR/wide-gamut pixels is incorrect.
        # Any source without verified SDR Rec.709 conform must be re-conformed
        # by S10 with an auditable color transform before using this renderer.
        must(all(visual[0].get(k) == "bt709" for k in (
                 "color_primaries", "color_transfer", "color_space")),
             "S10 proxy is not verified SDR Rec.709; re-conform before G4")

    # Each phrase is tied to already reviewed narration; do not invent wording.
    previous = 0
    phrase_texts = []
    filters = [f"trim=start_frame={start}:end_frame={end}",
               "setpts=PTS-STARTPTS", "fps=24",
               "scale=1080:1920:force_original_aspect_ratio=decrease",
               "pad=1080:1920:(ow-iw)/2:(oh-ih)/2:color=black", "format=yuv420p"]
    stage_dir = root / "staging" / uuid.uuid4().hex
    stage_dir.mkdir(parents=True, exist_ok=False)
    for n, cue in enumerate(cues):
        must(isinstance(cue, dict), "Cue must be object")
        a, b, text = cue.get("start_frame"), cue.get("end_frame"), cue.get("text")
        must(type(a) is int and type(b) is int and isinstance(text, str) and
             previous <= a < b <= duration, "Cue timing invalid/overlapping")
        must("\n" not in text and "\r" not in text and len(text) <= 70, "Cue text too long")
        words = text.split()
        must(all(len(word) <= 32 for word in words), "Single caption word too long")
        wrapped = textwrap.wrap(_normalized(text), width=32, break_long_words=False)
        must(1 <= len(wrapped) <= 2, "Caption needs more than two lines")
        phrase_texts.append(text)
        previous = b
        caption_file = stage_dir / f"caption_{n:03d}.txt"
        caption_file.write_text("\n".join(wrapped), encoding="utf-8")
        filters.append("drawtext=" + ":".join((
            f"fontfile='{_filter_path(font)}'", f"textfile='{_filter_path(caption_file)}'",
            "fontsize=52", "fontcolor=white", "borderw=2", "bordercolor=black",
            "box=1", "boxcolor=black@0.55", "boxborderw=12",
            "x=(w-text_w)/2", "y=h-350-text_h", f"enable='between(n,{a},{b-1})'")))
    must(_normalized(" ".join(phrase_texts)) == _normalized(video_text),
         "Caption phrases must reproduce approved voice text exactly")

    video_path = stage_dir / "captioned.mp4"
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-n",
           "-i", str(proxy), "-vf", ",".join(filters), "-frames:v", str(duration),
           "-an", "-c:v", "libx264", "-preset", "medium", "-crf", "18",
           "-pix_fmt", "yuv420p", "-r", "24", "-fps_mode", "cfr",
           "-x264-params", "colorprim=bt709:transfer=bt709:colormatrix=bt709",
           "-color_primaries", "bt709", "-color_trc", "bt709",
           "-colorspace", "bt709", "-movflags", "+faststart", str(video_path)]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=max(90, duration // 3 + 60))
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise G4Blocked("FFmpeg unavailable or timed out during G4 caption render") from exc
    must(result.returncode == 0 and video_path.is_file(),
         "G4 caption render failed: " + result.stderr[-600:])
    check_video(video_path, duration)
    sha = hash_file(video_path)
    receipt = {"schema": "g4-conform-receipt-v1", "beat_id": beat_id,
               "video_sha256": sha, "mapping_sha256": mapping_sha,
               "source_revision_id": shot["source_revision_id"],
               "source_sha256": shot["source_sha256"],
               "voice_text_sha256": voice["text_sha256"],
               "start_frame": start, "end_frame": end,
               "render_frames": duration,
               "caption_policy": "approved_phrase_cues_raster",
               "caption_cues": cues, "caption_font_sha256": hash_file(font),
               "crop_policy": "fit_preserves_full_frame",
               "source_proxy_sha256": mapping["proxy_sha256"]}
    receipt_path = stage_dir / "conform_receipt.json"
    receipt_path.write_bytes(canon(receipt))
    return {"status": "STAGED_REQUIRES_S08_COMMIT", "video_path": str(video_path),
            "video_sha256": sha, "receipt_path": str(receipt_path),
            "receipt_sha256": hash_file(receipt_path), "beat_id": beat_id,
            "required_publication_types": ["g4_captioned_cfr", "g4_conform_receipt"],
            "is_preview_approved": False}
