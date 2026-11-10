"""Adversarial checks for public G3 JSON-RPC surface."""
import json
import os
import tempfile
import unittest
from unittest.mock import patch

from aivideo_workers import g3_rpc_safe as safe
from aivideo_workers import main


def fact(
    cid="a",
    origin="user",
    use="attributed_or_qualified",
):
    return {
        "claim_id": cid,
        "revision_id": "rev-" + cid,
        "text": "Tôi đến nơi quay.",
        "origin": origin,
        "epistemic_status": "reported",
        "review_status": "confirmed",
        "support_status": "supported",
        "allowed_use": use,
        "scope_revalidation_status": "complete",
        "evidence_scope_revision_id": "scope-1",
    }


class G3SecurityRPC(unittest.TestCase):
    def test_registered_methods_have_guarded_handlers(
        self,
    ):
        self.assertIs(
            main.METHODS["g3.story.generate"],
            safe.generate_story,
        )
        self.assertIs(
            main.METHODS["g3.approval.propose"],
            safe.approval_proposal,
        )
        self.assertIs(
            main.METHODS["g3.cut.stage"],
            safe.stage_cut_plan,
        )

    def test_user_report_cannot_become_direct_fact(
        self,
    ):
        result = safe.generate_story({
            "evidence_scope_revision_id": "scope-1",
            "claims": [
                fact(use="direct_claim")
            ],
        })

        self.assertEqual(
            result["status"],
            "blocked_user_fact_requires_attribution",
        )

        story = safe.generate_story({
            "evidence_scope_revision_id": "scope-1",
            "claims": [fact()],
        })

        self.assertEqual(
            story["status"],
            "draft",
        )

        self.assertIn(
            "Theo thông tin",
            story["candidates"][0]["beats"][0][
                "voice_text"
            ],
        )

    def test_duplicate_claim_revision_is_rejected(
        self,
    ):
        result = safe.generate_story({
            "evidence_scope_revision_id": "scope-1",
            "claims": [
                fact("x"),
                fact("x"),
            ],
        })

        self.assertEqual(
            result["status"],
            "blocked_duplicate_claim_revision",
        )

    def test_tts_cannot_write_to_arbitrary_path(
        self,
    ):
        with tempfile.TemporaryDirectory() as root:
            with tempfile.TemporaryDirectory() as other:
                with patch.dict(
                    os.environ,
                    {"AIVIDEO_G3_STAGING_ROOT": root},
                ):
                    result = safe.voice_trial({
                        "staging_dir": other,
                    })

                    self.assertEqual(
                        result["status"],
                        "blocked_untrusted_staging_directory",
                    )

    def test_no_publication_means_no_approval_proposal(
        self,
    ):
        result = safe.approval_proposal({
            "cut_result": {
                "status": "SOLUTION_FOUND"
            }
        })

        self.assertEqual(
            result["status"],
            "blocked_cut_not_published_by_core",
        )

    def test_cut_staging_never_is_approval(
        self,
    ):
        with tempfile.TemporaryDirectory() as root:
            with patch.dict(
                os.environ,
                {"AIVIDEO_G3_STAGING_ROOT": root},
            ):
                result = safe.stage_cut_plan({
                    "staging_dir": root,
                    "candidate": {
                        "status": "DRAFT_NOT_BUILDABLE",
                        "script_revision_id": "a" * 64,
                        "scope_revision_id": "scope-1",
                        "beats": [
                            {"beat_id": "beat-01"}
                        ],
                    },
                    "cut_result": {
                        "status": "SOLUTION_FOUND",
                        "domain_sha256": "b" * 64,
                        "edit_plan": [
                            {"shot_id": "shot-A"}
                        ],
                        "validation": {
                            "valid": True
                        },
                    },
                })

                self.assertEqual(
                    result["status"],
                    "staged_requires_S08_publication",
                )
                self.assertFalse(
                    result["approved"]
                )

                with open(
                    result["staging_path"], "rb"
                ) as fh:
                    actual = fh.read()

                self.assertEqual(
                    safe.hashlib.sha256(
                        actual
                    ).hexdigest(),
                    result["sha256"],
                )

                self.assertEqual(
                    json.loads(actual)[
                        "schema_version"
                    ],
                    "g3-cut-plan-v1",
                )

    def test_search_is_provisional_not_approval(
        self,
    ):
        outcome = safe.search_cuts({
            "candidate_options": []
        })

        self.assertEqual(
            outcome["core_approval_state"],
            "NOT_VERIFIED_BY_PROJECTSTORE",
        )

    def test_oracle_flag_is_not_independent_evidence(
        self,
    ):
        rows = [{
            "candidate_id": "c",
            "claim_id": "v" + str(i),
            "trip_group_id": "trip-" + str(i % 5),
            "accepted_for_narration": True,
            "oracle_supported": True,
            "critical": False,
        } for i in range(25)]

        data = safe.script_ready_metrics({
            "human_labeled_claim_uses": rows,
            "presented_candidate_ids": ["c"],
            "evaluation_split": "held_out",
            "oracle_locked": True,
        })

        self.assertEqual(
            data["result"],
            "DESCRIPTIVE_PASS_NOT_GATE_EVIDENCE",
        )


if __name__ == "__main__":
    unittest.main()
