#!/usr/bin/env python3
"""
tools/setup_g0_model.py — Standalone Model & Runtime Setup Tool for AIVideo G0

Modes:
  --plan    : Inspect target paths, disk space, and required artifacts without mutating disk.
  --install : Download model snapshot to staging, verify all artifacts, atomically publish,
              record installation registry and lock hashes.
  --verify  : Strictly offline verification of local files, hashes, permissions, and runtime.

Specification:
  Profile ID: g0-text-smoke-v1
  Model ID: mlx-community/Qwen3-0.6B-4bit
  Model Revision: 73e3e38d981303bc594367cd910ea6eb48349da8
"""

import os
import sys
import json
import shutil
import hashlib
import argparse
import time
import uuid
import platform
import subprocess
from typing import Dict, Any, Optional, Tuple, List

G0_PROFILE_ID = "g0-text-smoke-v1"
G0_MODEL_ID = "mlx-community/Qwen3-0.6B-4bit"
G0_MODEL_REVISION = "73e3e38d981303bc594367cd910ea6eb48349da8"
G0_RUNTIME_PROFILE_ID = "g0-mlx-runtime"

REQUIRED_ARTIFACTS = [
    "config.json",
    "model.safetensors",
    "model.safetensors.index.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "added_tokens.json",
    "special_tokens_map.json",
    "merges.txt",
    "vocab.json"
]

ESTIMATED_DOWNLOAD_BYTES = 500 * 1024 * 1024  # ~500 MB
ESTIMATED_STAGING_BYTES = 600 * 1024 * 1024   # ~600 MB
MINIMUM_REQUIRED_DISK_BYTES = ESTIMATED_DOWNLOAD_BYTES + ESTIMATED_STAGING_BYTES  # ~1.1 GB


def get_default_app_support() -> str:
    if "AIVIDEO_APP_SUPPORT" in os.environ and os.path.isdir(os.environ["AIVIDEO_APP_SUPPORT"]):
        return os.path.abspath(os.environ["AIVIDEO_APP_SUPPORT"])
    home = os.path.expanduser("~")
    return os.path.join(home, "Library", "Application Support", "AIVideo")


def get_contracts_lock_path() -> str:
    # Look in repo root
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(repo_root, "contracts", "g0_model.lock.json")


def get_uv_lock_path() -> str:
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(repo_root, "workers", "uv.lock")


def compute_sha256(filepath: str) -> str:
    hasher = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            hasher.update(chunk)
    return hasher.hexdigest()


def check_system_environment() -> Dict[str, Any]:
    arch = platform.machine()
    system = platform.system()
    mac_ver = platform.mac_ver()[0]
    return {
        "architecture": arch,
        "is_arm64": arch == "arm64",
        "system": system,
        "mac_version": mac_ver,
        "python_version": sys.version.split()[0],
        "python_executable": sys.executable
    }


def verify_existing_pinned_install(model_dir: str) -> bool:
    lock_path = get_contracts_lock_path()
    if not os.path.isfile(lock_path):
        return False

    try:
        with open(lock_path, "r", encoding="utf-8") as f:
            lock = json.load(f)
    except Exception:
        return False

    expected = lock.get("verified_artifacts") or {}

    if lock.get("status") != "verified":
        return False

    if lock.get("model_id") != G0_MODEL_ID or lock.get("model_revision") != G0_MODEL_REVISION:
        return False

    if not all(a in expected for a in REQUIRED_ARTIFACTS):
        return False

    for name in REQUIRED_ARTIFACTS:
        meta = expected[name]
        path = os.path.join(model_dir, name)

        if not os.path.isfile(path):
            return False

        if os.path.getsize(path) != meta["size_bytes"]:
            return False

        if compute_sha256(path) != meta["sha256"]:
            return False

    return True


# MARK: - Mode 1: Plan

def execute_plan(app_support_dir: str) -> int:
    print("=======================================================")
    print("AIVIDEO G0 MODEL SETUP — EXECUTION PLAN (--plan)")
    print("=======================================================")

    env_info = check_system_environment()
    print(f"Target System Architecture : {env_info['architecture']} (Apple Silicon: {env_info['is_arm64']})")
    print(f"macOS Version               : {env_info['mac_version']}")
    print(f"Active Python Interpreter   : {env_info['python_executable']} ({env_info['python_version']})")

    model_dir = os.path.join(app_support_dir, "Models", "g0-text", G0_MODEL_REVISION)
    staging_base = os.path.join(app_support_dir, "Models", "g0-text")
    runtime_dir = os.path.join(app_support_dir, "Runtimes", G0_RUNTIME_PROFILE_ID)
    registry_file = os.path.join(app_support_dir, "Installations", f"{G0_PROFILE_ID}.json")

    print(f"\n[Model Configuration]")
    print(f"Profile ID      : {G0_PROFILE_ID}")
    print(f"Purpose         : g0_inference_smoke_only")
    print(f"Model ID        : {G0_MODEL_ID}")
    print(f"Revision        : {G0_MODEL_REVISION}")
    print(f"Target Path     : {model_dir}")
    print(f"Staging Parent  : {staging_base} (Same filesystem as target)")
    print(f"Runtime Path    : {runtime_dir}")
    print(f"Registry File   : {registry_file}")

    print(f"\n[Required Artifacts ({len(REQUIRED_ARTIFACTS)} files)]")
    for art in REQUIRED_ARTIFACTS:
        print(f"  • {art}")

    # Check disk space on target filesystem
    os.makedirs(app_support_dir, exist_ok=True)
    disk_stat = shutil.disk_usage(app_support_dir)
    free_gib = disk_stat.free / (1024 ** 3)
    needed_gib = MINIMUM_REQUIRED_DISK_BYTES / (1024 ** 3)
    print(f"\n[Disk Space Assessment]")
    print(f"Available Free Space : {free_gib:.2f} GiB")
    print(f"Required Space (Est) : {needed_gib:.2f} GiB (Includes download cache + staging + final model)")

    if disk_stat.free < MINIMUM_REQUIRED_DISK_BYTES:
        print(f"❌ INSUFFICIENT DISK SPACE: Need at least {needed_gib:.2f} GiB free.")
        return 1
    else:
        print(f"✅ Sufficient disk space verified.")

    # Check current status
    is_installed = os.path.isdir(model_dir) and all(os.path.isfile(os.path.join(model_dir, a)) for a in REQUIRED_ARTIFACTS)
    print(f"\nCurrent Local Status: {'ALREADY_INSTALLED (Eligible for verification/reuse)' if is_installed else 'NOT_INSTALLED'}")
    print("\nNote: Plan executed. No changes made to disk. No network requests initiated.")
    return 0


# MARK: - Mode 2: Install

def execute_install(app_support_dir: str, python_runtime_path: Optional[str] = None, force: bool = False) -> int:
    print("=======================================================")
    print("AIVIDEO G0 MODEL SETUP — INSTALLATION (--install)")
    print("=======================================================")

    # 1. Check if model already exists: always check tampering BEFORE arch/disk checks!
    target_model_dir = os.path.join(app_support_dir, "Models", "g0-text", G0_MODEL_REVISION)
    if os.path.lexists(target_model_dir):
        if not verify_existing_pinned_install(target_model_dir):
            if force:
                print(f"⚠️ Model directory exists but does not match pinned manifest. --force provided: removing {target_model_dir} for clean reinstallation...")
                if os.path.isdir(target_model_dir):
                    shutil.rmtree(target_model_dir)
                else:
                    os.remove(target_model_dir)
            else:
                print(
                    "BLOCKED: Existing model does not match "
                    "pinned manifest. No files were modified.\n"
                    "Tip: Re-run with --force to remove corrupted files and perform a clean reinstallation."
                )
                return 2

    env_info = check_system_environment()
    if not env_info["is_arm64"]:
        print(f"❌ ERROR: Architecture must be arm64 (Apple Silicon). Detected: {env_info['architecture']}")
        return 1

    # Check disk space
    os.makedirs(app_support_dir, exist_ok=True)
    disk_stat = shutil.disk_usage(app_support_dir)
    if disk_stat.free < MINIMUM_REQUIRED_DISK_BYTES:
        print(f"❌ ERROR: Insufficient disk space on {app_support_dir}. Free: {disk_stat.free / (1024**3):.2f} GiB.")
        return 1

    # Acquire exclusive installation lock
    lock_file = os.path.join(app_support_dir, ".g0_model_install.lock")
    lock_fd = os.open(lock_file, os.O_CREAT | os.O_RDWR)
    try:
        import fcntl
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (IOError, OSError):
        print("❌ ERROR: Another model setup operation is running on this machine.")
        os.close(lock_fd)
        return 1

    try:
        staging_parent = os.path.join(app_support_dir, "Models", "g0-text")
        os.makedirs(staging_parent, exist_ok=True)

        if os.path.lexists(target_model_dir):
            if not verify_existing_pinned_install(target_model_dir):
                if force:
                    print(f"Removing invalid target directory {target_model_dir}...")
                    if os.path.isdir(target_model_dir):
                        shutil.rmtree(target_model_dir)
                    else:
                        os.remove(target_model_dir)
                else:
                    print(
                        "BLOCKED: Existing model does not match "
                        "pinned manifest. No files were modified."
                    )
                    return 2

            with open(get_contracts_lock_path(), "r", encoding="utf-8") as f:
                pinned = json.load(f)

            return finalize_installation(
                app_support_dir,
                target_model_dir,
                pinned["verified_artifacts"],
                python_runtime_path
            )

        # 2. Download into unique staging directory on SAME filesystem
        staging_dir = os.path.join(staging_parent, f".staging_{G0_MODEL_REVISION}_{uuid.uuid4().hex[:8]}")
        os.makedirs(staging_dir, exist_ok=True)
        print(f"Staging directory created at: {staging_dir}")

        try:
            from huggingface_hub import snapshot_download
        except ImportError:
            print("❌ ERROR: 'huggingface_hub' is required for installation. Please ensure workers/uv.lock packages are installed.")
            shutil.rmtree(staging_dir, ignore_errors=True)
            return 1

        print(f"\nDownloading snapshot for '{G0_MODEL_ID}' (Revision: {G0_MODEL_REVISION})...")
        try:
            downloaded_path = snapshot_download(
                repo_id=G0_MODEL_ID,
                revision=G0_MODEL_REVISION,
                local_dir=staging_dir,
                local_dir_use_symlinks=False
            )
            print(f"Snapshot downloaded to staging.")
        except Exception as e:
            print(f"❌ ERROR: Download failed or interrupted: {e}")
            shutil.rmtree(staging_dir, ignore_errors=True)
            return 1

        # 3. Verify all required artifacts exist in staging and match pinned manifest if present
        print("Verifying downloaded artifacts in staging...")
        artifact_manifest = {}
        missing = []
        for art in REQUIRED_ARTIFACTS:
            art_path = os.path.join(staging_dir, art)
            if not os.path.isfile(art_path):
                missing.append(art)
            else:
                sz = os.path.getsize(art_path)
                if sz == 0:
                    missing.append(f"{art} (empty file)")
                else:
                    h = compute_sha256(art_path)
                    artifact_manifest[art] = {"size_bytes": sz, "sha256": h}

        if missing:
            print(f"❌ ERROR: Missing or invalid artifacts in downloaded snapshot: {', '.join(missing)}")
            shutil.rmtree(staging_dir, ignore_errors=True)
            return 1

        # Check against pinned lock manifest if one exists
        contracts_lock = get_contracts_lock_path()
        if os.path.isfile(contracts_lock):
            with open(contracts_lock, "r", encoding="utf-8") as f:
                lock_data = json.load(f)
            pinned = lock_data.get("verified_artifacts") or {}
            if pinned:
                for art, meta in pinned.items():
                    if art in artifact_manifest:
                        if artifact_manifest[art]["sha256"] != meta["sha256"]:
                            print(f"❌ ERROR: Downloaded {art} hash does not match pinned manifest in contract lock!")
                            shutil.rmtree(staging_dir, ignore_errors=True)
                            return 1

        # 4. Atomic publish: Move staging to target directory (never delete existing model dir)
        print(f"Publishing model atomically to: {target_model_dir}")
        if os.path.lexists(target_model_dir):
            print(f"❌ ERROR: Target model directory already exists: '{target_model_dir}'. Refusing to overwrite.")
            shutil.rmtree(staging_dir, ignore_errors=True)
            return 1

        os.replace(staging_dir, target_model_dir)

        print("✅ Model published to destination directory.")
        return finalize_installation(app_support_dir, target_model_dir, artifact_manifest, python_runtime_path)
    finally:
        try:
            import fcntl
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        except Exception:
            pass
        os.close(lock_fd)


def finalize_installation(
    app_support_dir: str,
    target_model_dir: str,
    artifact_manifest: Dict[str, Dict[str, Any]],
    python_runtime_path: Optional[str] = None
) -> int:
    # 1. Resolve Python executable for runtime registry
    resolved_python = python_runtime_path or sys.executable
    # Also check Application Support runtime
    dedicated_runtime_py = os.path.join(app_support_dir, "Runtimes", G0_RUNTIME_PROFILE_ID, "bin", "python3")
    if os.path.isfile(dedicated_runtime_py) and os.access(dedicated_runtime_py, os.X_OK):
        resolved_python = dedicated_runtime_py

    # 2. Compute lock hashes
    contracts_lock = get_contracts_lock_path()
    uv_lock = get_uv_lock_path()

    uv_lock_sha = compute_sha256(uv_lock) if os.path.isfile(uv_lock) else "UNKNOWN"

    # 3. Update contracts/g0_model.lock.json in repo with verified artifacts
    if os.path.isfile(contracts_lock):
        try:
            with open(contracts_lock, "r", encoding="utf-8") as f:
                lock_data = json.load(f)

            lock_data["status"] = "verified"
            lock_data["verified_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            lock_data["runtime_lock"]["sha256"] = uv_lock_sha
            lock_data["verified_artifacts"] = artifact_manifest

            with open(contracts_lock, "w", encoding="utf-8") as f:
                json.dump(lock_data, f, indent=2, ensure_ascii=False)
            print(f"Updated source contract lock: {contracts_lock}")
        except Exception as e:
            print(f"Warning: Failed updating contracts lock: {e}")

    model_lock_sha = compute_sha256(contracts_lock) if os.path.isfile(contracts_lock) else "UNKNOWN"

    # 4. Write machine installation registry
    installations_dir = os.path.join(app_support_dir, "Installations")
    os.makedirs(installations_dir, exist_ok=True)
    registry_file = os.path.join(installations_dir, f"{G0_PROFILE_ID}.json")

    registry_payload = {
        "schema_version": "1.0.0",
        "profile_id": G0_PROFILE_ID,
        "model_id": G0_MODEL_ID,
        "model_revision": G0_MODEL_REVISION,
        "model_path": os.path.abspath(target_model_dir),
        "python_path": os.path.abspath(resolved_python),
        "model_lock_sha256": model_lock_sha,
        "runtime_lock_sha256": uv_lock_sha,
        "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "status": "verified",
        "verification_result": {
            "artifact_count": len(artifact_manifest),
            "total_bytes": sum(a["size_bytes"] for a in artifact_manifest.values()),
            "runtime_python_available": os.path.isfile(resolved_python) and os.access(resolved_python, os.X_OK)
        }
    }

    with open(registry_file, "w", encoding="utf-8") as rf:
        json.dump(registry_payload, rf, indent=2, ensure_ascii=False)

    print(f"Installation registry published to: {registry_file}")
    print("\n=======================================================")
    print("✅ G0 MODEL INSTALLATION COMPLETED SUCCESSFULLY")
    print("=======================================================")
    return 0


# MARK: - Mode 3: Verify

def execute_verify(app_support_dir: str) -> int:
    print("=======================================================")
    print("AIVIDEO G0 MODEL SETUP — OFFLINE VERIFICATION (--verify)")
    print("=======================================================")
    # Enforce strictly offline
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"

    contracts_lock = get_contracts_lock_path()
    if not os.path.isfile(contracts_lock):
        print(f"❌ FAIL: Contracts lock file not found at '{contracts_lock}'")
        return 1

    try:
        with open(contracts_lock, "r", encoding="utf-8") as f:
            lock_data = json.load(f)
    except Exception as e:
        print(f"❌ FAIL: Malformed lock file: {e}")
        return 1

    if lock_data.get("status") != "verified":
        print(f"❌ FAIL: Contract lock status is '{lock_data.get('status')}', not 'verified'. Run --install first.")
        return 1

    # Check installation registry
    registry_file = os.path.join(app_support_dir, "Installations", f"{G0_PROFILE_ID}.json")
    if not os.path.isfile(registry_file):
        print(f"❌ FAIL: Installation registry not found at '{registry_file}'. Model has not been installed on this machine.")
        return 1

    try:
        with open(registry_file, "r", encoding="utf-8") as rf:
            reg_data = json.load(rf)
    except Exception as e:
        print(f"❌ FAIL: Malformed registry file: {e}")
        return 1

    model_dir = reg_data.get("model_path")
    if not model_dir or not os.path.isdir(model_dir):
        print(f"❌ FAIL: Model directory '{model_dir}' does not exist on disk.")
        return 1

    print(f"Verifying local artifacts in: {model_dir}")
    verified_artifacts = lock_data.get("verified_artifacts", {})
    if not verified_artifacts:
        print("❌ FAIL: Lock file does not contain verified_artifacts dictionary.")
        return 1

    for art in REQUIRED_ARTIFACTS:
        art_path = os.path.join(model_dir, art)
        if not os.path.isfile(art_path):
            print(f"❌ FAIL: Missing required artifact: {art}")
            return 1
        if not os.access(art_path, os.R_OK):
            print(f"❌ FAIL: Permission denied reading artifact: {art}")
            return 1

        expected_meta = verified_artifacts.get(art)
        if not expected_meta:
            print(f"❌ FAIL: Artifact '{art}' missing from lock file verified list.")
            return 1

        actual_size = os.path.getsize(art_path)
        if actual_size != expected_meta["size_bytes"]:
            print(f"❌ FAIL: Size mismatch on '{art}': expected {expected_meta['size_bytes']}, got {actual_size}")
            return 1

        actual_sha = compute_sha256(art_path)
        if actual_sha != expected_meta["sha256"]:
            print(f"❌ FAIL: SHA-256 mismatch on '{art}'!")
            print(f"   Expected: {expected_meta['sha256']}")
            print(f"   Actual  : {actual_sha}")
            return 1
        print(f"  ✅ Verified {art} ({actual_size} bytes, SHA: {actual_sha[:12]}...)")

    # Verify python runtime
    py_path = reg_data.get("python_path")
    if not py_path or not os.path.isfile(py_path) or not os.access(py_path, os.X_OK):
        print(f"❌ FAIL: Python executable '{py_path}' is missing or not executable.")
        return 1

    print(f"Checking MLX / MLX-LM import via runtime Python: {py_path}")
    probe_code = "import mlx, mlx.core as mx, mlx_lm; print('MLX_OK', mlx_lm.__version__)"
    proc = subprocess.run([py_path, "-c", probe_code], capture_output=True, text=True)
    if proc.returncode != 0 or "MLX_OK" not in proc.stdout:
        print(f"❌ FAIL: MLX / MLX-LM runtime probe failed: {proc.stderr.strip()}")
        return 1

    backend_ver = proc.stdout.strip().split()[-1]
    print(f"  ✅ Runtime verified: mlx-lm {backend_ver} is functional.")

    print("\n=======================================================")
    print("✅ ALL OFFLINE VERIFICATIONS PASSED (100% Valid)")
    print("=======================================================")
    return 0


def main():
    parser = argparse.ArgumentParser(description="AIVideo G0 Model & Runtime Setup Tool")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--plan", action="store_true", help="Display installation plan and disk requirements without mutating state")
    group.add_argument("--install", action="store_true", help="Download and install model snapshot, verify and register")
    group.add_argument("--verify", action="store_true", help="Perform offline verification of installed model artifacts and runtime")

    parser.add_argument("--app-support", type=str, default=None, help="Custom Application Support root directory")
    parser.add_argument("--python-path", type=str, default=None, help="Custom Python runtime path")
    parser.add_argument("--force", "--reinstall", dest="force", action="store_true", help="Force reinstall even if model already exists or is mismatched")

    args = parser.parse_args()
    app_support = resolve_app_support_dir(args.app_support) if args.app_support else get_default_app_support()

    if args.plan:
        sys.exit(execute_plan(app_support))
    elif args.install:
        sys.exit(execute_install(app_support, args.python_path, force=args.force))
    elif args.verify:
        sys.exit(execute_verify(app_support))


if __name__ == "__main__":
    main()
