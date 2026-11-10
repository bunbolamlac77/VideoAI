#!/usr/bin/env python3
"""Offline AIVideo release preflight for macOS arm64."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "apps/macos/build/AIVideo.app"
REPORT = ROOT / "build/reports/readiness_report.json"

if str(ROOT / "workers" / "src") not in sys.path:
    sys.path.insert(0, str(ROOT / "workers" / "src"))


def command(
    args: list[str],
    timeout: int = 20,
) -> tuple[bool, str]:
    try:
        completed = subprocess.run(
            args,
            text=True,
            capture_output=True,
            check=False,
            timeout=timeout,
        )
        output = (completed.stdout + "\n" + completed.stderr).strip()
        return completed.returncode == 0, output
    except Exception as exc:
        return False, str(exc)


def check_toolchain() -> dict[str, Any]:
    system = platform.system()
    machine = platform.machine()
    py_ver = sys.version_info

    ffmpeg_bin = shutil.which("ffmpeg")
    ffprobe_bin = shutil.which("ffprobe")
    swift_bin = shutil.which("swift")

    ffmpeg_ok, ffmpeg_ver = command(["ffmpeg", "-version"]) if ffmpeg_bin else (False, "missing")
    ffprobe_ok, ffprobe_ver = command(["ffprobe", "-version"]) if ffprobe_bin else (False, "missing")
    swift_ok, swift_ver = command(["swift", "--version"]) if swift_bin else (False, "missing")

    is_darwin_arm64 = (system == "Darwin") and (machine in ("arm64", "aarch64"))
    py_ok = py_ver >= (3, 10)

    pass_all = bool(is_darwin_arm64 and py_ok and ffmpeg_ok and ffprobe_ok and swift_ok)

    return {
        "passed": pass_all,
        "os": system,
        "arch": machine,
        "is_darwin_arm64": is_darwin_arm64,
        "python_version": f"{py_ver.major}.{py_ver.minor}.{py_ver.micro}",
        "python_ok": py_ok,
        "ffmpeg": {"installed": bool(ffmpeg_bin), "version": ffmpeg_ver.split("\n")[0] if ffmpeg_ok else ffmpeg_ver},
        "ffprobe": {"installed": bool(ffprobe_bin), "version": ffprobe_ver.split("\n")[0] if ffprobe_ok else ffprobe_ver},
        "swift": {"installed": bool(swift_bin), "version": swift_ver.split("\n")[0] if swift_ok else swift_ver},
    }


def check_app_bundle() -> dict[str, Any]:
    binary = APP / "Contents" / "MacOS" / "AIVideo"
    app_exists = APP.is_dir()
    bin_exists = binary.is_file()

    arch_ok = False
    codesign_ok = False
    codesign_detail = "app not found"

    if bin_exists:
        file_ok, file_out = command(["file", str(binary)])
        arch_ok = "arm64" in file_out
        cs_ok, cs_out = command(["codesign", "--verify", "--deep", "--strict", str(APP)])
        codesign_ok = cs_ok
        codesign_detail = cs_out or "valid"

    return {
        "app_exists": app_exists,
        "binary_exists": bin_exists,
        "is_arm64": arch_ok,
        "codesign_verified": codesign_ok,
        "codesign_detail": codesign_detail,
        "passed": app_exists and bin_exists and arch_ok and codesign_ok,
    }


def check_contracts_and_registry() -> dict[str, Any]:
    try:
        from aivideo_workers.runtime_paths import resolve_s11_registry
        from aivideo_workers.g5_capabilities import load_capability_registry

        reg_path = resolve_s11_registry()
        reg_data = load_capability_registry(reg_path)
        caps = reg_data.get("capabilities", {})
        exact_photo = caps.get("exact_photo_shutter_match", {})
        shutter_disabled = exact_photo.get("status") == "disabled"

        return {
            "passed": True,
            "registry_path": str(reg_path),
            "capabilities_count": len(caps),
            "exact_photo_shutter_match_status": exact_photo.get("status"),
            "exact_photo_shutter_match_gated": shutter_disabled,
        }
    except Exception as exc:
        return {
            "passed": False,
            "error": str(exc),
        }


def check_models_presence() -> dict[str, Any]:
    models_root = Path.home() / "Library" / "Application Support" / "AIVideo" / "Models"
    vis_dir = models_root / "visual_analysis_primary"
    safetensors = vis_dir / "model.safetensors"

    installed = False
    size_bytes = 0
    if safetensors.is_file():
        size_bytes = safetensors.stat().st_size
        installed = size_bytes >= 1_000_000_000  # Genuine 4-bit Qwen3-VL is ~2.5GB

    return {
        "models_root": str(models_root),
        "visual_model_installed": installed,
        "weights_byte_size": size_bytes,
        "status": "INSTALLED" if installed else "NOT_INSTALLED",
    }


def check_resolve_installation() -> dict[str, Any]:
    resolve_app = Path("/Applications/DaVinci Resolve/DaVinci Resolve.app")
    installed = resolve_app.is_dir()
    return {
        "path": str(resolve_app),
        "installed": installed,
    }


def check_field_corpus_and_certification(manifest_path: Path | None = None) -> dict[str, Any]:
    # Live field corpus certification requires cryptographically signed manifests AND verified video SHA-256 hashes
    from aivideo_workers.g5_release_audit import validate_signed_field_manifest

    field_corpus_manifest = manifest_path or (ROOT / "reports" / "evidence" / "signed_field_corpus_manifest.json")
    corpus_dir = ROOT / "fixtures" / "corpus"
    certified = False
    manifest_exists = field_corpus_manifest.is_file()
    if manifest_exists:
        try:
            data = json.loads(field_corpus_manifest.read_text(encoding="utf-8"))
            certified = validate_signed_field_manifest(
                data,
                corpus_dir=corpus_dir,
                enforce_signature=True,
            )
        except Exception:
            certified = False

    return {
        "live_field_corpus_certified": certified,
        "certification_status": "CERTIFIED_FIELD_CORPUS" if certified else "UNVERIFIED_INPUT_REQUIRES_SIGNED_FIELD_CORPUS",
        "manifest_path": str(field_corpus_manifest),
    }


def run_preflight() -> int:
    print("=== AIVideo Release Readiness Preflight (macOS arm64) ===")

    toolchain = check_toolchain()
    app_info = check_app_bundle()
    contracts = check_contracts_and_registry()
    models = check_models_presence()
    resolve = check_resolve_installation()
    field_corpus = check_field_corpus_and_certification()

    blockers: list[str] = []

    if not toolchain["passed"]:
        blockers.append("TOOLCHAIN_NOT_MET: Required macOS arm64, python>=3.10, ffmpeg, ffprobe, and swift")

    if not app_info["passed"]:
        blockers.append(f"APP_BUNDLE_NOT_VERIFIED: {app_info['codesign_detail']}")

    if not contracts["passed"]:
        blockers.append(f"REGISTRY_ERROR: {contracts.get('error')}")

    if not models["visual_model_installed"]:
        blockers.append("REAL_QWEN_VL_WEIGHTS_MISSING: Qwen3-VL-4B offline weights not installed in Application Support")

    if not field_corpus["live_field_corpus_certified"]:
        blockers.append("UNVERIFIED_INPUT_REQUIRES_SIGNED_FIELD_CORPUS: E0/E1 real video held-out runs require signed field corpus")

    report = {
        "schema": "aivideo-readiness-preflight-v1",
        "timestamp": platform.platform(),
        "ready_for_production_release": len(blockers) == 0,
        "blockers": blockers,
        "toolchain": toolchain,
        "app_bundle": app_info,
        "contracts": contracts,
        "models": models,
        "davinci_resolve": resolve,
        "field_corpus": field_corpus,
    }

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Report written to: {REPORT}")

    print("\n--- Summary ---")
    print(f"Toolchain: {'PASS' if toolchain['passed'] else 'FAIL'}")
    print(f"App Bundle: {'PASS' if app_info['passed'] else 'IN_REVIEW'}")
    print(f"Contracts & Gating: {'PASS' if contracts['passed'] else 'FAIL'}")
    print(f"Production Models: {models['status']}")
    print(f"Field Corpus Certification: {field_corpus['certification_status']}")

    if blockers:
        print("\nActive Blockers (Intentional Gate Enforcement):")
        for b in blockers:
            print(f"  - [BLOCKER] {b}")
        print("\nReadiness Preflight Decision: NO-GO (Blockers must be closed before field release)")
        return 2

    print("\nReadiness Preflight Decision: GO")
    return 0


if __name__ == "__main__":
    sys.exit(run_preflight())
