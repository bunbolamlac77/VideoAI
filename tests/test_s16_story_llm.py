"""
tests/test_s16_story_llm.py — Local LLM script writer (`P-STORY-SYNTH-v1`).

Rules under test:
  * the writer may only re-word an approved claim: beat order, claim ids and
    evidence references are byte-identical before and after;
  * invented numbers, missing diacritics, reordered beats and malformed JSON
    are rejected instead of being trusted;
  * any failure falls back to the verbatim claim text and records why — a
    failed rewrite never fabricates a script and never blocks the pipeline;
  * `script_engine` defaults to deterministic so gates/tests stay reproducible;
  * real 8B inference is opt-in (`AIVIDEO_RUN_HEAVY_STORY=1`).
"""

from __future__ import annotations

import os
from pathlib import Path
import sys
import unittest
from unittest import mock

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if _p.as_posix() not in sys.path:
        sys.path.insert(0, _p.as_posix())

from aivideo_workers import story_writer
from aivideo_workers.story_writer import (
    STORY_MODEL_DIR_ENV,
    LLMStoryWriter,
    StoryWriterError,
    parse_and_validate,
    story_model_available,
)
from aivideo_workers.g3_engine import generate_story

SCOPE = "scope-rev-1"

CLAIMS = [
    {
        "claim_id": "claim-1",
        "revision_id": "rev-1",
        "text": "Đoạn đường đèo uốn lượn, hai bên là rừng thông.",
        "evidence_scope_revision_id": SCOPE,
        "support_status": "supported",
        "allowed_use": "direct_claim",
        "review_status": "confirmed",
        "origin": "visual_model",
    "evidence_sha256": "a" * 64,
        # P0-07: a claim that never stated its scope revalidation is no longer
        # silently treated as revalidated; the fixture states it explicitly.
        "scope_revalidation_status": "complete",
        "epistemic_status": "observed",
    },
    {
        "claim_id": "claim-2",
        "revision_id": "rev-2",
        "text": "Người quay kể rằng trời mưa từ sáng nên đường trơn.",
        "evidence_scope_revision_id": SCOPE,
        "support_status": "supported",
        "allowed_use": "attributed_or_qualified",
        "review_status": "confirmed",
        "origin": "user",
        "epistemic_status": "reported",
        # P0-07: missing revalidation state is no longer read as "complete".
        "scope_revalidation_status": "complete",
    },
]


def _beats():
    return [
        {
            "beat_id": "beat-01",
            "claim_refs": [{"claim_id": "claim-1"}],
            "narrative_type": "evidence_backed",
            "_claim_text": CLAIMS[0]["text"],
        },
        {
            "beat_id": "beat-02",
            "claim_refs": [{"claim_id": "claim-2"}],
            "narrative_type": "reported_by_user",
            "_claim_text": CLAIMS[1]["text"],
        },
    ]


def _valid_payload():
    return (
        '{"beats":['
        '{"beat_id":"beat-01","claim_id":"claim-1","voice_text":"Tôi đi qua con đèo uốn theo triền núi, hai bên là rừng thông."},'
        '{"beat_id":"beat-02","claim_id":"claim-2","voice_text":"Nghe nói trời mưa từ sáng nên đường trơn trượt."}'
        ']}'
    )


class TestFaithfulnessValidation(unittest.TestCase):
    def test_faithful_rewrite_is_accepted(self) -> None:
        beats = parse_and_validate(_valid_payload(), _beats())
        self.assertEqual([b["claim_id"] for b in beats], ["claim-1", "claim-2"])
        self.assertNotEqual(beats[0]["voice_text"], CLAIMS[0]["text"])

    def test_invented_number_is_rejected(self) -> None:
        payload = _valid_payload().replace("trơn trượt.", "trơn trượt lúc 6 giờ.")
        with self.assertRaises(StoryWriterError) as ctx:
            parse_and_validate(payload, _beats())
        self.assertEqual(ctx.exception.code, "STORY_INVENTED_FACT")

    def test_reordered_beats_are_rejected(self) -> None:
        payload = (
            '{"beats":['
            '{"beat_id":"beat-02","claim_id":"claim-2","voice_text":"Nghe nói trời mưa từ sáng nên đường trơn trượt."},'
            '{"beat_id":"beat-01","claim_id":"claim-1","voice_text":"Tôi đi qua con đèo uốn theo triền núi, hai bên là rừng thông."}'
            ']}'
        )
        with self.assertRaises(StoryWriterError) as ctx:
            parse_and_validate(payload, _beats())
        self.assertEqual(ctx.exception.code, "STORY_BEAT_ORDER_CHANGED")

    def test_missing_diacritics_are_rejected(self) -> None:
        payload = _valid_payload().replace(
            "Tôi đi qua con đèo uốn theo triền núi, hai bên là rừng thông.",
            "Toi di qua con deo uon theo trien nui hai ben la rung thong.",
        )
        with self.assertRaises(StoryWriterError) as ctx:
            parse_and_validate(payload, _beats())
        self.assertEqual(ctx.exception.code, "STORY_TEXT_NO_DIACRITICS")

    def test_non_json_output_is_rejected(self) -> None:
        with self.assertRaises(StoryWriterError) as ctx:
            parse_and_validate("Xin lỗi, tôi không thể.", _beats())
        self.assertEqual(ctx.exception.code, "STORY_OUTPUT_NOT_JSON")

    def test_beat_count_mismatch_is_rejected(self) -> None:
        payload = (
            '{"beats":[{"beat_id":"beat-01","claim_id":"claim-1",'
            '"voice_text":"Tôi đi qua con đèo uốn theo triền núi."}]}'
        )
        with self.assertRaises(StoryWriterError) as ctx:
            parse_and_validate(payload, _beats())
        self.assertEqual(ctx.exception.code, "STORY_BEAT_COUNT_MISMATCH")


class TestGenerateStoryWiring(unittest.TestCase):
    def test_default_engine_stays_deterministic(self) -> None:
        result = generate_story({
            "evidence_scope_revision_id": SCOPE,
            "claims": CLAIMS,
            "shots": [],
        })
        candidate = result["candidates"][0]
        self.assertEqual(candidate["script_engine"]["engine"], "deterministic")
        self.assertEqual(candidate["beats"][0]["voice_text"], CLAIMS[0]["text"])

    def test_llm_engine_rewrites_without_touching_evidence(self) -> None:
        class FakeWriter:
            def __init__(self, *args, **kwargs):
                pass

            def rewrite(self, beats):
                return {
                    "beats": [
                        {"beat_id": b["beat_id"], "claim_id": b["claim_refs"][0]["claim_id"],
                         "voice_text": "Tôi nhớ lại: " + b["_claim_text"]}
                        for b in beats
                    ],
                    "meta": {"engine": "mlx_lm_local", "profile_id": "P-STORY-SYNTH-v1"},
                }

        with mock.patch.object(story_writer, "LLMStoryWriter", FakeWriter):
            result = generate_story({
                "evidence_scope_revision_id": SCOPE,
                "claims": CLAIMS,
                "shots": [],
                "script_engine": "llm",
            })
        candidate = result["candidates"][0]
        self.assertEqual(candidate["script_engine"]["engine"], "llm_local")
        self.assertTrue(candidate["beats"][0]["voice_text"].startswith("Tôi nhớ lại:"))
        self.assertEqual(candidate["beats"][0]["voice_text_origin"], "llm_local_rewrite")
        # Evidence untouched.
        self.assertEqual(candidate["beats"][0]["claim_refs"][0]["claim_id"], "claim-1")
        self.assertEqual(candidate["beats"][1]["claim_refs"][0]["allowed_use"], "attributed_or_qualified")
        self.assertEqual(len(candidate["beats"]), len(CLAIMS))

    def test_llm_failure_falls_back_and_records_reason(self) -> None:
        class BrokenWriter:
            def __init__(self, *args, **kwargs):
                pass

            def rewrite(self, beats):
                raise StoryWriterError("STORY_INVENTED_FACT", "beat-01 invented numbers")

        with mock.patch.object(story_writer, "LLMStoryWriter", BrokenWriter):
            result = generate_story({
                "evidence_scope_revision_id": SCOPE,
                "claims": CLAIMS,
                "shots": [],
                "script_engine": "llm",
            })
        candidate = result["candidates"][0]
        self.assertEqual(result["status"], "draft")
        self.assertEqual(candidate["script_engine"]["engine"], "deterministic")
        self.assertEqual(candidate["script_engine"]["fallback_reason"], "STORY_INVENTED_FACT")
        self.assertEqual(candidate["beats"][0]["voice_text"], CLAIMS[0]["text"])

    def test_invalid_script_engine_is_refused(self) -> None:
        with self.assertRaises(ValueError):
            generate_story({
                "evidence_scope_revision_id": SCOPE,
                "claims": CLAIMS,
                "shots": [],
                "script_engine": "gpt-cloud",
            })


class TestRealStoryModel(unittest.TestCase):
    def test_real_qwen3_writes_pov_script(self) -> None:
        if os.environ.get("AIVIDEO_RUN_HEAVY_STORY") != "1":
            self.skipTest("Heavy 8B script run; set AIVIDEO_RUN_HEAVY_STORY=1 to execute")
        if not story_model_available():
            self.skipTest(
                f"story model not installed ({os.environ.get(STORY_MODEL_DIR_ENV, 'default dir')})"
            )
        prepared = []
        for beat, claim in zip(_beats(), CLAIMS):
            item = dict(beat)
            item["_claim_text"] = claim["text"]
            prepared.append(item)
        result = LLMStoryWriter().rewrite(prepared)
        self.assertEqual([b["claim_id"] for b in result["beats"]], ["claim-1", "claim-2"])
        self.assertNotEqual(result["beats"][0]["voice_text"], CLAIMS[0]["text"])
        self.assertIn(result["meta"]["engine"], ("mlx_lm_local",))


if __name__ == "__main__":
    unittest.main(verbosity=2)
