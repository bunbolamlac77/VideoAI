"""
tests/test_source_hygiene.py — Wave E guards for handoff readiness.

Catches three regressions that made the project host-specific or made CI look
greener than it was:
  * absolute home-directory paths in shipped source;
  * AIVideoApp.swift growing back into a god file;
  * CI falling back to syntax-only checks instead of building and testing.
"""

from __future__ import annotations

from pathlib import Path
import unittest

_ROOT = Path(__file__).resolve().parents[1]
_SCAN_DIRS = ("apps", "packages", "workers/src", "tools", "tests")
_SUFFIXES = {".swift", ".py", ".sh", ".yml", ".yaml"}


def _iter_sources():
    for directory in _SCAN_DIRS:
        for path in (_ROOT / directory).rglob("*"):
            if path.is_file() and path.suffix in _SUFFIXES:
                yield path


class TestHostPathHygiene(unittest.TestCase):
    def test_no_absolute_user_paths_in_source(self) -> None:
        # Built dynamically so this guard does not flag its own source.
        needle = "/" + "Users/"
        offenders = []
        for path in _iter_sources():
            text = path.read_text(encoding="utf-8", errors="replace")
            if needle in text:
                offenders.append(str(path.relative_to(_ROOT)))
        self.assertEqual(offenders, [], f"hard-coded home paths: {offenders}")

    def test_contract_environment_matrix_is_portable(self) -> None:
        text = (_ROOT / "contracts" / "environment_matrix.json").read_text(encoding="utf-8")
        self.assertNotIn("/" + "Users/", text)


class TestAppStructure(unittest.TestCase):
    def test_app_state_is_its_own_file(self) -> None:
        app_state = _ROOT / "apps" / "macos" / "Sources" / "AppState.swift"
        self.assertTrue(app_state.is_file(), "AppState.swift must own the observable state")
        self.assertIn("final class AppState", app_state.read_text(encoding="utf-8"))

    def test_app_shell_and_state_stay_reviewable(self) -> None:
        app_lines = len((_ROOT / "apps" / "macos" / "Sources" / "AIVideoApp.swift").read_text(encoding="utf-8").splitlines())
        state_lines = len((_ROOT / "apps" / "macos" / "Sources" / "AppState.swift").read_text(encoding="utf-8").splitlines())
        self.assertLess(app_lines, 1700, f"AIVideoApp.swift grew back to {app_lines} lines")
        self.assertLess(state_lines, 1400, f"AppState.swift grew to {state_lines} lines")

    def test_prefilter_toggle_is_wired(self) -> None:
        app_state = (_ROOT / "apps" / "macos" / "Sources" / "AppState.swift").read_text(encoding="utf-8")
        self.assertIn("prefilterEnabled", app_state)
        app = (_ROOT / "apps" / "macos" / "Sources" / "AIVideoApp.swift").read_text(encoding="utf-8")
        self.assertIn("$state.prefilterEnabled", app)


class TestCIContract(unittest.TestCase):
    def test_ci_builds_the_app_and_runs_the_full_matrix(self) -> None:
        workflow = (_ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        self.assertIn("tools/build_macos_app.sh", workflow)
        self.assertIn("tools/run_tests.sh", workflow)
        self.assertIn("AIVIDEO_PYTHON", workflow)
        self.assertIn("warning:", workflow)


if __name__ == "__main__":
    unittest.main()
