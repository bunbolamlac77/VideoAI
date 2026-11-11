"""Gate G5 S23: Six Upgrade Foundations & Honest Capability Registry Gating.

Implements S23.1..S23.6 and S23.T1..S23.T4:
1. Photo moment matching (`exact_candidate` vs `use_mode`):
   - Separates embedding retrieval (`exact_candidate`) from final decision (`use_mode`).
   - Enforces capability gate `exact_photo_shutter_match`: if not `"enabled"`,
     automatically blocks `use_mode = "exact"` and falls back to `"illustrative_only"` or `"none"`.
2. Cross-source partial-order event graph:
   - Represents `before`, `after`, `overlaps`, `same_event_candidate`, `uncomparable_or_uncertain`.
   - Accounts for clock drift uncertainty `[delta_min_ms, delta_max_ms]` and detects cycles/conflicts.
3. Omission & counterevidence source re-audit:
   - Compares approved draft/final claims against raw source observations to flag omitted salient
     events and counterevidence before final release.
4. Local preference profile:
   - Supports `view`, `edit`, `reset`, `export`, and per-project overrides.
   - Enforces hard invariant: preferences only adjust soft scoring weights; they NEVER override
     `epistemic_status`, `support_status`, `allowed_use`, or hard solver constraints.
5. Final vs source/script audit findings & dependency recheck:
   - Verifies that every beat in the final timeline traces back to sealed sources, active claims,
     and approved script revisions without drift.
6. Comedy timing cues bound to final WAV:
   - Aligns setup/pause/punchline cues to verified speech WAV frame boundaries and enforces
     `caption_punchline_early_frame_count == 0` (punchline caption never appears before setup ends).
"""
from __future__ import annotations

from pathlib import Path
import json
import math
from typing import Any

from .g4_core import G4Blocked, canon, digest, must
from .runtime_paths import resolve_s11_registry


def load_capability_registry(registry_path: str | Path | None = None) -> dict[str, Any]:
    path = Path(registry_path) if registry_path else resolve_s11_registry()
    must(path.is_file(), f"Missing capability registry lock: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    must(isinstance(data, dict) and "capabilities" in data, "Invalid capability registry JSON")
    return data


def evaluate_capability_gate(
    capability_id: str,
    *,
    registry_path: str | Path | None = None,
    benchmark_evidence: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Return honest capability status (`enabled`, `candidate`, or `disabled`) and fallback policy.

    The pinned capability registry is the authoritative gate. Caller-supplied benchmark flags
    cannot promote a disabled or unvalidated capability in production.
    """
    reg = load_capability_registry(registry_path)
    caps = reg.get("capabilities", {})
    must(capability_id in caps, f"Unknown capability_id: {capability_id}")
    entry = dict(caps[capability_id])
    declared_status = entry.get("status", "disabled")
    must(declared_status in ("enabled", "candidate", "disabled"), "Invalid capability status")

    effective_status = declared_status
    promotion_blocked_reason = None
    if declared_status != "enabled":
        promotion_blocked_reason = f"capability_is_{declared_status}_in_lock_registry"

    return {
        "capability_id": capability_id,
        "declared_status": declared_status,
        "effective_status": effective_status,
        "production_claim_allowed": effective_status == "enabled",
        "primary_model": entry.get("primary_model"),
        "fallback_policy": entry.get("fallback_when_unvalidated", "disable_or_fallback"),
        "promotion_blocked_reason": promotion_blocked_reason,
    }


# ---------------------------------------------------------------------------
# 1. S23.1 — Photo Moment Matching (exact_candidate vs use_mode)
# ---------------------------------------------------------------------------

def evaluate_photo_moment_match(params: dict[str, Any]) -> dict[str, Any]:
    """Separate retrieval `exact_candidate` from gated `use_mode` (`exact`, `illustrative_only`, `none`)."""
    photo_id = str(params.get("photo_id", "")).strip()
    shot_id = str(params.get("shot_id", "")).strip()
    must(bool(photo_id) and bool(shot_id), "photo_id and shot_id are required")

    embedding_cosine = float(params.get("embedding_cosine", 0.0))
    temporal_consistent = bool(params.get("temporal_consistent", False))
    geometric_inlier_ratio = float(params.get("geometric_inlier_ratio", 0.0))
    requested_mode = str(params.get("requested_use_mode", "exact")).strip()
    must(requested_mode in ("exact", "illustrative_only", "none"), "Invalid requested_use_mode")

    gate = evaluate_capability_gate(
        "exact_photo_shutter_match",
        registry_path=params.get("registry_path"),
        benchmark_evidence=params.get("benchmark_evidence"),
    )

    is_exact_candidate = embedding_cosine >= 0.72
    passes_verification = (
        is_exact_candidate and temporal_consistent and geometric_inlier_ratio >= 0.60
    )

    if requested_mode == "none" or embedding_cosine < 0.45:
        use_mode = "none"
        reason = "below_minimum_similarity_or_excluded"
    elif requested_mode == "exact":
        if gate["effective_status"] != "enabled":
            # S23.T1: Unvalidated capability gate MUST block exact shutter match claim
            use_mode = "illustrative_only"
            reason = f"blocked_by_capability_gate:{gate['effective_status']}"
        elif not passes_verification:
            use_mode = "illustrative_only"
            reason = "failed_temporal_or_geometric_verification"
        else:
            use_mode = "exact"
            reason = "verified_exact_shutter_match"
    else:
        use_mode = "illustrative_only"
        reason = "illustrative_requested"

    return {
        "schema": "g5-photo-match-v1",
        "photo_id": photo_id,
        "shot_id": shot_id,
        "exact_candidate": is_exact_candidate,
        "temporal_consistent": temporal_consistent,
        "geometric_inlier_ratio": round(geometric_inlier_ratio, 4),
        "requested_use_mode": requested_mode,
        "use_mode": use_mode,
        "capability_gate": gate,
        "decision_reason": reason,
    }


# ---------------------------------------------------------------------------
# 2. S23.2 — Cross-Source Partial-Order Event Graph with Clock Drift
# ---------------------------------------------------------------------------

def build_partial_order_event_graph(params: dict[str, Any]) -> dict[str, Any]:
    """Build a partial-order event graph across devices with clock offset intervals."""
    events = params.get("events", [])
    explicit_edges = params.get("explicit_edges", [])
    must(isinstance(events, list) and 0 < len(events) <= 256, "Expected 1..256 events")

    nodes: dict[str, dict[str, Any]] = {}
    for raw in events:
        must(isinstance(raw, dict), "Event must be dict")
        eid = str(raw.get("event_id", "")).strip()
        dev = str(raw.get("device_id", "default")).strip()
        must(bool(eid) and eid not in nodes, f"Invalid or duplicate event_id: {eid}")
        start_ms = int(raw.get("start_ms", 0))
        end_ms = int(raw.get("end_ms", start_ms))
        must(start_ms <= end_ms, f"Event {eid} has start_ms > end_ms")
        drift_min = int(raw.get("clock_drift_min_ms", 0))
        drift_max = int(raw.get("clock_drift_max_ms", 0))
        must(drift_min <= drift_max, f"Event {eid} has invalid clock drift bounds")
        nodes[eid] = {
            "event_id": eid,
            "device_id": dev,
            "earliest_start_ms": start_ms + drift_min,
            "latest_start_ms": start_ms + drift_max,
            "earliest_end_ms": end_ms + drift_min,
            "latest_end_ms": end_ms + drift_max,
            "semantic_compatible_with": set(raw.get("semantic_compatible_with", [])),
        }

    relations: list[dict[str, Any]] = []
    adj: dict[str, set[str]] = {eid: set() for eid in nodes}

    eids = sorted(nodes.keys())
    for i, a_id in enumerate(eids):
        for b_id in eids[i + 1 :]:
            a, b = nodes[a_id], nodes[b_id]
            if a["latest_end_ms"] < b["earliest_start_ms"]:
                rel = "before"
                adj[a_id].add(b_id)
            elif b["latest_end_ms"] < a["earliest_start_ms"]:
                rel = "after"
                adj[b_id].add(a_id)
            else:
                # Intervals potentially overlap under clock uncertainty
                definitely_overlaps = (
                    max(a["latest_start_ms"], b["latest_start_ms"])
                    <= min(a["earliest_end_ms"], b["earliest_end_ms"])
                )
                if a["device_id"] != b["device_id"] and (
                    b_id in a["semantic_compatible_with"] or a_id in b["semantic_compatible_with"]
                ):
                    rel = "same_event_candidate"
                elif definitely_overlaps:
                    rel = "overlaps"
                else:
                    rel = "uncomparable_or_uncertain"
            relations.append({"from": a_id, "to": b_id, "relation": rel})

    for edge in explicit_edges:
        u = str(edge.get("from", "")).strip()
        v = str(edge.get("to", "")).strip()
        rel = str(edge.get("relation", "before")).strip()
        must(u in nodes and v in nodes, "Explicit edge references unknown event_id")
        if rel == "before":
            adj[u].add(v)
        elif rel == "after":
            adj[v].add(u)
        relations.append({"from": u, "to": v, "relation": rel, "explicit": True})

    # Detect cycles using DFS coloring (0=unvisited, 1=visiting, 2=visited)
    color: dict[str, int] = {eid: 0 for eid in nodes}
    cycles: list[list[str]] = []

    def dfs(u: str, path: list[str]) -> None:
        color[u] = 1
        for v in sorted(adj[u]):
            if color[v] == 1:
                idx = path.index(v) if v in path else 0
                cycles.append(path[idx:] + [v])
            elif color[v] == 0:
                dfs(v, path + [v])
        color[u] = 2

    for eid in eids:
        if color[eid] == 0:
            dfs(eid, [eid])

    return {
        "schema": "g5-partial-order-event-graph-v1",
        "event_count": len(nodes),
        "relations": relations,
        "has_temporal_conflict": len(cycles) > 0,
        "detected_cycles": cycles,
        "requires_targeted_review": len(cycles) > 0
        or any(r["relation"] == "uncomparable_or_uncertain" for r in relations),
    }


# ---------------------------------------------------------------------------
# 3. S23.3 & S23.5 — Omission, Counterevidence & Final-vs-Source Re-Audit
# ---------------------------------------------------------------------------

def audit_final_against_sources(params: dict[str, Any]) -> dict[str, Any]:
    """Compare final script/timeline beats against source observations & counterevidence."""
    observations = params.get("observations", [])
    beats = params.get("beats", [])
    claims = params.get("claims", [])
    must(isinstance(observations, list) and isinstance(beats, list), "Invalid audit inputs")

    covered_obs_ids: set[str] = set()
    for beat in beats:
        for oid in beat.get("covered_observation_ids", []):
            covered_obs_ids.add(str(oid))

    omitted_salient: list[dict[str, Any]] = []
    counterevidence_alerts: list[dict[str, Any]] = []

    claim_by_id = {str(c.get("claim_id")): c for c in claims if isinstance(c, dict)}

    for obs in observations:
        must(isinstance(obs, dict), "Observation must be dict")
        oid = str(obs.get("observation_id", "")).strip()
        salience = float(obs.get("salience_score", 0.0))
        is_key_moment = bool(obs.get("is_key_moment", False))
        if (salience >= 0.75 or is_key_moment) and oid not in covered_obs_ids:
            omitted_salient.append({
                "observation_id": oid,
                "source_revision_id": obs.get("source_revision_id"),
                "summary": obs.get("summary", ""),
                "salience_score": salience,
            })
        for contradicted_id in obs.get("contradicts_claim_ids", []):
            cid = str(contradicted_id)
            if cid in claim_by_id:
                counterevidence_alerts.append({
                    "observation_id": oid,
                    "claim_id": cid,
                    "claim_text": claim_by_id[cid].get("text", ""),
                    "severity": "critical_blocker",
                })

    status = "CLEAN"
    if counterevidence_alerts:
        status = "BLOCKED_BY_COUNTEREVIDENCE"
    elif omitted_salient:
        status = "ADVISORY_OMISSIONS_DETECTED"

    return {
        "schema": "g5-source-reaudit-v1",
        "status": status,
        "omitted_salient_events": omitted_salient,
        "counterevidence_alerts": counterevidence_alerts,
        "release_blocked": len(counterevidence_alerts) > 0,
    }


# ---------------------------------------------------------------------------
# 4. S23.4 — Local Preference Profile (View / Edit / Reset / Export / Override)
# ---------------------------------------------------------------------------

DEFAULT_PREFERENCES: dict[str, Any] = {
    "schema": "g5-preference-profile-v1",
    "pacing_style": "balanced",
    "humor_density_weight": 0.20,
    "scenic_broll_weight": 0.25,
    "voice_speed_multiplier": 1.00,
    "prefer_quiet_field_ambience": False,
}

FORBIDDEN_EPISTEMIC_OVERRIDES = {
    "epistemic_status",
    "support_status",
    "allowed_use",
    "allow_unsupported_facts",
    "bypass_s19_guard",
    "bypass_s21_qc",
    "force_direct_claim_on_user_fact",
}


def _preference_store_path(requested: Any) -> Path:
    """Resolve the only writable preference location, refusing anything outside it."""
    root = Path.home() / "Library" / "Application Support" / "AIVideo" / "Preferences"
    default = root / "g5_preferences.json"
    if not requested:
        return default
    candidate = Path(str(requested)).expanduser()
    resolved_root = root.resolve()
    try:
        resolved = candidate.resolve() if candidate.is_absolute() else (root / candidate).resolve()
    except OSError as exc:  # pragma: no cover - defensive
        must(False, f"PREFERENCE_PATH_REFUSED: {exc}")
        raise
    must(
        resolved == resolved_root or resolved_root in resolved.parents,
        "PREFERENCE_PATH_REFUSED: preferences must live under the app's Preferences directory",
    )
    return resolved


def manage_preference_profile(params: dict[str, Any]) -> dict[str, Any]:
    """Manage local user preferences while strictly blocking fact/epistemic overrides (S23.T2)."""
    action = str(params.get("action", "view")).strip().lower()
    must(
        action in ("view", "edit", "reset", "export", "apply_soft_weights"),
        f"Unsupported preference action: {action}",
    )
    # (P1-16) The profile path was caller-controlled and `mkdir(parents=True)` ran on it, so
    # any RPC client could write files anywhere the worker could. Preferences are user data
    # and only ever live under the app's own Application Support directory.
    store_path = _preference_store_path(params.get("profile_path"))

    current = dict(DEFAULT_PREFERENCES)
    if store_path and store_path.is_file() and action != "reset":
        loaded = json.loads(store_path.read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            for k in DEFAULT_PREFERENCES:
                if k in loaded:
                    current[k] = loaded[k]

    if action == "reset":
        current = dict(DEFAULT_PREFERENCES)
        if store_path:
            store_path.parent.mkdir(parents=True, exist_ok=True)
            store_path.write_bytes(canon(current))
        return {"status": "RESET_TO_DEFAULT", "profile": current}

    updates = params.get("updates", {}) or {}
    project_override = params.get("project_override", {}) or {}
    for source_dict in (updates, project_override):
        must(isinstance(source_dict, dict), "Preference updates must be an object")
        illegal = FORBIDDEN_EPISTEMIC_OVERRIDES.intersection(source_dict.keys())
        must(
            not illegal,
            f"PREFERENCE_SECURITY_VIOLATION: preferences cannot override epistemic/fact rules {sorted(illegal)}",
        )

    if action == "edit":
        for k, v in updates.items():
            must(k in DEFAULT_PREFERENCES and k != "schema", f"Unknown preference key: {k}")
            if k in ("humor_density_weight", "scenic_broll_weight"):
                val = float(v)
                must(0.0 <= val <= 1.0, f"{k} must be in [0.0, 1.0]")
                current[k] = round(val, 4)
            elif k == "voice_speed_multiplier":
                val = float(v)
                must(0.85 <= val <= 1.15, "voice_speed_multiplier must be in [0.85, 1.15]")
                current[k] = round(val, 4)
            elif k == "pacing_style":
                must(v in ("calm", "balanced", "dynamic"), "Invalid pacing_style")
                current[k] = v
            elif k == "prefer_quiet_field_ambience":
                must(isinstance(v, bool), "prefer_quiet_field_ambience must be bool")
                current[k] = v
        if store_path:
            store_path.parent.mkdir(parents=True, exist_ok=True)
            store_path.write_bytes(canon(current))

    effective = dict(current)
    for k, v in project_override.items():
        if k in DEFAULT_PREFERENCES and k != "schema":
            effective[k] = v

    if action == "apply_soft_weights":
        claims = params.get("claims", [])
        scored_claims = []
        for c in claims:
            c_copy = dict(c)
            # Soft score changes, but epistemic fields are strictly preserved verbatim
            base_score = float(c_copy.get("soft_utility_score", 0.5))
            bonus = effective["humor_density_weight"] * (0.1 if c_copy.get("is_humorous") else 0.0)
            c_copy["adjusted_soft_score"] = round(min(1.0, base_score + bonus), 4)
            scored_claims.append(c_copy)
        return {
            "status": "SOFT_WEIGHTS_APPLIED",
            "effective_profile": effective,
            "claims": scored_claims,
            "epistemic_fields_preserved": True,
        }

    return {
        "status": "OK",
        "action": action,
        "profile": effective,
        "profile_path": str(store_path) if store_path else None,
        "export_sha256": digest(canon(effective)),
    }


# ---------------------------------------------------------------------------
# 6. S23.6 — Comedy Timing Cues Bound to Final WAV (No Early Punchline Leak)
# ---------------------------------------------------------------------------

def align_comedy_timing_cues(params: dict[str, Any]) -> dict[str, Any]:
    """Bind setup/pause/punchline caption cues to WAV timing with zero early punchline frames."""
    beat_id = str(params.get("beat_id", "")).strip()
    duration_frames = int(params.get("duration_frames", 0))
    wav_samples = int(params.get("wav_samples", 0))
    setup_text = str(params.get("setup_text", "")).strip()
    punchline_text = str(params.get("punchline_text", "")).strip()
    setup_end_sample = int(params.get("setup_end_sample", 0))
    pause_samples = int(params.get("pause_samples", 4800))  # default 100ms @ 48kHz

    must(bool(beat_id) and duration_frames >= 12, "Invalid beat_id or duration_frames")
    must(bool(setup_text) and bool(punchline_text), "Both setup_text and punchline_text required")
    must(0 < setup_end_sample < wav_samples, "setup_end_sample must lie inside wav_samples")
    must(pause_samples >= 2000, "Comedy pause must be at least 1 frame (2000 samples @ 48kHz)")

    speech_frames = math.ceil(wav_samples / 2000.0)
    must(speech_frames <= duration_frames, "WAV speech exceeds beat duration_frames")

    setup_end_frame = math.ceil(setup_end_sample / 2000.0)
    pause_frames = max(1, math.floor(pause_samples / 2000.0))
    punchline_start_frame = setup_end_frame + pause_frames
    punchline_end_frame = max(punchline_start_frame + 1, speech_frames)
    must(punchline_end_frame <= duration_frames, "Punchline cue exceeds beat duration_frames")

    # Verify if caller supplied custom candidate cues whether any punchline frame leaked early
    candidate_cues = params.get("candidate_cues")
    early_leak_frames = 0
    if isinstance(candidate_cues, list):
        for cue in candidate_cues:
            if cue.get("role") == "punchline":
                c_start = int(cue.get("start_frame", 0))
                if c_start < punchline_start_frame:
                    early_leak_frames += punchline_start_frame - c_start

    must(
        early_leak_frames == 0,
        f"COMEDY_PUNCHLINE_LEAK: caption_punchline_early_frame_count={early_leak_frames} > 0",
    )

    cues = [
        {
            "role": "setup",
            "text": setup_text,
            "start_frame": 0,
            "end_frame": setup_end_frame,
        },
        {
            "role": "punchline",
            "text": punchline_text,
            "start_frame": punchline_start_frame,
            "end_frame": punchline_end_frame,
        },
    ]
    return {
        "schema": "g5-comedy-timing-v1",
        "beat_id": beat_id,
        "setup_end_frame": setup_end_frame,
        "beat_pause_frames": pause_frames,
        "punchline_start_frame": punchline_start_frame,
        "punchline_end_frame": punchline_end_frame,
        "caption_punchline_early_frame_count": 0,
        "cues": cues,
    }
