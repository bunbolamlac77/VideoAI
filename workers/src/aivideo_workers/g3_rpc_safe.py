"""Strict public RPC entrypoints for G3.

The existing g3_engine remains the deterministic algorithm.
Only Swift ProjectStore can approve committed artifacts.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
import uuid
import hashlib
from typing import Any

from . import g3_engine as engine


def _hex_sha(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(
            char in "0123456789abcdef"
            for char in value
        )
    )


def _dir_from_request(
    params: dict,
) -> Path | None:
    """Only allow staging inside app-managed directory."""
    root = os.environ.get(
        "AIVIDEO_G3_STAGING_ROOT", ""
    )
    requested = params.get("staging_dir")

    if (
        not root
        or not isinstance(requested, str)
        or not requested
    ):
        return None

    base = Path(root).expanduser().resolve()
    dest = Path(requested).expanduser().resolve()

    if not base.is_dir() or not dest.is_dir():
        return None

    if dest != base and base not in dest.parents:
        return None

    return dest


def generate_story(params: dict) -> dict:
    if not isinstance(params, dict):
        raise ValueError(
            "RPC params must be an object"
        )

    claims = params.get("claims")

    if not isinstance(claims, list):
        raise ValueError(
            "claims must be an array"
        )

    seen_claims = set()
    seen_revisions = set()

    for claim in claims:
        if not isinstance(claim, dict):
            raise ValueError(
                "each claim must be an object"
            )

        cid = claim.get("claim_id")
        revision = claim.get(
            "revision_id",
            claim.get("claim_revision_id"),
        )

        if (
            not isinstance(cid, str)
            or not isinstance(revision, str)
        ):
            raise ValueError(
                "claim identity/revision missing"
            )

        if (
            cid in seen_claims
            or revision in seen_revisions
        ):
            return {
                "status": "blocked_duplicate_claim_revision",
                "candidates": [],
            }

        seen_claims.add(cid)
        seen_revisions.add(revision)

        if (
            claim.get("origin") == "user"
            and claim.get("allowed_use")
            == "direct_claim"
        ):
            return {
                "status": "blocked_user_fact_requires_attribution",
                "claim_id": cid,
                "candidates": [],
            }

    return engine.generate_story(params)


def edit_story(params: dict) -> dict:
    return engine.edit_story(params)


def voice_trial(params: dict) -> dict:
    if not isinstance(params, dict):
        raise ValueError(
            "RPC params must be an object"
        )

    dest = _dir_from_request(params)

    if dest is None:
        return {
            "status": "blocked_untrusted_staging_directory",
            "required_env": "AIVIDEO_G3_STAGING_ROOT",
        }

    checked = dict(params)
    checked["staging_dir"] = str(dest)

    # Unique filename per trial; do not overwrite a
    # WAV currently awaiting listening/publication.
    checked["trial_nonce"] = uuid.uuid4().hex

    result = engine.voice_trial(checked)

    if result.get("staging_path"):
        resolved = Path(
            result["staging_path"]
        ).resolve()

        if dest not in resolved.parents:
            raise ValueError(
                "TTS returned WAV outside managed staging"
            )

    return result


def voice_phrases(params: dict) -> dict:
    if not isinstance(params, dict):
        raise ValueError("RPC params must be an object")

    dest = _dir_from_request(params)
    if dest is None:
        return {
            "status": "blocked_untrusted_staging_directory",
            "required_env": "AIVIDEO_G3_STAGING_ROOT",
        }

    checked = dict(params)
    checked["staging_dir"] = str(dest)
    checked["trial_nonce"] = uuid.uuid4().hex

    result = engine.voice_phrases(checked)

    for key in ("combined_path",):
        value = result.get(key)
        if value:
            resolved = Path(value).resolve()
            if dest not in resolved.parents:
                raise ValueError("TTS returned WAV outside managed staging")
    for value in result.get("phrase_paths", []):
        resolved = Path(value).resolve()
        if dest not in resolved.parents:
            raise ValueError("TTS returned WAV outside managed staging")

    return result


def search_cuts(params: dict) -> dict:
    result = engine.search_cuts(params)

    result["core_approval_state"] = (
        "NOT_VERIFIED_BY_PROJECTSTORE"
    )

    events = result.get("trace")

    if isinstance(events, list) and len(events) > 128:
        result["trace_omitted_count"] = (
            len(events) - 128
        )
        result["trace"] = events[:128]

    return result


def stage_cut_plan(params: dict) -> dict:
    """Stage cut; S08 must publish before S19 approval."""
    dest = _dir_from_request(params)

    if dest is None:
        return {
            "status": "blocked_untrusted_staging_directory"
        }

    script = params.get("candidate") or {}
    cut = params.get("cut_result") or {}

    if (
        script.get("status") != "DRAFT_NOT_BUILDABLE"
        or cut.get("status") != "SOLUTION_FOUND"
        or cut.get("validation", {}).get("valid")
        is not True
        or not _hex_sha(
            script.get("script_revision_id")
        )
        or not _hex_sha(
            cut.get("domain_sha256")
        )
    ):
        return {
            "status": "blocked_invalid_script_or_cut"
        }

    plan = {
        "schema_version": "g3-cut-plan-v1",
        "script_revision_id": script[
            "script_revision_id"
        ],
        "scope_revision_id": script[
            "scope_revision_id"
        ],
        "domain_sha256": cut[
            "domain_sha256"
        ],
        "timeline_profile": "M-24-SDR-v1",
        "edit_plan": cut.get(
            "edit_plan", []
        ),
    }

    if len(plan["edit_plan"]) != len(
        script.get("beats", [])
    ):
        return {
            "status": "blocked_cut_beat_mismatch"
        }

    encoded = json.dumps(
        plan,
        ensure_ascii=False,
        allow_nan=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")

    if len(encoded) > 8 * 1024 * 1024:
        raise ValueError(
            "G3 cut artifact exceeds 8 MiB"
        )

    fd, raw = tempfile.mkstemp(
        prefix=".g3-cut-",
        suffix=".json",
        dir=dest,
    )

    try:
        with os.fdopen(fd, "wb") as output:
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())

        final = dest / (
            f"g3_cut_{uuid.uuid4().hex}.json"
        )

        os.replace(raw, final)
    finally:
        if os.path.exists(raw):
            os.unlink(raw)

    return {
        "status": "staged_requires_S08_publication",
        "staging_path": str(final),
        "sha256": hashlib.sha256(
            encoded
        ).hexdigest(),
        "byte_size": len(encoded),
        "approved": False,
    }


def approval_proposal(params: dict) -> dict:
    if not isinstance(params, dict):
        raise ValueError(
            "RPC params must be an object"
        )

    pub_id = params.get(
        "cut_publication_id"
    )
    pub_sha = params.get(
        "cut_publication_sha256"
    )

    try:
        uuid.UUID(str(pub_id))
    except (
        ValueError,
        TypeError,
        AttributeError,
    ):
        return {
            "status": "blocked_cut_not_published_by_core"
        }

    if not _hex_sha(pub_sha):
        return {
            "status": "blocked_cut_publication_sha_invalid"
        }

    proposed = engine.approval_proposal(
        params
    )

    if proposed.get("status") != (
        "ready_for_core_transaction_not_approved"
    ):
        return proposed

    proposed["manifest"][
        "cut_publication_id"
    ] = str(pub_id).upper()

    proposed["manifest"][
        "edit_plan_sha256"
    ] = pub_sha

    proposed["manifest_sha256"] = (
        engine.digest(
            proposed["manifest"]
        )
    )

    proposed["status"] = (
        "ready_for_core_reverification_not_approved"
    )

    return proposed


def script_ready_metrics(params: dict) -> dict:
    result = engine.script_ready_metrics(
        params
    )

    # A caller-provided oracle_locked=True is not
    # independently verified evidence.
    result["audit_status"] = (
        "UNVERIFIED_INPUT_LABEL_ORACLE"
    )

    if result.get("result") == "PASS":
        result["result"] = (
            "DESCRIPTIVE_PASS_NOT_GATE_EVIDENCE"
        )

    return result
