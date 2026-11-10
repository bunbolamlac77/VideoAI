"""
tests/test_model_installation.py — one definition of "model installed" (D14).

Covers the states that used to disagree between the worker file-presence check and
the release preflight manifest check.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile

import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from aivideo_workers.model_installation import (
    INSTALL_MANIFEST,
    REQUIRED_ARTIFACTS,
    inspect_model_installation,
)


def _write_artifacts(root: Path, payload: bytes = b"weights") -> Path:
    directory = root / "visual_analysis_primary"
    directory.mkdir(parents=True)
    for index, name in enumerate(REQUIRED_ARTIFACTS):
        (directory / name).write_bytes(payload + bytes([index]))
    return directory


def _write_manifest(directory: Path, *, corrupt_size: bool = False, corrupt_hash: bool = False) -> None:
    import hashlib

    files = {}
    for name in REQUIRED_ARTIFACTS:
        path = directory / name
        files[name] = {
            "size_bytes": path.stat().st_size + (1 if corrupt_size else 0),
            "sha256": ("0" * 64) if corrupt_hash else hashlib.sha256(path.read_bytes()).hexdigest(),
        }
    manifest = {
        "schema": "aivideo-s11-install-v2",
        "model_id": "mlx-community/Qwen3-VL-4B-Instruct-4bit",
        "revision": "rev-test",
        "files": files,
    }
    (directory / INSTALL_MANIFEST).write_text(json.dumps(manifest), encoding="utf-8")


class TestModelInstallationStates(unittest.TestCase):
    def test_missing_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            status = inspect_model_installation(tmp)
        self.assertEqual(status["state"], "missing")
        self.assertFalse(status["verified"])

    def test_incomplete_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            directory = root / "visual_analysis_primary"
            directory.mkdir(parents=True)
            (directory / "config.json").write_bytes(b"{}")
            status = inspect_model_installation(root)
        self.assertEqual(status["state"], "incomplete")
        self.assertIn("model.safetensors", status["reason"])

    def test_present_without_manifest_is_unverified(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_artifacts(root)
            status = inspect_model_installation(root)
        self.assertEqual(status["state"], "present_unverified")
        self.assertFalse(status["verified"])

    def test_shallow_size_mismatch_is_unverified(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            directory = _write_artifacts(root)
            _write_manifest(directory, corrupt_size=True)
            status = inspect_model_installation(root)
        self.assertEqual(status["state"], "present_unverified")
        self.assertIn("SIZE_MISMATCH", status["reason"])

    def test_deep_hash_mismatch_is_unverified(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            directory = _write_artifacts(root)
            _write_manifest(directory, corrupt_hash=True)
            status = inspect_model_installation(root, deep=True)
        self.assertEqual(status["state"], "present_unverified")
        self.assertIn("HASH_MISMATCH", status["reason"])

    def test_matching_manifest_verifies_shallow_and_deep(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            directory = _write_artifacts(root)
            _write_manifest(directory)
            shallow = inspect_model_installation(root)
            deep = inspect_model_installation(root, deep=True)
        self.assertEqual(shallow["state"], "verified")
        self.assertEqual(deep["state"], "verified")
        self.assertEqual(deep["revision"], "rev-test")


if __name__ == "__main__":
    unittest.main()
