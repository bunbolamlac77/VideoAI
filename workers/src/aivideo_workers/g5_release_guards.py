"""Production JSON-RPC guards.
Test-only registry overrides must never cross IPC.
"""
from __future__ import annotations

from typing import Any

from . import g5_capabilities, g5_release_audit


def _trusted_params(value: Any) -> dict:
    if not isinstance(value, dict):
        raise ValueError("RPC params must be an object")
    if "registry_path" in value:
        raise ValueError(
            "REGISTRY_OVERRIDE_FORBIDDEN: production uses pinned S11 registry"
        )
    return dict(value)


def capability(params: dict) -> dict:
    clean = _trusted_params(params)
    return g5_capabilities.evaluate_capability_gate(
        clean["capability_id"]
    )


def photo_match(params: dict) -> dict:
    clean = _trusted_params(params)
    clean.pop("benchmark_evidence", None)
    return g5_capabilities.evaluate_photo_moment_match(clean)
