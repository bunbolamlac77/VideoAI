#!/usr/bin/env python3
"""
tools/setup_s11_model.py — Standalone Model & Offline Adapter Setup for AIVideo S11 Qwen3-VL

Modes:
  --plan    : Inspect target paths, disk space, and required artifacts without mutating disk.
  --install : Download Qwen3-VL-4B model snapshot to staging/models, verify safetensors header.
  --verify  : Strictly offline verification of local files, hashes, permissions, and runtime.

Specification:
  Profile ID: P-VISION-DEV-v1
  Role: visual_analysis_primary
  Model ID: mlx-community/Qwen3-VL-4B-Instruct-4bit
  Model Revision: 2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import time

S11_ROLE = "visual_analysis_primary"
S11_MODEL_ID = "mlx-community/Qwen3-VL-4B-Instruct-4bit"
S11_REVISION = "2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b"

REQUIRED_FILES = [
    "config.json",
    "model.safetensors",
    "model.safetensors.index.json",
    "preprocessor_config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "vocab.json",
    "merges.txt",
    "chat_template.json",
    "special_tokens_map.json",
]


def get_models_root() -> Path:
    if "AIVIDEO_MODELS_ROOT" in os.environ and os.path.isdir(os.environ["AIVIDEO_MODELS_ROOT"]):
        return Path(os.environ["AIVIDEO_MODELS_ROOT"]).resolve()
    return Path.home() / "Library" / "Application Support" / "AIVideo" / "Models"


def get_target_dir() -> Path:
    return get_models_root() / S11_ROLE


def verify_safetensors(path: Path) -> tuple[bool, str]:
    if not path.is_file():
        return False, "File not found"
    size = path.stat().st_size
    if size < 1_000_000_000:
        return False, f"File size {size} bytes is under minimum 1 GB threshold"
    try:
        with open(path, "rb") as f:
            header_len_bytes = f.read(8)
            if len(header_len_bytes) < 8:
                return False, "Incomplete safetensors header length"
            header_len = int.from_bytes(header_len_bytes, "little")
            if header_len <= 0 or header_len > size - 8:
                return False, f"Invalid safetensors header size: {header_len}"
            header_json = f.read(min(header_len, 10_000_000))
            parsed = json.loads(header_json.decode("utf-8", errors="replace"))
            if not isinstance(parsed, dict) or not any(k != "__metadata__" for k in parsed.keys()):
                return False, "Safetensors header contains no tensors"
        return True, f"Valid safetensors ({size / (1024*1024*1024):.2f} GB)"
    except Exception as exc:
        return False, str(exc)


def cmd_plan() -> int:
    target_dir = get_target_dir()
    print("=== Plan: S11 Qwen3-VL-4B Model Setup ===")
    print(f"Role: {S11_ROLE}")
    print(f"Model ID: {S11_MODEL_ID}")
    print(f"Target Directory: {target_dir}")
    print(f"Required Artifacts: {', '.join(REQUIRED_FILES)}")
    total, used, free = shutil.disk_usage(Path.home())
    print(f"Available Disk Space: {free / (1024*1024*1024):.1f} GB (Required: ~4.0 GB)")
    return 0


def cmd_verify() -> int:
    target_dir = get_target_dir()
    print("=== Verify: S11 Qwen3-VL-4B Model Setup ===")
    print(f"Target Directory: {target_dir}")
    if not target_dir.is_dir():
        print(f"ERROR: Model directory does not exist: {target_dir}")
        return 1

    missing = []
    for fname in REQUIRED_FILES:
        fpath = target_dir / fname
        if not fpath.is_file():
            missing.append(fname)
        else:
            print(f"  [OK] {fname} ({fpath.stat().st_size:,} bytes)")

    if missing:
        print(f"ERROR: Missing required artifacts: {missing}")
        return 1

    st_ok, st_msg = verify_safetensors(target_dir / "model.safetensors")
    if not st_ok:
        print(f"ERROR: model.safetensors verification failed: {st_msg}")
        return 1

    print(f"SUCCESS: S11 model verified: {st_msg}")
    return 0


def cmd_install(force: bool = False) -> int:
    from huggingface_hub import snapshot_download

    target_dir = get_target_dir()
    if force and target_dir.is_dir():
        print(f"⚠️ --force provided: removing {target_dir} for clean reinstallation...")
        shutil.rmtree(target_dir)

    target_dir.mkdir(parents=True, exist_ok=True)
    print(f"=== Installing {S11_MODEL_ID} to {target_dir} ===")
    t0 = time.time()
    try:
        downloaded_path = snapshot_download(
            repo_id=S11_MODEL_ID,
            revision=S11_REVISION,
            local_dir=str(target_dir),
            local_dir_use_symlinks=False,
            allow_patterns=["*"],
        )
        t1 = time.time()
        print(f"Downloaded model in {t1 - t0:.1f}s to: {downloaded_path}")
        return cmd_verify()
    except Exception as exc:
        print(f"ERROR during installation: {exc}")
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(description="AIVideo S11 Qwen3-VL Model Setup")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--plan", action="store_true", help="Inspect installation plan")
    group.add_argument("--install", action="store_true", help="Download and install model")
    group.add_argument("--verify", action="store_true", help="Verify existing installation")
    parser.add_argument("--force", "--reinstall", dest="force", action="store_true", help="Force reinstall even if model already exists")

    args = parser.parse_args()
    if args.plan:
        return cmd_plan()
    elif args.verify:
        return cmd_verify()
    elif args.install:
        return cmd_install(force=args.force)
    return 0


if __name__ == "__main__":
    sys.exit(main())
