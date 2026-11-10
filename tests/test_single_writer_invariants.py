"""
tests/test_single_writer_invariants.py — structural guard for the single-writer invariant.

Fails if G3/G4/G5 approval code opens its own SQLite handle or recreates schema,
which would put the canonical database back under multiple writers.
"""

from __future__ import annotations

from pathlib import Path
import sys
import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))


class TestSingleWriterInvariant(unittest.TestCase):
    STORAGE = _ROOT / "packages" / "AIVideoCore" / "Sources" / "Storage"

    def test_gate_stores_do_not_open_their_own_connection(self) -> None:
        """D06: G3/G4/G5 approval code must write through ProjectStore's handle."""
        offenders = []
        for name in ("G3ProjectStore.swift", "G4ProjectStore.swift", "G5ProjectStore.swift"):
            text = (self.STORAGE / name).read_text(encoding="utf-8")
            if "sqlite3_open_v2" in text:
                offenders.append(name)
        self.assertEqual(offenders, [], f"gate stores still open their own SQLite handle: {offenders}")

    def test_gate_schema_is_owned_by_the_canonical_store(self) -> None:
        """D06: gate tables must be created by ProjectStore, not lazily per call."""
        project_store = (self.STORAGE / "ProjectStore.swift").read_text(encoding="utf-8")
        for table in (
            "g3_scripts",
            "g3_approvals",
            "g4_preview_approvals",
            "g5_final_approvals",
            "g5_manual_handoff_branches",
        ):
            self.assertIn(f"CREATE TABLE IF NOT EXISTS {table}", project_store)

        for name in ("G3ProjectStore.swift", "G4ProjectStore.swift", "G5ProjectStore.swift"):
            text = (self.STORAGE / name).read_text(encoding="utf-8")
            self.assertNotIn("CREATE TABLE IF NOT EXISTS", text, f"{name} still creates schema")

    def test_gate_stores_use_the_canonical_transaction(self) -> None:
        for name in ("G3ProjectStore.swift", "G4ProjectStore.swift", "G5ProjectStore.swift"):
            text = (self.STORAGE / name).read_text(encoding="utf-8")
            self.assertIn("withCanonicalTransaction", text, f"{name} bypasses the canonical transaction")


if __name__ == "__main__":
    unittest.main()
