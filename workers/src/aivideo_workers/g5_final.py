"""Gate G5 S22: Final 2160x3840 24fps SDR Rec.709 conform, Resolve final build,
render, QC, and isolated manual handoff branch.

Invariants enforced:
- Only an active S21 canonical preview approval (g4_preview_approvals) unlocks S22.
- All upstream G3/G4 S08 publications + sealed S05 sources are re-verified on disk.
- Preflight disk free space check prevents mid-render volume exhaustion.
- Final output must be 2160x3840, 24/1 CFR, bt709, 48kHz audio, peak < -0.01 dBFS,
  decoded frame count == approved total_frames (<= 4319 frames / < 180s).
- Resolve final project exports a verifiable .drp archive (>1024B ZIP).
- Manual handoff forks a separate Resolve project/timeline and records an immutable
  handoff branch receipt so manual edits never overwrite or masquerade as the
  automated canonical timeline (RES-03, RES-05, INV-05).
"""
from __future__ import annotations

from fractions import Fraction
from pathlib import Path
import json
import os
import re
import shutil
import sqlite3
import subprocess
import textwrap
import time
import uuid
import zipfile

from .g4_core import (
    G4Blocked,
    MAX_BEATS,
    MAX_FRAMES,
    PROFILE,
    _as_int,
    _read_db,
    canon,
    digest,
    ffprobe,
    hash_file,
    must,
    publication,
    read_json,
    read_wav_samples,
    row,
)
from .g4_resolve import Journal, _assert_connected, _current, _locked, _resolve_connection

FINAL_WIDTH = 2160
FINAL_HEIGHT = 3840
MIN_FREE_DISK_BYTES = 512 * 1024 * 1024  # 512 MiB preflight floor


def _g5_safe_root() -> Path:
    root = os.environ.get("AIVIDEO_G5_WORK_ROOT") or os.environ.get("AIVIDEO_G4_WORK_ROOT", "")
    must(bool(root), "AIVIDEO_G5_WORK_ROOT (or AIVIDEO_G4_WORK_ROOT) must be provided by Swift")
    raw = Path(root).expanduser()
    must(raw.is_absolute() and not raw.is_symlink(),
         "G5 working root must be absolute and not a symlink")
    path = raw.resolve(strict=True)
    must(path.is_dir(), "G5 working directory not created")
    return path


def _preflight_disk_space(root: Path, min_bytes: int = MIN_FREE_DISK_BYTES) -> dict:
    override = os.environ.get("AIVIDEO_G5_SIMULATE_FREE_BYTES")
    if override is not None:
        free_bytes = int(override)
        total_bytes = max(free_bytes, min_bytes * 2)
    else:
        usage = shutil.disk_usage(str(root))
        free_bytes = int(usage.free)
        total_bytes = int(usage.total)
    must(free_bytes >= min_bytes,
         f"DISK_SPACE_INSUFFICIENT: {free_bytes} bytes free < required {min_bytes} bytes")
    return {"free_bytes": free_bytes, "required_min_bytes": min_bytes, "total_bytes": total_bytes}


def _filter_path(path: Path) -> str:
    return (str(path).replace("\\", "\\\\").replace(":", "\\:")
            .replace("'", "\\'").replace(",", "\\,").replace("[", "\\[")
            .replace("]", "\\]"))


def _normalized(text: str) -> str:
    return " ".join(text.split())


def check_final_video(path: Path, required_frames: int, *, with_audio: bool = False) -> dict:
    data = ffprobe(path, count_frames=True)
    video = [x for x in data.get("streams", []) if x.get("codec_type") == "video"]
    must(len(video) == 1, "Expected exactly one video stream in 4K final asset")
    item = video[0]
    must(int(item.get("width", 0)) == FINAL_WIDTH and int(item.get("height", 0)) == FINAL_HEIGHT,
         f"Final video must be {FINAL_WIDTH}x{FINAL_HEIGHT}")
    must(Fraction(item.get("avg_frame_rate", "0/1")) == 24 and
         Fraction(item.get("r_frame_rate", "0/1")) == 24,
         "Final video must be CFR 24fps (not VFR)")
    must(item.get("pix_fmt") in ("yuv420p", "yuv420p10le"), "Unsupported final video pixel format")
    frame_count = item.get("nb_read_frames")
    must(frame_count is not None and int(frame_count) == required_frames,
         "Final video decoded frame count != approved cut length")
    must(item.get("color_primaries") == "bt709" and
         item.get("color_transfer") == "bt709" and
         item.get("color_space") == "bt709", "Final output color tags must be Rec.709")
    if with_audio:
        audio = [x for x in data.get("streams", []) if x.get("codec_type") == "audio"]
        must(len(audio) == 1 and int(audio[0].get("sample_rate", 0)) == 48000,
             "Final render requires 48kHz audio")
        seconds = float(data.get("format", {}).get("duration", 0))
        must(seconds < 180.0 and abs(seconds - required_frames / 24) <= 1 / 24 + 0.03,
             "Final container duration differs from timeline or exceeds 180s")
    return {
        "frames": required_frames,
        "width": FINAL_WIDTH,
        "height": FINAL_HEIGHT,
        "fps": 24,
        "color": "bt709",
        "video_codec": item.get("codec_name"),
    }


def final_technical_qc(final_path: str, expected_sha: str, expected_frames: int) -> dict:
    path = Path(final_path).expanduser().resolve(strict=True)
    must(expected_frames in range(1, MAX_FRAMES + 1), "Expected frame count outside 1..4319 (<180s)")
    must(hash_file(path) == expected_sha, "Final MP4 bytes do not match review snapshot")
    summary = check_final_video(path, expected_frames, with_audio=True)
    try:
        command = [
            "ffmpeg", "-hide_banner", "-nostdin", "-i", str(path),
            "-vn", "-af", "volumedetect", "-f", "null", "-",
        ]
        checked = subprocess.run(command, capture_output=True, text=True, timeout=180)
        must(checked.returncode == 0, "Cannot decode final MP4 audio for loudness QC")
        match = re.findall(r"max_volume:\s*([+-]?(?:\d+\.?\d*|inf)) dB", checked.stderr)
        must(len(match) > 0, "Final audio peak could not be measured")
        max_volume_db = float(match[-1])
        must(max_volume_db < -0.01, "Final audio hits digital full scale")
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise G4Blocked("Final audio volume QC could not be completed") from exc
    return {
        "status": "FINAL_TECHNICAL_PASS_HUMAN_RELEASE_REVIEW_REQUIRED",
        "sha256": expected_sha,
        "bytes": path.stat().st_size,
        "verified": summary,
        "audio_max_volume_dbfs": max_volume_db,
        "semantic_verified": False,
        "human_release_qc_required": True,
    }


def _verified_s21_context(db: sqlite3.Connection, project_id: str) -> dict:
    """Verify active G3 S19 approval AND active G4 S21 preview approval in SQLite."""
    selected = row(db, "SELECT script_revision_id FROM g3_selected WHERE project_id=?", (project_id,))[0]
    g3_row = row(
        db,
        """SELECT approval_id,script_revision_id,manifest_json,manifest_sha256,
                  candidate_sha256,workday_id
           FROM g3_approvals WHERE project_id=? AND script_revision_id=?""",
        (project_id, selected),
    )
    g3_approval_id, rev, manifest_raw, manifest_sha, cand_sha, workday_id = tuple(g3_row)
    must(digest(manifest_raw.encode()) == manifest_sha, "Approved G3 manifest tampered")
    manifest = json.loads(manifest_raw)

    cand_row = row(
        db,
        """SELECT candidate_json,candidate_sha256,scope_revision_id
           FROM g3_scripts WHERE script_revision_id=? AND project_id=?""",
        (rev, project_id),
    )
    cand_raw, saved_cand_sha, scope = tuple(cand_row)
    must(saved_cand_sha == cand_sha == digest(cand_raw.encode()), "G3 script candidate changed")
    candidate = json.loads(cand_raw)
    must(
        candidate.get("status") == "DRAFT_NOT_BUILDABLE"
        and candidate.get("scope_revision_id") == scope == manifest.get("scope_revision_id"),
        "G3 scope or revision invalid",
    )

    for claim_rev in candidate.get("claim_revision_ids", []):
        claim = row(
            db,
            """SELECT claim_id,support_status,allowed_use,review_status,origin
               FROM claims WHERE revision_id=? AND workday_id=?""",
            (claim_rev, workday_id),
        )
        latest = row(
            db,
            "SELECT revision_id FROM claims WHERE claim_id=? ORDER BY rowid DESC LIMIT 1",
            (claim[0],),
        )[0]
        must(
            latest == claim_rev
            and claim[1] == "supported"
            and claim[2] in ("direct_claim", "attributed_or_qualified")
            and claim[3] not in ("rejected", "superseded", "needs_review", "unreviewed")
            and (claim[4] != "user" or claim[2] == "attributed_or_qualified"),
            "Stale or ineligible S19 claim blocks S22",
        )

    unresolved = db.execute(
        """SELECT COUNT(*) FROM review_items WHERE workday_id=?
           AND evidence_scope_revision_id=? AND is_critical=1 AND status!='resolved'""",
        (workday_id, scope),
    ).fetchone()[0]
    must(unresolved == 0, "Critical G2 review remains pending; S22 blocked")

    g4_row = row(
        db,
        """SELECT approval_id,preview_publication_id,preview_sha256,plan_sha256,
                  qc_receipt_json,qc_receipt_sha256
           FROM g4_preview_approvals
           WHERE project_id=? AND g3_approval_id=?
           ORDER BY approved_at DESC, rowid DESC LIMIT 1""",
        (project_id, g3_approval_id),
    )
    g4_approval_id, preview_pub_id, preview_sha, g4_plan_sha, g4_receipt_raw, g4_receipt_sha = tuple(g4_row)
    must(digest(g4_receipt_raw.encode()) == g4_receipt_sha, "G4 preview QC receipt hash mismatch")
    g4_receipt = json.loads(g4_receipt_raw)
    must(
        g4_receipt.get("g3_approval_id") == g3_approval_id
        and g4_receipt.get("g3_manifest_sha256") == manifest_sha
        and g4_receipt.get("preview_sha256") == preview_sha,
        "G4 preview approval not bound to current G3 approval",
    )
    preview_path, _ = publication(
        db, project_id, preview_pub_id, "g4_preview_mp4", preview_sha, max_bytes=4 * 1024**3
    )
    for dep_id in g4_receipt.get("required_publication_ids", []):
        dep_rec = row(
            db,
            """SELECT artifact_type,state,sha256_hash,canonical_path,byte_size
               FROM artifact_publications WHERE publication_id=? AND project_id=?""",
            (str(uuid.UUID(dep_id)).upper(), project_id),
        )
        must(dep_rec[1] == "COMMITTED", "G4 dependency publication not COMMITTED")
        dep_path = Path(dep_rec[3]).resolve(strict=True)
        must(
            dep_path.stat().st_size == int(dep_rec[4]) and hash_file(dep_path) == str(dep_rec[2]),
            "G4 dependency publication modified since S21 approval",
        )

    return {
        "project_id": project_id,
        "workday_id": workday_id,
        "script_revision_id": rev,
        "scope_revision_id": scope,
        "g3_approval_id": g3_approval_id,
        "g3_manifest_sha256": manifest_sha,
        "g3_manifest": manifest,
        "candidate": candidate,
        "g4_approval_id": g4_approval_id,
        "g4_preview_publication_id": preview_pub_id,
        "g4_preview_sha256": preview_sha,
        "g4_preview_path": str(preview_path),
        "g4_plan_sha256": g4_plan_sha,
    }


def stage_final_captioned_clip(params: dict) -> dict:
    """Stage a 2160x3840 24fps SDR Rec.709 captioned clip for S22 final render."""
    root = _g5_safe_root()
    _preflight_disk_space(root)
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
        ctx = _verified_s21_context(db, project)
        manifest = ctx["g3_manifest"]
        script = ctx["candidate"]
        beat_pos = next((i for i, b in enumerate(script["beats"]) if b["beat_id"] == beat_id), None)
        must(beat_pos is not None, "Beat not in approved G3 script")
        beat = script["beats"][beat_pos]
        video_text = beat["voice_text"]
        voice = manifest["voice_publications"][beat_pos]
        must(
            voice["beat_id"] == beat_id and digest(video_text.encode()) == voice["text_sha256"],
            "Voice text no longer matches G3",
        )
        cut_path, _ = publication(
            db, project, manifest["cut_publication_id"], "g3_cut_plan",
            manifest["edit_plan_sha256"], 8 * 1024 * 1024,
        )
        shot = read_json(cut_path.read_bytes())["edit_plan"][beat_pos]
        mapping_path, mapping_sha = publication(
            db, project, mapping_id, "g2_source_mapping", shot["mapping_sha256"], 8 * 1024 * 1024
        )
        mapping = read_json(mapping_path.read_bytes())
        cm = mapping.get("conform_map", {})
        start, end, duration = shot["range_start"], shot["range_end"], shot["duration_frames"]
        must(
            type(start) is type(end) is type(duration) is int
            and 0 <= start < end
            and duration == end - start,
            "G5 4K stage supports one-to-one hard-cut source frames only",
        )
        must(
            mapping.get("source_revision_id") == shot["source_revision_id"]
            and mapping.get("source_sha256") == shot["source_sha256"]
            and cm.get("profile_id") == PROFILE
            and cm.get("dropped_critical_evidence_frame_ids") == []
            and len(cm.get("mappings", [])) >= end,
            "Invalid S10 source-to-CFR mapping",
        )
        source = row(
            db,
            "SELECT snapshot_path,snapshot_sha256,is_stable FROM source_revisions WHERE source_revision_id=?",
            (shot["source_revision_id"],),
        )
        must(
            source[1] == shot["source_sha256"]
            and source[2] == 1
            and hash_file(Path(source[0])) == source[1],
            "Sealed source changed since S19/S21",
        )
        proxy = Path(mapping["proxy_path"]).expanduser().resolve(strict=True)
        must(
            hash_file(proxy) == mapping["proxy_sha256"] and mapping.get("proxy_fps") == "24/1",
            "Proxy does not match published S10 mapping",
        )
        index = ffprobe(proxy, count_frames=True)
        visual = [v for v in index.get("streams", []) if v.get("codec_type") == "video"]
        must(
            len(visual) == 1
            and Fraction(visual[0].get("avg_frame_rate", "0/1")) == 24
            and Fraction(visual[0].get("r_frame_rate", "0/1")) == 24
            and int(visual[0].get("nb_read_frames", 0)) >= end
            and all(visual[0].get(k) == "bt709" for k in ("color_primaries", "color_transfer", "color_space")),
            "S10 proxy is not verified 24fps SDR Rec.709",
        )

    previous = 0
    phrase_texts = []
    filters = [
        f"trim=start_frame={start}:end_frame={end}",
        "setpts=PTS-STARTPTS",
        "fps=24",
        f"scale={FINAL_WIDTH}:{FINAL_HEIGHT}:force_original_aspect_ratio=decrease",
        f"pad={FINAL_WIDTH}:{FINAL_HEIGHT}:(ow-iw)/2:(oh-ih)/2:color=black",
        "format=yuv420p",
    ]
    stage_dir = root / "g5_staging" / uuid.uuid4().hex
    stage_dir.mkdir(parents=True, exist_ok=False)
    for n, cue in enumerate(cues):
        must(isinstance(cue, dict), "Cue must be object")
        a, b, text = cue.get("start_frame"), cue.get("end_frame"), cue.get("text")
        must(
            type(a) is int and type(b) is int and isinstance(text, str) and previous <= a < b <= duration,
            "Cue timing invalid/overlapping",
        )
        must("\n" not in text and "\r" not in text and len(text) <= 70, "Cue text too long")
        words = text.split()
        must(all(len(word) <= 32 for word in words), "Single caption word too long")
        wrapped = textwrap.wrap(_normalized(text), width=32, break_long_words=False)
        must(1 <= len(wrapped) <= 2, "Caption needs more than two lines")
        phrase_texts.append(text)
        previous = b
        caption_file = stage_dir / f"caption_{n:03d}.txt"
        caption_file.write_text("\n".join(wrapped), encoding="utf-8")
        filters.append(
            "drawtext="
            + ":".join((
                f"fontfile='{_filter_path(font)}'",
                f"textfile='{_filter_path(caption_file)}'",
                "fontsize=104",
                "fontcolor=white",
                "borderw=4",
                "bordercolor=black",
                "box=1",
                "boxcolor=black@0.55",
                "boxborderw=24",
                "x=(w-text_w)/2",
                "y=h-700-text_h",
                f"enable='between(n,{a},{b-1})'",
            ))
        )
    must(
        _normalized(" ".join(phrase_texts)) == _normalized(video_text),
        "Caption phrases must reproduce approved voice text exactly",
    )

    video_path = stage_dir / "final_captioned_2160x3840.mp4"
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-n",
        "-i", str(proxy), "-vf", ",".join(filters), "-frames:v", str(duration),
        "-an", "-c:v", "libx264", "-preset", "medium", "-crf", "18",
        "-pix_fmt", "yuv420p", "-r", "24", "-fps_mode", "cfr",
        "-x264-params", "colorprim=bt709:transfer=bt709:colormatrix=bt709",
        "-color_primaries", "bt709", "-color_trc", "bt709",
        "-colorspace", "bt709", "-movflags", "+faststart", str(video_path),
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=max(120, duration // 2 + 60))
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise G4Blocked("FFmpeg unavailable or timed out during G5 4K caption render") from exc
    must(result.returncode == 0 and video_path.is_file(), "G5 4K caption render failed: " + result.stderr[-600:])
    check_final_video(video_path, duration)
    sha = hash_file(video_path)
    receipt = {
        "schema": "g5-conform-receipt-v1",
        "beat_id": beat_id,
        "video_sha256": sha,
        "mapping_sha256": mapping_sha,
        "source_revision_id": shot["source_revision_id"],
        "source_sha256": shot["source_sha256"],
        "voice_text_sha256": voice["text_sha256"],
        "g4_approval_id": ctx["g4_approval_id"],
        "g4_preview_sha256": ctx["g4_preview_sha256"],
        "start_frame": start,
        "end_frame": end,
        "render_frames": duration,
        "width": FINAL_WIDTH,
        "height": FINAL_HEIGHT,
        "caption_policy": "approved_phrase_cues_raster",
        "caption_cues": cues,
        "caption_font_sha256": hash_file(font),
        "crop_policy": "fit_preserves_full_frame",
        "source_proxy_sha256": mapping["proxy_sha256"],
    }
    receipt_path = stage_dir / "g5_conform_receipt.json"
    receipt_path.write_bytes(canon(receipt))
    return {
        "status": "STAGED_REQUIRES_S08_COMMIT",
        "video_path": str(video_path),
        "video_sha256": sha,
        "receipt_path": str(receipt_path),
        "receipt_sha256": hash_file(receipt_path),
        "beat_id": beat_id,
        "required_publication_types": ["g5_captioned_cfr_4k", "g5_conform_receipt"],
        "is_final_approved": False,
    }


def approved_final_plan(db_path: str, project_id: str, assets: list[dict]) -> dict:
    """Build a verified S22 2160x3840 24fps Resolve plan from S19 + S21 + S08 publications."""
    try:
        project_id = str(uuid.UUID(project_id)).upper()
    except ValueError as exc:
        raise G4Blocked("Invalid project ID") from exc
    must(isinstance(assets, list) and 0 < len(assets) <= MAX_BEATS, "Invalid G5 asset list")
    mapping = {a["beat_id"]: a for a in assets if isinstance(a, dict) and "beat_id" in a}
    must(len(mapping) == len(assets), "Duplicate or malformed G5 asset beat IDs")

    with _read_db(db_path) as db:
        ctx = _verified_s21_context(db, project_id)
        manifest = ctx["g3_manifest"]
        candidate = ctx["candidate"]
        rev = ctx["script_revision_id"]
        scope = ctx["scope_revision_id"]
        beats = candidate.get("beats", [])
        must(isinstance(beats, list) and 0 < len(beats) <= MAX_BEATS and len(beats) == len(mapping),
             "Beat count differs from S19")
        cut_path, cut_sha = publication(
            db, project_id, manifest["cut_publication_id"],
            "g3_cut_plan", manifest["edit_plan_sha256"], 8 * 1024 * 1024,
        )
        cut = read_json(cut_path.read_bytes())
        shots = cut.get("edit_plan", [])
        must(
            len(shots) == len(beats)
            and cut.get("script_revision_id") == rev
            and cut.get("scope_revision_id") == scope
            and cut.get("domain_sha256") == manifest.get("domain_sha256"),
            "Cut does not belong to approved G3 script",
        )
        must(
            manifest.get("total_frames") == sum(s.get("duration_frames", 0) for s in shots)
            and 0 < manifest["total_frames"] <= MAX_FRAMES,
            "Timeline length outside M-24-SDR-v1 or differs from edit plan",
        )
        voice_pubs = manifest["voice_publications"]
        entries = []
        source_hash_cache: dict[str, str] = {}
        for index, (beat, shot, voice) in enumerate(zip(beats, shots, voice_pubs)):
            beat_id = beat["beat_id"]
            must(beat_id in mapping and voice.get("beat_id") == beat_id, "Beat/media mapping mismatch")
            must(shot["shot_id"] in beat.get("shot_candidate_ids", []), "Shot not in approved domain")
            seal = row(
                db,
                """SELECT r.snapshot_path,r.snapshot_sha256,r.is_stable,m.content_sha256
                   FROM source_revisions r JOIN source_media m ON m.media_id=r.media_id
                   WHERE r.source_revision_id=? AND m.project_id=?""",
                (shot["source_revision_id"], project_id),
            )
            source_key = shot["source_revision_id"]
            if source_key not in source_hash_cache:
                source_hash_cache[source_key] = hash_file(Path(seal[0]))
            must(
                seal[2] == 1
                and seal[1] == seal[3] == shot["source_sha256"]
                and source_hash_cache[source_key] == shot["source_sha256"],
                "G3/G4 source snapshot not sealed or source bytes changed",
            )
            mapping_path, _ = publication(
                db, project_id, shot["mapping_publication_id"],
                "g2_source_mapping", shot["mapping_sha256"], 8 * 1024 * 1024,
            )
            conform = read_json(mapping_path.read_bytes())
            cm = conform.get("conform_map", {})
            must(
                conform.get("source_revision_id") == shot["source_revision_id"]
                and conform.get("source_sha256") == shot["source_sha256"]
                and cm.get("profile_id") == PROFILE
                and cm.get("is_valid_for_evidence") is True
                and cm.get("dropped_critical_evidence_frame_ids") == []
                and len(cm.get("mappings", [])) >= shot["range_end"],
                "G2 source mapping is stale or malformed",
            )
            duration = _as_int(shot.get("duration_frames"), "duration_frames")
            must(1 <= duration <= MAX_FRAMES and shot.get("transition_overlap_frames") == 0,
                 "Invalid shot duration or unsupported transition overlap")
            video_path, video_sha = publication(
                db, project_id, mapping[beat_id]["publication_id"],
                "g5_captioned_cfr_4k", max_bytes=4 * 1024**3,
            )
            receipt_path, _ = publication(
                db, project_id, mapping[beat_id]["receipt_publication_id"],
                "g5_conform_receipt", max_bytes=8 * 1024 * 1024,
            )
            stage_receipt = read_json(receipt_path.read_bytes())
            must(
                stage_receipt.get("schema") == "g5-conform-receipt-v1"
                and stage_receipt.get("beat_id") == beat_id
                and stage_receipt.get("video_sha256") == video_sha
                and stage_receipt.get("mapping_sha256") == shot["mapping_sha256"]
                and stage_receipt.get("source_revision_id") == shot["source_revision_id"]
                and stage_receipt.get("source_sha256") == shot["source_sha256"]
                and stage_receipt.get("voice_text_sha256") == voice["text_sha256"]
                and stage_receipt.get("g4_approval_id") == ctx["g4_approval_id"]
                and stage_receipt.get("g4_preview_sha256") == ctx["g4_preview_sha256"]
                and stage_receipt.get("start_frame") == shot["range_start"]
                and stage_receipt.get("end_frame") == shot["range_end"]
                and stage_receipt.get("render_frames") == duration
                and stage_receipt.get("width") == FINAL_WIDTH
                and stage_receipt.get("height") == FINAL_HEIGHT
                and stage_receipt.get("caption_policy") == "approved_phrase_cues_raster",
                "G5 4K captioned asset lacks matching conform/source/S21 proof",
            )
            video_proof = check_final_video(video_path, duration)
            voice_path, voice_sha = publication(
                db, project_id, voice["publication_id"], "voice_wav", voice["sha256"], 128 * 1024**2
            )
            voice_samples = read_wav_samples(voice_path)
            must((voice_samples + 1999) // 2000 <= duration, "Speech exceeds beat duration")
            revrow = row(
                db,
                """SELECT wav_sha256,text_sha256 FROM g3_voice_reviews
                   WHERE script_revision_id=? AND beat_id=? AND publication_id=?""",
                (rev, beat_id, voice["publication_id"]),
            )
            must(revrow[0] == voice_sha and revrow[1] == voice["text_sha256"],
                 "WAV was not verified against this narration")
            must(digest(beat["voice_text"].encode()) == voice["text_sha256"],
                 "Voice text differs from approved G3 beat")
            entries.append({
                "index": index,
                "beat_id": beat_id,
                "video_publication_id": mapping[beat_id]["publication_id"],
                "receipt_publication_id": mapping[beat_id]["receipt_publication_id"],
                "mapping_publication_id": shot["mapping_publication_id"],
                "voice_publication_id": voice["publication_id"],
                "shot_id": shot["shot_id"],
                "duration_frames": duration,
                "video_path": str(video_path),
                "video_sha256": video_sha,
                "voice_path": str(voice_path),
                "voice_sha256": voice_sha,
                "voice_samples": voice_samples,
                "caption_text_sha256": voice["text_sha256"],
                "source_revision_id": shot["source_revision_id"],
                "source_sha256": shot["source_sha256"],
                "mapping_sha256": shot["mapping_sha256"],
                "range_start": shot["range_start"],
                "range_end": shot["range_end"],
                "video_probe": video_proof,
            })

        result = {
            "schema": "g5-final-plan-v1",
            "profile": PROFILE,
            "width": FINAL_WIDTH,
            "height": FINAL_HEIGHT,
            "project_id": project_id,
            "g3_approval_id": ctx["g3_approval_id"],
            "g3_manifest_sha256": ctx["g3_manifest_sha256"],
            "g4_approval_id": ctx["g4_approval_id"],
            "g4_preview_publication_id": ctx["g4_preview_publication_id"],
            "g4_preview_sha256": ctx["g4_preview_sha256"],
            "script_revision_id": rev,
            "cut_sha256": cut_sha,
            "cut_publication_id": manifest["cut_publication_id"],
            "total_frames": manifest["total_frames"],
            "entries": entries,
            "caption_format": "raster_burned_in_not_native_editable",
        }
        result["plan_sha256"] = digest(canon(result))
        return result


def _final_names(plan: dict) -> tuple[str, str]:
    return "AIVideo_G5_" + plan["plan_sha256"][:20], "G5_FINAL_" + plan["plan_sha256"][:20]


def _readback_final(project, name: str, timeline_name: str, plan: dict) -> dict:
    must(project.GetName() == name, "Project identity changed")
    tl = project.GetCurrentTimeline()
    must(tl is not None and tl.GetName() == timeline_name, "TIMELINE_SWITCHED")
    unique = tl.GetUniqueId()
    must(isinstance(unique, str) and unique, "Timeline unique ID unavailable")
    width = str(tl.GetSetting("timelineResolutionWidth"))
    height = str(tl.GetSetting("timelineResolutionHeight"))
    rate = str(tl.GetSetting("timelineFrameRate"))
    must(
        width == str(FINAL_WIDTH) and height == str(FINAL_HEIGHT) and float(rate) == 24.0,
        "Managed 4K timeline profile drift",
    )
    videos = list(tl.GetItemListInTrack("video", 1) or [])
    audios = list(tl.GetItemListInTrack("audio", 1) or [])
    must(tl.GetTrackCount("video") == 1 and tl.GetTrackCount("audio") == 1,
         "Unexpected extra tracks; possible manual edit on managed timeline")
    must(len(videos) == len(audios) == len(plan["entries"]), "Timeline item count drift")
    baseline = int(tl.GetStartFrame())
    must(int(tl.GetEndFrame()) - baseline == plan["total_frames"],
         "Managed timeline duration drift")
    result = []
    cursor = baseline
    for entry, vid, aud in zip(plan["entries"], videos, audios):
        required = entry["duration_frames"]
        adur = (entry["voice_samples"] + 1999) // 2000
        must(int(vid.GetStart()) == cursor and int(vid.GetDuration()) == required,
             "Managed 4K video frame range drift")
        must(int(aud.GetStart()) == cursor and int(aud.GetDuration()) == adur,
             "Managed WAV position/duration drift")
        vp = vid.GetMediaPoolItem()
        ap = aud.GetMediaPoolItem()
        must(vp is not None and ap is not None, "Timeline media item unavailable")
        must(Path(str(vp.GetClipProperty("File Path"))).resolve() == Path(entry["video_path"]).resolve(),
             "Media path readback mismatch (V1)")
        must(Path(str(ap.GetClipProperty("File Path"))).resolve() == Path(entry["voice_path"]).resolve(),
             "Media path readback mismatch (A1)")
        vid_id = vid.GetUniqueId()
        aud_id = aud.GetUniqueId()
        must(vid_id and aud_id, "Timeline item unique ID unavailable")
        result.append({
            "video_uid": vid_id,
            "audio_uid": aud_id,
            "video_start": cursor,
            "video_frames": required,
            "audio_frames": adur,
            "video_sha256": entry["video_sha256"],
            "voice_sha256": entry["voice_sha256"],
        })
        cursor += required
    return {
        "project_name": name,
        "timeline_name": timeline_name,
        "timeline_uid": unique,
        "start_frame": baseline,
        "total_frames": plan["total_frames"],
        "width": FINAL_WIDTH,
        "height": FINAL_HEIGHT,
        "fps": 24,
        "items": result,
        "readback_scope": "track_items_paths_duration_only_effects_not_certified",
        "signature": digest(canon(result)),
    }


def build_final(params: dict, *, resolve=None) -> dict:
    """S22: Build managed 2160x3840 24fps Resolve timeline + export .drp archive."""
    root = _g5_safe_root()
    disk = _preflight_disk_space(root)
    with _locked(root):
        plan = approved_final_plan(params["db_path"], params["project_id"], params["assets"])
        name, tl_name = _final_names(plan)
        op_id = "g5_build:" + plan["plan_sha256"]
        journal = Journal(root)
        try:
            r = resolve if resolve is not None else _resolve_connection()
            pm = _assert_connected(r)
            old = journal.db.execute("SELECT state FROM operations WHERE op_id=?", (op_id,)).fetchone()
            if old:
                receipt = journal.load(op_id)
                observed = _readback_final(_current(pm, name), name, tl_name, plan)
                must(
                    observed["signature"] == receipt["readback"]["signature"]
                    and observed["timeline_uid"] == receipt["readback"]["timeline_uid"],
                    "Managed 4K timeline changed; preserve manual changes",
                )
                return {"status": "ALREADY_BUILT_VERIFIED", "receipt": receipt}
            must(pm.GetCurrentProject() is None,
                 "Close your current Resolve project before creating G5 managed project")
            existing = pm.GetProjectListInCurrentFolder() or []
            must(name not in existing, "Managed G5 project name already exists; manual reconciliation required")
            journal.start(op_id, "g5_build", plan["plan_sha256"], name, tl_name)
            project = pm.CreateProject(name)
            must(project is not None and project.GetName() == name,
                 "Resolve CreateProject failed or project changed")
            pool = project.GetMediaPool()
            must(pool is not None, "Resolve MediaPool unavailable")
            tl = pool.CreateEmptyTimeline(tl_name)
            must(tl is not None, "Resolve CreateEmptyTimeline failed")
            must(project.SetCurrentTimeline(tl) is True, "SetCurrentTimeline failed")
            for setting, val in (
                ("useCustomSettings", "1"),
                ("timelineResolutionWidth", str(FINAL_WIDTH)),
                ("timelineResolutionHeight", str(FINAL_HEIGHT)),
                ("timelineFrameRate", "24"),
            ):
                must(tl.SetSetting(setting, val) is True, "Cannot set " + setting)
            pos = 86400
            for entry in plan["entries"]:
                _current(pm, name)
                video = pool.ImportMedia([entry["video_path"]])
                audio = pool.ImportMedia([entry["voice_path"]])
                must(video and len(video) == 1 and audio and len(audio) == 1, "MediaPool import failed")
                v_info = {
                    "mediaPoolItem": video[0],
                    "startFrame": 0,
                    "endFrame": entry["duration_frames"],
                    "mediaType": 1,
                    "trackIndex": 1,
                    "recordFrame": pos,
                }
                a_info = {
                    "mediaPoolItem": audio[0],
                    "startFrame": 0,
                    "endFrame": (entry["voice_samples"] + 1999) // 2000,
                    "mediaType": 2,
                    "trackIndex": 1,
                    "recordFrame": pos,
                }
                must(pool.AppendToTimeline([v_info]), "Resolve 4K video append failed")
                must(pool.AppendToTimeline([a_info]), "Resolve WAV append failed")
                pos += entry["duration_frames"]
            must(pm.SaveProject() is True, "Resolve project save failed")
            readback = _readback_final(_current(pm, name), name, tl_name, plan)
            must(readback["start_frame"] == 86400, "Unexpected initial timecode")
            drp_dir = root / "g5_projects"
            drp_dir.mkdir(exist_ok=True)
            drp = drp_dir / (name + ".drp")
            temp = drp_dir / (name + ".partial.drp")
            must(not drp.exists() and not temp.exists(), "G5 DRP already exists; reconcile first")
            must(
                pm.ExportProject(name, str(temp)) is True
                and temp.is_file()
                and temp.stat().st_size > 1024
                and zipfile.is_zipfile(temp),
                "Resolve G5 DRP export not verifiable",
            )
            os.replace(temp, drp)
            receipt = {
                "schema": "g5-s22-build-receipt-v1",
                "plan_sha256": plan["plan_sha256"],
                "g3_approval_id": plan["g3_approval_id"],
                "g3_manifest_sha256": plan["g3_manifest_sha256"],
                "g4_approval_id": plan["g4_approval_id"],
                "g4_preview_sha256": plan["g4_preview_sha256"],
                "script_revision_id": plan["script_revision_id"],
                "readback": readback,
                "drp_path": str(drp),
                "drp_sha256": hash_file(drp),
                "disk_preflight": disk,
                "status": "BUILT_NEEDS_FINAL_RENDER_AND_QC",
            }
            journal.finish(op_id, receipt)
            return {"status": "BUILT_VERIFIED_4K_TRACK_ONLY", "receipt": receipt}
        finally:
            journal.close()


def render_final_start(params: dict, *, resolve=None) -> dict:
    """S22: Submit 2160x3840 24fps final render job with pre-render journal intent."""
    root = _g5_safe_root()
    _preflight_disk_space(root)
    with _locked(root):
        plan = approved_final_plan(params["db_path"], params["project_id"], params["assets"])
        name, tl_name = _final_names(plan)
        key = "g5_render:" + plan["plan_sha256"]
        journal = Journal(root)
        try:
            r = resolve if resolve is not None else _resolve_connection()
            pm = _assert_connected(r)
            receipt = journal.load("g5_build:" + plan["plan_sha256"])
            proj = _current(pm, name)
            observed = _readback_final(proj, name, tl_name, plan)
            must(
                observed["signature"] == receipt["readback"]["signature"]
                and observed["timeline_uid"] == receipt["readback"]["timeline_uid"],
                "MANAGED_4K_TIMELINE_DRIFT",
            )
            old = journal.db.execute("SELECT state,receipt_json FROM operations WHERE op_id=?", (key,)).fetchone()
            if old:
                if old[0] == "VERIFIED":
                    return {"status": "FINAL_RENDER_ALREADY_SUBMITTED", "receipt": json.loads(old[1])}
                raise G4Blocked("RECONCILIATION_REQUIRED: unknown final render side effect")
            must(proj.GetCurrentTimeline().GetUniqueId() == receipt["readback"]["timeline_uid"],
                 "Timeline changed")
            formats = proj.GetRenderCodecs("mp4") or {}
            codec = next((c for c in ("H.264", "H264") if c in formats), None)
            must(
                codec is not None and proj.SetCurrentRenderFormatAndCodec("mp4", codec) is True,
                "Resolve MP4 H.264 render codec unsupported",
            )
            outputs = root / "g5_renders"
            outputs.mkdir(exist_ok=True)
            filename = "G5_FINAL_" + plan["plan_sha256"][:20]
            outpath = outputs / (filename + ".mp4")
            must(not outpath.exists(), "Final MP4 already exists; manual reconciliation required")
            must(
                proj.SetRenderSettings({
                    "SelectAllFrames": True,
                    "TargetDir": str(outputs),
                    "CustomName": filename,
                    "FormatWidth": FINAL_WIDTH,
                    "FormatHeight": FINAL_HEIGHT,
                    "ExportVideo": True,
                    "ExportAudio": True,
                }) is True,
                "Resolve rejected 4K render settings",
            )
            journal.start(key, "g5_render", plan["plan_sha256"], name, tl_name)
            job_id = proj.AddRenderJob()
            must(isinstance(job_id, str) and job_id, "Resolve did not return final render job ID")
            job_receipt = {
                "job_id": job_id,
                "output_path": str(outpath),
                "plan_sha256": plan["plan_sha256"],
                "timeline_uid": observed["timeline_uid"],
                "timeline_signature": observed["signature"],
                "drp_path": receipt["drp_path"],
                "drp_sha256": receipt["drp_sha256"],
                "status": "QUEUED_NEEDS_FINAL_RENDER_STATUS",
            }
            journal.finish(key, job_receipt)
            if proj.StartRendering(job_id) is not True:
                return {"status": "FINAL_RENDER_START_UNCERTAIN_RECONCILE", "receipt": job_receipt}
            return {"status": "FINAL_RENDER_SUBMITTED", "receipt": job_receipt}
        finally:
            journal.close()


def render_final_inspect(params: dict, *, resolve=None) -> dict:
    """S22: Inspect completed 2160x3840 24fps final render and run technical QC."""
    root = _g5_safe_root()
    with _locked(root):
        plan = approved_final_plan(params["db_path"], params["project_id"], params["assets"])
        name, tl_name = _final_names(plan)
        journal = Journal(root)
        try:
            receipt = journal.load("g5_render:" + plan["plan_sha256"])
            build_receipt = journal.load("g5_build:" + plan["plan_sha256"])
            r = resolve if resolve is not None else _resolve_connection()
            pm = _assert_connected(r)
            project = _current(pm, name)
            observed = _readback_final(project, name, tl_name, plan)
            must(
                observed["timeline_uid"] == build_receipt["readback"]["timeline_uid"]
                and observed["signature"] == build_receipt["readback"]["signature"],
                "MANAGED_4K_TIMELINE_DRIFT: final render cannot be approved",
            )
            job = project.GetRenderJobStatus(receipt["job_id"])
            must(isinstance(job, dict), "Cannot verify Resolve final render job by ID")
            status = str(job.get("JobStatus", ""))
            if status != "Complete":
                return {
                    "status": "FINAL_RENDER_PENDING_OR_FAILED",
                    "resolve_status": status,
                    "job_id": receipt["job_id"],
                }
            path = Path(receipt["output_path"])
            must(path.is_file() and path.stat().st_size > 1024, "Resolve completed but final MP4 missing")
            drp_path = Path(build_receipt["drp_path"])
            must(
                drp_path.is_file()
                and drp_path.stat().st_size > 1024
                and zipfile.is_zipfile(drp_path)
                and hash_file(drp_path) == build_receipt["drp_sha256"],
                "Managed G5 DRP missing or modified",
            )
            final_sha = hash_file(path)
            qc = final_technical_qc(str(path), final_sha, plan["total_frames"])
            required_pubs = sorted(
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
            return {
                "status": "FINAL_TECHNICAL_PASS_HUMAN_RELEASE_REVIEW_REQUIRED",
                "final_path": str(path),
                "final_sha256": final_sha,
                "drp_path": str(drp_path),
                "drp_sha256": build_receipt["drp_sha256"],
                "g3_approval_id": plan["g3_approval_id"],
                "g3_manifest_sha256": plan["g3_manifest_sha256"],
                "g4_approval_id": plan["g4_approval_id"],
                "g4_preview_publication_id": plan["g4_preview_publication_id"],
                "g4_preview_sha256": plan["g4_preview_sha256"],
                "plan_sha256": plan["plan_sha256"],
                "timeline_signature": observed["signature"],
                "timeline_uid": observed["timeline_uid"],
                "render_job_id": receipt["job_id"],
                "qc": qc,
                "required_publication_ids": required_pubs,
                "approved": False,
            }
        finally:
            journal.close()


def fork_manual_handoff(params: dict) -> dict:
    """S22.5 (RES-03 / RES-05 / INV-05): Create isolated manual_handoff DRP & branch receipt.

    Manual edits in Resolve happen on a forked DRP archive (`*_MANUAL_HANDOFF.drp`),
    never mutating the managed automated timeline or auto-validating against G3/G4.
    """
    root = _g5_safe_root()
    with _locked(root):
        plan = approved_final_plan(params["db_path"], params["project_id"], params["assets"])
        journal = Journal(root)
        try:
            build_receipt = journal.load("g5_build:" + plan["plan_sha256"])
            source_drp = Path(build_receipt["drp_path"]).resolve(strict=True)
            must(
                source_drp.is_file()
                and zipfile.is_zipfile(source_drp)
                and hash_file(source_drp) == build_receipt["drp_sha256"],
                "Canonical managed G5 DRP is missing or tampered",
            )
            handoff_dir = root / "g5_manual_handoff"
            handoff_dir.mkdir(exist_ok=True)
            branch_id = str(uuid.uuid4()).upper()
            handoff_name = f"AIVideo_G5_{plan['plan_sha256'][:12]}_MANUAL_{branch_id[:8]}"
            handoff_drp = handoff_dir / f"{handoff_name}.drp"
            shutil.copy2(source_drp, handoff_drp)
            handoff_sha = hash_file(handoff_drp)
            manifest = {
                "schema": "g5-manual-handoff-branch-v1",
                "branch_id": branch_id,
                "branch_mode": "manual_handoff",
                "isolated_from_managed_timeline": True,
                "invalidates_automated_rerender_overwrite": True,
                "parent_plan_sha256": plan["plan_sha256"],
                "parent_drp_sha256": build_receipt["drp_sha256"],
                "handoff_project_name": handoff_name,
                "handoff_drp_path": str(handoff_drp),
                "handoff_drp_sha256": handoff_sha,
                "g3_approval_id": plan["g3_approval_id"],
                "g4_approval_id": plan["g4_approval_id"],
                "created_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            manifest_path = handoff_dir / f"{handoff_name}_receipt.json"
            manifest_path.write_bytes(canon(manifest))
            return {
                "status": "MANUAL_HANDOFF_BRANCH_CREATED",
                "branch": manifest,
                "receipt_path": str(manifest_path),
                "receipt_sha256": hash_file(manifest_path),
            }
        finally:
            journal.close()
