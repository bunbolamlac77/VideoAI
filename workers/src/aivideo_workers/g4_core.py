"""G4 contract, S19 authority, media verification and technical preview QC.

No mock evidence is accepted in production.  All paths to imported assets
must be resolved from committed artifact_publications, never from RPC input.
The Resolve worker does not grant approvals; Swift ProjectStore owns S21.
"""
from __future__ import annotations

from contextlib import contextmanager
from fractions import Fraction
from hashlib import sha256
from pathlib import Path
import json
import sqlite3
import subprocess
import re
from typing import Any
import uuid

MAX_FRAMES = 4319
MAX_BEATS = 48
PROFILE = "M-24-SDR-v1"


class G4Blocked(ValueError):
    pass


def must(condition: bool, explanation: str) -> None:
    if not condition:
        raise G4Blocked(explanation)


def canon(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, ensure_ascii=False,
                      separators=(",", ":"), allow_nan=False).encode("utf-8")


def digest(data: bytes) -> str:
    return sha256(data).hexdigest()


def hash_file(path: Path) -> str:
    h = sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_json(data: bytes) -> dict:
    must(len(data) <= 8 * 1024 * 1024, "JSON artifact too large")
    try:
        out = json.loads(data)
    except (ValueError, UnicodeError) as exc:
        raise G4Blocked("Invalid JSON artifact") from exc
    must(isinstance(out, dict), "JSON artifact must be object")
    return out


def row(db: sqlite3.Connection, sql: str, args: tuple) -> sqlite3.Row:
    result = db.execute(sql, args).fetchone()
    must(result is not None, "Missing canonical row: " + sql.split("FROM")[-1].split()[0])
    return result


def publication(db: sqlite3.Connection, project: str, pub_id: str,
                kind: str, expected: str | None = None,
                max_bytes: int = 4 * 1024 * 1024 * 1024) -> tuple[Path, str]:
    try:
        pub_id = str(uuid.UUID(pub_id)).upper()
    except (ValueError, TypeError) as exc:
        raise G4Blocked("Invalid publication UUID") from exc
    record = row(db, """SELECT artifact_type,state,sha256_hash,canonical_path,byte_size
                       FROM artifact_publications WHERE publication_id=? AND project_id=?""",
                 (pub_id, project))
    must(record[0] == kind and record[1] == "COMMITTED", "Artifact type/state incorrect: " + kind)
    expected_hash = str(record[2])
    must(len(expected_hash) == 64 and all(c in "0123456789abcdef" for c in expected_hash),
         "Invalid stored artifact hash")
    if expected is not None:
        must(expected_hash == expected, "Artifact hash differs from approved manifest")
    path = Path(record[3]).resolve(strict=True)
    size = path.stat().st_size
    must(0 < size <= max_bytes and size == int(record[4]), "Artifact size incorrect")
    must(hash_file(path) == expected_hash, "Artifact modified after publication")
    return path, expected_hash


@contextmanager
def _read_db(path: str):
    file = Path(path).expanduser().resolve(strict=True)
    uri = "file:" + str(file).replace("?", "%3F").replace("#", "%23") + "?mode=ro"
    db = sqlite3.connect(uri, uri=True, timeout=3)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA query_only=ON")
    try:
        yield db
    finally:
        db.close()


def _as_int(value: Any, name: str) -> int:
    must(type(value) is int, "Expected integer " + name)
    return value


def ffprobe(path: Path, *, count_frames: bool = False) -> dict:
    command = ["ffprobe", "-v", "error"]
    if count_frames:
        command.append("-count_frames")
    command += ["-show_streams", "-show_format", "-of", "json", str(path)]
    try:
        result = subprocess.run(command, check=True, capture_output=True,
                                text=True, timeout=180)
        return json.loads(result.stdout)
    except (subprocess.CalledProcessError, OSError, ValueError, subprocess.TimeoutExpired) as exc:
        raise G4Blocked("ffprobe could not verify media " + path.name) from exc


def check_video(path: Path, required_frames: int, *, preview: bool = False) -> dict:
    data = ffprobe(path, count_frames=True)
    video = [x for x in data.get("streams", []) if x.get("codec_type") == "video"]
    must(len(video) == 1, "Expected exactly one video stream")
    item = video[0]
    must(int(item.get("width", 0)) == 1080 and int(item.get("height", 0)) == 1920,
         "Video must be 1080x1920")
    must(Fraction(item.get("avg_frame_rate", "0/1")) == 24 and
         Fraction(item.get("r_frame_rate", "0/1")) == 24,
         "Video must be CFR 24fps (not VFR)")
    must(item.get("pix_fmt") in ("yuv420p", "yuv420p10le"), "Unsupported video pixel format")
    frame_count = item.get("nb_read_frames")
    must(frame_count is not None and int(frame_count) == required_frames,
         "Video decoded frame count != approved cut length")
    # Missing/unknown color tags are not silently certified as Rec.709.
    must(item.get("color_primaries") == "bt709" and
         item.get("color_transfer") == "bt709" and
         item.get("color_space") == "bt709", "Output color tags must be Rec.709")
    if preview:
        audio = [x for x in data.get("streams", []) if x.get("codec_type") == "audio"]
        must(len(audio) == 1 and int(audio[0].get("sample_rate", 0)) == 48000,
             "Preview requires 48kHz audio")
        seconds = float(data.get("format", {}).get("duration", 0))
        must(abs(seconds - required_frames / 24) <= 1 / 24 + 0.03,
             "Preview container duration differs from timeline")
    return {"frames": required_frames, "width": 1080, "height": 1920,
            "fps": 24, "color": "bt709", "video_codec": item.get("codec_name")}


def read_wav_samples(path: Path) -> int:
    import wave
    try:
        with wave.open(str(path), "rb") as wav:
            must(wav.getframerate() == 48000 and wav.getsampwidth() == 2 and
                 wav.getnchannels() in (1, 2) and wav.getcomptype() == "NONE",
                 "WAV must be PCM16 48000Hz")
            return wav.getnframes()
    except (wave.Error, EOFError, OSError) as exc:
        raise G4Blocked("Malformed speech WAV") from exc


def approved_plan(db_path: str, project_id: str, assets: list[dict]) -> dict:
    """Build a Resolve plan only from canonical G3 + S08 publications.

    assets: [{beat_id, publication_id, mapping_publication_id}] with a
    g4_captioned_cfr video per beat.  Raster captions are not native titles.
    """
    try:
        project_id = str(uuid.UUID(project_id)).upper()
    except ValueError as exc:
        raise G4Blocked("Invalid project ID") from exc
    must(isinstance(assets, list) and 0 < len(assets) <= MAX_BEATS, "Invalid G4 asset list")
    mapping = {a["beat_id"]: a for a in assets if isinstance(a, dict) and "beat_id" in a}
    must(len(mapping) == len(assets), "Duplicate or malformed asset beat IDs")
    with _read_db(db_path) as db:
        selected = row(db, "SELECT script_revision_id FROM g3_selected WHERE project_id=?",
                       (project_id,))[0]
        approval = row(db, """SELECT approval_id,script_revision_id,manifest_json,manifest_sha256,
                             candidate_sha256,workday_id FROM g3_approvals
                             WHERE project_id=? AND script_revision_id=?""", (project_id, selected))
        approved_id, rev, manifest_raw, manifest_sha, cand_sha, workday_id = tuple(approval)
        must(digest(manifest_raw.encode()) == manifest_sha, "Approved G3 manifest changed")
        manifest = json.loads(manifest_raw)
        candidate_row = row(db, """SELECT candidate_json,candidate_sha256,scope_revision_id
                                  FROM g3_scripts WHERE script_revision_id=? AND project_id=?""",
                            (rev, project_id))
        candidate_raw, saved_sha, scope = tuple(candidate_row)
        must(saved_sha == cand_sha == digest(candidate_raw.encode()), "G3 script has changed")
        candidate = json.loads(candidate_raw)
        must(candidate.get("status") == "DRAFT_NOT_BUILDABLE" and
             candidate.get("scope_revision_id") == scope == manifest.get("scope_revision_id"),
             "G3 scope or revision invalid")
        beats = candidate.get("beats", [])
        must(isinstance(beats, list) and 0 < len(beats) <= MAX_BEATS and len(beats) == len(mapping),
             "Beat count differs from S19")
        must(manifest.get("script_revision_id") == rev, "Manifest revision mismatch")
        for claim_rev in candidate.get("claim_revision_ids", []):
            claim = row(db, """SELECT claim_id,support_status,allowed_use,review_status,origin
                           FROM claims WHERE revision_id=? AND workday_id=?""",
                        (claim_rev, workday_id))
            latest = row(db, "SELECT revision_id FROM claims WHERE claim_id=? ORDER BY rowid DESC LIMIT 1",
                         (claim[0],))[0]
            must(latest == claim_rev and claim[1] == "supported" and
                 claim[2] in ("direct_claim", "attributed_or_qualified") and
                 claim[3] not in ("rejected", "superseded", "needs_review", "unreviewed") and
                 (claim[4] != "user" or claim[2] == "attributed_or_qualified"),
                 "Stale or ineligible S19 claim")
        unresolved = db.execute("""SELECT COUNT(*) FROM review_items WHERE workday_id=?
                                    AND evidence_scope_revision_id=? AND is_critical=1
                                    AND status!='resolved'""", (workday_id, scope)).fetchone()[0]
        must(unresolved == 0, "Critical G2 review remains pending")
        cut_path, cut_sha = publication(db, project_id, manifest["cut_publication_id"],
                                        "g3_cut_plan", manifest["edit_plan_sha256"], 8 * 1024 * 1024)
        cut = read_json(cut_path.read_bytes())
        shots = cut.get("edit_plan", [])
        must(len(shots) == len(beats) and cut.get("script_revision_id") == rev and
             cut.get("scope_revision_id") == scope and
             cut.get("domain_sha256") == manifest.get("domain_sha256"),
             "Cut does not belong to approved G3 script")
        must(manifest.get("total_frames") == sum(s.get("duration_frames", 0) for s in shots),
             "Timeline length differs from approved edit plan (only hard cuts supported in G4)")
        must(0 < manifest["total_frames"] <= MAX_FRAMES, "Timeline duration outside M-24-SDR-v1")
        voice_pubs = manifest["voice_publications"]
        entries = []
        # A single sealed source may be referenced by many beats. Verify
        # its hash once per RPC, not N times (important on 16GB Apple Silicon).
        source_hash_cache: dict[str, str] = {}
        for index, (beat, shot, voice) in enumerate(zip(beats, shots, voice_pubs)):
            beat_id = beat["beat_id"]
            must(beat_id in mapping and voice.get("beat_id") == beat_id, "Beat/media mapping mismatch")
            must(shot["shot_id"] in beat.get("shot_candidate_ids", []), "Shot not in approved domain")
            # Resolve must never consume a stale G3 plan if the sealed S05
            # source or G2 conform mapping has been modified on disk.
            seal = row(db, """SELECT r.snapshot_path,r.snapshot_sha256,r.is_stable,
                              m.content_sha256 FROM source_revisions r
                              JOIN source_media m ON m.media_id=r.media_id
                              WHERE r.source_revision_id=? AND m.project_id=?""",
                       (shot["source_revision_id"], project_id))
            source_key = shot["source_revision_id"]
            if source_key not in source_hash_cache:
                source_hash_cache[source_key] = hash_file(Path(seal[0]))
            must(seal[2] == 1 and seal[1] == seal[3] == shot["source_sha256"] and
                 source_hash_cache[source_key] == shot["source_sha256"],
                 "G3 source snapshot not sealed or source bytes changed")
            mapping_path, _ = publication(db, project_id, shot["mapping_publication_id"],
                                          "g2_source_mapping", shot["mapping_sha256"], 8 * 1024 * 1024)
            conform = read_json(mapping_path.read_bytes())
            cm = conform.get("conform_map", {})
            must(conform.get("source_revision_id") == shot["source_revision_id"] and
                 conform.get("source_sha256") == shot["source_sha256"] and
                 cm.get("profile_id") == PROFILE and
                 cm.get("source_revision_id") == shot["source_revision_id"] and
                 cm.get("is_valid_for_evidence") is True and
                 cm.get("dropped_critical_evidence_frame_ids") == [] and
                 cm.get("timeline_frame_count") == len(cm.get("mappings", [])) and
                 len(cm.get("mappings", [])) >= shot["range_end"],
                 "G2 source mapping is stale or malformed")
            duration = _as_int(shot.get("duration_frames"), "duration_frames")
            must(1 <= duration <= MAX_FRAMES and shot.get("transition_overlap_frames") == 0,
                 "Transition overlaps require separately verified G4 implementation")
            video_path, video_sha = publication(db, project_id, mapping[beat_id]["publication_id"],
                                                "g4_captioned_cfr", max_bytes=4 * 1024**3)
            receipt_path, _ = publication(db, project_id, mapping[beat_id]["receipt_publication_id"],
                                           "g4_conform_receipt", max_bytes=8 * 1024 * 1024)
            stage_receipt = read_json(receipt_path.read_bytes())
            must(stage_receipt.get("schema") == "g4-conform-receipt-v1" and
                 stage_receipt.get("beat_id") == beat_id and
                 stage_receipt.get("video_sha256") == video_sha and
                 stage_receipt.get("mapping_sha256") == shot["mapping_sha256"] and
                 stage_receipt.get("source_revision_id") == shot["source_revision_id"] and
                 stage_receipt.get("source_sha256") == shot["source_sha256"] and
                 stage_receipt.get("voice_text_sha256") == voice["text_sha256"] and
                 stage_receipt.get("start_frame") == shot["range_start"] and
                 stage_receipt.get("end_frame") == shot["range_end"] and
                 stage_receipt.get("render_frames") == duration and
                 stage_receipt.get("caption_policy") == "approved_phrase_cues_raster",
                 "Captioned asset lacks matching conform/source proof")
            # The receipt is source-bound, but content/semantic validation still
            # requires S21 human review, never inferred from a JSON boolean.
            video_proof = check_video(video_path, duration)
            voice_path, voice_sha = publication(db, project_id, voice["publication_id"],
                                                 "voice_wav", voice["sha256"], 128 * 1024**2)
            voice_samples = read_wav_samples(voice_path)
            must((voice_samples + 1999) // 2000 <= duration, "Speech exceeds beat duration")
            revrow = row(db, """SELECT wav_sha256,text_sha256 FROM g3_voice_reviews
                                WHERE script_revision_id=? AND beat_id=? AND publication_id=?""",
                         (rev, beat_id, voice["publication_id"]))
            must(revrow[0] == voice_sha and revrow[1] == voice["text_sha256"],
                 "WAV was not verified against this narration")
            # Caption content must come from the approved script. UI cannot override it.
            must(digest(beat["voice_text"].encode()) == voice["text_sha256"],
                 "Voice text differs from approved G3 beat")
            entries.append({"index": index, "beat_id": beat_id,
                            "video_publication_id": mapping[beat_id]["publication_id"],
                            "receipt_publication_id": mapping[beat_id]["receipt_publication_id"],
                            "mapping_publication_id": shot["mapping_publication_id"],
                            "voice_publication_id": voice["publication_id"],
                            "shot_id": shot["shot_id"], "duration_frames": duration,
                            "video_path": str(video_path), "video_sha256": video_sha,
                            "voice_path": str(voice_path), "voice_sha256": voice_sha,
                            "voice_samples": voice_samples,
                            "caption_text_sha256": voice["text_sha256"],
                            "source_revision_id": shot["source_revision_id"],
                            "source_sha256": shot["source_sha256"],
                            "mapping_sha256": shot["mapping_sha256"],
                            "range_start": shot["range_start"],
                            "range_end": shot["range_end"], "video_probe": video_proof})
        # No approval may use the worker's success flag as its sole authority.
        result = {"schema": "g4-resolve-plan-v1", "profile": PROFILE,
                  "project_id": project_id, "g3_approval_id": approved_id,
                  "script_revision_id": rev, "g3_manifest_sha256": manifest_sha,
                  "cut_sha256": cut_sha, "cut_publication_id": manifest["cut_publication_id"],
                  "total_frames": manifest["total_frames"],
                  "entries": entries, "caption_format": "raster_burned_in_not_native_editable"}
        result["plan_sha256"] = digest(canon(result))
        return result


def technical_qc(preview_path: str, expected_sha: str, expected_frames: int) -> dict:
    path = Path(preview_path).expanduser().resolve(strict=True)
    must(expected_frames in range(1, MAX_FRAMES + 1), "Expected frame count invalid")
    must(hash_file(path) == expected_sha, "Preview bytes do not match review snapshot")
    summary = check_video(path, expected_frames, preview=True)
    # Inspect the mixed rendered audio, not just the previously approved source WAV.
    # Silence may be intentional; a blank-looking waveform is for human review,
    # while full-scale clipping is a technical blocker.
    try:
        command = ["ffmpeg", "-hide_banner", "-nostdin", "-i", str(path),
                   "-vn", "-af", "volumedetect", "-f", "null", "-"]
        checked = subprocess.run(command, capture_output=True, text=True, timeout=180)
        must(checked.returncode == 0, "Cannot decode preview audio for loudness QC")
        match = re.findall(r"max_volume:\s*([+-]?(?:\d+\.?\d*|inf)) dB", checked.stderr)
        must(len(match) > 0, "Preview audio peak could not be measured")
        max_volume_db = float(match[-1])
        must(max_volume_db < -0.01, "Preview audio hits digital full scale")
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise G4Blocked("Audio volume QC could not be completed") from exc
    return {"status": "TECHNICAL_PASS_CONTENT_REVIEW_REQUIRED",
            "sha256": expected_sha, "bytes": path.stat().st_size,
            "verified": summary, "audio_max_volume_dbfs": max_volume_db,
            "semantic_verified": False, "human_audio_sync_review_required": True,
            "no_caption_semantic_or_crop_claim": True}
