#!/usr/bin/env python3
"""S05 snapshot fault injection and integrity invariants."""

import errno
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from tools.s05_snapshot import (
    InsufficientSpaceError,
    SnapshotError,
    SnapshotIntegrityError,
    SourceChangedError,
    import_snapshot,
    list_orphan_blobs,
    scan_candidates,
    verify_manifest,
)


class TestS05Snapshots(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / "nguồn 🎬.mov"
        self.store = self.base / "store"
        self.original_bytes = b"AIVideo-S05-test" * 4096
        self.source.write_bytes(self.original_bytes)

    def import_one(self, **kwargs):
        return import_snapshot(self.source, self.store, **kwargs)

    def manifests(self):
        return list((self.store / "manifests").glob("*.json"))

    def staging(self):
        return list((self.store / ".staging").glob("*"))

    def test_scan_candidates_preserves_unicode_and_ignores_other_files(self):
        nested = self.base / "nested"
        nested.mkdir()
        (nested / "BỈNH.HEIC").write_bytes(b"fake media candidate")
        (nested / "notes.txt").write_text("no scan", encoding="utf-8")
        candidates = scan_candidates(self.base)
        paths = [Path(x["path"]).name for x in candidates]
        self.assertIn("nguồn 🎬.mov", paths)
        self.assertIn("BỈNH.HEIC", paths)
        self.assertNotIn("notes.txt", paths)
        self.assertTrue(all(x["status"] == "CANDIDATE" for x in candidates))

    def test_scan_symlink_file_is_reported_as_error(self):
        (self.base / "other.mp4").symlink_to(self.source)
        entries = scan_candidates(self.base)
        error = [x for x in entries if x["path"].endswith("other.mp4")]
        self.assertEqual(len(error), 1)
        self.assertEqual(error[0]["status"], "ERROR")

    def test_snapshot_preserves_original_and_verifies_content(self):
        from hashlib import sha256
        before = sha256(self.source.read_bytes()).hexdigest()
        result = self.import_one()
        self.assertEqual(result["sha256"], before)
        self.assertEqual(sha256(self.source.read_bytes()).hexdigest(), before)
        self.assertEqual(result["byte_size"], len(self.original_bytes))
        self.assertEqual(result["projectstore_committed"], False)
        self.assertEqual(verify_manifest(self.store, result["manifest_relpath"]), result)
        self.assertEqual((self.store / result["snapshot_relpath"]).read_bytes(), self.original_bytes)
        self.assertEqual(self.staging(), [])

    def test_large_file_is_copied_in_chunks(self):
        self.source.write_bytes(b"A" * (3 * 1024 * 1024 + 17))
        result = self.import_one()
        self.assertEqual(result["byte_size"], 3 * 1024 * 1024 + 17)
        self.assertEqual((self.store / result["snapshot_relpath"]).stat().st_size,
                         result["byte_size"])
        verify_manifest(self.store, result["manifest_relpath"])

    def test_original_changed_after_seal_does_not_change_blob(self):
        result = self.import_one()
        self.source.write_bytes(b"new source content")
        self.assertEqual((self.store / result["snapshot_relpath"]).read_bytes(), self.original_bytes)
        verify_manifest(self.store, result["manifest_relpath"])

    def test_modified_source_during_acquisition_rejected(self):
        def modify(stage):
            if stage == "after_copy":
                self.source.write_bytes(b"Z" * len(self.original_bytes))

        with self.assertRaises(SourceChangedError):
            self.import_one(fault_hook=modify)
        self.assertEqual(self.manifests(), [])
        self.assertEqual(self.staging(), [])

    def test_path_replacement_during_acquisition_rejected(self):
        def replace(stage):
            if stage == "after_copy":
                old = self.base / "original-renamed.mov"
                self.source.rename(old)
                self.source.write_bytes(self.original_bytes)

        with self.assertRaises(SourceChangedError):
            self.import_one(fault_hook=replace)
        self.assertEqual(self.manifests(), [])
        self.assertEqual(self.staging(), [])

    def test_enospc_before_publish_never_publishes_manifest(self):
        def fail(stage):
            if stage == "after_copy":
                raise OSError(errno.ENOSPC, "disk full")

        with self.assertRaises(OSError):
            self.import_one(fault_hook=fail)
        self.assertEqual(self.manifests(), [])
        self.assertEqual(self.staging(), [])

    def test_preflight_fails_closed_when_insufficient_space(self):
        usage = shutil._ntuple_diskusage(total=1000, used=1000, free=0)
        with patch("tools.s05_snapshot.shutil.disk_usage", return_value=usage):
            with self.assertRaises(InsufficientSpaceError):
                self.import_one()
        self.assertEqual(self.manifests(), [])
        self.assertEqual(self.staging(), [])

    def test_orphan_after_blob_publish_is_auditable_but_not_ready(self):
        def fail(stage):
            if stage == "after_blob_publish":
                raise RuntimeError("simulated process interruption")

        with self.assertRaises(RuntimeError):
            self.import_one(fault_hook=fail)
        self.assertEqual(self.manifests(), [])
        self.assertEqual(len(list_orphan_blobs(self.store)), 1)
        self.assertEqual(self.staging(), [])

    def test_deduplicate_identical_content_but_keep_revisions(self):
        first = self.import_one()
        second_source = self.base / "different-name.mp4"
        second_source.write_bytes(self.original_bytes)
        second = import_snapshot(second_source, self.store)
        self.assertEqual(first["snapshot_relpath"], second["snapshot_relpath"])
        self.assertNotEqual(first["manifest_relpath"], second["manifest_relpath"])
        self.assertEqual(len(self.manifests()), 2)
        self.assertEqual(list_orphan_blobs(self.store), [])

    def test_corrupted_existing_blob_is_not_overwritten(self):
        first = self.import_one()
        blob = self.store / first["snapshot_relpath"]
        blob.chmod(0o600)
        blob.write_bytes(b"corrupt")
        with self.assertRaises(SnapshotIntegrityError):
            self.import_one()
        self.assertEqual(blob.read_bytes(), b"corrupt")
        self.assertEqual(len(self.manifests()), 1)
        with self.assertRaises(SnapshotIntegrityError):
            verify_manifest(self.store, first["manifest_relpath"])

    def test_symlink_source_is_rejected(self):
        alias = self.base / "symlink.mov"
        alias.symlink_to(self.source)
        with self.assertRaises(OSError):
            import_snapshot(alias, self.store)
        self.assertEqual(self.manifests(), [])

    def test_manifest_traversal_rejected(self):
        result = self.import_one()
        with self.assertRaises(SnapshotIntegrityError):
            verify_manifest(self.store, "../../secrets.json")
        path = self.store / result["manifest_relpath"]
        path.chmod(0o600)
        data = json.loads(path.read_text(encoding="utf-8"))
        data["snapshot_relpath"] = "../../secrets.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaises(SnapshotIntegrityError):
            verify_manifest(self.store, result["manifest_relpath"])

    def test_fault_before_manifest_publish_keeps_only_orphan(self):
        def fail(stage):
            if stage == "before_manifest_publish":
                raise RuntimeError("fail before publishing metadata")

        with self.assertRaises(RuntimeError):
            self.import_one(fault_hook=fail)
        self.assertEqual(self.manifests(), [])
        self.assertEqual(len(list_orphan_blobs(self.store)), 1)
        self.assertEqual(self.staging(), [])

    def test_non_regular_file_rejected(self):
        with self.assertRaises(SnapshotError):
            import_snapshot(self.base, self.store)
        self.assertEqual(self.manifests(), [])


if __name__ == "__main__":
    unittest.main()
