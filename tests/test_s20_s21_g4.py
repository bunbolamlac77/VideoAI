"""G4 adversarial tests: canonical receipts, no duplicate effects, drift, QC."""
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid
import wave
import zipfile

from aivideo_workers import g4_core, g4_resolve, g4_stage


def sha(data):
    return hashlib.sha256(data).hexdigest()


def uuid4():
    return str(uuid.uuid4()).upper()


class Fixture:
    def __init__(self, root):
        self.root = Path(root)
        self.project = uuid4()
        self.approval = uuid4()
        self.workday = uuid4()
        self.pub_cut = uuid4()
        self.pub_mapping = uuid4()
        self.source_id = uuid4()
        self.media_id = uuid4()
        self.sealed_source = self.root / "sealed.mp4"
        self.sealed_source.write_bytes(b"sealed G4 source fixture")
        self.source_sha = sha(self.sealed_source.read_bytes())
        self.pub_video = uuid4()
        self.pub_receipt = uuid4()
        self.pub_voice = uuid4()
        self.revision = "a" * 64
        self.db = self.root / "project.db"
        conn = sqlite3.connect(self.db)
        conn.executescript("""
        CREATE TABLE g3_selected(project_id TEXT,script_revision_id TEXT);
        CREATE TABLE g3_approvals(approval_id TEXT,project_id TEXT,script_revision_id TEXT,
            manifest_json TEXT,manifest_sha256 TEXT,candidate_sha256 TEXT,workday_id TEXT);
        CREATE TABLE g3_scripts(script_revision_id TEXT,project_id TEXT,candidate_json TEXT,
            candidate_sha256 TEXT,scope_revision_id TEXT);
        CREATE TABLE artifact_publications(publication_id TEXT,project_id TEXT,artifact_type TEXT,
            state TEXT,sha256_hash TEXT,canonical_path TEXT,byte_size INT);
        CREATE TABLE claims(claim_id TEXT,revision_id TEXT,workday_id TEXT,support_status TEXT,
            allowed_use TEXT,review_status TEXT,origin TEXT);
        CREATE TABLE review_items(workday_id TEXT,evidence_scope_revision_id TEXT,is_critical INTEGER,
            status TEXT);
        CREATE TABLE g3_voice_reviews(script_revision_id TEXT,beat_id TEXT,
            publication_id TEXT,wav_sha256 TEXT,text_sha256 TEXT);
        CREATE TABLE source_media(media_id TEXT, project_id TEXT, content_sha256 TEXT);
        CREATE TABLE source_revisions(source_revision_id TEXT, media_id TEXT,
            snapshot_path TEXT, snapshot_sha256 TEXT, is_stable INT);
        """)
        self.cn = conn
        self.voice_text = "A narrated fact."
        self.cut = {"schema_version": "g3-cut-plan-v1", "script_revision_id": self.revision,
                    "scope_revision_id": "scope-1", "domain_sha256": "d" * 64,
                    "timeline_profile": "M-24-SDR-v1", "edit_plan": [{
                        "shot_id": "shot-A", "source_revision_id": self.source_id,
                        "source_sha256": self.source_sha,
                        "mapping_sha256": "", "mapping_publication_id": self.pub_mapping,
                        "range_start": 0, "range_end": 24, "duration_frames": 24,
                        "transition_overlap_frames": 0,
                    }]}
        self.candidate = {"status": "DRAFT_NOT_BUILDABLE", "scope_revision_id": "scope-1",
                          "beats": [{"beat_id": "beat-01", "voice_text": self.voice_text,
                                     "shot_candidate_ids": ["shot-A"]}],
                          "claim_revision_ids": ["rev-claim"]}
        self.manifest = {"script_revision_id": self.revision,
                         "scope_revision_id": "scope-1", "domain_sha256": "d" * 64,
                         "cut_publication_id": self.pub_cut, "total_frames": 24,
                         "voice_publications": [{"beat_id": "beat-01",
                                                 "publication_id": self.pub_voice,
                                                 "sha256": "", "text_sha256": sha(self.voice_text.encode())}]}
        self._make_wav()
        initial_map = {"source_revision_id": self.source_id,
                       "source_sha256": self.source_sha,
                       "conform_map": {"profile_id": "M-24-SDR-v1",
                                       "source_revision_id": self.source_id,
                                       "timeline_frame_count": 24,
                                       "is_valid_for_evidence": True,
                                       "dropped_critical_evidence_frame_ids": [],
                                       "mappings": [{"timeline_frame_index": i,
                                                     "source_frame_id": i} for i in range(24)]}}
        self.cut["edit_plan"][0]["mapping_sha256"] = self.publish(
            self.pub_mapping, "g2_source_mapping", g4_core.canon(initial_map))
        self.cn.execute("INSERT INTO source_media VALUES(?,?,?)",
                        (self.media_id, self.project, self.source_sha))
        self.cn.execute("INSERT INTO source_revisions VALUES(?,?,?,?,1)",
                        (self.source_id, self.media_id,
                         str(self.sealed_source), self.source_sha))
        cut_hash = self.publish(self.pub_cut, "g3_cut_plan", g4_core.canon(self.cut))
        self.manifest["edit_plan_sha256"] = cut_hash
        self.publish(self.pub_video, "g4_captioned_cfr", b"fakevideo")
        video_sha = sha(b"fakevideo")
        self.receipt = {"schema": "g4-conform-receipt-v1", "beat_id": "beat-01",
                        "video_sha256": video_sha,
                        "mapping_sha256": self.cut["edit_plan"][0]["mapping_sha256"],
                        "source_revision_id": self.cut["edit_plan"][0]["source_revision_id"],
                        "source_sha256": self.cut["edit_plan"][0]["source_sha256"],
                        "voice_text_sha256": sha(self.voice_text.encode()),
                        "start_frame": 0, "end_frame": 24, "render_frames": 24,
                        "caption_policy": "approved_phrase_cues_raster"}
        self.publish(self.pub_receipt, "g4_conform_receipt", g4_core.canon(self.receipt))
        self.cn.execute("INSERT INTO g3_selected VALUES(?,?)", (self.project, self.revision))
        self.cn.execute("INSERT INTO g3_approvals VALUES(?,?,?,?,?,?,?)",
                        (self.approval, self.project, self.revision,
                         json.dumps(self.manifest), sha(json.dumps(self.manifest).encode()),
                         sha(json.dumps(self.candidate).encode()), self.workday))
        self.cn.execute("INSERT INTO g3_scripts VALUES(?,?,?,?,?)",
                        (self.revision, self.project, json.dumps(self.candidate),
                         sha(json.dumps(self.candidate).encode()), "scope-1"))
        self.cn.execute("INSERT INTO claims VALUES(?,?,?,?,?,?,?)",
                        ("claim-1", "rev-claim", self.workday, "supported",
                         "direct_claim", "confirmed", "visual"))
        self.cn.execute("INSERT INTO g3_voice_reviews VALUES(?,?,?,?,?)",
                        (self.revision, "beat-01", self.pub_voice,
                         self.manifest["voice_publications"][0]["sha256"],
                         sha(self.voice_text.encode())))
        self.cn.commit()
        self.assets = [{"beat_id": "beat-01", "publication_id": self.pub_video,
                        "receipt_publication_id": self.pub_receipt}]
        self.params = {"db_path": str(self.db), "project_id": self.project,
                       "assets": self.assets}

    def _make_wav(self):
        out = self.root / "voice.wav"
        with wave.open(str(out), "wb") as fh:
            fh.setnchannels(1)
            fh.setsampwidth(2)
            fh.setframerate(48000)
            fh.writeframes(struct.pack("<h", 500) * 24000)
        self.manifest["voice_publications"][0]["sha256"] = sha(out.read_bytes())
        self.publish(self.pub_voice, "voice_wav", out.read_bytes())

    def publish(self, pub, kind, data):
        path = self.root / (pub + ".blob")
        path.write_bytes(data)
        h = sha(data)
        self.cn.execute("INSERT INTO artifact_publications VALUES(?,?,?,?,?,?,?)",
                        (pub, self.project, kind, "COMMITTED", h, str(path), len(data)))
        return h

    def close(self):
        self.cn.close()


class FakeItem:
    def __init__(self, path, start, duration, n):
        self.path, self.start, self.duration, self.n = path, start, duration, n
    def GetStart(self): return self.start
    def GetDuration(self): return self.duration
    def GetUniqueId(self): return str(self.n)
    def GetMediaPoolItem(self): return FakeMedia(self.path)


class FakeMedia:
    def __init__(self, path): self.path = path
    def GetClipProperty(self, name): return self.path if name == "File Path" else ""


class FakeTimeline:
    def __init__(self, name):
        self.name = name
        self.settings = {}
        self.video, self.audio = [], []
        self.uid = uuid4()
    def GetName(self): return self.name
    def SetSetting(self, k, v): self.settings[k] = v; return True
    def GetSetting(self, k): return self.settings.get(k)
    def GetUniqueId(self): return self.uid
    def GetStartFrame(self): return 86400
    def GetEndFrame(self):
        return 86400 + (self.video[-1].GetStart() + self.video[-1].GetDuration() - 86400 if self.video else 0)
    def GetTrackCount(self, kind): return 1
    def GetItemListInTrack(self, kind, idx): return self.video if kind == "video" else self.audio


class FakePool:
    def __init__(self, project): self.project = project; self.fail_after_video = False
    def CreateEmptyTimeline(self, name):
        self.project.timeline = FakeTimeline(name)
        return self.project.timeline
    def ImportMedia(self, paths): return [FakeMedia(paths[0])]
    def AppendToTimeline(self, infos):
        info = infos[0]
        target = self.project.timeline.video if info["mediaType"] == 1 else self.project.timeline.audio
        if info["mediaType"] == 2 and self.fail_after_video:
            raise RuntimeError("injected Resolve crash after video append")
        target.append(FakeItem(info["mediaPoolItem"].path,
                               info["recordFrame"], info["endFrame"] - info["startFrame"],
                               len(target) + (100 if info["mediaType"] == 2 else 0)))
        return [target[-1]]


class FakeProject:
    def __init__(self, name):
        self.name, self.timeline = name, None
        self.pool = FakePool(self)
        self.jobs = {}
    def GetName(self): return self.name
    def GetMediaPool(self): return self.pool
    def SetCurrentTimeline(self, tl): self.timeline = tl; return True
    def GetCurrentTimeline(self): return self.timeline
    def GetRenderCodecs(self, ext): return {"H.264": "h264"}
    def SetCurrentRenderFormatAndCodec(self, a, b): return True
    def SetRenderSettings(self, settings): self.settings = settings; return True
    def AddRenderJob(self): self.jobs["JOB-1"] = "Queued"; return "JOB-1"
    def StartRendering(self, job): self.jobs[job] = "Rendering"; return True
    def GetRenderJobStatus(self, job): return {"JobStatus": self.jobs.get(job, "Unknown")}


class FakeManager:
    def __init__(self): self.project = None; self.created = 0
    def GetCurrentProject(self): return self.project
    def GetProjectListInCurrentFolder(self): return []
    def CreateProject(self, name):
        self.project = FakeProject(name)
        self.created += 1
        return self.project
    def SaveProject(self): return True
    def ExportProject(self, name, dest):
        # (P1-23) real .drp structure: project database + timeline payload
        with zipfile.ZipFile(dest, "w") as fh:
            fh.writestr("Project.db", os.urandom(2048))
            fh.writestr("Timelines/Timeline 1.xml", os.urandom(2048))
            fh.writestr("project.xml", os.urandom(2048))
        return True


class FakeResolve:
    def __init__(self): self.pm = FakeManager()
    def GetProjectManager(self): return self.pm


class S20S21Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.fixture = Fixture(self.temp.name)
        self.root = Path(self.temp.name)
        self.root.joinpath("work").mkdir()
        self.env = patch.dict(os.environ, {"AIVIDEO_G4_WORK_ROOT": str(self.root / "work")})
        self.env.start()
        self.vprobe = patch.object(g4_core, "check_video", return_value={"frames": 24, "color": "bt709"})
        self.vprobe.start()
        # g4_resolve uses approved_plan from g4_core, and mocked check_video there.

    def tearDown(self):
        self.vprobe.stop()
        self.env.stop()
        self.fixture.close()
        self.temp.cleanup()

    def test_sealed_source_mutation_blocks_resolve_before_side_effect(self):
        self.fixture.sealed_source.write_bytes(b"source changed after G3 approval")
        with self.assertRaises(g4_core.G4Blocked):
            g4_core.approved_plan(str(self.fixture.db), self.fixture.project, self.fixture.assets)
        resolver = FakeResolve()
        with self.assertRaises(g4_core.G4Blocked):
            g4_resolve.build(self.fixture.params, resolve=resolver)
        self.assertIsNone(resolver.pm.project)

    def test_preflight_reads_committed_s19_not_rpc_success_flag(self):
        plan = g4_core.approved_plan(**{"db_path": self.fixture.params["db_path"],
                                        "project_id": self.fixture.project,
                                        "assets": self.fixture.assets})
        self.assertEqual(plan["g3_approval_id"], self.fixture.approval)
        self.assertEqual(plan["total_frames"], 24)
        self.assertEqual(plan["caption_format"], "raster_burned_in_not_native_editable")

    def test_cut_or_receipt_tamper_is_rejected(self):
        path = self.root / (self.fixture.pub_receipt + ".blob")
        path.write_bytes(b"changed")
        with self.assertRaisesRegex(g4_core.G4Blocked, "modified|size"):
            g4_core.approved_plan(**self.fixture.params)

    def test_story_revision_mutation_stops_side_effects(self):
        self.fixture.cn.execute("UPDATE g3_scripts SET candidate_sha256='f' WHERE script_revision_id=?",
                                (self.fixture.revision,))
        self.fixture.cn.commit()
        resolver = FakeResolve()
        with self.assertRaises(g4_core.G4Blocked):
            g4_resolve.build(self.fixture.params, resolve=resolver)
        self.assertEqual(resolver.pm.created, 0)

    def test_first_build_and_reopen_do_not_duplicate(self):
        resolver = FakeResolve()
        first = g4_resolve.build(self.fixture.params, resolve=resolver)
        second = g4_resolve.build(self.fixture.params, resolve=resolver)
        self.assertEqual(first["status"], "BUILT_VERIFIED_TRACK_ONLY")
        self.assertEqual(second["status"], "ALREADY_BUILT_VERIFIED")
        self.assertEqual(resolver.pm.created, 1)
        self.assertEqual(len(resolver.pm.project.timeline.video), 1)

    def test_crash_after_video_append_never_retries(self):
        resolver = FakeResolve()
        # Failure is installed on project creation using a manager override.
        original = resolver.pm.CreateProject
        def create_and_fail(name):
            item = original(name)
            item.pool.fail_after_video = True
            return item
        resolver.pm.CreateProject = create_and_fail
        with self.assertRaisesRegex(RuntimeError, "injected"):
            g4_resolve.build(self.fixture.params, resolve=resolver)
        self.assertEqual(len(resolver.pm.project.timeline.video), 1)
        with self.assertRaisesRegex(g4_core.G4Blocked, "RECONCILIATION_REQUIRED"):
            g4_resolve.build(self.fixture.params, resolve=resolver)
        self.assertEqual(len(resolver.pm.project.timeline.video), 1)

    def test_manual_timeline_drift_blocks_render_and_reuse(self):
        resolver = FakeResolve()
        g4_resolve.build(self.fixture.params, resolve=resolver)
        resolver.pm.project.timeline.video[0].duration = 23
        with self.assertRaises(g4_core.G4Blocked):
            g4_resolve.render_start(self.fixture.params, resolve=resolver)
        with self.assertRaises(g4_core.G4Blocked):
            g4_resolve.build(self.fixture.params, resolve=resolver)

    def test_render_queue_is_not_duplicated(self):
        resolver = FakeResolve()
        g4_resolve.build(self.fixture.params, resolve=resolver)
        first = g4_resolve.render_start(self.fixture.params, resolve=resolver)
        again = g4_resolve.render_start(self.fixture.params, resolve=resolver)
        self.assertEqual(first["status"], "RENDER_SUBMITTED")
        self.assertEqual(again["status"], "RENDER_ALREADY_SUBMITTED")
        self.assertEqual(len(resolver.pm.project.jobs), 1)

    def test_raster_staging_uses_sealed_s10_map_and_actual_ffmpeg(self):
        with self.root.joinpath("source.mp4").open("wb") as f:
            f.write(b"sealed fixture")
        source = self.root / "source.mp4"
        source_sha = sha(source.read_bytes())
        source_id = self.fixture.cut["edit_plan"][0]["source_revision_id"]
        self.fixture.cut["edit_plan"][0]["source_sha256"] = source_sha
        proxy = self.root / "proxy.mp4"
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "color=c=blue:s=320x240:r=24:d=1",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an",
                        "-x264-params", "colorprim=bt709:transfer=bt709:colormatrix=bt709",
                        "-color_primaries", "bt709", "-color_trc", "bt709",
                        "-colorspace", "bt709", str(proxy)], check=True, timeout=90)
        proxy_sha = sha(proxy.read_bytes())
        mp = {"source_revision_id": source_id, "source_sha256": source_sha,
              "proxy_path": str(proxy), "proxy_sha256": proxy_sha,
              "proxy_fps": "24/1", "conform_map": {
                  "profile_id": "M-24-SDR-v1", "dropped_critical_evidence_frame_ids": [],
                  "mappings": [{"timeline_frame_index": x, "source_frame_id": x} for x in range(24)]}}
        pub_map = uuid4()
        map_sha = self.fixture.publish(pub_map, "g2_source_mapping", g4_core.canon(mp))
        self.fixture.cut["edit_plan"][0]["mapping_sha256"] = map_sha
        self.fixture.cut["edit_plan"][0]["mapping_publication_id"] = pub_map
        cut_bytes = g4_core.canon(self.fixture.cut)
        cut_path = self.root / (self.fixture.pub_cut + ".blob")
        cut_path.write_bytes(cut_bytes)
        self.fixture.cn.execute("UPDATE artifact_publications SET sha256_hash=?,byte_size=? WHERE publication_id=?",
                                (sha(cut_bytes), len(cut_bytes), self.fixture.pub_cut))
        self.fixture.manifest["edit_plan_sha256"] = sha(cut_bytes)
        man_raw = json.dumps(self.fixture.manifest)
        self.fixture.cn.execute("UPDATE g3_approvals SET manifest_json=?,manifest_sha256=? WHERE approval_id=?",
                                (man_raw, sha(man_raw.encode()), self.fixture.approval))
        self.fixture.cn.execute("UPDATE source_revisions SET snapshot_path=?,snapshot_sha256=? WHERE source_revision_id=?",
                                (str(source), source_sha, source_id))
        self.fixture.cn.execute("UPDATE source_media SET content_sha256=? WHERE media_id=?",
                                (source_sha, self.fixture.media_id))
        self.fixture.cn.commit()
        font_candidates = [
            Path("/System/Library/Fonts/Supplemental/Arial.ttf"),
            Path("/System/Library/Fonts/Supplemental/Tahoma.ttf"),
            Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
        ]
        font = next((p for p in font_candidates if p.exists()), None)
        if font is None:
            self.skipTest("Test caption font unavailable")
        from aivideo_workers.child_process import ffmpeg_has_filter
        if not ffmpeg_has_filter("drawtext"):
            self.skipTest("ffmpeg build lacks drawtext (freetype)")
        result = g4_stage.stage_captioned_clip({
            "db_path": str(self.fixture.db), "project_id": self.fixture.project,
            "beat_id": "beat-01", "mapping_publication_id": pub_map,
            "font_path": str(font), "cues": [
                {"text": self.fixture.voice_text, "start_frame": 0, "end_frame": 24}
            ],
        })
        self.assertEqual(result["status"], "STAGED_REQUIRES_S08_COMMIT")
        self.assertEqual(g4_core.hash_file(Path(result["video_path"])), result["video_sha256"])
        self.assertEqual(g4_core.check_video(Path(result["video_path"]), 24)["frames"], 24)

    def make_real_preview(self, path):
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "color=c=blue:s=1080x1920:r=24:d=1",
                        "-f", "lavfi", "-i", "sine=frequency=750:sample_rate=48000:duration=1",
                        "-c:v", "libx264", "-preset", "veryfast", "-crf", "22",
                        "-pix_fmt", "yuv420p", "-x264-params",
                        "colorprim=bt709:transfer=bt709:colormatrix=bt709",
                        "-color_primaries", "bt709", "-color_trc", "bt709",
                        "-colorspace", "bt709", "-c:a", "aac", "-ar", "48000",
                        "-shortest", str(path)], check=True, timeout=120)

    def test_technical_qc_measures_real_mp4_and_audio(self):
        preview = self.root / "real_preview.mp4"
        self.make_real_preview(preview)
        self.vprobe.stop()
        try:
            observed = g4_core.technical_qc(str(preview), sha(preview.read_bytes()), 24)
            self.assertEqual(observed["status"], "TECHNICAL_PASS_CONTENT_REVIEW_REQUIRED")
            self.assertLess(observed["audio_max_volume_dbfs"], 0)
            self.assertFalse(observed["semantic_verified"])
        finally:
            self.vprobe.start()
        with self.assertRaises(g4_core.G4Blocked):
            g4_core.technical_qc(str(preview), "0" * 64, 24)

    def test_project_switch_blocks_render(self):
        resolver = FakeResolve()
        g4_resolve.build(self.fixture.params, resolve=resolver)
        resolver.pm.project = FakeProject("SomeonesEditedProject")
        with self.assertRaisesRegex(g4_core.G4Blocked, "PROJECT_SWITCHED"):
            g4_resolve.render_start(self.fixture.params, resolve=resolver)

    def test_closed_resolve_is_blocked(self):
        with self.assertRaises(g4_core.G4Blocked):
            g4_resolve.build(self.fixture.params, resolve=False)


if __name__ == "__main__":
    unittest.main()
