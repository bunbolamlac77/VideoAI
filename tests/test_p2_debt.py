"""
tests/test_p2_debt.py — Regression for the P2 technical-debt list (audit section 6).

One test class per P2 group, each asserting the *property* that removes the debt rather
than the shape of the current code:

  P2-01 god files are being split (each concern has its own file, sizes bounded)
  P2-02 the app bundle carries exactly one worker copy
  P2-03/P2-05 reads never take the writer lock
  P2-04 UUID comparisons are case-insensitive; ffprobe fps parsing cannot trap
  P2-06 no broad exception handler swallows silently
  P2-07 UI state is typed, not matched from Vietnamese message prefixes
  P2-08/P2-09/P2-10 no seeded demo data, no fake "saved", no hard-coded project ids
  P2-11 accessibility labels + no sub-11pt body text + no mini hit targets
  P2-12 the Python review_workflow module is declared non-production
  P2-13 one schema source; the SQL file is a fixture
  P2-14 duplicated root docs cannot drift; REVIEW_SUMMARY is not a stale claim
"""

from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import sys
import unittest

_ROOT = Path(__file__).resolve().parents[1]
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

WORKERS = _ROOT / "workers" / "src" / "aivideo_workers"
APP = _ROOT / "apps" / "macos" / "Sources"
CORE = _ROOT / "packages" / "AIVideoCore" / "Sources"


def py_sources() -> list[Path]:
    """Live Python sources. `tools/historical/` holds already-applied migrations."""
    files = [p for p in WORKERS.rglob("*.py") if "__pycache__" not in str(p)]
    files += [
        p for p in (_ROOT / "tools").rglob("*.py")
        if "__pycache__" not in str(p) and "historical" not in p.parts
    ]
    return sorted(files)


def swift_sources() -> list[Path]:
    return sorted(list(CORE.rglob("*.swift")) + list(APP.rglob("*.swift")))


class TestGodFilesAreBeingSplit(unittest.TestCase):
    """P2-01: the largest files shrink, and new concerns live in their own file."""

    LIMITS = {
        "packages/AIVideoCore/Sources/Storage/ProjectStore.swift": 3200,
        "workers/src/aivideo_workers/g3_engine.py": 1900,
        "apps/macos/Sources/AIVideoApp.swift": 1700,
        "apps/macos/Sources/AppState.swift": 1400,
        "packages/AIVideoCore/Sources/Storage/G3ProjectStore.swift": 1150,
    }

    def test_no_file_exceeds_its_budget(self) -> None:
        for relative, limit in self.LIMITS.items():
            path = _ROOT / relative
            with self.subTest(file=relative):
                self.assertLessEqual(
                    len(path.read_text(encoding="utf-8").splitlines()), limit,
                    f"{relative} grew past {limit} lines; split it instead of appending",
                )

    def test_extracted_concerns_have_their_own_files(self) -> None:
        # The cross-border comparisons were duplicated in two guards; they now live once.
        self.assertTrue((CORE / "Storage/ProvenanceValue.swift").is_file())
        self.assertTrue((CORE / "Models/PersistenceState.swift").is_file())


class TestBundleHasOneWorker(unittest.TestCase):
    """P2-02: the app ships exactly one copy of the Python worker."""

    def test_build_script_asserts_single_copy(self) -> None:
        script = (_ROOT / "tools" / "build_macos_app.sh").read_text()
        self.assertIn("expected exactly one bundled worker", script)
        self.assertNotIn('cp -R workers/src "$RESOURCES_DIR/workers/"', script)

    def test_build_scripts_glob_sources(self) -> None:
        script = (_ROOT / "tools" / "build_macos_app.sh").read_text()
        self.assertIn("find packages/AIVideoCore/Sources apps/macos/Sources -name '*.swift'", script)
        # the matrix used to hand-list core files per suite, so a moved file broke every
        # Swift test while the app still compiled
        matrix = (_ROOT / "tools" / "run_tests.sh").read_text()
        self.assertIn("CORE_ALL=$(find", matrix)
        self.assertNotIn("packages/AIVideoCore/Sources/Storage/ProjectStore.swift \\", matrix)

    def test_app_resolves_the_single_supported_path(self) -> None:
        state = (APP / "AppState.swift").read_text()
        self.assertIn('"Workers/aivideo_workers/main.py"', state)
        self.assertNotIn('"workers/src/aivideo_workers/main.py").path\n            if fm.fileExists(atPath: bundledWorker2)',
                         state)


class TestReadsDoNotTakeTheWriterLock(unittest.TestCase):
    """P2-03/P2-05: polling paths use a deferred read transaction."""

    def test_read_transaction_exists_and_is_deferred(self) -> None:
        store = (CORE / "Storage/ProjectStore.swift").read_text()
        start = store.index("private func withReadTransaction")
        segment = store[start:start + 500]
        self.assertIn("BEGIN DEFERRED", segment)
        self.assertNotIn("BEGIN IMMEDIATE", segment)

    def test_current_readers_use_it(self) -> None:
        for relative in ("Storage/G3ProjectStore.swift", "Storage/G4ProjectStore.swift",
                         "Storage/G5ProjectStore.swift"):
            text = (CORE / relative).read_text()
            with self.subTest(file=relative):
                self.assertIn("withCanonicalRead", text)


class TestCrossBorderValues(unittest.TestCase):
    """P2-04: UUID equality and fps parsing are centralised and safe."""

    def _swift(self) -> str:
        return (CORE / "Storage/ProvenanceValue.swift").read_text()

    def test_uuid_comparison_is_case_insensitive(self) -> None:
        self.assertIn("func uuidsMatch", self._swift())
        self.assertIn("UUID(uuidString:", self._swift())

    def test_frame_rate_parser_cannot_trap(self) -> None:
        source = self._swift()
        self.assertIn("omittingEmptySubsequences: false", source)
        self.assertIn("guard !trimmed.isEmpty", source)
        # the trapping pattern must be gone everywhere
        for path in swift_sources():
            with self.subTest(file=path.name):
                self.assertNotIn("Double(parts[0])", path.read_text())

    def test_guards_use_the_shared_helpers(self) -> None:
        for name in ("G4S21Guard.swift", "G5S22Guard.swift"):
            text = (CORE / "Storage" / name).read_text()
            with self.subTest(file=name):
                self.assertIn("ProvenanceValue.is24fps", text)
                self.assertNotIn("private static func frameRate", text)


class TestNoSilentBroadHandlers(unittest.TestCase):
    """P2-06: an `except Exception` must record the error or re-raise."""

    def test_every_broad_handler_is_recorded_or_annotated(self) -> None:
        offenders = []
        triple = chr(34) * 3
        for path in py_sources():
            lines = path.read_text(encoding="utf-8").splitlines()
            in_literal = False
            for index, line in enumerate(lines):
                # A generator script quotes source code inside triple-quoted strings; that
                # text is data for another file, not a handler in this one.
                if line.count(triple) % 2 == 1:
                    in_literal = not in_literal
                    continue
                if in_literal:
                    continue
                if not re.search(r"except Exception", line):
                    continue
                if "noqa: BLE001" in line:
                    continue
                body = "\n".join(lines[index + 1: index + 5])
                if not re.search(r"note_suppressed|log|print|raise|warn|stderr|detail|errors=", body):
                    offenders.append(f"{path.relative_to(_ROOT)}:{index + 1}")
        self.assertEqual(offenders, [], f"silent broad handlers: {offenders}")

    def test_diagnostics_buffer_records_notes(self) -> None:
        from aivideo_workers import diagnostics

        diagnostics.clear_suppressed()
        diagnostics.note_suppressed("test:1", ValueError("boom"))
        notes = diagnostics.suppressed_notes()
        self.assertEqual(len(notes), 1)
        self.assertEqual(notes[0]["error_type"], "ValueError")
        self.assertEqual(notes[0]["context"], "test:1")
        diagnostics.clear_suppressed()


class TestUiStateIsTyped(unittest.TestCase):
    """P2-07: no colour or branch depends on a Vietnamese message prefix."""

    def test_no_status_prefix_matching(self) -> None:
        for path in swift_sources():
            text = path.read_text(encoding="utf-8")
            with self.subTest(file=path.name):
                self.assertNotIn('g1SaveStatus.hasPrefix(', text)
                self.assertNotIn('briefSaveStatus.hasPrefix(', text)

    def test_persistence_state_is_used(self) -> None:
        self.assertIn("PersistenceState", (CORE / "Models/PersistenceState.swift").read_text())
        self.assertIn("briefPersistence", (APP / "ScriptBriefView.swift").read_text())
        self.assertIn("g1Persistence", (APP / "AIVideoApp.swift").read_text())


class TestNoSeedData(unittest.TestCase):
    """P2-08/09/10: no demo content, no fake saved status, no fixed identifiers."""

    def test_no_hardcoded_project_ids(self) -> None:
        state = (APP / "AppState.swift").read_text()
        self.assertNotIn('"00000000-0000-4000-8000-000000000001"', state)
        self.assertNotIn('"00000000-0000-4000-8000-000000000002"', state)
        self.assertIn("installProjectId()", state)

    def test_no_seeded_demo_prompt(self) -> None:
        state = (APP / "AppState.swift").read_text()
        self.assertNotIn("đèo Prenn buổi sáng sớm", state)

    def test_saved_status_requires_a_real_revision(self) -> None:
        state = (APP / "AppState.swift").read_text()
        segment = state[state.index("func initializeG1ProjectStore"):]
        segment = segment[: segment.index("func resolveG2ReviewItemInStore")]
        self.assertIn("proj.currentRevision > 1", segment)


class TestAccessibility(unittest.TestCase):
    """P2-11: labels exist, body text is >= 11pt, no mini hit targets."""

    def test_no_sub_eleven_point_body_text(self) -> None:
        pattern = re.compile(r"\.font\(\.system\(size: (\d+)")
        offenders = []
        for path in swift_sources():
            for line in path.read_text(encoding="utf-8").splitlines():
                match = pattern.search(line)
                if match and int(match.group(1)) < 11:
                    offenders.append(f"{path.name}: {line.strip()}")
        self.assertEqual(offenders, [])

    def test_no_mini_controls(self) -> None:
        for path in swift_sources():
            self.assertNotIn(".controlSize(.mini)", path.read_text(encoding="utf-8"))

    def test_icon_only_buttons_are_labelled(self) -> None:
        text = (APP / "AIVideoApp.swift").read_text()
        self.assertIn('accessibilityLabel("Đóng thông báo")', text)
        self.assertIn('accessibilityLabel("Mở file bằng ứng dụng mặc định")', text)


class TestHistoricalScriptsAreQuarantined(unittest.TestCase):
    """P2-06/P2-12: an already-applied migration is data, not live code."""

    def test_nothing_imports_the_historical_scripts(self) -> None:
        offenders = []
        for root in (WORKERS, _ROOT / "apps", _ROOT / "packages", _ROOT / "tools"):
            for path in root.rglob("*.py"):
                if "historical" in path.parts or "__pycache__" in str(path):
                    continue
                text = path.read_text(encoding="utf-8", errors="ignore")
                if "fix_gate_integrity" in text:
                    offenders.append(str(path.relative_to(_ROOT)))
        self.assertEqual(offenders, [])

    def test_the_quarantine_is_documented(self) -> None:
        readme = (_ROOT / "tools" / "historical" / "README.md").read_text()
        self.assertIn("do not run", readme.lower())


class TestOrphanModuleIsDeclared(unittest.TestCase):
    """P2-12: review_workflow.py must announce that it is not production code."""

    def test_notice_is_present(self) -> None:
        text = (WORKERS / "review_workflow.py").read_text()
        self.assertIn("NOT WIRED INTO PRODUCTION", text)

    def test_no_production_module_imports_it(self) -> None:
        importers = []
        for path in py_sources():
            if path.name == "review_workflow.py":
                continue
            text = path.read_text(encoding="utf-8")
            if re.search(r"import\s+.*review_workflow|from\s+\S*review_workflow", text):
                importers.append(str(path.relative_to(_ROOT)))
        self.assertEqual(importers, [], f"production importers: {importers}")


class TestSingleSchemaSource(unittest.TestCase):
    """P2-13: Swift owns the schema; the SQL file is a test fixture."""

    def test_migration_directory_documents_the_rule(self) -> None:
        readme = (_ROOT / "contracts" / "migrations" / "README.md").read_text()
        self.assertIn("Swift is the only writer and the only schema owner", readme)

    def test_fixture_tables_exist_in_the_runtime_schema(self) -> None:
        fixture = (_ROOT / "contracts/migrations/fixtures/g1_schema_fixture.sql").read_text()
        fixture_tables = set(re.findall(r"CREATE TABLE (?:IF NOT EXISTS )?(\w+)", fixture))
        runtime = "".join(
            p.read_text() for p in (CORE / "Storage").glob("*.swift")
        )
        runtime_tables = set(re.findall(r"CREATE TABLE IF NOT EXISTS (\w+)", runtime))
        self.assertTrue(fixture_tables)
        self.assertEqual(sorted(fixture_tables - runtime_tables), [])

    def test_no_production_code_reads_the_fixture(self) -> None:
        users = []
        for path in py_sources():
            text = path.read_text(encoding="utf-8")
            if "g1_schema_fixture.sql" in text or "001_initial_g1_schema.sql" in text:
                if "tests" not in str(path):
                    users.append(str(path.relative_to(_ROOT)))
        self.assertEqual(users, [], f"production users of the fixture: {users}")


class TestDocsCannotDrift(unittest.TestCase):
    """P2-14: the duplicated root docs stay identical; the summary is not a stale claim."""

    DUPLICATES = ("README.md", "01-PRODUCT.md", "02-ANALYSIS-AND-DATA.md")

    def test_root_copies_match_docs(self) -> None:
        for name in self.DUPLICATES:
            root = _ROOT / name
            under = _ROOT / "docs" / name
            with self.subTest(file=name):
                self.assertEqual(root.read_bytes(), under.read_bytes(),
                                 f"{name} drifted from docs/{name}")

    def test_review_summary_points_at_the_report(self) -> None:
        text = (_ROOT / "REVIEW_SUMMARY.md").read_text()
        self.assertIn("python_test_summary.json", text)
        # The old hand-written count must not survive as a current claim. It may only appear
        # inside the historical banner that says it is out of date.
        current_lines = [
            line for line in text.splitlines()
            if "189 PASS" in line and "lần chạy cũ" not in line
        ]
        self.assertEqual(current_lines, [], "stale hand-written pass count is still claimed")


if __name__ == "__main__":
    unittest.main()
