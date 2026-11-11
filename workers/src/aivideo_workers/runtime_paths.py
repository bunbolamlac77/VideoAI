"""Locate the pinned S11 model registry in checkout or app bundle."""
from __future__ import annotations

import os
from pathlib import Path

REGISTRY_NAME = "s11_model_registry.lock.json"


def resolve_s11_registry() -> Path:
    # (P1-20) Runtime contracts resolve from the package/bundle only. `AIVIDEO_CONTRACTS_DIR`
    # let any process running the worker substitute the capability registry (or the model
    # lock) with its own file; a build-provided location must not be caller-controlled.
    if os.environ.get("AIVIDEO_CONTRACTS_DIR"):
        raise RuntimeError(
            "CONTRACTS_DIR_FORBIDDEN: runtime contracts resolve from the package/bundle, "
            "not from AIVIDEO_CONTRACTS_DIR"
        )
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
