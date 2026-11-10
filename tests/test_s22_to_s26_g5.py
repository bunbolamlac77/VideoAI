"""Gate G5 (S22..S26) Automated Test Suite.

Covers:
- S22: Final 2160x3840 24fps SDR Rec.709 conform, Resolve final build, render,
       technical QC, .drp export, S21 preview authority requirement, disk preflight,
       and isolated `manual_handoff` branch.
- S23: Capability registry gating (`exact_photo_shutter_match` blocked when disabled),
       cross-source partial-order event graph with clock drift & cycle detection,
       omission & counterevidence source re-audit, local preference profile management
       (never overriding epistemic/fact status), and comedy timing cue alignment
       (`caption_punchline_early_frame_count == 0`).
- S25: Commit-boundary fault injection suite and E0/E1 honest completion/abstention/
       blocked/failure denominator accounting.
- S26: Release handover manifest generation & capability disclosure.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sqlite3
import struct
import tempfile
import unittest
from unittest.mock import patch
import uuid
import wave
import zipfile

from aivideo_workers import g4_core, g5_capabilities, g5_final, g5_release_audit, main


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def uuid4() -> str:
    return str(uuid.uuid4()).upper()


class G5Fixture:
    def __init__(self, root: str):
        self.root = Path(root)
        self.project = uuid4()
        self.g3_approval = uuid4()
        self.g4_approval = uuid4()
        self.workday = uuid4()
        self.pub_cut = uuid4()
        self.pub_mapping = uuid4()
        self.pub_g4_video = uuid4()
        self.pub_g4_receipt = uuid4()
        self.pub_g4_preview = uuid4()
        self.pub_g5_video = uuid4()
        self.pub_g5_receipt = uuid4()
        self.pub_voice = uuid4()
        self.source_id = uuid4()
        self.media_id = uuid4()
        self.sealed_source = self.root / "sealed.mp4"
        self.sealed_source.write_bytes(b"sealed G5 source fixture")
        self.source_sha = sha(self.sealed_source.read_bytes())
        self.revision = "b" * 64
        self.db = self.root / "project_g5.db"
        conn = sqlite3.connect(self.db)
        conn.executescript("""
            CREATE TABLE g3_selected(project_id TEXT, script_revision_id TEXT);
            CREATE TABLE g3_approvals(
                approval_id TEXT, project_id TEXT, script_revision_id TEXT,
                manifest_json TEXT, manifest_sha256 TEXT, candidate_sha256 TEXT, workday_id TEXT
            );
            CREATE TABLE g3_scripts(
                script_revision_id TEXT, project_id TEXT, candidate_json TEXT,
                candidate_sha256 TEXT, scope_revision_id TEXT
            );
            CREATE TABLE g4_preview_approvals(
                approval_id TEXT, project_id TEXT, g3_approval_id TEXT,
                preview_publication_id TEXT, preview_sha256 TEXT, plan_sha256 TEXT,
                qc_receipt_json TEXT, qc_receipt_sha256 TEXT,
                reviewed_by TEXT, review_notes TEXT,
                approved_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            );
            CREATE TABLE artifact_publications(
                publication_id TEXT, project_id TEXT, artifact_type TEXT,
                state TEXT, sha256_hash TEXT, canonical_path TEXT, byte_size INT
            );
            CREATE TABLE claims(
                claim_id TEXT, revision_id TEXT, workday_id TEXT, support_status TEXT,
                allowed_use TEXT, review_status TEXT, origin TEXT
            );
            CREATE TABLE review_items(
                workday_id TEXT, evidence_scope_revision_id TEXT, is_critical INTEGER, status TEXT
            );
            CREATE TABLE g3_voice_reviews(
                script_revision_id TEXT, beat_id TEXT, publication_id TEXT,
                wav_sha256 TEXT, text_sha256 TEXT
            );
            CREATE TABLE source_media(media_id TEXT, project_id TEXT, content_sha256 TEXT);
            CREATE TABLE source_revisions(
                source_revision_id TEXT, media_id TEXT, snapshot_path TEXT,
                snapshot_sha256 TEXT, is_stable INT
            );
        """)
        self.cn = conn
        self.voice_text = "Theo thông tin đã được người quay xác nhận: Đến đèo Prenn lúc bình minh."
        self.cut = {
            "schema_version": "g3-cut-plan-v1",
            "script_revision_id": self.revision,
            "scope_revision_id": "scope-1",
            "domain_sha256": "d" * 64,
            "timeline_profile": "M-24-SDR-v1",
            "edit_plan": [{
                "shot_id": "shot-A",
                "source_revision_id": self.source_id,
                "source_sha256": self.source_sha,
                "mapping_sha256": "",
                "mapping_publication_id": self.pub_mapping,
                "range_start": 0,
                "range_end": 24,
                "duration_frames": 24,
                "transition_overlap_frames": 0,
            }],
        }
        self.candidate = {
            "status": "DRAFT_NOT_BUILDABLE",
            "scope_revision_id": "scope-1",
            "beats": [{
                "beat_id": "beat-01",
                "voice_text": self.voice_text,
                "shot_candidate_ids": ["shot-A"],
            }],
            "claim_revision_ids": ["rev-claim"],
        }
        self.manifest = {
            "script_revision_id": self.revision,
            "scope_revision_id": "scope-1",
            "domain_sha256": "d" * 64,
            "cut_publication_id": self.pub_cut,
            "total_frames": 24,
            "voice_publications": [{
                "beat_id": "beat-01",
                "publication_id": self.pub_voice,
                "sha256": "",
                "text_sha256": sha(self.voice_text.encode()),
            }],
        }
        self._make_wav()
        initial_map = {
            "source_revision_id": self.source_id,
            "source_sha256": self.source_sha,
            "conform_map": {
                "profile_id": "M-24-SDR-v1",
                "source_revision_id": self.source_id,
                "timeline_frame_count": 24,
                "is_valid_for_evidence": True,
                "dropped_critical_evidence_frame_ids": [],
                "mappings": [{"timeline_frame_index": i, "source_frame_id": i} for i in range(24)],
            },
        }
        self.cut["edit_plan"][0]["mapping_sha256"] = self.publish(
            self.pub_mapping, "g2_source_mapping", g4_core.canon(initial_map)
        )
        self.cn.execute("INSERT INTO source_media VALUES(?,?,?)",
                        (self.media_id, self.project, self.source_sha))
        self.cn.execute("INSERT INTO source_revisions VALUES(?,?,?,?,1)",
                        (self.source_id, self.media_id, str(self.sealed_source), self.source_sha))
        cut_hash = self.publish(self.pub_cut, "g3_cut_plan", g4_core.canon(self.cut))
        self.manifest["edit_plan_sha256"] = cut_hash

        # Publish G4 preview + dependencies
        g4_video_sha = self.publish(self.pub_g4_video, "g4_captioned_cfr", b"g4_preview_beat")
        g4_receipt = {
            "schema": "g4-conform-receipt-v1",
            "beat_id": "beat-01",
            "video_sha256": g4_video_sha,
            "mapping_sha256": self.cut["edit_plan"][0]["mapping_sha256"],
            "source_revision_id": self.source_id,
            "source_sha256": self.source_sha,
            "voice_text_sha256": sha(self.voice_text.encode()),
            "start_frame": 0,
            "end_frame": 24,
            "render_frames": 24,
            "caption_policy": "approved_phrase_cues_raster",
        }
        self.publish(self.pub_g4_receipt, "g4_conform_receipt", g4_core.canon(g4_receipt))
        self.preview_sha = self.publish(self.pub_g4_preview, "g4_preview_mp4", b"committed_g4_preview_mp4_bytes")

        manifest_raw = json.dumps(self.manifest)
        manifest_sha = sha(manifest_raw.encode())
        cand_raw = json.dumps(self.candidate)
        cand_sha = sha(cand_raw.encode())

        self.cn.execute("INSERT INTO g3_selected VALUES(?,?)", (self.project, self.revision))
        self.cn.execute("INSERT INTO g3_approvals VALUES(?,?,?,?,?,?,?)",
                        (self.g3_approval, self.project, self.revision,
                         manifest_raw, manifest_sha, cand_sha, self.workday))
        self.cn.execute("INSERT INTO g3_scripts VALUES(?,?,?,?,?)",
                        (self.revision, self.project, cand_raw, cand_sha, "scope-1"))
        self.cn.execute("INSERT INTO claims VALUES(?,?,?,?,?,?,?)",
                        ("claim-1", "rev-claim", self.workday, "supported",
                         "attributed_or_qualified", "confirmed", "user"))
        self.cn.execute("INSERT INTO g3_voice_reviews VALUES(?,?,?,?,?)",
                        (self.revision, "beat-01", self.pub_voice,
                         self.manifest["voice_publications"][0]["sha256"],
                         sha(self.voice_text.encode())))

        g4_qc_receipt = {
            "status": "PREVIEW_TECHNICAL_PASS_CONTENT_REVIEW_REQUIRED",
            "g3_approval_id": self.g3_approval,
            "g3_manifest_sha256": manifest_sha,
            "preview_sha256": self.preview_sha,
            "required_publication_ids": [
                self.pub_cut, self.pub_mapping, self.pub_voice,
                self.pub_g4_video, self.pub_g4_receipt,
            ],
        }
        g4_qc_raw = json.dumps(g4_qc_receipt)
        self.cn.execute(
            """INSERT INTO g4_preview_approvals(
                   approval_id, project_id, g3_approval_id, preview_publication_id,
                   preview_sha256, plan_sha256, qc_receipt_json, qc_receipt_sha256,
                   reviewed_by, review_notes
               ) VALUES (?,?,?,?,?,?,?,?,?,?)""",
            (self.g4_approval, self.project, self.g3_approval, self.pub_g4_preview,
             self.preview_sha, "c" * 64, g4_qc_raw, sha(g4_qc_raw.encode()),
             "Human Reviewer", "Preview checked carefully"),
        )

        # Publish G5 4K captioned clip + receipt
        g5_video_sha = self.publish(self.pub_g5_video, "g5_captioned_cfr_4k", b"g5_4k_captioned_video")
        self.g5_receipt = {
            "schema": "g5-conform-receipt-v1",
            "beat_id": "beat-01",
            "video_sha256": g5_video_sha,
            "mapping_sha256": self.cut["edit_plan"][0]["mapping_sha256"],
            "source_revision_id": self.source_id,
            "source_sha256": self.source_sha,
            "voice_text_sha256": sha(self.voice_text.encode()),
            "g4_approval_id": self.g4_approval,
            "g4_preview_sha256": self.preview_sha,
            "start_frame": 0,
            "end_frame": 24,
            "render_frames": 24,
            "width": 2160,
            "height": 3840,
            "caption_policy": "approved_phrase_cues_raster",
            "crop_policy": "fit_preserves_full_frame",
            "caption_cues": [{"text": self.voice_text, "start_frame": 0, "end_frame": 24}],
        }
        self.publish(self.pub_g5_receipt, "g5_conform_receipt", g4_core.canon(self.g5_receipt))
        self.cn.commit()
        self.assets = [{
            "beat_id": "beat-01",
            "publication_id": self.pub_g5_video,
            "receipt_publication_id": self.pub_g5_receipt,
        }]
        self.params = {
            "db_path": str(self.db),
            "project_id": self.project,
            "assets": self.assets,
        }

    def _make_wav(self) -> None:
        out = self.root / "voice.wav"
        with wave.open(str(out), "wb") as fh:
            fh.setnchannels(1)
            fh.setsampwidth(2)
            fh.setframerate(48000)
            fh.writeframes(struct.pack("<h", 500) * 24000)
        self.manifest["voice_publications"][0]["sha256"] = sha(out.read_bytes())
        self.publish(self.pub_voice, "voice_wav", out.read_bytes())

    def publish(self, pub: str, kind: str, data: bytes) -> str:
        path = self.root / f"{pub}.blob"
        path.write_bytes(data)
        h = sha(data)
        self.cn.execute("INSERT INTO artifact_publications VALUES(?,?,?,?,?,?,?)",
                        (pub, self.project, kind, "COMMITTED", h, str(path), len(data)))
        return h

    def close(self) -> None:
        self.cn.close()


class Fake4KItem:
    def __init__(self, path: str, start: int, duration: int, n: int):
        self.path, self.start, self.duration, self.n = path, start, duration, n
    def GetStart(self) -> int: return self.start
    def GetDuration(self) -> int: return self.duration
    def GetUniqueId(self) -> str: return str(self.n)
    def GetMediaPoolItem(self): return Fake4KMedia(self.path)


class Fake4KMedia:
    def __init__(self, path: str): self.path = path
    def GetClipProperty(self, name: str) -> str: return self.path if name == "File Path" else ""


class Fake4KTimeline:
    def __init__(self, name: str):
        self.name = name
        self.settings: dict[str, str] = {}
        self.video: list[Fake4KItem] = []
        self.audio: list[Fake4KItem] = []
        self.uid = uuid4()
    def GetName(self) -> str: return self.name
    def SetSetting(self, k: str, v: str) -> bool: self.settings[k] = v; return True
    def GetSetting(self, k: str): return self.settings.get(k)
    def GetUniqueId(self) -> str: return self.uid
    def GetStartFrame(self) -> int: return 86400
    def GetEndFrame(self) -> int:
        return 86400 + (self.video[-1].GetStart() + self.video[-1].GetDuration() - 86400 if self.video else 0)
    def GetTrackCount(self, kind: str) -> int: return 1
    def GetItemListInTrack(self, kind: str, idx: int): return self.video if kind == "video" else self.audio


class Fake4KPool:
    def __init__(self, project): self.project = project
    def CreateEmptyTimeline(self, name: str):
        self.project.timeline = Fake4KTimeline(name)
        return self.project.timeline
    def ImportMedia(self, paths: list[str]): return [Fake4KMedia(paths[0])]
    def AppendToTimeline(self, infos: list[dict]):
        info = infos[0]
        target = self.project.timeline.video if info["mediaType"] == 1 else self.project.timeline.audio
        target.append(Fake4KItem(
            info["mediaPoolItem"].path,
            info["recordFrame"],
            info["endFrame"] - info["startFrame"],
            len(target) + (100 if info["mediaType"] == 2 else 0),
        ))
        return [target[-1]]


class Fake4KProject:
    def __init__(self, name: str):
        self.name = name
        self.timeline = None
        self.pool = Fake4KPool(self)
        self.jobs: dict[str, str] = {}
        self.settings: dict = {}
    def GetName(self) -> str: return self.name
    def GetMediaPool(self): return self.pool
    def SetCurrentTimeline(self, tl) -> bool: self.timeline = tl; return True
    def GetCurrentTimeline(self): return self.timeline
    def GetRenderCodecs(self, ext: str) -> dict: return {"H.264": "h264"}
    def SetCurrentRenderFormatAndCodec(self, a: str, b: str) -> bool: return True
    def SetRenderSettings(self, settings: dict) -> bool: self.settings = settings; return True
    def AddRenderJob(self) -> str: self.jobs["JOB-4K-1"] = "Queued"; return "JOB-4K-1"
    def StartRendering(self, job: str) -> bool: self.jobs[job] = "Rendering"; return True
    def GetRenderJobStatus(self, job: str) -> dict: return {"JobStatus": self.jobs.get(job, "Unknown")}


class Fake4KManager:
    def __init__(self): self.project = None; self.created = 0
    def GetCurrentProject(self): return self.project
    def GetProjectListInCurrentFolder(self): return []
    def CreateProject(self, name: str):
        self.project = Fake4KProject(name)
        self.created += 1
        return self.project
    def SaveProject(self) -> bool: return True
    def ExportProject(self, name: str, dest: str) -> bool:
        with zipfile.ZipFile(dest, "w") as fh:
            fh.writestr("project.xml", os.urandom(2048))
        return True


class Fake4KResolve:
    def __init__(self): self.pm = Fake4KManager()
    def GetProjectManager(self): return self.pm


class TestS22ToS26G5(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.fixture = G5Fixture(self.temp.name)
        self.root = Path(self.temp.name)
        (self.root / "g5_work").mkdir()
        self.env = patch.dict(os.environ, {"AIVIDEO_G5_WORK_ROOT": str(self.root / "g5_work")})
        self.env.start()
        self.vprobe = patch.object(
            g5_final,
            "check_final_video",
            return_value={"frames": 24, "width": 2160, "height": 3840, "fps": 24, "color": "bt709"},
        )
        self.vprobe.start()

    def tearDown(self):
        self.vprobe.stop()
        self.env.stop()
        self.fixture.close()
        self.temp.cleanup()

    def test_s22_requires_active_s21_preview_approval(self):
        """S22.T1: Missing or invalidated S21 preview approval blocks S22 final build."""
        self.fixture.cn.execute("DELETE FROM g4_preview_approvals")
        self.fixture.cn.commit()
        resolver = Fake4KResolve()
        with self.assertRaises(g4_core.G4Blocked):
            g5_final.build_final(self.fixture.params, resolve=resolver)
        self.assertIsNone(resolver.pm.project)

    def test_s22_build_render_inspect_and_manual_handoff_branch(self):
        """S22.T2 & S22.T4: 2160x3840 24fps build, DRP export, render inspect, and manual handoff fork."""
        resolver = Fake4KResolve()
        built = g5_final.build_final(self.fixture.params, resolve=resolver)
        self.assertEqual(built["status"], "BUILT_VERIFIED_4K_TRACK_ONLY")
        self.assertEqual(built["receipt"]["readback"]["width"], 2160)
        self.assertEqual(built["receipt"]["readback"]["height"], 3840)

        # Fork isolated manual handoff DRP branch
        handoff = g5_final.fork_manual_handoff(self.fixture.params)
        self.assertEqual(handoff["status"], "MANUAL_HANDOFF_BRANCH_CREATED")
        self.assertEqual(handoff["branch"]["branch_mode"], "manual_handoff")
        self.assertTrue(handoff["branch"]["isolated_from_managed_timeline"])
        self.assertTrue(Path(handoff["branch"]["handoff_drp_path"]).is_file())

        # Start render & inspect
        started = g5_final.render_final_start(self.fixture.params, resolve=resolver)
        self.assertEqual(started["status"], "FINAL_RENDER_SUBMITTED")
        self.assertEqual(resolver.pm.project.settings["FormatWidth"], 2160)
        self.assertEqual(resolver.pm.project.settings["FormatHeight"], 3840)

        out_mp4 = Path(started["receipt"]["output_path"])
        out_mp4.write_bytes(b"0" * 4096)
        resolver.pm.project.jobs["JOB-4K-1"] = "Complete"

        with patch.object(
            g5_final,
            "final_technical_qc",
            return_value={
                "status": "FINAL_TECHNICAL_PASS_HUMAN_RELEASE_REVIEW_REQUIRED",
                "sha256": sha(out_mp4.read_bytes()),
                "semantic_verified": False,
                "verified": {"width": 2160, "height": 3840, "fps": 24, "color": "bt709"},
            },
        ):
            inspected = g5_final.render_final_inspect(self.fixture.params, resolve=resolver)
        self.assertEqual(inspected["status"], "FINAL_TECHNICAL_PASS_HUMAN_RELEASE_REVIEW_REQUIRED")
        self.assertFalse(inspected["approved"])
        self.assertIn(self.fixture.pub_g4_preview, inspected["required_publication_ids"])

    def test_s23_t1_capability_gate_blocks_unvalidated_exact_photo_match(self):
        """S23.T1: Disabled `exact_photo_shutter_match` gate blocks `use_mode='exact'` even if RPC provides benchmark flags."""
        res = g5_capabilities.evaluate_photo_moment_match({
            "photo_id": "IMG_001",
            "shot_id": "shot-A",
            "embedding_cosine": 0.94,
            "temporal_consistent": True,
            "geometric_inlier_ratio": 0.88,
            "requested_use_mode": "exact",
        })
        self.assertTrue(res["exact_candidate"])
        self.assertEqual(res["use_mode"], "illustrative_only")
        self.assertIn("blocked_by_capability_gate", res["decision_reason"])

        # Caller-supplied benchmark evidence MUST NOT unlock disabled capability
        res_rpc_attempt = g5_capabilities.evaluate_photo_moment_match({
            "photo_id": "IMG_001",
            "shot_id": "shot-A",
            "embedding_cosine": 0.94,
            "temporal_consistent": True,
            "geometric_inlier_ratio": 0.88,
            "requested_use_mode": "exact",
            "benchmark_evidence": {
                "passed_all_thresholds": True,
                "held_out_sample_size": 45,
                "zero_leakage_verified": True,
            },
        })
        self.assertEqual(res_rpc_attempt["use_mode"], "illustrative_only")
        self.assertIn("blocked_by_capability_gate", res_rpc_attempt["decision_reason"])

        # Only when the lock registry genuinely enables the capability does `exact` unlock
        with tempfile.TemporaryDirectory() as td:
            reg_copy = dict(g5_capabilities.load_capability_registry())
            reg_copy["capabilities"] = dict(reg_copy["capabilities"])
            reg_copy["capabilities"]["exact_photo_shutter_match"] = dict(
                reg_copy["capabilities"]["exact_photo_shutter_match"],
                status="enabled",
            )
            fake_reg_path = Path(td) / "s11_model_registry.lock.json"
            fake_reg_path.write_text(json.dumps(reg_copy), encoding="utf-8")
            res_enabled = g5_capabilities.evaluate_photo_moment_match({
                "photo_id": "IMG_001",
                "shot_id": "shot-A",
                "embedding_cosine": 0.94,
                "temporal_consistent": True,
                "geometric_inlier_ratio": 0.88,
                "requested_use_mode": "exact",
                "registry_path": str(fake_reg_path),
            })
            self.assertEqual(res_enabled["use_mode"], "exact")

    def test_s23_t2_preferences_never_override_epistemic_or_fact_rules(self):
        """S23.T2: Local preference profile rejects epistemic overrides and only adjusts soft weights."""
        with self.assertRaisesRegex(g4_core.G4Blocked, "PREFERENCE_SECURITY_VIOLATION"):
            g5_capabilities.manage_preference_profile({
                "action": "edit",
                "updates": {"allowed_use": "direct_claim"},
            })

        applied = g5_capabilities.manage_preference_profile({
            "action": "apply_soft_weights",
            "project_override": {"humor_density_weight": 0.5},
            "claims": [{
                "claim_id": "c1",
                "epistemic_status": "reported",
                "support_status": "supported",
                "allowed_use": "attributed_or_qualified",
                "soft_utility_score": 0.6,
                "is_humorous": True,
            }],
        })
        self.assertTrue(applied["epistemic_fields_preserved"])
        claim = applied["claims"][0]
        self.assertEqual(claim["epistemic_status"], "reported")
        self.assertEqual(claim["allowed_use"], "attributed_or_qualified")
        self.assertAlmostEqual(claim["adjusted_soft_score"], 0.65)

    def test_s23_partial_order_event_graph_and_source_reaudit(self):
        """S23.2 & S23.3: Partial-order event graph detects cycles; source re-audit flags counterevidence."""
        graph = g5_capabilities.build_partial_order_event_graph({
            "events": [
                {"event_id": "E1", "device_id": "camA", "start_ms": 1000, "end_ms": 2000},
                {"event_id": "E2", "device_id": "camB", "start_ms": 5000, "end_ms": 6000},
            ],
            "explicit_edges": [{"from": "E2", "to": "E1", "relation": "before"}],
        })
        self.assertTrue(graph["has_temporal_conflict"])
        self.assertGreater(len(graph["detected_cycles"]), 0)

        audit = g5_capabilities.audit_final_against_sources({
            "observations": [{
                "observation_id": "obs-rain",
                "salience_score": 0.9,
                "is_key_moment": True,
                "contradicts_claim_ids": ["c-sunny"],
            }],
            "beats": [{"beat_id": "beat-01", "covered_observation_ids": []}],
            "claims": [{"claim_id": "c-sunny", "text": "Trời nắng ráo suốt buổi sáng"}],
        })
        self.assertEqual(audit["status"], "BLOCKED_BY_COUNTEREVIDENCE")
        self.assertTrue(audit["release_blocked"])
        self.assertEqual(len(audit["omitted_salient_events"]), 1)

    def test_s23_t3_comedy_timing_blocks_early_punchline_frame_leak(self):
        """S23.T3: Comedy cue alignment enforces `caption_punchline_early_frame_count == 0`."""
        aligned = g5_capabilities.align_comedy_timing_cues({
            "beat_id": "beat-01",
            "duration_frames": 72,
            "wav_samples": 96000,
            "setup_text": "Tưởng đường đèo vắng vẻ,",
            "punchline_text": "ai ngờ gặp nguyên đàn bò đứng ngắm cảnh.",
            "setup_end_sample": 40000,
            "pause_samples": 6000,
        })
        self.assertEqual(aligned["caption_punchline_early_frame_count"], 0)
        self.assertGreater(aligned["punchline_start_frame"], aligned["setup_end_frame"])

        with self.assertRaisesRegex(g4_core.G4Blocked, "COMEDY_PUNCHLINE_LEAK"):
            g5_capabilities.align_comedy_timing_cues({
                "beat_id": "beat-01",
                "duration_frames": 72,
                "wav_samples": 96000,
                "setup_text": "Setup",
                "punchline_text": "Punchline",
                "setup_end_sample": 40000,
                "pause_samples": 6000,
                "candidate_cues": [{"role": "punchline", "start_frame": 15, "end_frame": 40}],
            })

    def test_s25_fault_suite_e0_e1_accounting_and_s26_release_manifest(self):
        """S25.T1..T3 & S26: Fault injection across commit boundaries, E0/E1 accounting, and release manifest."""
        fault_res = g5_release_audit.run_commit_boundary_fault_suite()
        self.assertEqual(fault_res["status"], "PASS")
        self.assertEqual(len(fault_res["boundaries_tested"]), 4)

        eval_res = g5_release_audit.evaluate_e0_e1_accounting({
            "corpus_kind": "E0_5_HELD_OUT_TRIPS",
            "is_synthetic_fixture": True,
            "runs": [
                {"trip_id": "T1", "outcome": "completed", "duration_sec": 310, "peak_rss_mb": 4200,
                 "verified_supported_claims": 18, "total_emitted_claims": 18},
                {"trip_id": "T2", "outcome": "completed", "duration_sec": 295, "peak_rss_mb": 4100,
                 "verified_supported_claims": 15, "total_emitted_claims": 15},
                {"trip_id": "T3", "outcome": "abstained", "duration_sec": 120, "peak_rss_mb": 3100,
                 "verified_supported_claims": 0, "total_emitted_claims": 0},
                {"trip_id": "T4", "outcome": "completed", "duration_sec": 340, "peak_rss_mb": 4500,
                 "verified_supported_claims": 20, "total_emitted_claims": 20},
                {"trip_id": "T5", "outcome": "blocked", "duration_sec": 45, "peak_rss_mb": 2200,
                 "verified_supported_claims": 0, "total_emitted_claims": 0},
            ],
        })
        self.assertEqual(eval_res["total_runs"], 5)
        self.assertFalse(eval_res["live_field_corpus_certified"])  # honest flag for synthetic fixture
        self.assertAlmostEqual(eval_res["rates"]["completion_rate"], 0.6)
        self.assertAlmostEqual(eval_res["rates"]["abstention_rate"], 0.2)
        self.assertAlmostEqual(eval_res["rates"]["blocked_rate"], 0.2)
        self.assertEqual(eval_res["fact_precision"], 1.0)
        self.assertTrue(eval_res["memory_within_16gb_budget"])

        manifest = g5_release_audit.generate_release_handover_manifest()
        self.assertEqual(manifest["schema"], "aivideo-v3.1-s26-release-manifest-v1")
        self.assertTrue(manifest["offline_policy"]["enforce_offline_after_setup"])
        self.assertIn("exact_photo_shutter_match", manifest["capabilities_disclosure"])

        init = main.handle_initialize({})
        self.assertIn("g5.timeline.build_4k", init["capabilities"])
        self.assertIn("g5.release.manifest", init["capabilities"])


if __name__ == "__main__":
    unittest.main()
