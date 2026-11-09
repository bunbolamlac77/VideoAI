import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class BridgeLauncherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.tmp_path = Path(self.tmp.name)

        # Mock project
        self.project = self.tmp_path / "project"
        self.project.mkdir()
        (self.project / "PROGRESS_TRACKER.md").write_text("# Progress\n", encoding="utf-8")

        # Copy launcher
        self.repo_root = Path(__file__).resolve().parents[3]
        self.launcher_src = self.repo_root / "run_aivideo_bridge.sh"
        self.launcher = self.project / "run_aivideo_bridge.sh"
        shutil.copy2(self.launcher_src, self.launcher)
        self.launcher.chmod(0o755)

        # Mock runner
        self.bridge_dir = self.tmp_path / "bridge"
        self.bridge_dir.mkdir()
        self.runner = self.bridge_dir / "bridge_runner.py"
        self.log = self.tmp_path / "runner.log"

        runner_code = f"""#!/usr/bin/env python3
import sys, os

if "--help" in sys.argv:
    print('''
usage: bridge_runner.py [--project-dir PROJECT_DIR] [--goal GOAL]
                        [--test-cmd TEST_CMD] [--mode {{direct,hybrid}}]
                        [--max-rounds MAX_ROUNDS] [--cooldown COOLDOWN]
                        [--auto-push]
''')
    sys.exit(0)

log_file = os.environ.get("MOCK_LOG", "{self.log}")
with open(log_file, "a", encoding="utf-8") as f:
    for arg in sys.argv[1:]:
        f.write(arg + "\\n")
sys.exit(0)
"""
        self.runner.write_text(runner_code, encoding="utf-8")
        self.runner.chmod(0o755)

    def launch(self, *args, project_dir: Path | None = None, **env_vars) -> subprocess.CompletedProcess:
        target_dir = project_dir or self.project
        launcher = target_dir / "run_aivideo_bridge.sh"
        if self.log.exists():
            self.log.unlink()
        env = os.environ.copy()
        env["AIVIDEO_BRIDGE_DIR"] = str(self.bridge_dir)
        env["AIVIDEO_OPEN_CHATGPT"] = "0"
        env["MOCK_LOG"] = str(self.log)
        for k, v in env_vars.items():
            env[k] = v
        return subprocess.run(
            [str(launcher), *args],
            cwd=str(target_dir),
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )

    def get_args(self) -> list[str]:
        if not self.log.exists():
            return []
        return self.log.read_text(encoding="utf-8").splitlines()

    def test_spaces_in_project_path(self) -> None:
        space_project = self.tmp_path / "project with spaces"
        space_project.mkdir()
        (space_project / "PROGRESS_TRACKER.md").write_text("# Progress\n", encoding="utf-8")
        space_launcher = space_project / "run_aivideo_bridge.sh"
        shutil.copy2(self.launcher_src, space_launcher)
        space_launcher.chmod(0o755)

        result = self.launch(project_dir=space_project)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.get_args()
        self.assertIn("--project-dir", args)
        idx = args.index("--project-dir")
        self.assertEqual(args[idx + 1], str(space_project.resolve()))

    def test_vietnamese_parameters_passed_cleanly(self) -> None:
        goal = "Sửa lỗi các bài test và hoàn thiện mã nguồn theo checklist PROGRESS_TRACKER.md"
        test_cmd = "python3 tools/run_python_tests.py"
        result = self.launch(goal, test_cmd)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.get_args()
        self.assertIn(goal, args)
        self.assertIn(test_cmd, args)

    def test_hybrid_mode_supported(self) -> None:
        result = self.launch("goal", "test", "hybrid")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.get_args()
        self.assertIn("--mode", args)
        idx = args.index("--mode")
        self.assertEqual(args[idx + 1], "hybrid")

    def test_missing_runner_fails_closed(self) -> None:
        result = self.launch(AIVIDEO_BRIDGE_DIR=str(self.tmp_path / "nonexistent"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Thiếu runner", result.stderr)
        self.assertFalse(self.log.exists())

    def test_invalid_mode_rejected(self) -> None:
        result = self.launch("goal", "test", "auto")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Mode không hợp lệ", result.stderr)
        self.assertFalse(self.log.exists())

    def test_push_opt_in_and_dry_run_do_not_execute(self) -> None:
        result = self.launch(
            AIVIDEO_AUTO_PUSH="1",
            AIVIDEO_DRY_RUN="1",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--auto-push", result.stdout)
        self.assertFalse(self.log.exists())

        result = self.launch(AIVIDEO_AUTO_PUSH="1")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--auto-push", self.get_args())

    def test_invalid_rounds_cooldown_fail_closed(self) -> None:
        for setting, value in [
            ("AIVIDEO_MAX_ROUNDS", "0"),
            ("AIVIDEO_COOLDOWN", "1; rm -rf ~"),
        ]:
            with self.subTest(setting=setting):
                result = self.launch(**{setting: value})

                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.log.exists())

    def test_missing_progress_tracker_fails_closed(self) -> None:
        (self.project / "PROGRESS_TRACKER.md").unlink()

        result = self.launch()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PROGRESS_TRACKER", result.stderr)


if __name__ == "__main__":
    unittest.main()
