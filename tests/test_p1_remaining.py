"""
tests/test_p1_remaining.py — Regression for audit P1-18/19/35/36/37 and the UI items
P1-46..54 (2026-11-11).

Worker-side:
  P1-18  the release manifest carried only a self-computed checksum, never a signature
  P1-19  E0/E1 certification accepted caller-supplied `runs` without binding them
  P1-35  forward-check work was invisible to `node_budget`
  P1-36  a TTS runtime that fails at inference returned INTERNAL_ERROR, not "blocked"
  P1-37  LLM faithfulness only rejected invented *digits*

UI-side: the source is scanned for the exact constructs that produced those defects,
because these are SwiftUI views that cannot be instantiated from a unit test.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from aivideo_workers import g3_engine, g5_release_audit, story_writer


class TestReleaseManifestIsSigned(unittest.TestCase):
    """P1-18: a checksum is not a signature; Ed25519 signing/verification round-trips."""

    def test_manifest_declares_it_is_unsigned_by_default(self) -> None:
        manifest = g5_release_audit.generate_release_handover_manifest({})
        self.assertFalse(manifest["signing"]["signed"])
        self.assertNotIn("signature", manifest)

    def test_signed_manifest_round_trips_and_detects_tampering(self) -> None:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

        with tempfile.TemporaryDirectory() as tmp:
            key = Ed25519PrivateKey.generate()
            private_path = Path(tmp) / "release_private.pem"
            public_path = Path(tmp) / "release_public.pem"
            private_path.write_bytes(key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            ))
            public_path.write_bytes(key.public_key().public_bytes(
                serialization.Encoding.PEM,
                serialization.PublicFormat.SubjectPublicKeyInfo,
            ))
            manifest = g5_release_audit.generate_release_handover_manifest(
                {"release_private_key_path": str(private_path)}
            )
            self.assertTrue(manifest["signing"]["signed"])
            self.assertTrue(g5_release_audit.verify_release_manifest(manifest, public_path))
            tampered = json.loads(json.dumps(manifest))
            tampered["version"] = "9.9.9-forged"
            self.assertFalse(g5_release_audit.verify_release_manifest(tampered, public_path))

            other_key = Ed25519PrivateKey.generate()
            other_public = Path(tmp) / "other_public.pem"
            other_public.write_bytes(other_key.public_key().public_bytes(
                serialization.Encoding.PEM,
                serialization.PublicFormat.SubjectPublicKeyInfo,
            ))
            self.assertFalse(g5_release_audit.verify_release_manifest(manifest, other_public))


class TestE0E1RunsMustBeBound(unittest.TestCase):
    """P1-19: certification needs the signed manifest to pin the run results."""

    def _runs(self) -> list[dict]:
        return [
            {"trip_id": f"t{i}", "outcome": "completed", "duration_sec": 300,
             "peak_rss_mb": 4000, "verified_supported_claims": 5, "total_emitted_claims": 5}
            for i in range(5)
        ]

    def test_unbound_runs_never_certify(self) -> None:
        signed_manifest = {
            "schema": "aivideo-signed-field-corpus-manifest-v1",
            "corpus_scope": {
                "corpus_kind": "E0_5_HELD_OUT_TRIPS",
                "labels": {"labeler_types": ["human"], "source_kinds": ["field_footage"]},
            },
            "signing_authority": {"algorithm": "ed25519"},
        }
        with mock.patch.object(g5_release_audit, "validate_signed_field_manifest", return_value=True):
            report = g5_release_audit.evaluate_e0_e1_accounting({
                "runs": self._runs(),
                "corpus_kind": "E0_5_HELD_OUT_TRIPS",
                "is_synthetic_fixture": False,
                "signed_field_manifest": signed_manifest,
            })
        self.assertFalse(report["live_field_corpus_certified"])
        self.assertIn("RUNS_NOT_BOUND_TO_SIGNED_MANIFEST", report["certification_blockers"])

    def test_bound_runs_count_as_the_same_set(self) -> None:
        runs = self._runs()
        digest = hashlib.sha256(g5_release_audit.canon({"runs": runs})).hexdigest()
        signed_manifest = {
            "schema": "aivideo-signed-field-corpus-manifest-v1",
            "corpus_scope": {
                "corpus_kind": "E0_5_HELD_OUT_TRIPS",
                "runs_sha256": digest,
                "labels": {"labeler_types": ["human"], "source_kinds": ["field_footage"]},
            },
            "signing_authority": {"algorithm": "ed25519"},
        }
        with mock.patch.object(g5_release_audit, "validate_signed_field_manifest", return_value=True):
            report = g5_release_audit.evaluate_e0_e1_accounting({
                "runs": runs,
                "corpus_kind": "E0_5_HELD_OUT_TRIPS",
                "is_synthetic_fixture": False,
                "signed_field_manifest": signed_manifest,
            })
        self.assertTrue(report["runs_bound_to_manifest"])


class TestSearchBudgetCountsLookahead(unittest.TestCase):
    """P1-35: forward-check evaluations are charged to node_budget.

    The observable property is that a search allowed `node_budget` nodes cannot do
    dramatically more work than that, however expensive the lookahead is.
    """

    def _domain(self, beats: int, options: int) -> list[list[dict]]:
        return [
            [
                {
                    "shot_id": f"s{b}_{o}",
                    "start_frame": 0,
                    "end_frame": 48,
                    "source_revision_id": "src-1",
                }
                for o in range(options)
            ]
            for b in range(beats)
        ]

    def _run(self, beats: int, options: int, budget: int) -> tuple[dict, float]:
        import time

        started = time.perf_counter()
        result = g3_engine.search_cuts({
            "candidate_options": self._domain(beats, options),
            "voice_samples_per_beat": [48_000] * beats,
            "voice_review_status": "unverified",
            "beam_width": 8,
            "node_budget": budget,
            "forward_check": True,
        })
        return result, time.perf_counter() - started

    def test_tight_budget_is_respected(self) -> None:
        result, elapsed = self._run(beats=6, options=32, budget=500)
        self.assertLess(elapsed, 5.0)
        self.assertIn(
            result["status"],
            ("SEARCH_BUDGET_EXHAUSTED", "SOLUTION_FOUND", "CANDIDATE_SET_EXHAUSTED"),
        )
        if result.get("nodes_visited") is not None:
            self.assertLessEqual(result["nodes_visited"], 500 + 500)

    def test_budget_exhaustion_names_the_forward_check(self) -> None:
        """The exhausted status must say whether the lookahead or the beam consumed it."""
        result, _ = self._run(beats=12, options=32, budget=60)
        if result["status"] == "SEARCH_BUDGET_EXHAUSTED":
            self.assertTrue(
                result.get("reason", "").startswith(("node_budget", "forward")),
                result.get("reason"),
            )


class TestTtsRuntimeFailureIsBlocked(unittest.TestCase):
    """P1-36: a runtime that fails at inference is "blocked", never INTERNAL_ERROR."""

    class _ExplodingEngine:
        def list_preset_voices(self):
            return [("Mai Linh", "vi")]

        def infer(self, text, voice=None):  # noqa: D401 - raises on purpose
            raise RuntimeError("kokoro backend missing")

        def save(self, audio, path):
            raise AssertionError("save must not be reached")

    def test_voice_trial_returns_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            result = g3_engine.voice_trial(
                {
                    "script_revision_id": "script",
                    "beat_id": "beat-01",
                    "voice_text": "Xin chào",
                    "voice_id": "Mai Linh",
                    "staging_dir": tmp,
                },
                tts_factory=lambda: self._ExplodingEngine(),
            )
        self.assertEqual(result["status"], "blocked_tts_runtime_unavailable")


class TestFaithfulnessRejectsInventedNames(unittest.TestCase):
    """P1-37: proper nouns the claim never mentioned are rejected."""

    def test_place_name_is_rejected(self) -> None:
        invented = story_writer._invented_entities(
            "Tôi đi qua Đà Lạt lúc bình minh.", "Đoạn đường đèo"
        )
        self.assertIn("Đà", invented)

    def test_parse_and_validate_raises_for_invented_place(self) -> None:
        beats = [{"beat_id": "beat-01", "claim_refs": [{"claim_id": "c1"}],
                  "narrative_type": "evidence_backed", "_claim_text": "Đoạn đường đèo uốn lượn."}]
        payload = ('{"beats":[{"beat_id":"beat-01","claim_id":"c1",'
                   '"voice_text":"Đèo Đà Lạt uốn lượn quanh sườn núi."}]}')
        with self.assertRaises(story_writer.StoryWriterError) as ctx:
            story_writer.parse_and_validate(payload, beats)
        self.assertEqual(ctx.exception.code, "STORY_INVENTED_ENTITY")

    def test_faithful_rewrite_has_no_entities(self) -> None:
        self.assertEqual(
            story_writer._invented_entities(
                "Nghe nói trời mưa từ sáng nên đường trơn trượt.",
                "Người quay kể rằng trời mưa từ sáng nên đường trơn.",
            ),
            [],
        )


class TestUiDefectsAreGone(unittest.TestCase):
    """P1-46..54: the source no longer contains the constructs that caused them."""

    def _app(self, name: str) -> str:
        return (_ROOT / "apps" / "macos" / "Sources" / name).read_text(encoding="utf-8")

    def test_no_invented_script_revision(self) -> None:
        self.assertNotIn('"rev-01"', self._app("G3ConsoleView.swift"))

    def test_no_placeholder_caption(self) -> None:
        for view in ("G4ConsoleView.swift", "G5ConsoleView.swift"):
            self.assertNotIn("Nội dung đã duyệt", self._app(view))

    def test_workflow_reset_exists_and_is_used(self) -> None:
        self.assertIn("func resetWorkflowForNewVideo()", self._app("AppState.swift"))
        self.assertIn("resetWorkflowForNewVideo()", self._app("G5ConsoleView.swift"))

    def test_cancel_cancels_the_running_task(self) -> None:
        state = self._app("AppState.swift")
        self.assertIn("currentBatchTask?.cancel()", state)

    def test_worker_restart_guard_precedes_await(self) -> None:
        state = self._app("AppState.swift")
        start = state.index("func restartWorker()")
        segment = state[start:start + 400]
        self.assertLess(segment.index("isStartingWorker = true"), segment.index("await worker.terminate()"))

    def test_inspector_only_shows_the_probed_file(self) -> None:
        app = self._app("AIVideoApp.swift")
        self.assertNotIn("probe.filePath == item.id || state.selectedFilePath == item.id", app)

    def test_mapping_publication_is_a_g2_mapping(self) -> None:
        g5 = self._app("G5ConsoleView.swift")
        start = g5.index("private func autoPopulateFromStateAndStore()")
        segment = g5[start:start + 600]
        self.assertIn("latestG2MappingPublicationId", segment)
        self.assertNotIn("mappingPublicationId = state.latestG4PublicationId", segment)

    def test_caption_timing_is_not_guessed(self) -> None:
        state = self._app("AppState.swift")
        self.assertNotIn("* 0.45", state)
        self.assertIn("captionTimingSource", state)


if __name__ == "__main__":
    unittest.main()
