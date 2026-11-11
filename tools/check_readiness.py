#!/usr/bin/env python3
"""Offline AIVideo release preflight for macOS arm64."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
from typing import Any

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
    # Verify the worker runtime selected by the app, not merely this script's Python.
    support_python = Path.home() / "Library/Application Support/AIVideo/Runtimes/g0-mlx-runtime/bin/python3"
    local_python = ROOT / "workers/.venv/bin/python3"
    chosen_python = next(
        (str(p) for p in (Path(os.environ.get("AIVIDEO_PYTHON_PATH", "/no-such-python")),
                                 support_python, local_python) if p.is_file() and os.access(p, os.X_OK)),
        sys.executable,
    )
    py_probe_ok, py_output = command([chosen_python, "-c", "import sys; print(*sys.version_info[:3], sep='.')"])
    py_parts = py_output.splitlines()[0].strip().split(".") if py_probe_ok else []
    try:
        py_version = tuple(int(x) for x in py_parts)
    except ValueError:
        py_version = ()

    ffmpeg_bin = shutil.which("ffmpeg")
    ffprobe_bin = shutil.which("ffprobe")
    swift_bin = shutil.which("swift")

    ffmpeg_ok, ffmpeg_ver = command(["ffmpeg", "-version"]) if ffmpeg_bin else (False, "missing")
    ffprobe_ok, ffprobe_ver = command(["ffprobe", "-version"]) if ffprobe_bin else (False, "missing")
    swift_ok, swift_ver = command(["swift", "--version"]) if swift_bin else (False, "missing")

    is_darwin_arm64 = (system == "Darwin") and (machine in ("arm64", "aarch64"))
    py_ok = len(py_version) >= 2 and py_version[:2] == (3, 12)

    pass_all = bool(is_darwin_arm64 and py_ok and ffmpeg_ok and ffprobe_ok and swift_ok)

    return {
        "passed": pass_all,
        "os": system,
        "arch": machine,
        "is_darwin_arm64": is_darwin_arm64,
        "python_version": py_output.splitlines()[0] if py_probe_ok else "UNKNOWN",
        "python_path": chosen_python,
        "python_ok": py_ok,
        "ffmpeg": {"installed": bool(ffmpeg_bin), "version": ffmpeg_ver.split("\n")[0] if ffmpeg_ok else ffmpeg_ver},
        "ffprobe": {"installed": bool(ffprobe_bin), "version": ffprobe_ver.split("\n")[0] if ffprobe_ok else ffprobe_ver},
        "swift": {"installed": bool(swift_bin), "version": swift_ver.split("\n")[0] if swift_ok else swift_ver},
    }


def check_app_bundle(allow_adhoc: bool = False) -> dict[str, Any]:
    binary = APP / "Contents" / "MacOS" / "AIVideo"
    app_exists = APP.is_dir()
    bin_exists = binary.is_file()

    arch_ok = False
    codesign_ok = False
    codesign_detail = "app not found"
    team_id = "not set"
    is_adhoc = True
    team_id_ok = True

    if bin_exists:
        file_ok, file_out = command(["file", str(binary)])
        arch_ok = "arm64" in file_out
        cs_ok, cs_out = command(["codesign", "--verify", "--deep", "--strict", str(APP)])
        codesign_ok = cs_ok
        codesign_detail = cs_out or "valid"

        # Check TeamIdentifier and adhoc status
        info_ok, info_out = command(["codesign", "-d", "-v", str(APP)])
        full_info = (info_out or "") + "\n" + (cs_out or "")
        for line in full_info.splitlines():
            line = line.strip()
            if line.startswith("TeamIdentifier="):
                team_id = line.split("=", 1)[1].strip()
            if line.startswith("Signature="):
                is_adhoc = "adhoc" in line.lower()

        # (P1-22) An ad-hoc signature is not a release signature. It used to pass whenever
        # AIVIDEO_RELEASE_TEAM_ID was unset, so "no team configured" silently meant "ready".
        # Ad-hoc is now a blocker unless the caller explicitly asks for a development build.
        if is_adhoc and not allow_adhoc:
            team_id_ok = False
            codesign_detail = (
                "Ad-hoc signed app: a release requires an Apple Developer signature "
                "(set AIVIDEO_RELEASE_TEAM_ID and sign with --options runtime)"
            )
        required_team = os.environ.get("AIVIDEO_RELEASE_TEAM_ID", "").strip()
        if required_team:
            if is_adhoc or team_id != required_team or team_id == "not set":
                team_id_ok = False
                codesign_detail = (
                    f"Release requires Apple Developer signature with Team ID '{required_team}', "
                    f"got TeamIdentifier='{team_id}' (Signature={'adhoc' if is_adhoc else 'signed'})"
                )

    passed = app_exists and bin_exists and arch_ok and codesign_ok and team_id_ok
    return {
        "app_exists": app_exists,
        "binary_exists": bin_exists,
        "is_arm64": arch_ok,
        "codesign_verified": codesign_ok and team_id_ok,
        "codesign_detail": codesign_detail,
        "team_identifier": team_id,
        "is_adhoc": is_adhoc,
        "passed": passed,
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
            "passed": shutter_disabled,
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
    """Fail closed if the real weights or pinned local artifact manifest are unverified.

    2026-11-10 fix (D14): this now calls the same inspector as the worker
    (`model_installation.inspect_model_installation`) instead of maintaining a
    second, divergent definition of "model installed". Release requires `verified`
    (install manifest + hashes); the worker may still run on `present_unverified`
    but reports that weaker provenance to the caller.
    """
    from aivideo_workers.model_installation import inspect_model_installation

    status = inspect_model_installation(deep=True)
    if status["state"] == "verified":
        return {
            "models_root": status["models_root"],
            "visual_model_installed": True,
            "weights_byte_size": (Path(status["directory"]) / "model.safetensors").stat().st_size,
            "pinned_model_revision": status.get("revision"),
            "model_id": status.get("model_id"),
            "status": "VERIFIED_PINNED_LOCAL",
        }
    return {
        "models_root": status["models_root"],
        "visual_model_installed": False,
        "weights_byte_size": 0,
        "status": "NOT_VERIFIED",
        "installation_state": status["state"],
        "reason": status["reason"],
    }


def check_resolve_installation() -> dict[str, Any]:
    resolve_app = Path("/Applications/DaVinci Resolve/DaVinci Resolve.app")
    installed = resolve_app.is_dir()
    return {
        "path": str(resolve_app),
        "installed": installed,
    }


SMOKE_CORPORA = (
    ROOT / "fixtures" / "smoke",
    ROOT / "fixtures" / "corpus",
)


def check_smoke_corpus_is_not_field_evidence() -> dict[str, Any]:
    """(P0-06) The clips committed under `fixtures/smoke/` are 36-frame title cards labelled
    by an agent. They are useful for smoke tests and are *never* field evidence, so they must
    report themselves as such. This check fails closed if a clip is relabelled as field data
    without being replaced by real footage."""
    findings: list[dict[str, Any]] = []
    blockers: list[str] = []
    for base in SMOKE_CORPORA:
        labels_dir = base / "labels"
        if not labels_dir.is_dir():
            continue
        for label_file in sorted(labels_dir.glob("*.json")):
            try:
                data = json.loads(label_file.read_text(encoding="utf-8"))
            except Exception as exc:  # noqa: BLE001 - surfaced as a blocker
                blockers.append(f"SMOKE_LABEL_UNREADABLE:{label_file.name}:{exc}")
                continue
            labeler = data.get("labeler_type")
            source_kind = data.get("source_kind")
            claims = data.get("claims") or []
            events = data.get("events") or []
            findings.append(
                {
                    "label": label_file.name,
                    "labeler_type": labeler,
                    "source_kind": source_kind,
                    "claims": len(claims),
                    "events": len(events),
                }
            )
            if labeler == "human" or source_kind == "field_footage":
                blockers.append(
                    f"SMOKE_CLIP_PRESENTED_AS_FIELD:{label_file.name}:"
                    f"labeler={labeler},source={source_kind}"
                )
    return {
        "smoke_corpus_present": bool(findings),
        "smoke_clips": findings,
        "smoke_label_blockers": blockers,
        "smoke_is_field_evidence": False,
    }


def check_field_corpus_and_certification(
    manifest_path: Path | None = None,
) -> dict[str, Any]:
    """A signed manifest is necessary but not sufficient: it must also be real
    footage with human labels. A valid signature over synthetic fixtures proves the
    key works, not that the model was accepted on field data."""
    from aivideo_workers.g5_release_audit import validate_signed_field_manifest

    path = manifest_path or (ROOT / "reports" / "evidence" / "signed_field_corpus_manifest.json")
    corpus_dir = ROOT / "fixtures" / "smoke"
    signature_valid = False
    scope: dict[str, Any] = {}
    blockers: list[str] = []
    if path.is_file():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            scope = data.get("corpus_scope", {}) if isinstance(data, dict) else {}
            authority = data.get("signing_authority", {})
            algorithm = authority.get("algorithm", "") if isinstance(authority, dict) else ""
            signature_valid = (
                algorithm.strip().lower() == "ed25519"
                and validate_signed_field_manifest(
                    data, corpus_dir=corpus_dir, enforce_signature=True
                )
            )
        except Exception as exc:
            blockers.append(f"MANIFEST_UNREADABLE:{exc}")
    else:
        blockers.append("MANIFEST_MISSING")

    labels = scope.get("labels", {}) if isinstance(scope, dict) else {}
    corpus_kind = str(scope.get("corpus_kind", "")) if isinstance(scope, dict) else ""
    labelers = list(labels.get("labeler_types") or [])
    sources = list(labels.get("source_kinds") or [])

    if not signature_valid:
        blockers.append("SIGNED_MANIFEST_INVALID")
    if corpus_kind != "E0_5_HELD_OUT_TRIPS":
        blockers.append(f"CORPUS_KIND_NOT_FIELD:{corpus_kind or 'unknown'}")
    if labelers != ["human"]:
        blockers.append(f"LABELS_NOT_HUMAN:{labelers}")
    if sources != ["field_footage"]:
        blockers.append(f"NOT_FIELD_FOOTAGE:{sources}")

    certified = not blockers
    return {
        "live_field_corpus_certified": certified,
        "certification_status": (
            "CERTIFIED_FIELD_CORPUS" if certified else "UNVERIFIED_INPUT_REQUIRES_SIGNED_FIELD_CORPUS"
        ),
        "certification_blockers": blockers,
        "corpus_kind": corpus_kind,
        "labels": labels,
        "manifest_path": str(path),
    }


class _Args:
    allow_adhoc = False


ARGS = _Args()


def run_preflight() -> int:
    print("=== AIVideo Release Readiness Preflight (macOS arm64) ===")

    toolchain = check_toolchain()
    app_info = check_app_bundle(allow_adhoc=ARGS.allow_adhoc)
    contracts = check_contracts_and_registry()
    models = check_models_presence()
    resolve = check_resolve_installation()
    field_corpus = check_field_corpus_and_certification()
    smoke = check_smoke_corpus_is_not_field_evidence()

    blockers: list[str] = []

    if not toolchain["passed"]:
        blockers.append("TOOLCHAIN_NOT_MET: Required macOS arm64, worker Python 3.12, ffmpeg, ffprobe, and swift")

    if not app_info["passed"]:
        blockers.append(f"APP_BUNDLE_NOT_VERIFIED: {app_info['codesign_detail']}")

    if not contracts["passed"]:
        blockers.append(f"REGISTRY_OR_CAPABILITY_GATE_ERROR: {contracts.get('error') or 'disabled capability was unexpectedly enabled'}")

    if not models["visual_model_installed"]:
        blockers.append("REAL_QWEN_VL_WEIGHTS_UNVERIFIED: pinned offline model not verified (missing/corrupt/unsupported install)")

    # DaVinci Resolve is OPTIONAL since Phase 1c: the G4/G5 render path defaults to
    # the bundled ffmpeg native renderer. Resolve is only needed for the legacy
    # managed-timeline/manual-handoff branch, so a missing install is a notice,
    # not a release blocker.
    warnings: list[str] = []
    if not resolve["installed"]:
        warnings.append(
            "DAVINCI_RESOLVE_OPTIONAL_NOT_INSTALLED: ffmpeg native renderer is the default; "
            "install Resolve Studio only if you need the managed Resolve timeline / .drp handoff"
        )

    if smoke["smoke_label_blockers"]:
        blockers.append(
            "SMOKE_CORPUS_PRESENTED_AS_FIELD: committed smoke clips are labelled as field "
            f"footage ({', '.join(smoke['smoke_label_blockers'])})"
        )

    if not field_corpus["live_field_corpus_certified"]:
        detail = ", ".join(field_corpus.get("certification_blockers", [])) or "unknown"
        blockers.append(
            "UNVERIFIED_INPUT_REQUIRES_SIGNED_FIELD_CORPUS: E0/E1 real video held-out runs "
            f"require signed field corpus ({detail})"
        )

    report = {
        "schema": "aivideo-readiness-preflight-v1",
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "platform": platform.platform(),
        "ready_for_production_release": len(blockers) == 0,
        "blockers": blockers,
        "warnings": warnings,
        "toolchain": toolchain,
        "app_bundle": app_info,
        "contracts": contracts,
        "models": models,
        "davinci_resolve": resolve,
        "field_corpus": field_corpus,
        "smoke_corpus": smoke,
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
    smoke_count = len(smoke["smoke_clips"])
    print(
        f"Committed Smoke Corpus: {smoke_count} clip(s), not field evidence"
        if smoke_count
        else "Committed Smoke Corpus: none"
    )

    if blockers:
        print("\nActive Blockers (Intentional Gate Enforcement):")
        for b in blockers:
            print(f"  - [BLOCKER] {b}")
        print("\nReadiness Preflight Decision: NO-GO (Blockers must be closed before field release)")
        return 2

    print("\nReadiness Preflight Decision: GO")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="AIVideo release readiness preflight")
    parser.add_argument(
        "--allow-adhoc",
        action="store_true",
        help="development only: accept an ad-hoc signed app instead of requiring a Developer ID",
    )
    ARGS.allow_adhoc = parser.parse_args().allow_adhoc
    sys.exit(run_preflight())
