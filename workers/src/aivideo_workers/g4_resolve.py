"""S20/S21 Resolve operations: durable intent, isolated project, readback.

A journal intent is persisted BEFORE each Resolve side effect. An uncertain
operation is never retried automatically. The only supported transition is
hard-cut video V1 + narration WAV A1. Raster captions are baked in video.
"""
from __future__ import annotations

from contextlib import contextmanager
from hashlib import sha256
from pathlib import Path
import fcntl
import json
import os
import sqlite3
import time
import uuid
import zipfile

from .g4_core import (G4Blocked, approved_plan, canon, digest, hash_file,
                      must, technical_qc)


def _resolve_connection():
    try:
        import DaVinciResolveScript as dvr
    except ImportError:
        from . import resolve_adapter as legacy
        return legacy.get_resolve()
    return dvr.scriptapp("Resolve")


def _safe_root() -> Path:
    root = os.environ.get("AIVIDEO_G4_WORK_ROOT", "")
    must(bool(root), "AIVIDEO_G4_WORK_ROOT must be provided by Swift")
    raw = Path(root).expanduser()
    must(raw.is_absolute() and not raw.is_symlink(),
         "G4 working root must be absolute and not a symlink")
    path = raw.resolve(strict=True)
    must(path.is_dir(), "G4 working directory not created")
    return path


@contextmanager
def _locked(root: Path):
    with (root / ".g4_resolve.lock").open("a+b") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


class Journal:
    def __init__(self, root: Path):
        self.db = sqlite3.connect(str(root / "g4_operations.sqlite3"), timeout=10)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("""CREATE TABLE IF NOT EXISTS operations (
            op_id TEXT PRIMARY KEY, kind TEXT NOT NULL, plan_sha TEXT NOT NULL,
            state TEXT NOT NULL, project_name TEXT NOT NULL,
            timeline_name TEXT NOT NULL, receipt_json TEXT,
            updated_at INTEGER NOT NULL
        )""")
        self.db.commit()

    def close(self):
        self.db.close()

    def start(self, key, kind, plan, project_name, timeline_name):
        old = self.db.execute("SELECT state,receipt_json FROM operations WHERE op_id=?", (key,)).fetchone()
        if old is not None:
            if old[0] == "VERIFIED":
                return json.loads(old[1])
            raise G4Blocked("RECONCILIATION_REQUIRED: effect may have occurred; no blind retry")
        with self.db:
            self.db.execute("INSERT INTO operations VALUES (?,?,?,?,?,?,?,?)",
                            (key, kind, plan, "INTENT", project_name, timeline_name, None, int(time.time())))
        return None

    def finish(self, key, receipt):
        with self.db:
            self.db.execute("UPDATE operations SET state='VERIFIED',receipt_json=?,updated_at=? WHERE op_id=? AND state='INTENT'",
                            (json.dumps(receipt, sort_keys=True), int(time.time()), key))

    def load(self, key):
        old = self.db.execute("SELECT state,receipt_json FROM operations WHERE op_id=?", (key,)).fetchone()
        must(old is not None, "No recorded S20 operation")
        must(old[0] == "VERIFIED", "RECONCILIATION_REQUIRED: side effect unknown")
        return json.loads(old[1])


def _assert_connected(resolve):
    must(resolve is not None and resolve is not False,
         "RESOLVE_CLOSED_OR_SCRIPTING_DISABLED")
    pm = resolve.GetProjectManager()
    must(pm is not None, "RESOLVE_PROJECT_MANAGER_MISSING")
    return pm


def _current(pm, name):
    project = pm.GetCurrentProject()
    must(project is not None and project.GetName() == name,
         "RESOLVE_PROJECT_SWITCHED: do not mutate other projects")
    return project


def _readback(project, name: str, timeline_name: str, plan: dict) -> dict:
    must(project.GetName() == name, "Project identity changed")
    tl = project.GetCurrentTimeline()
    must(tl is not None and tl.GetName() == timeline_name,
         "TIMELINE_SWITCHED")
    unique = tl.GetUniqueId()
    must(isinstance(unique, str) and unique, "Timeline unique ID unavailable")
    width = str(tl.GetSetting("timelineResolutionWidth"))
    height = str(tl.GetSetting("timelineResolutionHeight"))
    rate = str(tl.GetSetting("timelineFrameRate"))
    must(width == "1080" and height == "1920" and float(rate) == 24.0,
         "Managed timeline profile drift")
    videos = list(tl.GetItemListInTrack("video", 1) or [])
    audios = list(tl.GetItemListInTrack("audio", 1) or [])
    must(tl.GetTrackCount("video") == 1 and tl.GetTrackCount("audio") == 1,
         "Unexpected extra tracks; possible manual edit")
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
             "Managed video frame range drift")
        must(int(aud.GetStart()) == cursor and int(aud.GetDuration()) == adur,
             "Managed WAV position/duration drift")
        vp = vid.GetMediaPoolItem()
        ap = aud.GetMediaPoolItem()
        must(vp is not None and ap is not None, "Timeline media item unavailable")
        # Resolve scripting may not expose the file path consistently. No silent success.
        must(Path(str(vp.GetClipProperty("File Path"))).resolve() == Path(entry["video_path"]).resolve(),
             "Media path readback mismatch (V1)")
        must(Path(str(ap.GetClipProperty("File Path"))).resolve() == Path(entry["voice_path"]).resolve(),
             "Media path readback mismatch (A1)")
        vid_id = vid.GetUniqueId()
        aud_id = aud.GetUniqueId()
        must(vid_id and aud_id, "Timeline item unique ID unavailable")
        result.append({"video_uid": vid_id, "audio_uid": aud_id,
                       "video_start": cursor, "video_frames": required,
                       "audio_frames": adur, "video_sha256": entry["video_sha256"],
                       "voice_sha256": entry["voice_sha256"]})
        cursor += required
    return {"project_name": name, "timeline_name": timeline_name,
            "timeline_uid": unique, "start_frame": baseline,
            "total_frames": plan["total_frames"], "items": result,
            "readback_scope": "track_items_paths_duration_only_effects_not_certified",
            "signature": digest(canon(result))}


def _names(plan):
    return "AIVideo_G4_" + plan["plan_sha256"][:20], "G4_" + plan["plan_sha256"][:20]


def build(params: dict, *, resolve=None) -> dict:
    """No side effects on another user's project. Do not auto-retry uncertain operations."""
    root = _safe_root()
    with _locked(root):
        plan = approved_plan(params["db_path"], params["project_id"], params["assets"])
        name, tl_name = _names(plan)
        op_id = "build:" + plan["plan_sha256"]
        journal = Journal(root)
        try:
            r = resolve if resolve is not None else _resolve_connection()
            pm = _assert_connected(r)
            old = journal.db.execute("SELECT state FROM operations WHERE op_id=?", (op_id,)).fetchone()
            if old:
                receipt = journal.load(op_id)
                observed = _readback(_current(pm, name), name, tl_name, plan)
                must(observed["signature"] == receipt["readback"]["signature"] and
                     observed["timeline_uid"] == receipt["readback"]["timeline_uid"],
                     "Managed timeline changed; preserve manual changes")
                return {"status": "ALREADY_BUILT_VERIFIED", "receipt": receipt}
            must(pm.GetCurrentProject() is None,
                 "Close your current Resolve project before creating G4 managed project")
            existing = pm.GetProjectListInCurrentFolder() or []
            must(name not in existing, "Managed project name already exists; manual reconciliation required")
            journal.start(op_id, "build", plan["plan_sha256"], name, tl_name)
            project = pm.CreateProject(name)
            must(project is not None and project.GetName() == name,
                 "Resolve CreateProject failed or project changed")
            pool = project.GetMediaPool()
            must(pool is not None, "Resolve MediaPool unavailable")
            tl = pool.CreateEmptyTimeline(tl_name)
            must(tl is not None, "Resolve CreateEmptyTimeline failed")
            must(project.SetCurrentTimeline(tl) is True, "SetCurrentTimeline failed")
            for setting, val in (("useCustomSettings", "1"),
                                 ("timelineResolutionWidth", "1080"),
                                 ("timelineResolutionHeight", "1920"),
                                 ("timelineFrameRate", "24")):
                must(tl.SetSetting(setting, val) is True, "Cannot set " + setting)
            # Isolate media to this project. Only committed, preverified local assets.
            pos = 86400
            for entry in plan["entries"]:
                _current(pm, name)
                video = pool.ImportMedia([entry["video_path"]])
                audio = pool.ImportMedia([entry["voice_path"]])
                must(video and len(video) == 1 and audio and len(audio) == 1,
                     "MediaPool import failed")
                v_info = {"mediaPoolItem": video[0], "startFrame": 0,
                          "endFrame": entry["duration_frames"],
                          "mediaType": 1, "trackIndex": 1, "recordFrame": pos}
                a_info = {"mediaPoolItem": audio[0], "startFrame": 0,
                          "endFrame": (entry["voice_samples"] + 1999) // 2000,
                          "mediaType": 2, "trackIndex": 1, "recordFrame": pos}
                must(pool.AppendToTimeline([v_info]), "Resolve video append failed")
                must(pool.AppendToTimeline([a_info]), "Resolve WAV append failed")
                pos += entry["duration_frames"]
            must(pm.SaveProject() is True, "Resolve project save failed")
            readback = _readback(_current(pm, name), name, tl_name, plan)
            must(readback["start_frame"] == 86400, "Unexpected initial timecode")
            # DRP is a recoverable project archive, never the video preview.
            drp_dir = root / "projects"
            drp_dir.mkdir(exist_ok=True)
            drp = drp_dir / (name + ".drp")
            temp = drp_dir / (name + ".partial.drp")
            must(not drp.exists() and not temp.exists(), "DRP already exists; reconcile first")
            # (P1-23) a .drp must be a real Resolve project archive, not merely a ZIP
            from .g5_final import validate_resolve_drp_structure

            must(pm.ExportProject(name, str(temp)) is True, "Resolve DRP export failed")
            validate_resolve_drp_structure(temp)
            os.replace(temp, drp)
            receipt = {"schema": "g4-s20-receipt-v1", "plan_sha256": plan["plan_sha256"],
                       "g3_approval_id": plan["g3_approval_id"],
                       "g3_manifest_sha256": plan["g3_manifest_sha256"],
                       "script_revision_id": plan["script_revision_id"],
                       "readback": readback, "drp_path": str(drp), "drp_sha256": hash_file(drp),
                       "status": "BUILT_NEEDS_RENDER_AND_CONTENT_QC"}
            journal.finish(op_id, receipt)
            return {"status": "BUILT_VERIFIED_TRACK_ONLY", "receipt": receipt}
        finally:
            journal.close()


def render_start(params: dict, *, resolve=None) -> dict:
    root = _safe_root()
    with _locked(root):
        plan = approved_plan(params["db_path"], params["project_id"], params["assets"])
        name, tl_name = _names(plan)
        key = "render:" + plan["plan_sha256"]
        journal = Journal(root)
        try:
            r = resolve if resolve is not None else _resolve_connection()
            pm = _assert_connected(r)
            receipt = journal.load("build:" + plan["plan_sha256"])
            proj = _current(pm, name)
            observed = _readback(proj, name, tl_name, plan)
            must(observed["signature"] == receipt["readback"]["signature"] and
                 observed["timeline_uid"] == receipt["readback"]["timeline_uid"],
                 "MANAGED_TIMELINE_DRIFT")
            # Strictly no speculative repeats. Even an INTENT may have produced a render job.
            old = journal.db.execute("SELECT state,receipt_json FROM operations WHERE op_id=?", (key,)).fetchone()
            if old:
                if old[0] == "VERIFIED":
                    return {"status": "RENDER_ALREADY_SUBMITTED", "receipt": json.loads(old[1])}
                raise G4Blocked("RECONCILIATION_REQUIRED: unknown render side effect")
            must(proj.GetCurrentTimeline().GetUniqueId() == receipt["readback"]["timeline_uid"],
                 "Timeline changed")
            formats = proj.GetRenderCodecs("mp4") or {}
            codec = next((c for c in ("H.264", "H264") if c in formats), None)
            must(codec is not None and proj.SetCurrentRenderFormatAndCodec("mp4", codec) is True,
                 "Resolve MP4 H.264 render codec unsupported")
            outputs = root / "renders"
            outputs.mkdir(exist_ok=True)
            filename = "G4_" + plan["plan_sha256"][:20]
            outpath = outputs / (filename + ".mp4")
            must(not outpath.exists(), "Preview already exists; manual reconciliation required")
            must(proj.SetRenderSettings({"SelectAllFrames": True, "TargetDir": str(outputs),
                                         "CustomName": filename, "FormatWidth": 1080,
                                         "FormatHeight": 1920, "ExportVideo": True,
                                         "ExportAudio": True}) is True,
                 "Resolve rejected render settings")
            journal.start(key, "render", plan["plan_sha256"], name, tl_name)
            job_id = proj.AddRenderJob()
            must(isinstance(job_id, str) and job_id, "Resolve did not return render job ID")
            # Persist job identity before starting actual render.
            job_receipt = {"job_id": job_id, "output_path": str(outpath),
                           "plan_sha256": plan["plan_sha256"],
                           "timeline_uid": observed["timeline_uid"],
                           "timeline_signature": observed["signature"],
                           "status": "QUEUED_NEEDS_RENDER_STATUS"}
            journal.finish(key, job_receipt)
            # A failed StartRendering does NOT mean it is safe to add the job again.
            if proj.StartRendering(job_id) is not True:
                return {"status": "RENDER_START_UNCERTAIN_RECONCILE", "receipt": job_receipt}
            return {"status": "RENDER_SUBMITTED", "receipt": job_receipt}
        finally:
            journal.close()


def render_inspect(params: dict, *, resolve=None) -> dict:
    root = _safe_root()
    with _locked(root):
        plan = approved_plan(params["db_path"], params["project_id"], params["assets"])
        name, tl_name = _names(plan)
        journal = Journal(root)
        try:
            receipt = journal.load("render:" + plan["plan_sha256"])
            build_receipt = journal.load("build:" + plan["plan_sha256"])
            r = resolve if resolve is not None else _resolve_connection()
            pm = _assert_connected(r)
            project = _current(pm, name)
            observed = _readback(project, name, tl_name, plan)
            must(observed["timeline_uid"] == build_receipt["readback"]["timeline_uid"] and
                 observed["signature"] == build_receipt["readback"]["signature"],
                 "MANAGED_TIMELINE_DRIFT: preview cannot be approved")
            job = project.GetRenderJobStatus(receipt["job_id"])
            must(isinstance(job, dict), "Cannot verify Resolve render job by ID")
            status = str(job.get("JobStatus", ""))
            if status != "Complete":
                return {"status": "RENDER_PENDING_OR_FAILED", "resolve_status": status,
                        "job_id": receipt["job_id"]}
            path = Path(receipt["output_path"])
            must(path.is_file() and path.stat().st_size > 1024, "Resolve completed but preview missing")
            preview_sha = hash_file(path)
            qc = technical_qc(str(path), preview_sha, plan["total_frames"])
            return {"status": "PREVIEW_TECHNICAL_PASS_CONTENT_REVIEW_REQUIRED",
                    "preview_path": str(path), "preview_sha256": preview_sha,
                    "g3_approval_id": plan["g3_approval_id"],
                    "g3_manifest_sha256": plan["g3_manifest_sha256"],
                    "plan_sha256": plan["plan_sha256"],
                    "timeline_signature": observed["signature"],
                    "timeline_uid": observed["timeline_uid"],
                    "render_job_id": receipt["job_id"], "qc": qc,
                    "required_publication_ids": sorted({plan["cut_publication_id"]} |
                        {e[field] for e in plan["entries"] for field in (
                            "video_publication_id", "receipt_publication_id",
                            "mapping_publication_id", "voice_publication_id")}),
                    "approved": False}
        finally:
            journal.close()
