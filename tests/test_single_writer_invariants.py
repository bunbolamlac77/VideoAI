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
        """D06: G3/G4/G5 approval code must write through ProjectStore's handle.

        Read-only evidence gathering lives in the guards on private READ-ONLY connections
        (audit P1-02: hashing gigabytes inside the single writer blocked the whole app), so
        the rule enforced here is about *writes*: a gate store may never open a writable
        handle, use its own transaction, or create schema on its own connection.
        """
        offenders = []
        for name in ("G3ProjectStore.swift", "G4ProjectStore.swift", "G5ProjectStore.swift"):
            text = (self.STORAGE / name).read_text(encoding="utf-8")
            if "SQLITE_OPEN_READWRITE" in text or "SQLITE_OPEN_CREATE" in text:
                offenders.append(name)
            if "sqlite3_open_v2" in text and "SQLITE_OPEN_READONLY" not in text:
                offenders.append(name)
        self.assertEqual(offenders, [], f"gate stores open a writable SQLite handle: {offenders}")

    def test_every_read_only_handle_is_explicit(self) -> None:
        """An application-owned connection may only be opened read-only for evidence."""
        for path in self.STORAGE.glob("*.swift"):
            text = path.read_text(encoding="utf-8")
            for line_no, line in enumerate(text.splitlines(), 1):
                if "sqlite3_open_v2" not in line:
                    continue
                # The canonical writer is the one and only writable opener.
                if path.name == "ProjectStore.swift":
                    continue
                self.assertIn(
                    "SQLITE_OPEN_READONLY", line,
                    f"{path.name}:{line_no} opens SQLite without SQLITE_OPEN_READONLY",
                )

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
