"""
tests/test_corpus_labels.py — labels, signed manifest and certification honesty.

The repository ships five generated title cards. Their labels are agent-written and
describe a synthetic source, so a valid Ed25519 signature over them must NOT certify
a field corpus.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys

import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from aivideo_workers.corpus_labels import (
    label_blockers,
    load_clip_labels,
    summarize_label_eligibility,
    validate_clip_labels,
)
from aivideo_workers.g5_release_audit import (
    evaluate_e0_e1_accounting,
    validate_signed_field_manifest,
)

_CORPUS = _ROOT / "fixtures" / "corpus"
_LABELS = _CORPUS / "labels"
_MANIFEST = _ROOT / "reports" / "evidence" / "signed_field_corpus_manifest.json"


class TestClipLabels(unittest.TestCase):
    def test_labels_cover_every_clip_and_match_hashes(self) -> None:
        labels = load_clip_labels(_LABELS)
        self.assertEqual(len(labels), 5)
        self.assertEqual(validate_clip_labels(labels, _CORPUS), [])

    def test_labels_are_not_acceptance_eligible(self) -> None:
        summary = summarize_label_eligibility(load_clip_labels(_LABELS))
        self.assertFalse(summary["acceptance_eligible"])
        self.assertEqual(summary["labeler_types"], ["agent_visual_review"])
        self.assertEqual(summary["source_kinds"], ["synthetic_title_card"])
        blockers = label_blockers(summary)
        self.assertTrue(any("LABELS_NOT_HUMAN" in b for b in blockers))
        self.assertTrue(any("NOT_FIELD_FOOTAGE" in b for b in blockers))

    def test_tampered_label_hash_is_reported(self) -> None:
        labels = load_clip_labels(_LABELS)
        first = next(iter(labels))
        labels[first] = dict(labels[first], source_sha256="0" * 64)
        problems = validate_clip_labels(labels, _CORPUS)
        self.assertTrue(any("source_sha256" in p for p in problems))

    def test_human_field_labels_would_be_eligible(self) -> None:
        labels = load_clip_labels(_LABELS)
        upgraded = {
            trip: dict(label, labeler_type="human", source_kind="field_footage")
            for trip, label in labels.items()
        }
        summary = summarize_label_eligibility(upgraded)
        self.assertTrue(summary["acceptance_eligible"])
        self.assertEqual(label_blockers(summary), [])


class TestSignedManifestHonesty(unittest.TestCase):
    def test_manifest_signature_and_hashes_verify(self) -> None:
        manifest = json.loads(_MANIFEST.read_text(encoding="utf-8"))
        self.assertTrue(validate_signed_field_manifest(manifest, corpus_dir=_CORPUS))

    def test_synthetic_corpus_is_never_certified(self) -> None:
        runs = [
            {"outcome": "completed", "total_emitted_claims": 1, "verified_supported_claims": 1}
            for _ in range(5)
        ]
        manifest = json.loads(_MANIFEST.read_text(encoding="utf-8"))
        result = evaluate_e0_e1_accounting(
            {
                "runs": runs,
                "is_synthetic_fixture": False,
                "signed_field_manifest": manifest,
                "corpus_dir": str(_CORPUS),
            }
        )
        self.assertFalse(result["live_field_corpus_certified"])
        blockers = " ".join(result["certification_blockers"])
        self.assertIn("CORPUS_KIND_NOT_FIELD", blockers)
        self.assertIn("LABELS_NOT_HUMAN_FIELD", blockers)

    def test_manifest_hash_mismatch_breaks_signature_validation(self) -> None:
        manifest = json.loads(_MANIFEST.read_text(encoding="utf-8"))
        with_tamper = json.loads(json.dumps(manifest))
        with_tamper["corpus_scope"]["held_out_trips"][0]["sha256"] = "0" * 64
        self.assertFalse(validate_signed_field_manifest(with_tamper, corpus_dir=_CORPUS))


if __name__ == "__main__":
    unittest.main()
