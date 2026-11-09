#!/usr/bin/env python3
"""S05 isolated full-copy source snapshots (stdlib only).

This is a persistence primitive, not a ProjectStore commit or a media decoder.
Only a DB transaction with verified revision/authority can mark an asset ready.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile
import uuid
from datetime import datetime, timezone

CHUNK_BYTES = 1024 * 1024
MAX_MANIFEST_BYTES = 64 * 1024
MEDIA_EXTENSIONS = frozenset({".mov", ".mp4", ".m4v", ".jpg", ".jpeg", ".heic", ".png"})
DIGEST_RE = re.compile(r"^[a-f0-9]{64}$")
MANIFEST_RE = re.compile(r"^manifests/[a-f0-9]{32}\.json$")


class SnapshotError(Exception):
    """An import was rejected; the original file is never modified."""


class SourceChangedError(SnapshotError):
    """The source identity or contents changed during acquisition."""


class InsufficientSpaceError(SnapshotError):
    """Preflight detected insufficient space for a full copy."""


class SnapshotIntegrityError(SnapshotError):
    """A sealed blob/manifest did not verify."""


def _directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise SnapshotError(f"Unsafe snapshot directory: {path}")
    if info.st_mode & stat.S_IWOTH:
        raise SnapshotError(f"World-writable snapshot directory: {path}")


def _fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    fd = os.open(str(path), flags)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _open_regular_nofollow(path: Path) -> int:
    if not hasattr(os, "O_NOFOLLOW"):
        raise SnapshotError("O_NOFOLLOW is required to reject symlink races")
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise SnapshotError(f"Not a regular file: {path}")
    return fd


def _identity(info: os.stat_result) -> tuple:
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _hash_fd(fd: int) -> tuple[str, int]:
    os.lseek(fd, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    n = 0
    while True:
        chunk = os.read(fd, CHUNK_BYTES)
        if not chunk:
            return digest.hexdigest(), n
        digest.update(chunk)
        n += len(chunk)


def _hash_file(path: Path) -> tuple[str, int]:
    fd = _open_regular_nofollow(path)
    try:
        return _hash_fd(fd)
    finally:
        os.close(fd)


def _check_existing_blob(path: Path, sha256: str, size: int) -> None:
    actual_hash, actual_size = _hash_file(path)
    if actual_size != size or actual_hash != sha256:
        raise SnapshotIntegrityError(f"Existing content-addressed blob is corrupted: {path}")


def _invoke(hook, name: str) -> None:
    if hook is not None:
        hook(name)


def scan_candidates(source_dir) -> list[dict]:
    """Scan potential media without decoding, modifying, or trusting it.

    Candidates are NOT validated media and are never marked ready here.
    Symlink entries are reported as errors rather than silently followed.
    """
    root = Path(source_dir).expanduser().absolute()
    try:
        info = root.lstat()
    except OSError as exc:
        raise SnapshotError(f"Cannot inspect source directory: {exc}") from exc
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise SnapshotError("Source root must be a real directory")
    items = []
    for current, dirs, filenames in os.walk(root, followlinks=False):
        dirs[:] = sorted(
            name for name in dirs
            if not name.startswith(".") and not (Path(current) / name).is_symlink()
        )
        for name in sorted(filenames):
            extension = Path(name).suffix.casefold()
            if name.startswith(".") or extension not in MEDIA_EXTENSIONS:
                continue
            file_path = Path(current) / name
            try:
                info = file_path.lstat()
                if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
                    raise SnapshotError("Not a regular non-symlink source file")
                items.append({
                    "path": str(file_path),
                    "extension": extension,
                    "byte_size": info.st_size,
                    "status": "CANDIDATE",
                })
            except (OSError, SnapshotError) as exc:
                items.append({"path": str(file_path), "status": "ERROR", "error": str(exc)})
    return items


def import_snapshot(source, store_root, *, reserve_bytes=0, fault_hook=None) -> dict:
    """Full-copy into an immutable-by-convention content-addressed blob.

    Failure before manifest publication never creates a ready manifest. Any
    orphan blob is safe to audit, but must NOT be deleted without a store lock.
    A full copy is intentional: APFS clone use needs separate capability tests.
    """
    if not isinstance(reserve_bytes, int) or reserve_bytes < 0:
        raise ValueError("reserve_bytes must be a non-negative integer")

    original = Path(source).expanduser().absolute()
    root = Path(store_root).expanduser().absolute()
    _directory(root)
    staging = root / ".staging"
    manifests = root / "manifests"
    blobs = root / "blobs"
    for folder in (staging, manifests, blobs):
        _directory(folder)
    # Directory creation itself must be flushed before a manifest can refer
    # to descendants (on filesystems supporting directory fsync).
    _fsync_directory(root)

    source_fd = _open_regular_nofollow(original)
    staged_path = None
    try:
        before = os.fstat(source_fd)
        if before.st_size < 0:
            raise SnapshotError("Invalid source size")
        # Reserve space for a full-copy (not a hardlink), manifest, and margin.
        overhead = max(CHUNK_BYTES, before.st_size // 100)
        required = before.st_size + overhead + reserve_bytes
        available = shutil.disk_usage(root).free
        if available < required:
            raise InsufficientSpaceError(
                f"Full copy needs {required} bytes, only {available} available"
            )

        _invoke(fault_hook, "before_copy")
        fd, temp_name = tempfile.mkstemp(prefix=".incoming-", dir=str(staging))
        staged_path = Path(temp_name)
        digest = hashlib.sha256()
        total = 0
        try:
            os.lseek(source_fd, 0, os.SEEK_SET)
            with os.fdopen(fd, "wb") as out:
                while True:
                    part = os.read(source_fd, CHUNK_BYTES)
                    if not part:
                        break
                    out.write(part)
                    digest.update(part)
                    total += len(part)
                out.flush()
                os.fsync(out.fileno())
        except BaseException:
            # fdopen owns the descriptor after successful construction.
            raise
        _invoke(fault_hook, "after_copy")

        expected_hash = digest.hexdigest()
        staged_hash, staged_size = _hash_file(staged_path)
        again_hash, again_size = _hash_fd(source_fd)
        after = os.fstat(source_fd)
        try:
            pathname_info = original.lstat()
        except FileNotFoundError as exc:
            raise SourceChangedError("Source path disappeared during acquisition") from exc
        if (
            _identity(before) != _identity(after)
            or (pathname_info.st_dev, pathname_info.st_ino) != (before.st_dev, before.st_ino)
            or total != before.st_size
            or staged_size != total
            or again_size != total
            or staged_hash != expected_hash
            or again_hash != expected_hash
        ):
            raise SourceChangedError("Source changed, or copied bytes did not match")

        prefix = blobs / expected_hash[:2]
        _directory(prefix)
        _fsync_directory(blobs)
        blob = prefix / expected_hash
        rel_blob = blob.relative_to(root).as_posix()
        os.chmod(staged_path, 0o400)
        _invoke(fault_hook, "before_blob_publish")
        try:
            # link is an atomic NO-REPLACE publication from owned staging.
            # This never hardlinks the ORIGINAL; staging is unlinked below.
            os.link(str(staged_path), str(blob), follow_symlinks=False)
            _fsync_directory(prefix)
        except FileExistsError:
            _check_existing_blob(blob, expected_hash, total)
        finally:
            staged_path.unlink(missing_ok=True)
            staged_path = None
        _check_existing_blob(blob, expected_hash, total)
        _invoke(fault_hook, "after_blob_publish")

        snapshot_id = uuid.uuid4().hex
        rel_manifest = f"manifests/{snapshot_id}.json"
        receipt = {
            "schema_version": 1,
            "snapshot_id": snapshot_id,
            "manifest_relpath": rel_manifest,
            "snapshot_relpath": rel_blob,
            "source_path": str(original),
            "source_identity": {
                "device": before.st_dev,
                "inode": before.st_ino,
                "mtime_ns": before.st_mtime_ns,
                "size": before.st_size,
            },
            "sha256": expected_hash,
            "byte_size": total,
            "copy_mode": "full_copy",
            "integrity_status": "VERIFIED",
            "projectstore_committed": False,
            "acquired_at": datetime.now(timezone.utc).isoformat(),
        }
        # A manifest advertises verified bytes only, NOT a committed DB asset.
        _invoke(fault_hook, "before_manifest_publish")
        metadata_fd, metadata_temp = tempfile.mkstemp(prefix=".manifest-", dir=str(manifests))
        try:
            with os.fdopen(metadata_fd, "w", encoding="utf-8") as out:
                json.dump(receipt, out, ensure_ascii=False, sort_keys=True)
                out.write("\n")
                out.flush()
                os.fsync(out.fileno())
            os.chmod(metadata_temp, 0o400)
            os.link(metadata_temp, str(root / rel_manifest), follow_symlinks=False)
            _fsync_directory(manifests)
        finally:
            Path(metadata_temp).unlink(missing_ok=True)
        return receipt
    finally:
        os.close(source_fd)
        if staged_path is not None:
            staged_path.unlink(missing_ok=True)


def verify_manifest(store_root, manifest_relpath: str) -> dict:
    """Verify an untrusted manifest path, schema, content hash, and size."""
    if not isinstance(manifest_relpath, str) or not MANIFEST_RE.fullmatch(manifest_relpath):
        raise SnapshotIntegrityError("Invalid manifest relative path")
    root = Path(store_root).expanduser().absolute()
    path = root / manifest_relpath
    try:
        fd = _open_regular_nofollow(path)
        if os.fstat(fd).st_size > MAX_MANIFEST_BYTES:
            os.close(fd)
            raise SnapshotIntegrityError("Manifest exceeds safe size limit")
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            receipt = json.load(stream)
        sha256 = receipt.get("sha256")
        size = receipt.get("byte_size")
        if (
            type(receipt.get("schema_version")) is not int
            or receipt.get("schema_version") != 1
            or not isinstance(sha256, str)
            or not DIGEST_RE.fullmatch(sha256)
            or type(size) is not int
            or size < 0
            or receipt.get("manifest_relpath") != manifest_relpath
            or receipt.get("snapshot_id") != Path(manifest_relpath).stem
            or receipt.get("snapshot_relpath") != f"blobs/{sha256[:2]}/{sha256}"
            or receipt.get("copy_mode") != "full_copy"
            or receipt.get("integrity_status") != "VERIFIED"
            or receipt.get("projectstore_committed") is not False
        ):
            raise SnapshotIntegrityError("Manifest schema/integrity invariants invalid")
        _check_existing_blob(root / receipt["snapshot_relpath"], sha256, size)
        return receipt
    except (OSError, ValueError, TypeError, AttributeError, KeyError) as exc:
        raise SnapshotIntegrityError(f"Cannot verify manifest: {exc}") from exc


def list_orphan_blobs(store_root) -> list[str]:
    """Audit only. Do not delete without a process/store writer lock."""
    root = Path(store_root).expanduser().absolute()
    manifests_dir = root / "manifests"
    blobs_dir = root / "blobs"
    references = set()
    if manifests_dir.exists():
        for path in manifests_dir.glob("*.json"):
            receipt = verify_manifest(root, f"manifests/{path.name}")
            references.add(receipt["snapshot_relpath"])
    unreferenced = []
    if blobs_dir.exists():
        for path in blobs_dir.glob("*/*"):
            relative = path.relative_to(root).as_posix()
            if not DIGEST_RE.fullmatch(path.name) or path.parent.name != path.name[:2]:
                raise SnapshotIntegrityError(f"Unexpected blob path: {path}")
            if relative not in references:
                # Orphans are NOT necessarily safe to collect: a concurrent
                # import may still be publishing its manifest.
                unreferenced.append(relative)
    return sorted(unreferenced)
