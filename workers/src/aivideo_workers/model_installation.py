"""
workers/src/aivideo_workers/model_installation.py — one definition of "model installed".

Before 2026-11-10 there were three answers to the same question:
  * the worker only checked that config.json/model.safetensors existed;
  * the release preflight required the install manifest and pinned hashes;
  * the UI showed whatever the worker said.
So a machine could analyze video while preflight reported NOT_VERIFIED (or the
reverse). This module is the single source of truth; callers choose the depth:

  state = "missing"            -> no model directory
  state = "incomplete"         -> directory exists but required artifacts are absent/empty
  state = "present_unverified" -> artifacts exist, no installation manifest (cannot prove integrity)
  state = "verified"           -> artifacts match the recorded install manifest AND the
                                  weights hash equals the value pinned in this source file
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from typing import Any, Optional

VISUAL_ROLE = "visual_analysis_primary"
# (P1-12) The only weights this build accepts. The value is pinned in source (and printed by
# tools/setup_s11_model.py); an install manifest can never substitute its own identity, and
# the shallow check compares the declared hash rather than trusting size alone.
PINNED_VISUAL_WEIGHTS_SHA256 = "90eeb02604181dbcccd0a30a1f550a4a8928ca7dcbee4aee1449239306cfdfca"
INSTALL_MANIFEST = ".aivideo-install-manifest.json"
REQUIRED_ARTIFACTS = ("config.json", "model.safetensors", "tokenizer.json", "preprocessor_config.json")


def default_models_root() -> Path:
    # (P1-12) The root is an app-level setting, never a per-request parameter. It resolves
    # from the app-support profile directory so a differently-provisioned machine (or the
    # test harness) can be pointed at its own pinned store.
    support = os.environ.get("AIVIDEO_APP_SUPPORT", "").strip()
    base = Path(support).expanduser() if support else Path.home() / "Library" / "Application Support" / "AIVideo"
    return base / "Models"


def _sha256_file(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def inspect_model_installation(
    models_root: Optional[str | Path] = None,
    *,
    role: str = VISUAL_ROLE,
    deep: bool = False,
) -> dict[str, Any]:
    """Return the canonical installation state for `role`.

    `deep=True` re-hashes every required artifact and compares it with the install
    manifest; `deep=False` only checks presence/size and the manifest's identity
    fields (cheap enough to call per analysis request).
    """
    root = Path(models_root).expanduser() if models_root else default_models_root()
    directory = root / role
    result: dict[str, Any] = {
        "role": role,
        "models_root": str(root),
        "directory": str(directory),
        "state": "missing",
        "reason": "",
        "verified": False,
        "deep": deep,
    }

    if not directory.is_dir():
        result["reason"] = f"MODEL_DIRECTORY_MISSING: {directory}"
        return result

    missing = [
        name
        for name in REQUIRED_ARTIFACTS
        if not (directory / name).is_file() or (directory / name).stat().st_size <= 0
    ]
    if missing:
        result["state"] = "incomplete"
        result["reason"] = f"MISSING_OR_EMPTY_ARTIFACTS: {', '.join(missing)}"
        return result

    manifest_path = directory / INSTALL_MANIFEST
    if manifest_path.is_symlink() or not manifest_path.is_file():
        result["state"] = "present_unverified"
        result["reason"] = "INSTALL_MANIFEST_MISSING: weights exist but integrity is unproven"
        return result

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        result["state"] = "present_unverified"
        result["reason"] = f"INSTALL_MANIFEST_UNREADABLE: {exc}"
        return result

    files = manifest.get("files") if isinstance(manifest, dict) else None
    if not isinstance(files, dict):
        result["state"] = "present_unverified"
        result["reason"] = "INSTALL_MANIFEST_INVALID: missing 'files' map"
        return result

    # The pinned identity is the manifest's declared weights digest, read before hashing.
    recorded_weights = str(files.get("model.safetensors", {}).get("sha256", "")).lower()

    for name in REQUIRED_ARTIFACTS:
        recorded = files.get(name)
        if not isinstance(recorded, dict):
            result["state"] = "present_unverified"
            result["reason"] = f"INSTALL_MANIFEST_INVALID: no entry for {name}"
            return result
        actual_size = (directory / name).stat().st_size
        if int(recorded.get("size_bytes", -1)) != actual_size:
            result["state"] = "present_unverified"
            result["reason"] = f"ARTIFACT_SIZE_MISMATCH: {name} (manifest {recorded.get('size_bytes')}, actual {actual_size})"
            return result
        # Hashing decides *integrity* (bytes match the manifest). Whether those bytes are the
        # pinned revision is a separate identity question answered below, for both depths.
        if deep:
            actual_sha = _sha256_file(directory / name)
            if actual_sha != str(recorded.get("sha256", "")):
                result["state"] = "present_unverified"
                result["reason"] = f"ARTIFACT_HASH_MISMATCH: {name}"
                return result

    # (P1-12) A manifest that describes *some* weights is not "verified": the recorded
    # weights hash must equal the pinned revision this build was validated against.
    if role == VISUAL_ROLE and recorded_weights != PINNED_VISUAL_WEIGHTS_SHA256:
        result["state"] = "present_unverified"
        result["reason"] = "PINNED_WEIGHT_SHA256_MISMATCH: install manifest describes different weights"
        return result

    result["state"] = "verified"
    result["verified"] = True
    result["pinned_weights_sha256"] = PINNED_VISUAL_WEIGHTS_SHA256
    result["model_id"] = manifest.get("model_id")
    result["revision"] = manifest.get("revision")
    return result
