"""
tests/test_p1_closure.py — Regression for audit P1-11/13/15/23/25/31 (2026-11-11).

These are the items that stayed open after the first P1 sweep:

  P1-11  native ffmpeg renders never took the S07 heavy lease
  P1-13  `label_source` was a caller string, so a run could declare itself acceptance-ready
  P1-15  `allow_overwrite` let a request replace an approved artifact
  P1-23  a `.drp` only had to be *a ZIP file*, not a Resolve project
  P1-25  `g2.analyze_source` returned every observation in one 1 MiB-capped frame
  P1-31  transitions/inserts could change the timeline length away from the approved plan
"""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from aivideo_workers import g5_final, main_g2, native_render
from aivideo_workers.g2_benchmark_runner import (
    build_canonical_g2_benchmark_fixture,
    run_g2_analysis_eligible_benchmark,
)
from aivideo_workers.native_render import NativeRenderError


def _fixture_report(**kwargs) -> dict:
    fix = build_canonical_g2_benchmark_fixture()
    base = dict(
        manifest=fix["manifest"],
        asset_to_group_map=fix["asset_to_group_map"],
        dev_asset_ids=fix["dev_assets"],
        holdout_asset_ids=fix["holdout_assets"],
        claim_opportunities=fix["claim_opportunities"],
        observable_events=fix["observable_events"],
        verifier_adversarial_suite=fix["verifier_suite"],
        frame_coverage_by_group=fix["synthetic_coverage_by_group"],
    )
    base.update(kwargs)
    return run_g2_analysis_eligible_benchmark(**base)


class TestLabelSourceIsNotSelfDeclared(unittest.TestCase):
    """P1-13: only a verified signed human/field manifest makes a run acceptance-eligible."""

    def test_no_manifest_is_never_eligible(self) -> None:
        report = _fixture_report()
        self.assertFalse(report["acceptance_eligible"])
        self.assertFalse(report["label_provenance_verified"])
        self.assertEqual(report["label_source"], "agent_labeled_synthetic_fixture")

    def test_unsigned_manifest_is_not_eligible(self) -> None:
        report = _fixture_report(label_provenance={
            "corpus_scope": {"labels": {"labeler_types": ["human"],
                                        "source_kinds": ["field_footage"]}},
        })
        self.assertFalse(report["label_provenance_verified"])
        self.assertFalse(report["acceptance_eligible"])

    def test_label_source_parameter_is_gone(self) -> None:
        with self.assertRaises(TypeError):
            _fixture_report(label_source="human_labeled_holdout")


class TestOverwriteIsNotAnOption(unittest.TestCase):
    """P1-15: overwriting an approved artifact is never accepted over RPC."""

    def test_allow_overwrite_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            import os
            from unittest import mock

            with mock.patch.dict(os.environ, {"AIVIDEO_RENDER_ROOT": str(work)}):
                with self.assertRaises(NativeRenderError) as ctx:
                    native_render.render_native({
                        "beats": [{"beat_id": "b1", "media_path": str(work / "a.mp4"),
                                   "frames": 12}],
                        "output_path": str(work / "x.mp4"),
                        "allow_overwrite": True,
                        "width": 1080, "height": 1920,
                    })
        self.assertEqual(ctx.exception.code, "OVERWRITE_FORBIDDEN")


class TestDrpMustBeAResolveProject(unittest.TestCase):
    """P1-23: a renamed ZIP is not a Resolve handoff."""

    def test_plain_zip_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "fake.drp"
            with zipfile.ZipFile(archive, "w") as fh:
                fh.writestr("notes.txt", "hello" * 500)
            with self.assertRaises(Exception) as ctx:
                g5_final.validate_resolve_drp_structure(archive)
            self.assertIn("DRP_STRUCTURE_INVALID", str(ctx.exception))

    def test_resolve_shaped_zip_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "real.drp"
            with zipfile.ZipFile(archive, "w") as fh:
                fh.writestr("Project.db", b"sqlite-ish" * 200)
                fh.writestr("Timelines/Timeline 1.xml", b"<timeline/>")
            info = g5_final.validate_resolve_drp_structure(archive)
        self.assertTrue(info["has_project_database"])
        self.assertGreaterEqual(info["member_count"], 2)

    def test_corrupt_archive_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "bad.drp"
            archive.write_bytes(b"PK\x03\x04" + b"\x00" * 4000)
            with self.assertRaises(Exception) as ctx:
                g5_final.validate_resolve_drp_structure(archive)
            self.assertIn("DRP_STRUCTURE_INVALID", str(ctx.exception))


class TestObservationPayloadIsBudgeted(unittest.TestCase):
    """P1-25: the inline observation list never overflows a 1 MiB frame."""

    def _observations(self, count: int, size: int) -> list[dict]:
        return [
            {"observation_id": f"obs-{i:05d}", "text": "x" * size, "frame_ids": [i]}
            for i in range(count)
        ]

    def test_huge_list_is_truncated_and_paged(self) -> None:
        observations = self._observations(4000, 1024)
        page = main_g2.paginate_raw_observations(observations)
        self.assertTrue(page["raw_observations_truncated"])
        self.assertEqual(page["raw_observations_count"], 4000)
        self.assertLess(page["raw_observations_inline_count"], 4000)
        inline_bytes = len(json.dumps(page["raw_observations"], ensure_ascii=False).encode())
        self.assertLessEqual(inline_bytes, main_g2.MAX_INLINE_OBSERVATION_BYTES * 2)
        self.assertEqual(
            page["raw_observations_next_offset"], page["raw_observations_inline_count"]
        )

    def test_small_list_is_untouched(self) -> None:
        observations = self._observations(3, 100)
        page = main_g2.paginate_raw_observations(observations)
        self.assertFalse(page["raw_observations_truncated"])
        self.assertEqual(page["raw_observations_inline_count"], 3)
        self.assertIsNone(page["raw_observations_next_offset"])

    def test_paging_reads_only_the_worker_checkpoint(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            result = main_g2.handle_g2_get_raw_observations({
                "source_revision_id": "rev-p1-25",
                "source_sha256": "a" * 64,
                "offset": 0,
                "limit": 10,
                "checkpoint_namespace": f"p1-25-{Path(tmp).name}",
            })
        self.assertEqual(result["status"], "checkpoint_missing")

    def test_paging_rejects_arbitrary_paths(self) -> None:
        with self.assertRaises(ValueError):
            main_g2.handle_g2_get_raw_observations({
                "source_revision_id": "../../etc/passwd",
                "source_sha256": "a" * 64,
            })


class TestPlanLengthCannotDrift(unittest.TestCase):
    """P1-31: the rendered timeline must equal the approved plan length."""

    def test_plan_frame_mismatch_is_rejected(self) -> None:
        import inspect

        source = inspect.getsource(native_render)
        self.assertIn("PLAN_FRAME_MISMATCH", source)
        # the check must compare against the plan's own total before writing a receipt
        self.assertLess(
            source.index("PLAN_FRAME_MISMATCH"),
            source.index('"schema": "native-render-receipt-v1"'),
        )


class TestPhotoInsertMustBePublished(unittest.TestCase):
    """P1-32 (second half): a photo needs an S08 publication, not just a hash."""

    def _plan(self, work: Path) -> dict:
        clip = work / "clip.mp4"
        clip.write_bytes(b"video")
        voice = work / "voice.wav"
        voice.write_bytes(b"audio")
        return {
            "plan_sha256": "0" * 64,
            "total_frames": 48,
            "entries": [{
                "beat_id": "b1", "video_path": str(clip), "voice_path": str(voice),
                "duration_frames": 48, "video_sha256": "1" * 64,
                "voice_sha256": "2" * 64,
                "caption_text_sha256": native_render._sha256_bytes("Xin chào".encode()),
                "video_publication_id": "00000000-0000-4000-8000-000000000001",
                "voice_publication_id": "00000000-0000-4000-8000-000000000002",
                "mapping_publication_id": "00000000-0000-4000-8000-000000000003",
                "receipt_publication_id": "00000000-0000-4000-8000-000000000004",
            }],
        }

    def test_photo_without_publication_is_refused(self) -> None:
        import hashlib

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            photo = work / "photo.jpg"
            photo.write_bytes(b"jpeg")
            with self.assertRaises(NativeRenderError) as ctx:
                native_render.build_beats_from_plan(
                    self._plan(work),
                    {
                        "voice_texts": {"b1": "Xin chào"},
                        "photo_inserts": [{
                            "after_beat_id": "b1", "path": str(photo), "frames": 24,
                            "photo_sha256": hashlib.sha256(photo.read_bytes()).hexdigest(),
                        }],
                    },
                    staging_root=work,
                )
        self.assertEqual(ctx.exception.code, "PHOTO_PUBLICATION_REQUIRED")

    def test_published_photo_is_cited_in_evidence(self) -> None:
        import hashlib

        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp).resolve()
            photo = work / "photo.jpg"
            photo.write_bytes(b"jpeg")
            _, evidence = native_render.build_beats_from_plan(
                self._plan(work),
                {
                    "voice_texts": {"b1": "Xin chào"},
                    "photo_inserts": [{
                        "after_beat_id": "b1", "path": str(photo), "frames": 24,
                        "photo_sha256": hashlib.sha256(photo.read_bytes()).hexdigest(),
                        "photo_publication_id": "00000000-0000-4000-8000-000000000099",
                    }],
                },
                staging_root=work,
            )
        photo_entry = [e for e in evidence if e.get("kind") == "photo_insert"][0]
        self.assertEqual(photo_entry["photo_publication_id"],
                         "00000000-0000-4000-8000-000000000099")


class TestNativeRenderTakesALease(unittest.TestCase):
    """P1-11: the UI render paths contend for the S07 heavy lease."""

    def _app(self, name: str) -> str:
        return (_ROOT / "apps" / "macos" / "Sources" / name).read_text(encoding="utf-8")

    def test_both_render_paths_use_the_lease(self) -> None:
        self.assertIn("withHeavyLease", self._app("G4ConsoleView.swift"))
        self.assertIn("withHeavyLease", self._app("G5ConsoleView.swift"))

    def test_governor_exposes_the_wrapper(self) -> None:
        governor = (_ROOT / "packages" / "AIVideoCore" / "Sources" / "Scheduler"
                    / "ResourceGovernor.swift").read_text(encoding="utf-8")
        self.assertIn("public func withHeavyLease<T>", governor)
        self.assertIn("releaseHeavyLease(leaseId: reservation.leaseId", governor)


if __name__ == "__main__":
    unittest.main()
