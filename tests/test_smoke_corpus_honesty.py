"""
tests/test_smoke_corpus_honesty.py — Regression for audit P0-06 (2026-11-11).

The five clips committed under the fixture directory are 1080x1920 / 24 fps / 1.5 s title
cards labelled by an agent (`labeler_type="agent_visual_review"`,
`source_kind="synthetic_title_card"`, zero claims, zero events). They were nevertheless
announced as "5 video held-out thực tế" in `task_plan.md` and praised as a passed benchmark
in the review package.

The fix renames the directory to `fixtures/smoke` and makes the preflight report what the
clips really are; this test fails closed if someone relabels a smoke clip as field footage.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import unittest

_ROOT = Path(__file__).resolve().parents[1]
if str(_ROOT / "workers" / "src") not in sys.path:
    sys.path.insert(0, str(_ROOT / "workers" / "src"))

_SPEC = importlib.util.spec_from_file_location("check_readiness", _ROOT / "tools" / "check_readiness.py")
check_readiness = importlib.util.module_from_spec(_SPEC)
assert _SPEC and _SPEC.loader
_SPEC.loader.exec_module(check_readiness)


class TestSmokeCorpusIsNotFieldEvidence(unittest.TestCase):
    def test_directory_was_renamed(self) -> None:
        self.assertTrue((_ROOT / "fixtures" / "smoke").is_dir())
        self.assertFalse((_ROOT / "fixtures" / "corpus").is_dir())

    def test_committed_clips_are_reported_as_smoke(self) -> None:
        result = check_readiness.check_smoke_corpus_is_not_field_evidence()
        self.assertTrue(result["smoke_corpus_present"])
        self.assertFalse(result["smoke_is_field_evidence"])
        self.assertEqual(result["smoke_label_blockers"], [])
        for clip in result["smoke_clips"]:
            self.assertEqual(clip["source_kind"], "synthetic_title_card")
            self.assertNotEqual(clip["labeler_type"], "human")
            self.assertEqual(clip["claims"], 0)
            self.assertEqual(clip["events"], 0)

    def test_relabelled_smoke_clip_is_a_blocker(self) -> None:
        """Fail closed: a title card relabelled as human field footage must be caught."""
        import tempfile

        labels = _ROOT / "fixtures" / "smoke" / "labels"
        source = next(iter(sorted(labels.glob("*.json"))))
        data = json.loads(source.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as tmp:
            fake_root = Path(tmp) / "fixtures" / "smoke"
            (fake_root / "labels").mkdir(parents=True)
            forged = dict(data)
            forged["labeler_type"] = "human"
            forged["source_kind"] = "field_footage"
            (fake_root / "labels" / source.name).write_text(json.dumps(forged), encoding="utf-8")
            original = check_readiness.SMOKE_CORPORA
            check_readiness.SMOKE_CORPORA = (fake_root,)
            try:
                result = check_readiness.check_smoke_corpus_is_not_field_evidence()
            finally:
                check_readiness.SMOKE_CORPORA = original
        self.assertTrue(result["smoke_label_blockers"])
        self.assertIn("SMOKE_CLIP_PRESENTED_AS_FIELD", result["smoke_label_blockers"][0])

    def test_preflight_still_requires_a_real_signed_field_corpus(self) -> None:
        """Renaming must not soften the field-corpus gate itself."""
        result = check_readiness.check_field_corpus_and_certification()
        if result["live_field_corpus_certified"]:
            self.fail("the committed smoke corpus must never certify the field corpus")
        self.assertTrue(
            any(b.startswith("CORPUS_KIND_NOT_FIELD") for b in result["certification_blockers"]),
            result["certification_blockers"],
        )


if __name__ == "__main__":
    unittest.main()
