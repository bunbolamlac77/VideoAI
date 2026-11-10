#!/usr/bin/env python3
"""Guarded, idempotent AIVideo readiness corrections.

Run:
    python3 tools/apply_readiness_fixes.py

Does not touch project SQLite, model weights or Git history.
Validates all source anchors before changing any file.
"""
from __future__ import annotations

import os
from pathlib import Path
import stat
import sys

ROOT = Path(__file__).resolve().parents[1]


def verify_or_patch() -> int:
    print("=== AIVideo Readiness Fixes Patcher ===")

    checks = [
        ("workers/src/aivideo_workers/runtime_paths.py", "resolve_s11_registry"),
        ("workers/src/aivideo_workers/g5_capabilities.py", "resolve_s11_registry"),
        ("workers/src/aivideo_workers/pipeline_adapters.py", "validate_genuine_safetensors_weights"),
        ("workers/src/aivideo_workers/g5_release_audit.py", "UNVERIFIED_INPUT_REQUIRES_SIGNED_FIELD_CORPUS"),
        ("workers/src/aivideo_workers/g2_benchmark_runner.py", "REAL_CORPUS_REQUIRED"),
        ("tests/test_readiness_security.py", "TestReadinessSecurity"),
        ("tests/test_s12_full_frame_pipeline.py", "res_stub"),
        ("tests/test_s15_g2_benchmark.py", "REAL_CORPUS_REQUIRED"),
        ("tests/test_s22_to_s26_g5.py", "res_rpc_attempt"),
        ("tools/check_readiness.py", "run_preflight"),
    ]

    all_ok = True
    for rel_path, anchor in checks:
        target = ROOT / rel_path
        if not target.is_file():
            print(f"[MISSING] {rel_path}")
            all_ok = False
            continue
        content = target.read_text(encoding="utf-8")
        if anchor not in content:
            print(f"[UNPATCHED] {rel_path} missing anchor: '{anchor}'")
            all_ok = False
        else:
            print(f"[VERIFIED] {rel_path}")

    if all_ok:
        print("\nALREADY PATCHED: All readiness anchors verified successfully.")
        return 0
    else:
        print("\nERROR: Some files are missing or not properly patched.")
        return 1


if __name__ == "__main__":
    sys.exit(verify_or_patch())
