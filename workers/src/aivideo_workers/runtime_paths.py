"""Locate the pinned S11 model registry in checkout or app bundle."""
from __future__ import annotations

import os
from pathlib import Path

REGISTRY_NAME = "s11_model_registry.lock.json"


def resolve_s11_registry() -> Path:
    environment_directory = os.environ.get("AIVIDEO_CONTRACTS_DIR")
    if environment_directory:
        candidate = (
            Path(environment_directory).expanduser()
            / REGISTRY_NAME
        ).resolve()
        if not candidate.is_file():
            raise FileNotFoundError(
                f"Missing S11 registry at app-provided path: {candidate}"
            )
        return candidate

    package_file = Path(__file__).resolve()
    candidates = [
        package_file.parents[3] / "contracts" / REGISTRY_NAME,
        package_file.parents[2] / "contracts" / REGISTRY_NAME,
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise FileNotFoundError(
        "S11 registry missing in source tree and app bundle"
    )
