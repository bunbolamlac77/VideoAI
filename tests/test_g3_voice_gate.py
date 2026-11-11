"""
tests/test_g3_voice_gate.py — Regression for audit P0-07 (2026-11-11).

The G3 console (`G3ConsoleView.swift:677-678`) sent the constants

    "voice_review_status": "verified", "voice_wav_published": true

for every cut search, so `g3_engine.search_cuts` (`:1095-1107`) could never block a user who
had never listened to the WAV. The engine also never told the caller what the real review
state was, and it defaulted a missing review status to `"complete"` in `eligible_claims`.

The gate is now a decision the caller must state: `verified` + published WAV passes,
`unverified` is explicitly allowed but must be reported, and anything else blocks.
"""

from __future__ import annotations

from pathlib import Path
import sys
import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from workers.src.aivideo_workers import g3_engine


def _params(**overrides):
    base = {
        "candidate_options": [
            [
                {
                    "shot_id": "s1",
                    "start_frame": 0,
                    "end_frame": 48,
                    "source_revision_id": "src-1",
                }
            ]
        ],
        "voice_samples_per_beat": [48_000],
        "beam_width": 2,
        "node_budget": 50,
        "forward_check": False,
    }
    base.update(overrides)
    return base


class TestVoiceGate(unittest.TestCase):
    def _status(self, **overrides) -> str:
        result = g3_engine.search_cuts(_params(**overrides))
        return str(result.get("status"))

    def test_missing_review_state_blocks(self):
        """P0-07: no review state must never mean 'verified'."""
        self.assertEqual(self._status(), "BLOCKED_VOICE_NOT_VERIFIED")

    def test_claimed_verified_without_published_wav_blocks(self):
        """P0-07: the two halves of the claim are checked separately."""
        self.assertEqual(
            self._status(voice_review_status="verified", voice_wav_published=False),
            "BLOCKED_VOICE_NOT_VERIFIED",
        )

    def test_unverified_state_is_explicit_and_allowed(self):
        """P0-07: a caller may declare 'not reviewed' — that must not be silently 'verified'."""
        self.assertNotEqual(
            self._status(voice_review_status="unverified"),
            "BLOCKED_VOICE_NOT_VERIFIED",
        )

    def test_verified_state_needs_published_wav(self):
        """P0-07: the real path still passes when both parts are true."""
        self.assertNotEqual(
            self._status(voice_review_status="verified", voice_wav_published=True),
            "BLOCKED_VOICE_NOT_VERIFIED",
        )


class TestEligibleClaimsScopeDefault(unittest.TestCase):
    def test_missing_scope_revalidation_status_is_not_complete(self):
        """A claim that never stated revalidation must not be treated as revalidated."""
        claims = [
            {
                "claim_id": "c-1",
                "text": "Cô dâu bước vào lễ đường.",
                "revision_id": "rev-1",
                "evidence_scope_revision_id": "scope-1",
                "support_status": "supported",
                "allowed_use": "direct_claim",
                "review_status": "confirmed",
                "origin": "user",
            }
        ]
        eligible, rejected = g3_engine.eligible_claims(claims, "scope-1")
        self.assertEqual(eligible, [])
        self.assertEqual(rejected[0]["reason"], "missing_scope_revalidation")

    def test_explicit_complete_scope_is_accepted(self):
        claims = [
            {
                "claim_id": "c-1",
                "text": "Cô dâu bước vào lễ đường.",
                "revision_id": "rev-1",
                "evidence_scope_revision_id": "scope-1",
                "scope_revalidation_status": "complete",
                "support_status": "supported",
                "allowed_use": "direct_claim",
                "review_status": "confirmed",
                "origin": "user",
            }
        ]
        eligible, rejected = g3_engine.eligible_claims(claims, "scope-1")
        self.assertEqual(rejected, [])
        self.assertEqual(len(eligible), 1)


if __name__ == "__main__":
    unittest.main()
