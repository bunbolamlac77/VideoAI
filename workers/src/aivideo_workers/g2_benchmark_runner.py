"""
workers/src/aivideo_workers/g2_benchmark_runner.py — S15 Gate G2 Analysis & Evidence Benchmark Harness,
Group-Aware Split/Leakage Verifier, Wilson 95% CI, 10,000-Iteration Group Bootstrap & Gate G2 Evaluator.
Compliant with docs/06-DECISIONS-AND-RISKS.md, docs/08-ACCURACY-FIRST.md (Sections 12, 15, 20),
docs/09-UPGRADES-AND-ACCEPTANCE.md (Sections 3, 4, 8; AI-01..AI-06, AI-09, REL-01),
and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S15).
"""

from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field
import hashlib
import json
import math
from pathlib import Path
import random
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

from .semantic_verifier import (
    DECISION_POLICY_VERSION,
    VERIFIER_POLICY_VERSION,
    AtomicClaimProposal,
    EvidenceEdge,
    evaluate_claim_support_and_use,
)


G2_BENCHMARK_TARGET_VERSION = "acceptance-targets-v0.1"


class G2BenchmarkError(RuntimeError):
    """Scoped error raised by S15 Gate G2 benchmark runner."""

    def __init__(self, code: str, message: str, details: Optional[Dict[str, Any]] = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}


@dataclass(frozen=True)
class FrozenG2EvaluationManifest:
    """
    S15.3 & docs/09 Section 3.4:
    Frozen evaluation configuration locked AFTER development tuning and BEFORE held-out evaluation.
    """

    manifest_id: str
    target_version: str
    runtime_profile_id: str
    decision_policy_version: str
    verifier_policy_version: str
    bootstrap_iterations: int
    bootstrap_seed: int
    dev_trip_group_ids: List[str]
    holdout_trip_group_ids: List[str]
    prompt_example_group_ids: List[str]
    cached_summary_group_ids: List[str]

    def compute_lock_sha256(self) -> str:
        canonical = json.dumps(dataclasses.asdict(self), sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def verify_split_and_anti_leakage(
    *,
    manifest: FrozenG2EvaluationManifest,
    asset_to_group_map: Dict[str, str],
    dev_asset_ids: Sequence[str],
    holdout_asset_ids: Sequence[str],
) -> None:
    """
    S15.1 & S15.T3 (docs/09 Section 3.1 & 3.4):
    1. Ensures `dev_trip_group_ids` and `holdout_trip_group_ids` are strictly disjoint.
    2. Ensures no asset or sibling clip from the same `trip_group_id` appears in both dev and holdout.
    3. Ensures `prompt_example_group_ids` and `cached_summary_group_ids` never draw from `holdout_trip_group_ids`.
    """
    dev_groups = set(manifest.dev_trip_group_ids)
    holdout_groups = set(manifest.holdout_trip_group_ids)

    overlap_groups = dev_groups.intersection(holdout_groups)
    if overlap_groups:
        raise G2BenchmarkError(
            "SPLIT_GROUP_LEAKAGE",
            f"Trip/workday group(s) appear in both dev and holdout: {sorted(overlap_groups)}",
        )

    dev_asset_groups = {asset_to_group_map[a] for a in dev_asset_ids if a in asset_to_group_map}
    holdout_asset_groups = {asset_to_group_map[a] for a in holdout_asset_ids if a in asset_to_group_map}
    cross_split_groups = dev_asset_groups.intersection(holdout_asset_groups)
    if cross_split_groups:
        raise G2BenchmarkError(
            "SIBLING_CLIP_SPLIT_LEAKAGE",
            f"Assets from the same trip group were split across dev and holdout: {sorted(cross_split_groups)}",
        )

    leaked_prompts = set(manifest.prompt_example_group_ids).intersection(holdout_groups)
    if leaked_prompts:
        raise G2BenchmarkError(
            "HOLDOUT_PROMPT_LEAKAGE",
            f"Prompt examples leaked from holdout group(s): {sorted(leaked_prompts)}",
        )

    leaked_cache = set(manifest.cached_summary_group_ids).intersection(holdout_groups)
    if leaked_cache:
        raise G2BenchmarkError(
            "HOLDOUT_CACHE_LEAKAGE",
            f"Cached summaries/preferences leaked from holdout group(s): {sorted(leaked_cache)}",
        )


def compute_wilson_95_ci(successes: int, total: int, z: float = 1.959963984540054) -> Tuple[Optional[float], Optional[float]]:
    """
    docs/09 Section 3.5: Computes Wilson score 95% confidence interval for a binomial proportion.
    Returns (None, None) when total == 0 (never fabricates 100% on zero denominator).
    """
    if total <= 0:
        return (None, None)
    n = float(total)
    p = float(successes) / n
    z2 = z * z
    denom = 1.0 + z2 / n
    center = (p + z2 / (2.0 * n)) / denom
    half_width = (z / denom) * math.sqrt((p * (1.0 - p) / n) + (z2 / (4.0 * n * n)))
    low = max(0.0, round(center - half_width, 6))
    high = min(1.0, round(center + half_width, 6))
    return (low, high)


def compute_group_bootstrap_95_ci(
    *,
    group_outcomes: Dict[str, Tuple[int, int]],  # group_id -> (numerator_count, denominator_count)
    iterations: int = 10000,
    seed: int = 20261109,
) -> Dict[str, Any]:
    """
    docs/09 Section 3.5:
    Cluster bootstrap by independent trip/workday group (`iterations = 10,000` with fixed `seed`).
    Resamples whole groups with replacement, keeping all claims/events within a group together.
    Also reports per-group ratios, min, and max.
    """
    group_ids = sorted(group_outcomes.keys())
    k = len(group_ids)
    if k == 0:
        return {
            "group_count": 0,
            "bootstrap_ci_95": [None, None],
            "group_min": None,
            "group_max": None,
            "per_group_ratios": {},
        }

    per_group_ratios: Dict[str, Optional[float]] = {}
    valid_group_ratios: List[float] = []
    for gid in group_ids:
        num, den = group_outcomes[gid]
        if den > 0:
            r = round(num / float(den), 6)
            per_group_ratios[gid] = r
            valid_group_ratios.append(r)
        else:
            per_group_ratios[gid] = None

    rng = random.Random(seed)
    samples: List[float] = []
    for _ in range(iterations):
        sum_num = 0
        sum_den = 0
        for _ in range(k):
            picked = group_ids[rng.randrange(k)]
            n_i, d_i = group_outcomes[picked]
            sum_num += n_i
            sum_den += d_i
        if sum_den > 0:
            samples.append(sum_num / float(sum_den))

    if not samples:
        return {
            "group_count": k,
            "bootstrap_ci_95": [None, None],
            "group_min": None,
            "group_max": None,
            "per_group_ratios": per_group_ratios,
        }

    samples.sort()
    low_idx = int(0.025 * (len(samples) - 1))
    high_idx = int(0.975 * (len(samples) - 1))
    return {
        "group_count": k,
        "bootstrap_seed": seed,
        "bootstrap_iterations": iterations,
        "bootstrap_ci_95": [round(samples[low_idx], 6), round(samples[high_idx], 6)],
        "group_min": round(min(valid_group_ratios), 6) if valid_group_ratios else None,
        "group_max": round(max(valid_group_ratios), 6) if valid_group_ratios else None,
        "per_group_ratios": per_group_ratios,
    }


@dataclass(frozen=True)
class LabeledClaimOpportunity:
    """
    S15.2 & S15.4: A labeled claim decision opportunity at the G2 `analysis_eligible` checkpoint.
    Includes oracle ground-truth (`oracle_is_truthfully_supported`, `oracle_allowed_use_set`)
    so the runner can detect semantic false accepts even when schema/JSON is valid (S15.T1).
    """

    opportunity_id: str
    trip_group_id: str
    workday_id: str
    claim: AtomicClaimProposal
    evidence_edges: List[EvidenceEdge]
    proposed_narrative_type: str
    oracle_is_truthfully_supported: bool
    oracle_allowed_use_set: List[str]  # e.g. ['direct_claim'] or ['attributed_or_qualified'] or ['exclude']
    nonliteral_has_false_premise: bool = False


@dataclass(frozen=True)
class LabeledObservableEvent:
    """
    S15.2 & docs/09 Section 3.3:
    An important observable event labeled prior to running the benchmark.
    Event localization window rule: detected evidence duration must be `<= max(2 * labeled_duration_sec, 2.0)`
    (unless `allows_long_context` is True) — returning the entire clip as evidence is rejected!
    """

    event_id: str
    trip_group_id: str
    workday_id: str
    source_revision_id: str
    expected_action: str
    decisive_frame_id: int
    labeled_duration_sec: float
    detected_action: Optional[str]
    detected_frame_ids: List[int]
    detected_evidence_duration_sec: float
    allows_long_context: bool = False


@dataclass(frozen=True)
class VerifierAdversarialCase:
    """
    S15.4 & docs/09 Section 4.1 (AI-05):
    Dedicated adversarial verifier test case:
    - At least 50 known-unsupported/false claims (including >= 20 critical) + supported claims to measure false rejection.
    """

    case_id: str
    trip_group_id: str
    category: str  # 'irrelevant_citation' | 'partial_compound' | 'unproven_causal' | 'cross_session_confusion' | 'user_fact_as_observed' | 'context_negation' | 'false_premise_humor' | 'unknown_unprovable' | 'valid_supported_control'
    is_ground_truth_unsupported: bool
    claim: AtomicClaimProposal
    evidence_edges: List[EvidenceEdge]
    proposed_narrative_type: str
    nonliteral_has_false_premise: bool = False


def evaluate_observable_event_detection(ev: LabeledObservableEvent) -> Tuple[bool, str]:
    """
    docs/09 Section 3.3:
    Checks whether an important observable event was recalled and localized within `max(2 * duration, 2.0s)`.
    Rejects whole-clip evidence dumps!
    """
    if ev.detected_action != ev.expected_action:
        return False, "action_mismatch_or_missed"
    if ev.decisive_frame_id not in ev.detected_frame_ids:
        return False, "missing_decisive_frame"
    max_allowed_dur = max(2.0 * ev.labeled_duration_sec, 2.0)
    if not ev.allows_long_context and ev.detected_evidence_duration_sec > max_allowed_dur + 1e-6:
        return False, f"evidence_span_too_wide({ev.detected_evidence_duration_sec}s > {max_allowed_dur}s)"
    return True, "matched_and_localized"


def run_g2_analysis_eligible_benchmark(
    *,
    manifest: FrozenG2EvaluationManifest,
    asset_to_group_map: Dict[str, str],
    dev_asset_ids: Sequence[str],
    holdout_asset_ids: Sequence[str],
    claim_opportunities: Sequence[LabeledClaimOpportunity],
    observable_events: Sequence[LabeledObservableEvent],
    verifier_adversarial_suite: Sequence[VerifierAdversarialCase],
    frame_coverage_by_group: Dict[str, Tuple[int, int]],  # group_id -> (unique_processed_frames, total_valid_frames)
) -> Dict[str, Any]:
    """
    S15.1 - S15.5 & S15.T1 - S15.T4:
    Executes the frozen Gate G2 evaluation at the `analysis_eligible` checkpoint:
    1. Verifies split isolation and anti-leakage (`verify_split_and_anti_leakage`).
    2. Evaluates all `claim_opportunities` using the S13 verifier & Section 6 decision table, then compares
       against the independent ground-truth oracle (`S15.T1`: catches mislabeled relation/provenance even if schema is valid).
    3. Protects against "reject-everything" gaming (`S15.T2`): reports accepted count, qualified count, excluded count,
       and fails the gate if `accepted_claim_count == 0` (precision on 0 denominator is `None`, never `1.0`!).
    4. Evaluates `important_observable_event_recall` with strict `max(2 * duration, 2.0s)` localization check.
    5. Evaluates `verifier_false_accept_rate` on the >= 50-item adversarial suite (`>= 20` critical).
    6. Explicitly records `NOT_RUN` for downstream stages (`script_ready_ai03`, `exact_photo_use_precision`,
       `eligible_project_completion_rate`) per S15.G & docs/09 Section 2.1.
    """
    verify_split_and_anti_leakage(
        manifest=manifest,
        asset_to_group_map=asset_to_group_map,
        dev_asset_ids=dev_asset_ids,
        holdout_asset_ids=holdout_asset_ids,
    )

    # 1. Evaluate Claim Opportunities at `analysis_eligible`
    accepted_total = 0
    accepted_truthfully_supported = 0
    critical_false_accepts = 0
    false_accept_case_ids: List[str] = []

    usage_breakdown = {
        "direct_claim": 0,
        "attributed_or_qualified": 0,
        "illustrative_only": 0,
        "exclude": 0,
    }
    group_precision_outcomes: Dict[str, List[int]] = {
        gid: [0, 0] for gid in manifest.holdout_trip_group_ids
    }

    for opp in claim_opportunities:
        assess, dec = evaluate_claim_support_and_use(
            claim=opp.claim,
            evidence_edges=opp.evidence_edges,
            evidence_scope_revision_id=f"scope-{opp.workday_id}",
            narrative_type=opp.proposed_narrative_type,
            nonliteral_has_false_premise=opp.nonliteral_has_false_premise,
        )
        usage_breakdown[dec.allowed_use] = usage_breakdown.get(dec.allowed_use, 0) + 1

        # A claim is considered "accepted for use" if allowed_use is direct_claim or attributed_or_qualified
        if dec.allowed_use in ("direct_claim", "attributed_or_qualified") and dec.is_effective:
            accepted_total += 1
            g_pair = group_precision_outcomes.setdefault(opp.trip_group_id, [0, 0])
            g_pair[1] += 1

            # Check against independent oracle: both truthfulness AND allowed_use provenance must match!
            is_oracle_valid = (
                opp.oracle_is_truthfully_supported
                and (dec.allowed_use in opp.oracle_allowed_use_set)
            )
            if is_oracle_valid:
                accepted_truthfully_supported += 1
                g_pair[0] += 1
            else:
                false_accept_case_ids.append(opp.opportunity_id)
                if opp.claim.is_critical:
                    critical_false_accepts += 1

    if accepted_total > 0:
        claim_precision: Optional[float] = round(accepted_truthfully_supported / float(accepted_total), 6)
    else:
        # S15.T2 & docs/08 Section 15: Never report 100% precision when 0 claims are accepted!
        claim_precision = None

    precision_wilson = compute_wilson_95_ci(accepted_truthfully_supported, accepted_total)
    precision_bootstrap = compute_group_bootstrap_95_ci(
        group_outcomes={k: (v[0], v[1]) for k, v in group_precision_outcomes.items()},
        iterations=manifest.bootstrap_iterations,
        seed=manifest.bootstrap_seed,
    )

    # 2. Evaluate Important Observable Event Recall (AI-04)
    total_events = len(observable_events)
    recalled_events = 0
    missed_event_details: List[Dict[str, Any]] = []
    group_event_outcomes: Dict[str, List[int]] = {
        gid: [0, 0] for gid in manifest.holdout_trip_group_ids
    }

    for ev in observable_events:
        g_ev = group_event_outcomes.setdefault(ev.trip_group_id, [0, 0])
        g_ev[1] += 1
        ok, reason = evaluate_observable_event_detection(ev)
        if ok:
            recalled_events += 1
            g_ev[0] += 1
        else:
            missed_event_details.append({"event_id": ev.event_id, "group_id": ev.trip_group_id, "reason": reason})

    event_recall: Optional[float] = (
        round(recalled_events / float(total_events), 6) if total_events > 0 else None
    )
    recall_wilson = compute_wilson_95_ci(recalled_events, total_events)
    recall_bootstrap = compute_group_bootstrap_95_ci(
        group_outcomes={k: (v[0], v[1]) for k, v in group_event_outcomes.items()},
        iterations=manifest.bootstrap_iterations,
        seed=manifest.bootstrap_seed,
    )

    # 3. Evaluate Adversarial Verifier Suite (AI-05)
    unsupported_cases = [c for c in verifier_adversarial_suite if c.is_ground_truth_unsupported]
    supported_controls = [c for c in verifier_adversarial_suite if not c.is_ground_truth_unsupported]
    critical_unsupported_cases = [c for c in unsupported_cases if c.claim.is_critical]

    verifier_false_accepts = 0
    verifier_critical_false_accepts = 0
    verifier_false_rejects = 0
    verifier_failure_ids: List[str] = []

    for vc in unsupported_cases:
        _, v_dec = evaluate_claim_support_and_use(
            claim=vc.claim,
            evidence_edges=vc.evidence_edges,
            evidence_scope_revision_id="scope-verifier-suite",
            narrative_type=vc.proposed_narrative_type,
            nonliteral_has_false_premise=vc.nonliteral_has_false_premise,
        )
        if v_dec.allowed_use in ("direct_claim", "attributed_or_qualified"):
            verifier_false_accepts += 1
            verifier_failure_ids.append(vc.case_id)
            if vc.claim.is_critical:
                verifier_critical_false_accepts += 1

    for sc in supported_controls:
        _, s_dec = evaluate_claim_support_and_use(
            claim=sc.claim,
            evidence_edges=sc.evidence_edges,
            evidence_scope_revision_id="scope-verifier-suite",
            narrative_type=sc.proposed_narrative_type,
            nonliteral_has_false_premise=sc.nonliteral_has_false_premise,
        )
        if s_dec.allowed_use == "exclude":
            verifier_false_rejects += 1

    verifier_far: Optional[float] = (
        round(verifier_false_accepts / float(len(unsupported_cases)), 6) if unsupported_cases else None
    )
    verifier_frr: Optional[float] = (
        round(verifier_false_rejects / float(len(supported_controls)), 6) if supported_controls else None
    )

    # 4. Evaluate Frame Input Coverage across groups (AI-01)
    total_proc_frames = sum(v[0] for v in frame_coverage_by_group.values())
    total_decl_frames = sum(v[1] for v in frame_coverage_by_group.values())
    frame_coverage_ratio: Optional[float] = (
        round(total_proc_frames / float(total_decl_frames), 6) if total_decl_frames > 0 else None
    )

    # 5. Gate G2 Pass/Fail Decision against `acceptance-targets-v0.1`
    # S15.T2: Also require non-trivial usage (`accepted_total > 0` and `accepted_ratio >= 0.25`) so a trivial
    # "reject almost everything" harness cannot pass Gate G2!
    total_opportunities = len(claim_opportunities)
    accepted_usage_rate = (accepted_total / float(total_opportunities)) if total_opportunities > 0 else 0.0

    gate_checks = {
        "precision_meets_target": (claim_precision is not None and claim_precision >= 0.98),
        "non_trivial_claim_usage": (accepted_total > 0 and accepted_usage_rate >= 0.25),
        "zero_critical_false_accepts": (critical_false_accepts == 0),
        "event_recall_meets_target": (event_recall is not None and event_recall >= 0.90),
        "verifier_far_meets_target": (
            verifier_far is not None
            and verifier_far <= 0.02
            and verifier_critical_false_accepts == 0
            and len(unsupported_cases) >= 50
            and len(critical_unsupported_cases) >= 20
        ),
        "full_frame_input_coverage": (frame_coverage_ratio is not None and frame_coverage_ratio == 1.0),
    }
    g2_gate_passed = all(gate_checks.values())

    return {
        "checkpoint_stage": "G2_analysis_eligible",
        "evaluation_mode": "synthetic_decision_harness_fixture",
        "production_video_inference_verified": False,
        "target_version": manifest.target_version,
        "frozen_manifest_sha256": manifest.compute_lock_sha256(),
        "independent_holdout_group_count": len(manifest.holdout_trip_group_ids),
        "metrics": {
            "accepted_claim_support_precision": {
                "numerator": accepted_truthfully_supported,
                "denominator": accepted_total,
                "total_opportunities_evaluated": total_opportunities,
                "accepted_usage_rate": round(accepted_usage_rate, 6),
                "point_estimate": claim_precision,
                "target_v0_1": ">= 0.98",
                "wilson_95_ci": list(precision_wilson),
                "group_bootstrap_95": precision_bootstrap,
                "usage_breakdown": usage_breakdown,
                "false_accept_case_ids": false_accept_case_ids,
            },
            "critical_false_accept_count": {
                "count": critical_false_accepts,
                "target_v0_1": 0,
            },
            "important_observable_event_recall": {
                "numerator": recalled_events,
                "denominator": total_events,
                "point_estimate": event_recall,
                "target_v0_1": ">= 0.90",
                "wilson_95_ci": list(recall_wilson),
                "group_bootstrap_95": recall_bootstrap,
                "missed_events": missed_event_details,
            },
            "verifier_false_accept_rate": {
                "false_accept_numerator": verifier_false_accepts,
                "unsupported_denominator": len(unsupported_cases),
                "critical_unsupported_count": len(critical_unsupported_cases),
                "critical_false_accept_count": verifier_critical_false_accepts,
                "point_estimate": verifier_far,
                "target_v0_1": "<= 0.02 (and 0 critical)",
                "false_reject_rate_on_supported_controls": verifier_frr,
                "supported_control_denominator": len(supported_controls),
                "failure_case_ids": verifier_failure_ids,
            },
            "frame_input_coverage": {
                "numerator": total_proc_frames,
                "denominator": total_decl_frames,
                "point_estimate": frame_coverage_ratio,
                "target_v0_1": "1.00",
            },
        },
        "deferred_stage_metrics": {
            "G3_script_ready_claim_precision": "NOT_RUN (Scheduled for Gate G3 — S19.T4)",
            "AI_07_exact_photo_use_precision": "NOT_RUN (Capability status='candidate'; fallback='illustrative_only' enforced until S23.C1)",
            "G5_eligible_project_completion_rate": "NOT_RUN (Scheduled for Gate G5 end-to-end evaluation — S25.5)",
            "G5_project_abstention_rate": "NOT_RUN (Scheduled for Gate G5 end-to-end evaluation — S25.5)",
        },
        "gate_checks": gate_checks,
        "g2_gate_decision": "PASS" if g2_gate_passed else "FAIL",
    }


def build_canonical_g2_benchmark_fixture() -> Dict[str, Any]:
    """
    Constructs the deterministic, reproducible Gate G2 benchmark dataset:
    - 3 independent development trip groups (`trip-dev-01..03`)
    - 5 independent held-out trip/workday groups (`trip-holdout-01..05`)
    - 105 labeled claim decision opportunities across the 5 held-out groups
    - 50 labeled important observable events across the 5 held-out groups
    - 60 adversarial verifier test cases (50 unsupported claims with 25 critical across all 8 failure modes in docs/08 Section 12,
      plus 10 supported control claims).
    """
    dev_groups = ["trip-dev-01", "trip-dev-02", "trip-dev-03"]
    holdout_groups = [
        "trip-holdout-01-dalat",
        "trip-holdout-02-halong",
        "trip-holdout-03-hagiang",
        "trip-holdout-04-phuquoc",
        "trip-holdout-05-mekong",
    ]
    manifest = FrozenG2EvaluationManifest(
        manifest_id="G2-FROZEN-EVAL-v1",
        target_version=G2_BENCHMARK_TARGET_VERSION,
        runtime_profile_id="P-VISION-DEV-v1",
        decision_policy_version=DECISION_POLICY_VERSION,
        verifier_policy_version=VERIFIER_POLICY_VERSION,
        bootstrap_iterations=10000,
        bootstrap_seed=20261109,
        dev_trip_group_ids=dev_groups,
        holdout_trip_group_ids=holdout_groups,
        prompt_example_group_ids=["trip-dev-01", "trip-dev-02"],
        cached_summary_group_ids=["trip-dev-03"],
    )

    asset_to_group_map: Dict[str, str] = {}
    dev_assets: List[str] = []
    holdout_assets: List[str] = []

    for dg in dev_groups:
        for i in range(4):
            aid = f"asset-{dg}-{i:02d}"
            asset_to_group_map[aid] = dg
            dev_assets.append(aid)

    for hg in holdout_groups:
        for i in range(5):
            aid = f"asset-{hg}-{i:02d}"
            asset_to_group_map[aid] = hg
            holdout_assets.append(aid)

    # Build 105 labeled claim opportunities (21 per holdout group):
    # - 12 valid visual direct claims per group (60 total)
    # - 4 valid confirmed user facts narrated as reported_by_user per group (20 total)
    # - 5 unsupported / contradicted / partial-compound claims per group that must be excluded (25 total)
    opportunities: List[LabeledClaimOpportunity] = []
    for g_idx, hg in enumerate(holdout_groups):
        wd_id = f"wd-{hg}"
        # 12 direct visual claims
        for c_idx in range(12):
            cid = f"opp-{g_idx}-vis-{c_idx:02d}"
            rev_id = f"{cid}-r1"
            claim = AtomicClaimProposal(
                claim_id=cid,
                claim_revision_id=rev_id,
                workday_id=wd_id,
                claim_type="atomic_action",
                subject="nhân_vật_chính",
                predicate_text=f"Quan sát hành động thực địa {c_idx} tại {hg}",
                parent_compound_id=None,
                component_claim_ids=[cid],
                is_critical=(c_idx < 4),
                origin="visual_model",
                epistemic_status="observed",
                review_status="auto_checked",
            )
            edge = EvidenceEdge(
                edge_id=f"edge-{cid}",
                claim_revision_id=rev_id,
                evidence_revision_id=f"obs-{hg}-{c_idx:02d}",
                evidence_kind="visual_observation",
                role="supports",
                covered_component_ids=[cid],
            )
            opportunities.append(
                LabeledClaimOpportunity(
                    opportunity_id=cid,
                    trip_group_id=hg,
                    workday_id=wd_id,
                    claim=claim,
                    evidence_edges=[edge],
                    proposed_narrative_type="observed",
                    oracle_is_truthfully_supported=True,
                    oracle_allowed_use_set=["direct_claim"],
                )
            )

        # 4 confirmed user facts narrated in first-person (`reported_by_user`)
        for u_idx in range(4):
            cid = f"opp-{g_idx}-usr-{u_idx:02d}"
            rev_id = f"{cid}-r1"
            claim = AtomicClaimProposal(
                claim_id=cid,
                claim_revision_id=rev_id,
                workday_id=wd_id,
                claim_type="off_camera_fact",
                subject="nhân_vật_chính",
                predicate_text=f"Khởi hành lúc sáng sớm tại {hg} ({u_idx})",
                parent_compound_id=None,
                component_claim_ids=[cid],
                is_critical=True,
                origin="user",
                epistemic_status="reported",
                review_status="confirmed",
            )
            edge = EvidenceEdge(
                edge_id=f"edge-{cid}",
                claim_revision_id=rev_id,
                evidence_revision_id=f"fact-{hg}-{u_idx:02d}",
                evidence_kind="user_fact",
                role="supports",
                covered_component_ids=[cid],
            )
            opportunities.append(
                LabeledClaimOpportunity(
                    opportunity_id=cid,
                    trip_group_id=hg,
                    workday_id=wd_id,
                    claim=claim,
                    evidence_edges=[edge],
                    proposed_narrative_type="reported_by_user",
                    oracle_is_truthfully_supported=True,
                    oracle_allowed_use_set=["attributed_or_qualified"],
                )
            )

        # 5 unsupported / contradicted claims that the policy must exclude
        for x_idx in range(5):
            cid = f"opp-{g_idx}-excl-{x_idx:02d}"
            rev_id = f"{cid}-r1"
            claim = AtomicClaimProposal(
                claim_id=cid,
                claim_revision_id=rev_id,
                workday_id=wd_id,
                claim_type="causal_relation",
                subject="nhân_vật_chính",
                predicate_text=f"Quay đầu xe vì GPS mất sóng tại {hg} ({x_idx})",
                parent_compound_id=None,
                component_claim_ids=[f"{cid}-act", f"{cid}-cause"],
                is_critical=True,
                origin="derived",
                epistemic_status="inferred",
                review_status="unreviewed",
            )
            # Only supports the action component, NOT the GPS cause component!
            edge = EvidenceEdge(
                edge_id=f"edge-{cid}",
                claim_revision_id=rev_id,
                evidence_revision_id=f"obs-{hg}-turn-{x_idx:02d}",
                evidence_kind="visual_observation",
                role="supports",
                covered_component_ids=[f"{cid}-act"],
            )
            opportunities.append(
                LabeledClaimOpportunity(
                    opportunity_id=cid,
                    trip_group_id=hg,
                    workday_id=wd_id,
                    claim=claim,
                    evidence_edges=[edge],
                    proposed_narrative_type="observed",
                    oracle_is_truthfully_supported=False,
                    oracle_allowed_use_set=["exclude"],
                )
            )

    # Build 50 labeled observable events (10 per holdout group; 48 recalled & localized, 2 subtle missed -> 96% recall >= 90%)
    events: List[LabeledObservableEvent] = []
    for g_idx, hg in enumerate(holdout_groups):
        wd_id = f"wd-{hg}"
        for e_idx in range(10):
            ev_id = f"ev-{g_idx}-{e_idx:02d}"
            is_missed = (g_idx in (1, 3) and e_idx == 9)
            decisive_f = 100 + e_idx * 24
            events.append(
                LabeledObservableEvent(
                    event_id=ev_id,
                    trip_group_id=hg,
                    workday_id=wd_id,
                    source_revision_id=f"src-{hg}-01",
                    expected_action="stop_at_viewpoint",
                    decisive_frame_id=decisive_f,
                    labeled_duration_sec=2.0,
                    detected_action=None if is_missed else "stop_at_viewpoint",
                    detected_frame_ids=[] if is_missed else [decisive_f - 4, decisive_f, decisive_f + 4],
                    detected_evidence_duration_sec=0.0 if is_missed else 3.2,  # <= max(2 * 2.0, 2.0) = 4.0s
                )
            )

    # Build 60 adversarial verifier cases (50 unsupported with 25 critical across the 8 categories of docs/08 Section 12 + 10 valid controls)
    verifier_suite: List[VerifierAdversarialCase] = []
    categories = [
        "irrelevant_citation",
        "partial_compound",
        "unproven_causal",
        "cross_session_confusion",
        "user_fact_as_observed",
        "context_negation",
        "false_premise_humor",
        "unknown_unprovable",
    ]
    for v_idx in range(50):
        cat = categories[v_idx % len(categories)]
        hg = holdout_groups[v_idx % len(holdout_groups)]
        vc_id = f"adv-unsup-{v_idx:03d}"
        rev_id = f"{vc_id}-r1"
        is_crit = (v_idx < 25)  # 25 critical unsupported cases (>= 20 required)

        if cat == "user_fact_as_observed":
            claim = AtomicClaimProposal(
                claim_id=vc_id,
                claim_revision_id=rev_id,
                workday_id=f"wd-{hg}",
                claim_type="off_camera_fact",
                subject="user",
                predicate_text="User fact bị trình bày sai thành camera quan sát trực tiếp",
                parent_compound_id=None,
                component_claim_ids=[vc_id],
                is_critical=is_crit,
                origin="user",
                epistemic_status="reported",
                review_status="confirmed",
            )
            edges = [
                EvidenceEdge(
                    edge_id=f"e-{vc_id}",
                    claim_revision_id=rev_id,
                    evidence_revision_id="fact-1",
                    evidence_kind="user_fact",
                    role="supports",
                    covered_component_ids=[vc_id],
                )
            ]
            narrative = "observed"  # Illegal for user fact!
            false_prem = False
        elif cat == "context_negation":
            claim = AtomicClaimProposal(
                claim_id=vc_id,
                claim_revision_id=rev_id,
                workday_id=f"wd-{hg}",
                claim_type="atomic_action",
                subject="user",
                predicate_text="Đã qua phà thành công",
                parent_compound_id=None,
                component_claim_ids=[vc_id],
                is_critical=is_crit,
                origin="visual_model",
                epistemic_status="observed",
                review_status="auto_checked",
            )
            edges = [
                EvidenceEdge(
                    edge_id=f"e-{vc_id}-sup",
                    claim_revision_id=rev_id,
                    evidence_revision_id="obs-1",
                    evidence_kind="visual_observation",
                    role="supports",
                    covered_component_ids=[vc_id],
                ),
                EvidenceEdge(
                    edge_id=f"e-{vc_id}-contra",
                    claim_revision_id=rev_id,
                    evidence_revision_id="obs-2",
                    evidence_kind="visual_observation",
                    role="contradicts",
                    covered_component_ids=[vc_id],
                ),
            ]
            narrative = "observed"
            false_prem = False
        elif cat == "false_premise_humor":
            claim = AtomicClaimProposal(
                claim_id=vc_id,
                claim_revision_id=rev_id,
                workday_id=f"wd-{hg}",
                claim_type="atomic_action",
                subject="user",
                predicate_text="Câu đùa cài tiền đề sai sự thật",
                parent_compound_id=None,
                component_claim_ids=[vc_id],
                is_critical=is_crit,
                origin="derived",
                epistemic_status="inferred",
                review_status="unreviewed",
            )
            edges = []
            narrative = "nonliteral_commentary"
            false_prem = True
        else:
            # Partial compound, unproven causal, irrelevant citation (context_only), etc.
            claim = AtomicClaimProposal(
                claim_id=vc_id,
                claim_revision_id=rev_id,
                workday_id=f"wd-{hg}",
                claim_type="causal_relation",
                subject="user",
                predicate_text=f"Adversarial unsupported case ({cat})",
                parent_compound_id=None,
                component_claim_ids=[f"{vc_id}-c1", f"{vc_id}-c2"],
                is_critical=is_crit,
                origin="derived",
                epistemic_status="inferred",
                review_status="unreviewed",
            )
            edges = [
                EvidenceEdge(
                    edge_id=f"e-{vc_id}-ctx",
                    claim_revision_id=rev_id,
                    evidence_revision_id="obs-ctx",
                    evidence_kind="visual_observation",
                    role="context_only" if cat == "irrelevant_citation" else "supports",
                    covered_component_ids=[f"{vc_id}-c1"],
                )
            ]
            narrative = "observed"
            false_prem = False

        verifier_suite.append(
            VerifierAdversarialCase(
                case_id=vc_id,
                trip_group_id=hg,
                category=cat,
                is_ground_truth_unsupported=True,
                claim=claim,
                evidence_edges=edges,
                proposed_narrative_type=narrative,
                nonliteral_has_false_premise=false_prem,
            )
        )

    # 10 valid supported controls
    for s_idx in range(10):
        hg = holdout_groups[s_idx % len(holdout_groups)]
        sc_id = f"adv-sup-ctrl-{s_idx:03d}"
        rev_id = f"{sc_id}-r1"
        claim = AtomicClaimProposal(
            claim_id=sc_id,
            claim_revision_id=rev_id,
            workday_id=f"wd-{hg}",
            claim_type="atomic_action",
            subject="user",
            predicate_text=f"Supported control observation {s_idx}",
            parent_compound_id=None,
            component_claim_ids=[sc_id],
            is_critical=True,
            origin="visual_model",
            epistemic_status="observed",
            review_status="auto_checked",
        )
        edges = [
            EvidenceEdge(
                edge_id=f"e-{sc_id}",
                claim_revision_id=rev_id,
                evidence_revision_id=f"obs-ctrl-{s_idx}",
                evidence_kind="visual_observation",
                role="supports",
                covered_component_ids=[sc_id],
            )
        ]
        verifier_suite.append(
            VerifierAdversarialCase(
                case_id=sc_id,
                trip_group_id=hg,
                category="valid_supported_control",
                is_ground_truth_unsupported=False,
                claim=claim,
                evidence_edges=edges,
                proposed_narrative_type="observed",
            )
        )

    frame_coverage_by_group = {hg: (1200, 1200) for hg in holdout_groups}

    return {
        "manifest": manifest,
        "asset_to_group_map": asset_to_group_map,
        "dev_assets": dev_assets,
        "holdout_assets": holdout_assets,
        "claim_opportunities": opportunities,
        "observable_events": events,
        "verifier_suite": verifier_suite,
        "frame_coverage_by_group": frame_coverage_by_group,
    }
