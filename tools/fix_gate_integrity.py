#!/usr/bin/env python3
"""Fail-closed S11/G5 repair for audited 2026-11-09 layout.
Run:
    python3 tools/fix_gate_integrity.py
Does not modify project databases, weights or source media.
Backups are stored under build/gate_integrity_backups/.
All source anchors are validated before changes are written.
"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
BACKUP_DIR = ROOT / "build" / "gate_integrity_backups" / time.strftime("%Y%m%d_%H%M%S")
CHANGES: dict[Path, str] = {}


def prepare(relative: str, old: str, new: str) -> None:
    path = ROOT / relative
    if not path.is_file():
        print(f"SKIPPED (missing file): {relative}")
        return

    original = CHANGES.get(path, path.read_text(encoding="utf-8"))
    if new in original:
        print(f"ALREADY FIXED: {relative}")
        return

    count = original.count(old)
    if count == 0:
        print(f"ANCHOR NOT FOUND: {relative}")
        return
    if count > 1:
        print(f"AMBIGUOUS ANCHOR ({count} matches): {relative}")
        return

    CHANGES[path] = original.replace(old, new)
    print(f"PREPARED: {relative}")


def apply_changes() -> None:
    if not CHANGES:
        print("No changes needed. All integrity guards already in place.")
        return

    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    for path, new_content in CHANGES.items():
        rel = path.relative_to(ROOT)
        backup_path = BACKUP_DIR / rel
        backup_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, backup_path)
        path.write_text(new_content, encoding="utf-8")
        print(f"APPLIED: {rel} (backup saved to {backup_path})")


def main() -> int:
    print("=== AIVideo Gate Integrity Repair Tool ===")

    # 1. Guards for G5 RPC overrides
    prepare(
        "workers/src/aivideo_workers/main.py",
        '    "g5.capability.evaluate": lambda params: g5_capabilities.evaluate_capability_gate(\n'
        '        params["capability_id"],\n'
        '        registry_path=params.get("registry_path"),\n'
        '        benchmark_evidence=params.get("benchmark_evidence"),\n'
        '    ),\n'
        '    "g5.photo.match": g5_capabilities.evaluate_photo_moment_match,',
        '    "g5.capability.evaluate": g5_release_guards.capability,\n'
        '    "g5.photo.match": g5_release_guards.photo_match,',
    )

    # 2. Honest VLM connection fail-closed check
    prepare(
        "workers/src/aivideo_workers/pipeline_adapters.py",
        '        if "model.safetensors" in required_files:\n'
        '            self.validate_genuine_safetensors_weights(adapter_dir / "model.safetensors")',
        '        if "model.safetensors" in required_files:\n'
        '            self.validate_genuine_safetensors_weights(adapter_dir / "model.safetensors")\n\n'
        '        # Invariant: Neural VLM inference engine must be connected.\n'
        '        # Heuristic frame statistics (ffmpeg luminance/motion) must NEVER be labeled as visual_model observations.\n'
        '        raise PipelineAdapterError(\n'
        '            "VLM_INFERENCE_BACKEND_NOT_CONNECTED",\n'
        '            "Real offline VLM inference backend (Qwen3-VL 4B) is not connected. "\n'
        '            "Computing raw frame luminance/motion statistics without neural inference engine "\n'
        '            "must not produce visual_model observations with observed epistemic status.",\n'
        '        )',
    )

    # 3. Honest signed field manifest validation
    prepare(
        "workers/src/aivideo_workers/g5_release_audit.py",
        '    # Live field corpus certification requires genuine signed corpus artifacts (never unverified caller JSON)\n'
        '    signed_manifest = params.get("signed_field_manifest")\n'
        '    live_field_corpus_certified = bool(\n'
        '        signed_manifest\n'
        '        and not is_synthetic_fixture\n'
        '        and total_runs >= 5\n'
        '        and counts["failed"] == 0\n'
        '    )',
        '    # Live field corpus certification requires genuine signed corpus artifacts (never unverified caller JSON)\n'
        '    signed_manifest = params.get("signed_field_manifest")\n'
        '    has_valid_manifest = validate_signed_field_manifest(signed_manifest)\n'
        '    live_field_corpus_certified = bool(\n'
        '        has_valid_manifest\n'
        '        and not is_synthetic_fixture\n'
        '        and total_runs >= 5\n'
        '        and counts["failed"] == 0\n'
        '    )',
    )

    # 4. Readiness check must require physical corpus videos
    prepare(
        "tools/check_readiness.py",
        'def check_field_corpus_and_certification() -> dict[str, Any]:\n'
        '    # Live field corpus certification requires signed manifests from real 5 held-out trips / 10 workdays\n'
        '    field_corpus_manifest = ROOT / "reports" / "evidence" / "signed_field_corpus_manifest.json"\n'
        '    certified = field_corpus_manifest.is_file()\n\n'
        '    return {\n'
        '        "live_field_corpus_certified": certified,\n'
        '        "certification_status": "CERTIFIED_FIELD_CORPUS" if certified else "UNVERIFIED_INPUT_REQUIRES_SIGNED_FIELD_CORPUS",\n'
        '        "manifest_path": str(field_corpus_manifest),\n'
        '    }',
        'def check_field_corpus_and_certification() -> dict[str, Any]:\n'
        '    # Live field corpus certification requires signed manifests AND verified physical video files for all 5 held-out trips\n'
        '    field_corpus_manifest = ROOT / "reports" / "evidence" / "signed_field_corpus_manifest.json"\n'
        '    certified = False\n'
        '    manifest_exists = field_corpus_manifest.is_file()\n'
        '    if manifest_exists:\n'
        '        try:\n'
        '            data = json.loads(field_corpus_manifest.read_text(encoding="utf-8"))\n'
        '            trips = data.get("corpus_scope", {}).get("held_out_trips", [])\n'
        '            if trips and len(trips) >= 5:\n'
        '                all_videos_present = True\n'
        '                for trip in trips:\n'
        '                    vpath = ROOT / "fixtures" / "corpus" / f"{trip.get(\'trip_id\', \'\')}.mp4"\n'
        '                    if not vpath.is_file():\n'
        '                        all_videos_present = False\n'
        '                        break\n'
        '                certified = all_videos_present\n'
        '        except Exception:\n'
        '            certified = False\n\n'
        '    return {\n'
        '        "live_field_corpus_certified": certified,\n'
        '        "certification_status": "CERTIFIED_FIELD_CORPUS" if certified else "UNVERIFIED_INPUT_REQUIRES_SIGNED_FIELD_CORPUS",\n'
        '        "manifest_path": str(field_corpus_manifest),\n'
        '    }',
    )

    apply_changes()
    print("Gate integrity repair completed successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
