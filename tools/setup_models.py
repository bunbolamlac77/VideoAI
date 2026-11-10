#!/usr/bin/env python3
"""
tools/setup_models.py — Unified Model Setup & Verification Tool for AIVideo v3.1
Runs verification or installation across all local models:
1. G0 Smoke Model: Qwen3-0.6B-4bit (contracts/g0_model.lock.json)
2. S11 VLM Primary Model: Qwen3-VL-4B-Instruct-4bit (P-VISION-DEV-v1)
"""

from __future__ import annotations
import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run_g0(mode: str, force: bool = False) -> int:
    script = ROOT / "tools" / "setup_g0_model.py"
    cmd = [sys.executable, str(script), f"--{mode}"]
    if force:
        cmd.append("--force")
    print(f"\n>>> Running G0 Model Setup ({mode})...")
    res = subprocess.run(cmd)
    return res.returncode


def run_s11(mode: str, force: bool = False) -> int:
    script = ROOT / "tools" / "setup_s11_model.py"
    cmd = [sys.executable, str(script), f"--{mode}"]
    if force:
        cmd.append("--force")
    print(f"\n>>> Running S11 VLM Model Setup ({mode})...")
    res = subprocess.run(cmd)
    return res.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description="Unified Model Setup & Verification for AIVideo")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--plan", action="store_true", help="Inspect all models' installation plan")
    group.add_argument("--verify", action="store_true", help="Verify all installed models offline")
    group.add_argument("--install", action="store_true", help="Download and install all models")
    parser.add_argument("--force", "--reinstall", dest="force", action="store_true", help="Force reinstall even if models exist or are mismatched")

    args = parser.parse_args()
    mode = "plan" if args.plan else ("verify" if args.verify else "install")

    g0_rc = run_g0(mode, force=args.force)
    s11_rc = run_s11(mode, force=args.force)

    if g0_rc == 0 and s11_rc == 0:
        print("\n=======================================================")
        print(f"✅ ALL MODELS {mode.upper()} COMPLETED SUCCESSFULLY (100% OK)")
        print("=======================================================")
        return 0
    else:
        print(f"\n❌ Failure detected: G0 exit={g0_rc}, S11 exit={s11_rc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
