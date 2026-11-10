"""
tests/test_qa_anchor_invariants.py — structural guard for the pinned QA trust anchor.

Fails if the Ed25519 verification key becomes discoverable through an environment
variable or if an unprovisioned repo silently starts certifying field corpora.
"""

from __future__ import annotations

import os
from pathlib import Path
import sys
import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from aivideo_workers import g5_release_audit


class TestPinnedQATrustAnchor(unittest.TestCase):
    def test_key_path_ignores_contracts_env_override(self) -> None:
        """D07: AIVIDEO_CONTRACTS_DIR must not be able to redirect signature verification."""
        previous = os.environ.get("AIVIDEO_CONTRACTS_DIR")
        try:
            os.environ["AIVIDEO_CONTRACTS_DIR"] = "/tmp/attacker-controlled-contracts"
            self.assertTrue(str(g5_release_audit._QA_PUBLIC_KEY_PATH).startswith(str(_ROOT)))
            self.assertNotIn("attacker-controlled", str(g5_release_audit._QA_PUBLIC_KEY_PATH))
        finally:
            if previous is None:
                os.environ.pop("AIVIDEO_CONTRACTS_DIR", None)
            else:
                os.environ["AIVIDEO_CONTRACTS_DIR"] = previous

    def test_production_anchor_matches_the_committed_public_key(self) -> None:
        """The pinned fingerprint must equal the committed PEM, or signing breaks."""
        import hashlib

        pem = (_ROOT / "contracts" / "field_qa_ed25519_public_key.pem").read_bytes()
        self.assertEqual(
            hashlib.sha256(pem).hexdigest(),
            g5_release_audit.PINNED_FIELD_QA_KEY_SHA256,
        )
        self.assertEqual(g5_release_audit.FIELD_QA_KEY_ID, "aivideo-field-qa-v1")

    def test_private_key_never_lives_in_the_repository(self) -> None:
        private_candidates = list(_ROOT.rglob("*field_qa*private*"))
        self.assertEqual(private_candidates, [], f"private key committed: {private_candidates}")


if __name__ == "__main__":
    unittest.main()
