#!/usr/bin/env python3
"""Install and verify pinned S11 Qwen3-VL model without exposing partial installs.

Only --install downloads. --verify/--plan are local-only. Installation is
staged on the target filesystem, guarded by an advisory lock, checked against
the upstream weight SHA-256, then published. Failed downloads NEVER destroy an
existing install. --force requires the operator to close running model users.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import time
import uuid

S11_ROLE = "visual_analysis_primary"
S11_MODEL_ID = "mlx-community/Qwen3-VL-4B-Instruct-4bit"
S11_REVISION = "2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b"
# Published for the same revision on Hugging Face's model.safetensors page.
S11_PINNED_WEIGHTS_SHA256 = "90eeb02604181dbcccd0a30a1f550a4a8928ca7dcbee4aee1449239306cfdfca"
MIN_WEIGHTS_SIZE_BYTES = 1_000_000_000
REQUIRED_DISK_FREE_BYTES = 4 * 1024 ** 3
INSTALL_MANIFEST = ".aivideo-install-manifest.json"
REQUIRED_FILES = (
    "config.json", "model.safetensors", "model.safetensors.index.json",
    "preprocessor_config.json", "tokenizer.json", "tokenizer_config.json",
    "vocab.json", "merges.txt", "chat_template.json",
    "special_tokens_map.json",
)


class ModelValidationError(RuntimeError):
    pass


def get_models_root() -> Path:
    custom = os.environ.get("AIVIDEO_MODELS_ROOT")
    return Path(custom).expanduser().resolve() if custom else (
        Path.home() / "Library" / "Application Support" / "AIVideo" / "Models"
    )


def get_target_dir() -> Path:
    return get_models_root() / S11_ROLE


def _read_regular_file(path: Path):
    if path.is_symlink():
        raise ModelValidationError(f"Symlink not permitted: {path}")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise ModelValidationError(f"Not a regular file: {path}")
    return os.fdopen(fd, "rb")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with _read_regular_file(path) as src:
        for chunk in iter(lambda: src.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_safetensors(path: Path) -> tuple[bool, str]:
    """Validate header/offset ranges; SHA-256 pin provides actual provenance."""
    try:
        size = path.stat().st_size
        if size < MIN_WEIGHTS_SIZE_BYTES:
            return False, f"Weights too small ({size} bytes)"
        with _read_regular_file(path) as src:
            raw_len = src.read(8)
            if len(raw_len) != 8:
                return False, "Missing safetensors header length"
            header_size = int.from_bytes(raw_len, "little")
            if header_size <= 0 or header_size > min(16 * 1024 * 1024, size - 8):
                return False, "Invalid or excessive safetensors header size"
            header = json.loads(src.read(header_size).decode("utf-8"))
        if not isinstance(header, dict):
            return False, "Safetensors header must be a JSON object"
        tensors = [(k, v) for k, v in header.items() if k != "__metadata__"]
        if not tensors:
            return False, "Safetensors header has no tensors"
        for name, tensor in tensors:
            if not isinstance(tensor, dict) or not isinstance(tensor.get("data_offsets"), list):
                return False, f"Bad tensor descriptor: {name}"
            offsets = tensor["data_offsets"]
            if (len(offsets) != 2 or any(type(n) is not int for n in offsets)
                    or not 0 <= offsets[0] <= offsets[1] <= size - 8 - header_size):
                return False, f"Bad tensor offsets: {name}"
        return True, f"Valid safetensors header ({size:,} bytes)"
    except (OSError, ValueError, TypeError, UnicodeError, ModelValidationError) as exc:
        return False, str(exc)


def _verify_required_files(directory: Path, *, enforce_pinned_sha: bool) -> dict:
    if directory.is_symlink() or not directory.is_dir():
        raise ModelValidationError(f"Model directory absent or symlink: {directory}")
    hashes = {}
    for name in REQUIRED_FILES:
        path = directory / name
        if not path.is_file() or path.is_symlink() or path.stat().st_size <= 0:
            raise ModelValidationError(f"Missing/empty/symlink artifact: {name}")
        hashes[name] = {"size_bytes": path.stat().st_size, "sha256": sha256_file(path)}
    okay, reason = verify_safetensors(directory / "model.safetensors")
    if not okay:
        raise ModelValidationError(reason)
    if enforce_pinned_sha and hashes["model.safetensors"]["sha256"] != S11_PINNED_WEIGHTS_SHA256:
        raise ModelValidationError("PINNED_WEIGHT_SHA256_MISMATCH: model.safetensors differs from pinned revision")
    return hashes


def build_manifest(directory: Path) -> dict:
    return {
        "schema": "aivideo-s11-install-v2",
        "model_id": S11_MODEL_ID,
        "revision": S11_REVISION,
        "pinned_weights_sha256": S11_PINNED_WEIGHTS_SHA256,
        "files": _verify_required_files(directory, enforce_pinned_sha=True),
    }


def verify_model_directory(directory: Path, *, require_manifest: bool = True) -> dict:
    """Release-safe verifier: pinned upstream weights + locally recorded file hashes."""
    hashes = _verify_required_files(directory, enforce_pinned_sha=True)
    manifest_path = directory / INSTALL_MANIFEST
    if require_manifest:
        if manifest_path.is_symlink() or not manifest_path.is_file():
            raise ModelValidationError("INSTALL_MANIFEST_MISSING: reinstall with --install --force")
        try:
            with _read_regular_file(manifest_path) as src:
                manifest = json.load(src)
        except (OSError, ValueError, TypeError) as exc:
            raise ModelValidationError(f"Invalid installation manifest: {exc}") from exc
        if not isinstance(manifest, dict):
            raise ModelValidationError("Installation manifest must be a JSON object")
        if (manifest.get("schema") != "aivideo-s11-install-v2"
                or manifest.get("model_id") != S11_MODEL_ID
                or manifest.get("revision") != S11_REVISION
                or manifest.get("pinned_weights_sha256") != S11_PINNED_WEIGHTS_SHA256
                or manifest.get("files") != hashes):
            raise ModelValidationError("Model artifacts or revision differ from installation manifest")
    return {"model_id": S11_MODEL_ID, "revision": S11_REVISION,
            "weights_bytes": hashes["model.safetensors"]["size_bytes"],
            "artifact_count": len(hashes), "weights_sha256": S11_PINNED_WEIGHTS_SHA256}


def _atomic_write_manifest(staging: Path, manifest: dict) -> None:
    dest = staging / INSTALL_MANIFEST
    tmp = staging / f".manifest-{uuid.uuid4().hex}.tmp"
    try:
        with tmp.open("x", encoding="utf-8") as f:
            json.dump(manifest, f, sort_keys=True, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, dest)
    finally:
        tmp.unlink(missing_ok=True)


@contextmanager
def _exclusive_install_lock(parent: Path):
    lock_path = parent / ".aivideo-s11-install.lock"
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ModelValidationError("Another S11 model installation is running") from exc
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def download_snapshot(staging: Path) -> None:
    """Only called by the explicit --install command."""
    from huggingface_hub import snapshot_download
    snapshot_download(repo_id=S11_MODEL_ID, revision=S11_REVISION,
                      local_dir=str(staging), local_dir_use_symlinks=False)


def cmd_plan() -> int:
    target = get_target_dir()
    anchor = next((p for p in [target.parent, *target.parent.parents] if p.exists()), None)
    if anchor is None:
        print("ERROR: Cannot locate existing filesystem ancestor")
        return 1
    free = shutil.disk_usage(anchor).free
    print(f"Pinned model: {S11_MODEL_ID} @ {S11_REVISION}")
    print(f"Target: {target}; available disk: {free / 1024 ** 3:.2f} GiB")
    print(f"Required free disk: {REQUIRED_DISK_FREE_BYTES / 1024 ** 3:.2f} GiB")
    print("No changes made. No network used.")
    return 0


def cmd_verify() -> int:
    try:
        details = verify_model_directory(get_target_dir())
    except (OSError, ModelValidationError) as exc:
        print(f"NOT_READY: {exc}")
        return 1
    print("VERIFIED_LOCAL_PINNED_MODEL: " + json.dumps(details, sort_keys=True))
    return 0


def cmd_install(force: bool = False) -> int:
    target = get_target_dir()
    parent = target.parent
    try:
        if parent.is_symlink():
            raise ModelValidationError("Model root may not be a symlink")
        parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with _exclusive_install_lock(parent):
            if target.is_symlink():
                raise ModelValidationError("Target model path is a symlink; refusing destructive changes")
            if target.exists() and not force:
                verify_model_directory(target)
                print("Model already installed and verified; no download needed")
                return 0
            if shutil.disk_usage(parent).free < REQUIRED_DISK_FREE_BYTES:
                raise ModelValidationError("Insufficient free space for staged S11 model download")

            staging = Path(tempfile.mkdtemp(prefix=".aivideo-s11-staging-", dir=parent))
            backup = parent / f".aivideo-s11-backup-{uuid.uuid4().hex}"
            moved_old = False
            published = False
            try:
                start = time.monotonic()
                download_snapshot(staging)
                manifest = build_manifest(staging)
                _atomic_write_manifest(staging, manifest)
                verify_model_directory(staging)

                if target.exists():
                    if not force:
                        raise ModelValidationError("Target appeared while installing; use --force")
                    # An on-disk backup survives if the second rename fails.
                    os.replace(target, backup)
                    moved_old = True
                try:
                    os.replace(staging, target)
                    published = True
                except OSError:
                    if moved_old and not target.exists():
                        os.replace(backup, target)
                        moved_old = False
                    raise

                print(f"S11 model verified and published: {target} ({time.monotonic() - start:.1f}s)")
                if moved_old:
                    # Publication already succeeded. A cleanup failure must not
                    # misreport a healthy installation as a failed install.
                    try:
                        shutil.rmtree(backup)
                    except OSError as cleanup_error:
                        print(f"WARNING: published model is valid, old backup needs cleanup: "
                              f"{backup}: {cleanup_error}", file=sys.stderr)
                return 0
            finally:
                if not published and staging.exists():
                    shutil.rmtree(staging)
                if moved_old and backup.exists() and not target.exists():
                    os.replace(backup, target)
    except Exception as exc:
        # The downloader can raise RuntimeError and HTTP-specific exceptions.
        # Still fail closed, preserve the existing model and report exit status.
        print(f"INSTALL_BLOCKED: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


def cmd_seal() -> int:
    """Seal an existing, hash-verified install by writing its manifest.

    Some installs come from a plain `snapshot_download` (correct weights, no
    manifest). Re-downloading 3 GB just to obtain the manifest is wasteful, so
    this action hashes what is on disk, compares the weights against the pinned
    upstream SHA-256, and only then writes `.aivideo-install-manifest.json`.
    If any byte differs from the pin it refuses and writes nothing.
    """
    target = get_target_dir()
    try:
        for name in REQUIRED_FILES:
            path = target / name
            if not path.is_file():
                raise ModelValidationError(f"MISSING_ARTIFACT: {name}")
        hashes = _verify_required_files(target, enforce_pinned_sha=True)
        manifest = {
            "schema": "aivideo-s11-install-v2",
            "model_id": S11_MODEL_ID,
            "revision": S11_REVISION,
            "pinned_weights_sha256": S11_PINNED_WEIGHTS_SHA256,
            "files": hashes,
        }
        _atomic_write_manifest(target, manifest)
        verify_model_directory(target, require_manifest=True)
        print(f"Sealed existing verified install: {target}")
        print(f"  weights_sha256={S11_PINNED_WEIGHTS_SHA256}")
        return 0
    except Exception as exc:
        print(f"SEAL_BLOCKED: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Pinned offline S11 model installer")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--plan", action="store_true")
    group.add_argument("--install", action="store_true")
    group.add_argument("--verify", action="store_true")
    group.add_argument("--seal", action="store_true",
                       help="Write the manifest for an existing install whose weights match the pin")
    parser.add_argument("--force", action="store_true", help="Replace existing model only after fully verifying staging")
    args = parser.parse_args()
    if args.plan:
        return cmd_plan()
    if args.install:
        return cmd_install(force=args.force)
    if args.seal:
        return cmd_seal()
    return cmd_verify()


if __name__ == "__main__":
    sys.exit(main())
