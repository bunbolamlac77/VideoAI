"""G3 regression tests: S16, S17, S18, S19."""
import struct
import tempfile
import unittest
import wave
from pathlib import Path

from aivideo_workers.g3_engine import (
    approval_proposal,
    digest,
    edit_story,
    generate_story,
    search_cuts,
    voice_trial,
    script_ready_metrics,
)

SCOPE = "scope-test-1"


def claim(cid, text, **override):
    item = dict(
        claim_id=cid,
        revision_id=f"rev-{cid}",
        text=text,
        evidence_scope_revision_id=SCOPE,
        scope_revalidation_status="complete",
        support_status="supported",
        allowed_use="direct_claim",
        origin="user",
        epistemic_status="reported",
        review_status="confirmed",
    )
    item.update(override)
    return item


def opt(name, key, score, start):
    return dict(
        shot_id=name,
        source_revision_id="source-v1",
        source_sha256="a" * 64,
        mapping_sha256="b" * 64,
        evidence_scope_valid=True,
        claim_use_valid=True,
        crop_preserves_evidence=True,
        range_start=start,
        range_end=start + 25,
        duration_frames=24,
        transition_overlap_frames=0,
        reuse_key=key,
        quality_score=score,
    )


class G3Tests(unittest.TestCase):
    def search_payload(
        self,
        unsat=False,
        **overrides,
    ):
        beats = [
            [
                opt("A", "X", 10, 0),
            ] + (
                []
                if unsat
                else [opt("B", "Y", 8, 25)]
            ),
            [
                opt("C", "X", 1, 50),
            ],
        ]

        payload = dict(
            candidate_options=beats,
            voice_samples_per_beat=[
                48000,
                48000,
            ],
            voice_review_status="verified",
            voice_wav_published=True,
            beam_width=1,
            forward_check=False,
            node_budget=500,
            constraints={
                "must_not_use": [],
                "must_use": [],
            },
        )
        payload.update(overrides)
        return payload

    def test_s16_unsupported_and_uncertain_are_excluded(
        self,
    ):
        story = generate_story({
            "evidence_scope_revision_id": SCOPE,
            "claims": [
                claim(
                    "1",
                    "Tôi dừng trước biển báo.",
                ),
                claim(
                    "2",
                    "GPS gây ra việc đi sai",
                    support_status="insufficient",
                ),
                claim(
                    "3",
                    "Tôi thấy xe",
                    review_status="unreviewed",
                ),
            ],
            "shots": [],
        })

        self.assertEqual(
            story["status"],
            "draft",
        )
        self.assertEqual(
            len(story["candidates"]),
            1,
        )
        self.assertEqual(
            len(story["candidates"][0]["beats"]),
            1,
        )
        self.assertIn(
            "Tôi dừng trước",
            story["candidates"][0]["beats"][0][
                "voice_text"
            ],
        )
        self.assertEqual(
            len(story["excluded"]),
            2,
        )

    def test_s16_must_use_without_evidence_blocks(
        self,
    ):
        story = generate_story({
            "evidence_scope_revision_id": SCOPE,
            "claims": [
                claim(
                    "1",
                    "Cảnh trời sáng.",
                )
            ],
            "constraints": {
                "must_use": ["unknown"],
                "must_not_use": [],
                "preferred": [],
            },
        })

        self.assertEqual(
            story["status"],
            "blocked_constraints",
        )

    def test_s16_edit_stales_downstream(
        self,
    ):
        story = generate_story({
            "evidence_scope_revision_id": SCOPE,
            "claims": [
                claim(
                    "1",
                    "Một cảnh thật.",
                )
            ],
            "shots": [],
        })["candidates"][0]

        changed = edit_story({
            "candidate": story,
            "beat_id": "beat-01",
            "new_text": "Câu cần xác minh lại.",
        })

        self.assertEqual(
            changed["status"],
            "revalidation_required",
        )
        self.assertEqual(
            changed["candidate"]["revision"],
            2,
        )
        self.assertIn(
            "approval",
            changed["invalidated"],
        )

    def test_s18_pruning_then_recovery(
        self,
    ):
        first = search_cuts(
            self.search_payload()
        )

        self.assertEqual(
            first["status"],
            "SEARCH_BUDGET_EXHAUSTED",
        )

        self.assertTrue(
            any(
                item["event"] == "beam_prune"
                and item["option"] == "B"
                for item in first["trace"]
            )
        )

        recovered = search_cuts(
            self.search_payload(
                beam_width=2
            )
        )

        self.assertEqual(
            recovered["status"],
            "SOLUTION_FOUND",
        )
        self.assertEqual(
            recovered["shots"],
            ["B", "C"],
        )

    def test_s18_forward_check_gets_solution(
        self,
    ):
        result = search_cuts(
            self.search_payload(
                forward_check=True
            )
        )

        self.assertEqual(
            result["status"],
            "SOLUTION_FOUND",
        )
        self.assertEqual(
            result["shots"],
            ["B", "C"],
        )
        self.assertTrue(
            any(
                item["event"] == "forward_prune"
                and item["option"] == "A"
                for item in result["trace"]
            )
        )
        self.assertFalse(
            result["exact_checker_used"]
        )

    def test_s18_exact_unsat_proof(
        self,
    ):
        no_exact = search_cuts(
            self.search_payload(
                unsat=True
            )
        )
        self.assertNotEqual(
            no_exact["status"],
            "PROVEN_INFEASIBLE_IN_DECLARED_DOMAIN",
        )

        exact = search_cuts(
            self.search_payload(
                unsat=True,
                run_exact_checker=True,
            )
        )
        self.assertEqual(
            exact["status"],
            "PROVEN_INFEASIBLE_IN_DECLARED_DOMAIN",
        )
        self.assertTrue(
            exact["proof"]["fully_enumerated"]
        )

    def test_s18_exact_budget_no_false_unsat(
        self,
    ):
        result = search_cuts(
            self.search_payload(
                unsat=True,
                run_exact_checker=True,
                exact_node_budget=1,
            )
        )
        self.assertEqual(
            result["status"],
            "SEARCH_BUDGET_EXHAUSTED",
        )

    def test_s18_voice_and_evidence_hard_constraints(
        self,
    ):
        payload = self.search_payload(
            beam_width=2,
            voice_samples_per_beat=[
                48_000,
                49_000,
            ],
        )

        self.assertNotEqual(
            search_cuts(payload)["status"],
            "SOLUTION_FOUND",
        )

        payload = self.search_payload(
            beam_width=2
        )
        payload["candidate_options"][0][0][
            "claim_use_valid"
        ] = False

        result = search_cuts(payload)

        self.assertEqual(
            result["shots"],
            ["B", "C"],
        )

    def test_s17_tts_wav_contract(
        self,
    ):
        class FakeTTS:
            def list_preset_voices(self):
                return [
                    ("Giọng thử", "voice-1")
                ]

            def infer(self, text, voice):
                return text

            def save(self, audio, path):
                with wave.open(path, "wb") as wf:
                    wf.setnchannels(1)
                    wf.setsampwidth(2)
                    wf.setframerate(48000)
                    wf.writeframes(
                        struct.pack("<h", 512) * 4800
                    )

        with tempfile.TemporaryDirectory() as d:
            info = voice_trial(
                {
                    "script_revision_id": "script-rev-1",
                    "beat_id": "beat-01",
                    "voice_text": "Một câu tiếng Việt.",
                    "voice_id": "Giọng thử",
                    "staging_dir": d,
                },
                tts_factory=FakeTTS,
            )

            self.assertEqual(
                info["wav"]["samples"],
                4800,
            )
            self.assertFalse(
                info["approved"]
            )
            self.assertIn(
                "pending",
                info["status"],
            )
            self.assertTrue(
                Path(
                    info["staging_path"]
                ).exists()
            )

            with self.assertRaises(ValueError):
                voice_trial(
                    {
                        "script_revision_id": "s",
                        "beat_id": "beat-01",
                        "voice_text": "test",
                        "voice_id": "Giọng thử",
                        "staging_dir": d,
                        "speed": 1.2,
                    },
                    tts_factory=FakeTTS,
                )

    def test_s19_script_ready_metrics_heldout_only(
        self,
    ):
        self.assertEqual(
            script_ready_metrics({})["result"],
            "NOT_RUN",
        )

        rows = [
            {
                "candidate_id": "story-1",
                "claim_id": f"claim-{i}",
                "trip_group_id": f"trip-{i % 5}",
                "accepted_for_narration": True,
                "oracle_supported": True,
                "critical": True,
            }
            for i in range(25)
        ]

        measured = script_ready_metrics({
            "human_labeled_claim_uses": rows,
            "presented_candidate_ids": [
                "story-1"
            ],
            "evaluation_split": "held_out",
            "oracle_locked": True,
        })

        self.assertEqual(
            measured["result"],
            "PASS",
        )
        self.assertEqual(
            measured["denominator"],
            25,
        )

        rows[0]["oracle_supported"] = False

        measured = script_ready_metrics({
            "human_labeled_claim_uses": rows,
            "presented_candidate_ids": [
                "story-1"
            ],
            "evaluation_split": "held_out",
            "oracle_locked": True,
        })

        self.assertEqual(
            measured[
                "critical_false_accept_count"
            ],
            1,
        )
        self.assertNotEqual(
            measured["result"],
            "PASS",
        )

    def test_s19_never_auto_approve(
        self,
    ):
        story = generate_story({
            "evidence_scope_revision_id": SCOPE,
            "claims": [
                claim(
                    "1",
                    "Một cảnh thật.",
                )
            ],
            "shots": [],
        })["candidates"][0]

        cut = search_cuts({
            "candidate_options": [
                [opt("A", "X", 1, 0)]
            ],
            "voice_samples_per_beat": [
                48000
            ],
            "voice_review_status": "verified",
            "voice_wav_published": True,
        })

        wav = [{
            "speech_review_status": "verified",
            "publication_state": "COMMITTED",
            "publication_id": "p-1",
            "wav": {
                "sha256": "x" * 64,
            },
            "beat_id": "beat-01",
            "script_revision_id": (
                story["script_revision_id"]
            ),
            "text_fingerprint": digest(
                story["beats"][0][
                    "voice_text"
                ].encode("utf-8")
            ),
        }]

        evidence = [{
            "revision_id": "rev-1",
            "support_status": "supported",
            "scope_revalidation_status": (
                "complete"
            ),
            "allowed_use": "direct_claim",
        }]

        proposed = approval_proposal({
            "candidate": story,
            "cut_result": cut,
            "voice_trials": wav,
            "claim_revisions": evidence,
        })

        self.assertEqual(
            proposed["status"],
            "ready_for_core_transaction_not_approved",
        )
        self.assertNotIn(
            "approved",
            proposed,
        )

        wav[0][
            "speech_review_status"
        ] = "unreviewed"

        blocked = approval_proposal({
            "candidate": story,
            "cut_result": cut,
            "voice_trials": wav,
            "claim_revisions": evidence,
        })
        self.assertEqual(
            blocked["status"],
            "blocked_voice_or_publication",
        )


if __name__ == "__main__":
    unittest.main()
