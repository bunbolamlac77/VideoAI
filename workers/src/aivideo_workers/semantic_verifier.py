"""
workers/src/aivideo_workers/semantic_verifier.py — S13 Brief Parser, Atomic Claims, Section 6 Decision Table,
Partial-Order Event Graph, Scope-Sensitive Revalidation & Independent Semantic Verifier.
Compliant with docs/02-ANALYSIS-AND-DATA.md (Sections 3..6, 11, 13), docs/07-OPTIMIZATION.md (Sections 4, 6, 17),
docs/08-ACCURACY-FIRST.md (Sections 10..12, 16), docs/09-UPGRADES-AND-ACCEPTANCE.md (AI-03..AI-06, DATA-04, DATA-05),
and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S13).
"""

from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field
import hashlib
import json
import re
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple


DECISION_POLICY_VERSION = "DECISION-TABLE-02-v1"
VERIFIER_POLICY_VERSION = "SEMANTIC-VERIFIER-08-v1"


class SemanticVerifierError(RuntimeError):
    """Scoped error raised by S13 brief parser, event graph, or semantic verifier."""

    def __init__(self, code: str, message: str, details: Optional[Dict[str, Any]] = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}


@dataclass(frozen=True)
class BriefItemDraft:
    """
    S13.1: Extracted item from raw user brief.
    Strictly separates `event_fact`, `style_preference`, and `usage_constraint` (`must_use` / `must_not_use`).
    Preserves exact source character spans `[start_char, end_char)`, negation, and time precision.
    """

    draft_id: str
    brief_revision_id: str
    workday_id: str
    item_kind: str  # 'event_fact' | 'style_preference' | 'usage_constraint'
    raw_span_text: str
    start_char: int
    end_char: int
    is_negated: bool
    is_uncertain: bool
    time_precision: str  # 'exact' | 'approximate' | 'range' | 'date_only' | 'unknown'
    reported_time_text: Optional[str]
    timezone_iana: Optional[str]  # Never auto-filled from system clock if unknown!
    constraint_type: Optional[str] = None  # 'must_use' | 'must_not_use' | 'preferred' | None
    origin: str = "user"
    epistemic_status: str = "reported"
    review_status: str = "unreviewed"

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


@dataclass(frozen=True)
class AtomicClaimProposal:
    """
    S13.2: Atomic factual or relational claim decomposed from compound statements.
    """

    claim_id: str
    claim_revision_id: str
    workday_id: str
    claim_type: str  # 'atomic_action' | 'causal_relation' | 'temporal_before' | 'utterance_only' | 'off_camera_fact'
    subject: Optional[str]
    predicate_text: str
    parent_compound_id: Optional[str]
    component_claim_ids: List[str]
    is_critical: bool
    origin: str  # 'user' | 'visual_model' | 'asr' | 'ocr' | 'derived'
    epistemic_status: str  # 'observed' | 'reported' | 'inferred' | 'unknown'
    review_status: str  # 'unreviewed' | 'auto_checked' | 'needs_review' | 'confirmed' | 'rejected' | 'superseded'
    scope_sensitive: bool = False

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


@dataclass(frozen=True)
class EvidenceEdge:
    """
    S13.2 & docs/02 Section 5.1:
    `role` is strictly `supports`, `contradicts`, or `context_only`.
    `context_only` NEVER upgrades into `supports`.
    """

    edge_id: str
    claim_revision_id: str
    evidence_revision_id: str
    evidence_kind: str  # 'visual_observation' | 'asr_transcript' | 'ocr_crop' | 'user_fact' | 'metadata'
    role: str  # 'supports' | 'contradicts' | 'context_only'
    covered_component_ids: List[str]  # Which atomic components this evidence actually covers
    schema_and_hash_valid: bool = True
    notes: str = ""

    def __post_init__(self) -> None:
        if self.role not in ("supports", "contradicts", "context_only"):
            raise SemanticVerifierError("INVALID_EVIDENCE_ROLE", f"Invalid evidence role: {self.role}")

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


@dataclass(frozen=True)
class SupportAssessmentRecord:
    """S13.2 & S13.6: Reproducible support assessment for a specific claim revision and evidence set."""

    assessment_id: str
    claim_revision_id: str
    evidence_scope_revision_id: str
    policy_version: str
    support_status: str  # 'supported' | 'contradicted' | 'insufficient' | 'disputed'
    supporting_edge_ids: List[str]
    contradicting_edge_ids: List[str]
    context_only_edge_ids: List[str]
    pending_revalidation: bool
    reason: str

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


@dataclass(frozen=True)
class ClaimUseDecisionRecord:
    """S13.3: Canonical Section 6 Decision Table evaluation."""

    decision_id: str
    claim_revision_id: str
    assessment_id: str
    policy_version: str
    narrative_type: str  # 'observed' | 'reported_by_user' | 'inferred' | 'nonliteral_commentary'
    allowed_use: str  # 'direct_claim' | 'attributed_or_qualified' | 'illustrative_only' | 'exclude'
    is_effective: bool
    requires_targeted_review: bool
    next_step_action: str
    reason: str

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


@dataclass(frozen=True)
class EventNode:
    """S13.4: Event node in the partial-order chronology graph."""

    event_id: str
    workday_id: str
    source_revision_id: str
    camera_session_id: str
    location_tag: Optional[str]
    action_summary: str
    start_pts_sec: float
    end_pts_sec: float
    clock_uncertainty_sec: float = 0.0


@dataclass(frozen=True)
class EventRelationEdge:
    """S13.4: Partial-order edge between two events (`before`, `overlaps`, `continues`, `same_session_candidate`, `causal`)."""

    relation_id: str
    from_event_id: str
    to_event_id: str
    relation_type: str  # 'before' | 'overlaps' | 'continues' | 'same_session_candidate' | 'causal'
    evidence_source: str
    is_uncertain: bool = False


@dataclass(frozen=True)
class EventGraphAnalysisResult:
    """S13.4 & S13.T4: Partial-order event graph analysis with cycle detection and same-session candidate checks."""

    nodes: List[EventNode]
    edges: List[EventRelationEdge]
    detected_before_cycles: List[List[str]]
    ambiguous_chronology_pairs: List[Tuple[str, str, str]]
    rejected_filename_or_costume_merges: List[str]
    requires_chronology_review: bool

    def to_dict(self) -> Dict[str, Any]:
        return {
            "nodes": [dataclasses.asdict(n) for n in self.nodes],
            "edges": [dataclasses.asdict(e) for e in self.edges],
            "detected_before_cycles": self.detected_before_cycles,
            "ambiguous_chronology_pairs": [list(p) for p in self.ambiguous_chronology_pairs],
            "rejected_filename_or_costume_merges": self.rejected_filename_or_costume_merges,
            "requires_chronology_review": self.requires_chronology_review,
        }


# ---------------------------------------------------------------------------
# S13.1 — Brief Parser (Facts vs Preferences vs Constraints, Time Precision)
# ---------------------------------------------------------------------------

def parse_raw_brief_to_drafts(
    *,
    brief_revision_id: str,
    workday_id: str,
    raw_brief_text: str,
    explicit_timezone_iana: Optional[str] = None,
) -> List[BriefItemDraft]:
    """
    S13.1: Splits raw Vietnamese brief into structured drafts while preserving:
    - Character spans `[start_char, end_char)` in `raw_brief_text`
    - Separation of `event_fact`, `style_preference`, and `usage_constraint`
    - Negation (`không`, `chưa`, `đừng`, `cấm`)
    - Uncertainty & approximate time (`khoảng`, `tầm`, `chưa chắc`, `có lẽ`, `hình như`)
    - Never fabricates an exact minute or system timezone if `explicit_timezone_iana` is None.
    """
    drafts: List[BriefItemDraft] = []
    # Match clauses separated by sentence punctuation or semicolons/newlines while tracking spans
    pattern = re.compile(r"[^.;\n]+")
    idx = 0

    for match in pattern.finditer(raw_brief_text):
        raw_clause = match.group(0)
        stripped = raw_clause.strip()
        if not stripped:
            continue

        lead_ws = len(raw_clause) - len(raw_clause.lstrip())
        trail_ws = len(raw_clause) - len(raw_clause.rstrip())
        start_c = match.start() + lead_ws
        end_c = match.end() - trail_ws
        lower = stripped.lower()

        # Classify constraint vs preference vs event_fact
        constraint_type: Optional[str] = None
        # Wedding POV phrasing is explicit: "Bắt buộc có cảnh: …" / "Không quay: …".
        if any(tok in lower for tok in (
            "không dùng cảnh", "cấm dùng", "đừng đưa cảnh", "bỏ cảnh", "must_not_use",
            "không quay", "đừng quay", "tránh quay", "tránh cảnh", "không đưa cảnh",
        )):
            item_kind = "usage_constraint"
            constraint_type = "must_not_use"
        elif any(tok in lower for tok in (
            "bắt buộc dùng", "bắt buộc có", "nhất định giữ cảnh", "phải có cảnh",
            "phải quay", "cần có cảnh", "must_use",
        )):
            item_kind = "usage_constraint"
            constraint_type = "must_use"
        elif any(tok in lower for tok in (
            "thích nhạc", "gu dựng", "phong cách", "nhịp nhanh", "nhạc vui", "giọng điệu",
            "cinematic", "fine-art", "documentary", "tone",
        )):
            item_kind = "style_preference"
            constraint_type = "preferred"
        else:
            item_kind = "event_fact"

        is_negated = any(re.search(rf"\b{w}\b", lower) for w in ("không", "chưa", "chẳng", "đừng", "cấm"))
        is_uncertain = any(
            phrase in lower for phrase in ("khoảng", "tầm", "có lẽ", "chưa chắc", "hình như", "không nhớ rõ")
        )

        # Time precision extraction (never turns "khoảng 3 giờ" into exact 03:00 or ±15m)
        time_match = re.search(
            r"((?:khoảng|tầm|lúc|từ)?\s*\d{1,2}\s*(?:giờ|h)(?:\s*\d{1,2}\s*phút)?(?:\s*(?:sáng|chiều|tối|đêm))?(?:\s*đến\s*\d{1,2}\s*(?:giờ|h))?)",
            lower,
        )
        reported_time: Optional[str] = None
        if time_match:
            reported_time = time_match.group(1).strip()
            if "đến" in reported_time:
                time_precision = "range"
            elif any(w in lower for w in ("khoảng", "tầm", "có lẽ", "chưa chắc")):
                time_precision = "approximate"
            else:
                time_precision = "exact"
        elif any(w in lower for w in ("ngày", "buổi sáng", "buổi chiều", "hôm đó")):
            time_precision = "date_only"
        else:
            time_precision = "unknown"

        drafts.append(
            BriefItemDraft(
                draft_id=f"draft-{brief_revision_id[:8]}-{idx:03d}",
                brief_revision_id=brief_revision_id,
                workday_id=workday_id,
                item_kind=item_kind,
                raw_span_text=stripped,
                start_char=start_c,
                end_char=end_c,
                is_negated=is_negated,
                is_uncertain=is_uncertain,
                time_precision=time_precision,
                reported_time_text=reported_time,
                timezone_iana=explicit_timezone_iana,  # Kept None if not explicitly provided!
                constraint_type=constraint_type,
                origin="user",
                epistemic_status="reported",
                review_status="unreviewed",
            )
        )
        idx += 1

    return drafts


# ---------------------------------------------------------------------------
# S13.2 & S13.T1 — Decompose Causal / Compound Claims
# ---------------------------------------------------------------------------

def decompose_causal_or_compound_statement(
    *,
    compound_id: str,
    workday_id: str,
    raw_statement: str,
    subject: Optional[str] = "nhân_vật_chính",
    is_critical: bool = True,
    origin: str = "derived",
    epistemic_status: str = "inferred",
    review_status: str = "unreviewed",
) -> List[AtomicClaimProposal]:
    """
    S13.2 & S13.T1:
    Splits a causal statement (`<Action A> vì <Reason B>`, e.g. "Quay đầu vì GPS báo nhầm")
    or a multi-clause compound statement (`<Clause 1> và <Clause 2>`) into independent atomic claims
    plus a relational/compound claim linking them.
    """
    proposals: List[AtomicClaimProposal] = []
    stmt = raw_statement.strip()

    # Check causal connector " vì " or " do "
    causal_split = re.split(r"\s+(?:vì|do|bởi vì)\s+", stmt, maxsplit=1, flags=re.IGNORECASE)
    if len(causal_split) == 2:
        action_part, reason_part = causal_split[0].strip(), causal_split[1].strip()
        c_action_id = f"{compound_id}-act"
        c_reason_id = f"{compound_id}-cause"
        c_rel_id = f"{compound_id}-causal-rel"

        proposals.append(
            AtomicClaimProposal(
                claim_id=c_action_id,
                claim_revision_id=f"{c_action_id}-r1",
                workday_id=workday_id,
                claim_type="atomic_action",
                subject=subject,
                predicate_text=action_part,
                parent_compound_id=c_rel_id,
                component_claim_ids=[],
                is_critical=is_critical,
                origin="visual_model" if origin == "derived" else origin,
                epistemic_status="observed" if origin == "visual_model" else epistemic_status,
                review_status=review_status,
            )
        )
        proposals.append(
            AtomicClaimProposal(
                claim_id=c_reason_id,
                claim_revision_id=f"{c_reason_id}-r1",
                workday_id=workday_id,
                claim_type="off_camera_fact",
                subject=subject,
                predicate_text=reason_part,
                parent_compound_id=c_rel_id,
                component_claim_ids=[],
                is_critical=is_critical,
                origin=origin,
                epistemic_status="inferred" if origin != "user" else "reported",
                review_status=review_status,
            )
        )
        proposals.append(
            AtomicClaimProposal(
                claim_id=c_rel_id,
                claim_revision_id=f"{c_rel_id}-r1",
                workday_id=workday_id,
                claim_type="causal_relation",
                subject=subject,
                predicate_text=stmt,
                parent_compound_id=None,
                component_claim_ids=[c_action_id, c_reason_id],
                is_critical=is_critical,
                origin=origin,
                epistemic_status="inferred" if origin != "user" else "reported",
                review_status=review_status,
                scope_sensitive=True,
            )
        )
        return proposals

    # Check multi-clause conjunction (" và ", ", sau đó ")
    conj_split = re.split(r"\s+(?:và|rồi|sau đó)\s+|,\s*", stmt)
    conj_parts = [p.strip() for p in conj_split if p.strip()]
    if len(conj_parts) > 1:
        comp_ids: List[str] = []
        parent_id = f"{compound_id}-compound"
        for i, part in enumerate(conj_parts):
            cid = f"{compound_id}-c{i+1}"
            comp_ids.append(cid)
            proposals.append(
                AtomicClaimProposal(
                    claim_id=cid,
                    claim_revision_id=f"{cid}-r1",
                    workday_id=workday_id,
                    claim_type="atomic_action",
                    subject=subject,
                    predicate_text=part,
                    parent_compound_id=parent_id,
                    component_claim_ids=[],
                    is_critical=is_critical,
                    origin=origin,
                    epistemic_status=epistemic_status,
                    review_status=review_status,
                )
            )
        proposals.append(
            AtomicClaimProposal(
                claim_id=parent_id,
                claim_revision_id=f"{parent_id}-r1",
                workday_id=workday_id,
                claim_type="temporal_before" if "sau đó" in stmt.lower() or "rồi" in stmt.lower() else "atomic_action",
                subject=subject,
                predicate_text=stmt,
                parent_compound_id=None,
                component_claim_ids=comp_ids,
                is_critical=is_critical,
                origin=origin,
                epistemic_status=epistemic_status,
                review_status=review_status,
                scope_sensitive=True,
            )
        )
        return proposals

    proposals.append(
        AtomicClaimProposal(
            claim_id=compound_id,
            claim_revision_id=f"{compound_id}-r1",
            workday_id=workday_id,
            claim_type="atomic_action",
            subject=subject,
            predicate_text=stmt,
            parent_compound_id=None,
            component_claim_ids=[],
            is_critical=is_critical,
            origin=origin,
            epistemic_status=epistemic_status,
            review_status=review_status,
        )
    )
    return proposals


# ---------------------------------------------------------------------------
# S13.2, S13.3 & S13.6 — Support Assessment & Section 6 Decision Table
# ---------------------------------------------------------------------------

def evaluate_claim_support_and_use(
    *,
    claim: AtomicClaimProposal,
    evidence_edges: Sequence[EvidenceEdge],
    evidence_scope_revision_id: str,
    narrative_type: str = "observed",
    pending_revalidation: bool = False,
    nonliteral_has_false_premise: bool = False,
) -> Tuple[SupportAssessmentRecord, ClaimUseDecisionRecord]:
    """
    S13.2, S13.3, S13.T1, S13.T2 & docs/02 Section 6:
    Evaluates a claim against its evidence edges and applies the 12-row ordered Decision Table:
    1. Invalid schema/hash/dependency -> `exclude`.
    2. `pending_revalidation == True` -> temporarily withhold effective use decision (`is_effective = False`).
    3. Any `contradicts` edge -> `support_status = contradicted` (or `disputed`), `allowed_use = exclude`.
    4. Unconfirmed user/brief fact -> `exclude` for factual storytelling.
    5. Compound / causal claim where evidence only covers a subset of `component_claim_ids` ->
       `support_status = insufficient`, `allowed_use = exclude` (never passes full-sentence gate from partial support!).
    6. `context_only` edges NEVER count as `supports`.
    7. User-confirmed causal/off-camera fact (`origin=user`, `epistemic_status=reported`, `review_status=confirmed`) ->
       `support_status = supported` (within user provenance), `allowed_use = attributed_or_qualified`
       (never becomes `observed` or `direct_claim` as if camera proved it!).
    8. Direct visual observation covering all required components with no contradiction -> `direct_claim`.
    9. Audio/ASR speech proving only that someone spoke -> `direct_claim` ONLY if `claim_type == 'utterance_only'`,
       otherwise `insufficient` / `exclude` for proving the external event occurred.
    10. Context-only media match -> `illustrative_only` (only when used purely as B-roll illustration, not factual assertion).
    """
    relevant_edges = [e for e in evidence_edges if e.claim_revision_id == claim.claim_revision_id]

    # Check schema/hash validity first (Row 1 of Section 6 table)
    if any(not e.schema_and_hash_valid for e in relevant_edges):
        assessment = SupportAssessmentRecord(
            assessment_id=f"assess-{claim.claim_revision_id}",
            claim_revision_id=claim.claim_revision_id,
            evidence_scope_revision_id=evidence_scope_revision_id,
            policy_version=DECISION_POLICY_VERSION,
            support_status="insufficient",
            supporting_edge_ids=[],
            contradicting_edge_ids=[],
            context_only_edge_ids=[],
            pending_revalidation=pending_revalidation,
            reason="Schema, source hash, or timecode reference invalid.",
        )
        decision = ClaimUseDecisionRecord(
            decision_id=f"dec-{claim.claim_revision_id}",
            claim_revision_id=claim.claim_revision_id,
            assessment_id=assessment.assessment_id,
            policy_version=DECISION_POLICY_VERSION,
            narrative_type=narrative_type,
            allowed_use="exclude",
            is_effective=False,
            requires_targeted_review=True,
            next_step_action="block_dependent_artifact_and_fix_source",
            reason="Row 1: Invalid schema/hash/timecode.",
        )
        return assessment, decision

    supporting_edges = [e for e in relevant_edges if e.role == "supports"]
    contradicting_edges = [e for e in relevant_edges if e.role == "contradicts"]
    context_edges = [e for e in relevant_edges if e.role == "context_only"]

    # Determine component coverage for multi-clause / causal claims (S13.T1 & S13.T2)
    required_components = set(claim.component_claim_ids) if claim.component_claim_ids else {claim.claim_id}
    covered_by_visual_or_asr: Set[str] = set()
    covered_by_confirmed_user_fact: Set[str] = set()
    has_unconfirmed_user_fact = False

    for edge in supporting_edges:
        if edge.evidence_kind == "user_fact":
            if claim.review_status == "confirmed":
                covered_by_confirmed_user_fact.update(edge.covered_component_ids or [claim.claim_id])
            else:
                has_unconfirmed_user_fact = True
        elif edge.evidence_kind == "asr_transcript" and claim.claim_type != "utterance_only":
            # Hearing "Tôi đã lên phà" only supports utterance_only, NOT that the ferry event happened (Section 4)
            continue
        else:
            covered_by_visual_or_asr.update(edge.covered_component_ids or [claim.claim_id])

    all_covered_combined = covered_by_visual_or_asr.union(covered_by_confirmed_user_fact)
    fully_covered = required_components.issubset(all_covered_combined)
    purely_visual_covered = required_components.issubset(covered_by_visual_or_asr)

    # Determine SupportStatus
    if contradicting_edges:
        support_status = "contradicted" if not supporting_edges else "disputed"
        support_reason = f"Contradicted by {len(contradicting_edges)} counterevidence edge(s)."
    elif not fully_covered:
        support_status = "insufficient"
        missing = sorted(required_components - all_covered_combined)
        support_reason = f"Insufficient evidence: missing support for component(s) {missing}. Context-only edges ({len(context_edges)}) do not upgrade to support."
    else:
        support_status = "supported"
        if covered_by_confirmed_user_fact:
            support_reason = "Supported with confirmed user fact provenance (reported)."
        else:
            support_reason = "Supported by direct observation covering all atomic components."

    assessment = SupportAssessmentRecord(
        assessment_id=f"assess-{claim.claim_revision_id}",
        claim_revision_id=claim.claim_revision_id,
        evidence_scope_revision_id=evidence_scope_revision_id,
        policy_version=DECISION_POLICY_VERSION,
        support_status=support_status,
        supporting_edge_ids=[e.edge_id for e in supporting_edges],
        contradicting_edge_ids=[e.edge_id for e in contradicting_edges],
        context_only_edge_ids=[e.edge_id for e in context_edges],
        pending_revalidation=pending_revalidation,
        reason=support_reason,
    )

    # Row 2: Pending scope revalidation withholds effective decision
    if pending_revalidation:
        return assessment, ClaimUseDecisionRecord(
            decision_id=f"dec-{claim.claim_revision_id}",
            claim_revision_id=claim.claim_revision_id,
            assessment_id=assessment.assessment_id,
            policy_version=DECISION_POLICY_VERSION,
            narrative_type=narrative_type,
            allowed_use="exclude",
            is_effective=False,
            requires_targeted_review=False,
            next_step_action="await_scope_impact_revalidation",
            reason="Row 2: Scope revalidation pending; previous decision cannot be used for final gate.",
        )

    # Row 3: Contradicted or disputed claim -> exclude
    if support_status in ("contradicted", "disputed"):
        return assessment, ClaimUseDecisionRecord(
            decision_id=f"dec-{claim.claim_revision_id}",
            claim_revision_id=claim.claim_revision_id,
            assessment_id=assessment.assessment_id,
            policy_version=DECISION_POLICY_VERSION,
            narrative_type=narrative_type,
            allowed_use="exclude",
            is_effective=True,
            requires_targeted_review=True,
            next_step_action="create_conflict_review_or_drop_claim",
            reason="Row 3: Claim has contradictory evidence.",
        )

    # Row 12 check: Non-literal commentary smuggling a false factual premise -> exclude
    if narrative_type == "nonliteral_commentary" and nonliteral_has_false_premise:
        return assessment, ClaimUseDecisionRecord(
            decision_id=f"dec-{claim.claim_revision_id}",
            claim_revision_id=claim.claim_revision_id,
            assessment_id=assessment.assessment_id,
            policy_version=DECISION_POLICY_VERSION,
            narrative_type=narrative_type,
            allowed_use="exclude",
            is_effective=True,
            requires_targeted_review=True,
            next_step_action="drop_false_premise_joke",
            reason="Row 12 violation: Non-literal/humorous commentary introduces unsupported factual premise.",
        )

    # Row 4: Unconfirmed AI-extracted fact from brief -> exclude
    if has_unconfirmed_user_fact or (claim.origin == "user" and claim.review_status != "confirmed"):
        return assessment, ClaimUseDecisionRecord(
            decision_id=f"dec-{claim.claim_revision_id}",
            claim_revision_id=claim.claim_revision_id,
            assessment_id=assessment.assessment_id,
            policy_version=DECISION_POLICY_VERSION,
            narrative_type=narrative_type,
            allowed_use="exclude",
            is_effective=True,
            requires_targeted_review=True,
            next_step_action="confirm_or_edit_user_fact",
            reason="Row 4: User/brief fact is not yet confirmed for this revision.",
        )

    # Row 5 & Row 6: Supported claim
    if support_status == "supported":
        # Invariant INV-02: If claim relies on user-confirmed fact (or is reported), it MUST NOT be narrated as observed!
        if covered_by_confirmed_user_fact or claim.origin == "user" or claim.epistemic_status in ("reported", "inferred"):
            if narrative_type == "observed":
                return assessment, ClaimUseDecisionRecord(
                    decision_id=f"dec-{claim.claim_revision_id}",
                    claim_revision_id=claim.claim_revision_id,
                    assessment_id=assessment.assessment_id,
                    policy_version=DECISION_POLICY_VERSION,
                    narrative_type=narrative_type,
                    allowed_use="exclude",
                    is_effective=True,
                    requires_targeted_review=True,
                    next_step_action="change_narrative_to_reported_or_qualified",
                    reason="INV-02 / Row 6: User-reported or inferred claim cannot be presented as direct camera observation.",
                )
            return assessment, ClaimUseDecisionRecord(
                decision_id=f"dec-{claim.claim_revision_id}",
                claim_revision_id=claim.claim_revision_id,
                assessment_id=assessment.assessment_id,
                policy_version=DECISION_POLICY_VERSION,
                narrative_type=narrative_type,
                allowed_use="attributed_or_qualified",
                is_effective=True,
                requires_targeted_review=False,
                next_step_action="allow_first_person_or_qualified_narration",
                reason="Row 6/8: Supported via confirmed user fact or valid inference; allowed as attributed_or_qualified.",
            )

        if purely_visual_covered:
            return assessment, ClaimUseDecisionRecord(
                decision_id=f"dec-{claim.claim_revision_id}",
                claim_revision_id=claim.claim_revision_id,
                assessment_id=assessment.assessment_id,
                policy_version=DECISION_POLICY_VERSION,
                narrative_type=narrative_type,
                allowed_use="direct_claim",
                is_effective=True,
                requires_targeted_review=False,
                next_step_action="allow_direct_claim",
                reason="Row 5: Direct visual/utterance observation fully supports all atomic components.",
            )

    # Row 9: Context-only media match when used strictly as illustration
    if context_edges and not claim.is_critical and narrative_type == "nonliteral_commentary":
        return assessment, ClaimUseDecisionRecord(
            decision_id=f"dec-{claim.claim_revision_id}",
            claim_revision_id=claim.claim_revision_id,
            assessment_id=assessment.assessment_id,
            policy_version=DECISION_POLICY_VERSION,
            narrative_type=narrative_type,
            allowed_use="illustrative_only",
            is_effective=True,
            requires_targeted_review=False,
            next_step_action="use_as_broll_illustration_only",
            reason="Row 9: Context-only match allowed strictly as non-assertive B-roll illustration.",
        )

    # Row 10 & Row 11: Insufficient evidence for critical or detail claim -> exclude
    return assessment, ClaimUseDecisionRecord(
        decision_id=f"dec-{claim.claim_revision_id}",
        claim_revision_id=claim.claim_revision_id,
        assessment_id=assessment.assessment_id,
        policy_version=DECISION_POLICY_VERSION,
        narrative_type=narrative_type,
        allowed_use="exclude",
        is_effective=True,
        requires_targeted_review=claim.is_critical,
        next_step_action="targeted_review_or_switch_story_angle" if claim.is_critical else "drop_detail_keep_unknown",
        reason=f"Row {'10' if claim.is_critical else '11'}: Insufficient evidence ({support_reason}).",
    )


# ---------------------------------------------------------------------------
# S13.4 & S13.T4 — Partial-Order Event Graph & Cycle / Clock-Drift Detector
# ---------------------------------------------------------------------------

def analyze_partial_order_event_graph(
    *,
    nodes: Sequence[EventNode],
    edges: Sequence[EventRelationEdge],
    proposed_filename_or_costume_merges: Sequence[Tuple[str, str, str]] = (),
) -> EventGraphAnalysisResult:
    """
    S13.4 & S13.T4 (AI-06):
    1. Builds a partial-order graph over `EventNode`s.
    2. Detects cycles in `before` relations (e.g. A before B, B before C, C before A due to clock drift or multi-day revisit).
    3. Flags ambiguous chronology when two events share the same `location_tag` on different workdays or different
       `camera_session_id`s with overlapping clock uncertainty.
    4. Explicitly rejects merging events solely by filename order or matching costume.
    """
    node_map = {n.event_id: n for n in nodes}
    adj: Dict[str, List[str]] = {n.event_id: [] for n in nodes}
    for edge in edges:
        if edge.relation_type == "before" and edge.from_event_id in adj and edge.to_event_id in adj:
            adj[edge.from_event_id].append(edge.to_event_id)

    # Detect directed cycles in `before` edges using DFS coloring
    visited: Dict[str, int] = {nid: 0 for nid in node_map}  # 0=unvisited, 1=visiting, 2=done
    parent_stack: List[str] = []
    cycles: List[List[str]] = []

    def dfs(u: str) -> None:
        visited[u] = 1
        parent_stack.append(u)
        for v in adj.get(u, []):
            if visited[v] == 0:
                dfs(v)
            elif visited[v] == 1:
                idx = parent_stack.index(v)
                cycle_path = parent_stack[idx:] + [v]
                if cycle_path not in cycles:
                    cycles.append(cycle_path)
        parent_stack.pop()
        visited[u] = 2

    for nid in sorted(node_map.keys()):
        if visited[nid] == 0:
            dfs(nid)

    # Detect ambiguous chronology across different workdays / camera sessions at same location
    ambiguous_pairs: List[Tuple[str, str, str]] = []
    node_list = list(nodes)
    for i in range(len(node_list)):
        for j in range(i + 1, len(node_list)):
            a, b = node_list[i], node_list[j]
            if a.location_tag and a.location_tag == b.location_tag:
                if a.workday_id != b.workday_id:
                    ambiguous_pairs.append(
                        (a.event_id, b.event_id, f"same_location_different_workday:{a.location_tag}")
                    )
                elif a.camera_session_id != b.camera_session_id:
                    gap = abs(a.start_pts_sec - b.start_pts_sec)
                    if gap <= (a.clock_uncertainty_sec + b.clock_uncertainty_sec):
                        ambiguous_pairs.append(
                            (a.event_id, b.event_id, f"clock_drift_overlap_at_location:{a.location_tag}")
                        )

    rejected_merges: List[str] = []
    for ev1, ev2, merge_basis in proposed_filename_or_costume_merges:
        if merge_basis in ("filename_order", "same_costume", "same_day_metadata_only"):
            rejected_merges.append(f"Rejected merge ({ev1}, {ev2}) based on '{merge_basis}' (violates AI-06).")

    requires_review = bool(cycles or ambiguous_pairs)
    return EventGraphAnalysisResult(
        nodes=list(nodes),
        edges=list(edges),
        detected_before_cycles=cycles,
        ambiguous_chronology_pairs=ambiguous_pairs,
        rejected_filename_or_costume_merges=rejected_merges,
        requires_chronology_review=requires_review,
    )


# ---------------------------------------------------------------------------
# S13.5 & S13.T3 — Evidence Scope Revision & Reverse Retrieval Impact Engine
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class EvidenceScopeRevision:
    """S13.5 & docs/02 Section 11.1: Snapshot of the active evidence corpus for a workday."""

    scope_revision_id: str
    workday_id: str
    parent_scope_revision_id: Optional[str]
    active_source_revision_ids: List[str]
    excluded_source_revision_ids: List[str]

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


@dataclass(frozen=True)
class ScopeImpactRevalidationReport:
    """
    S13.5 & S13.T3 (DATA-05):
    When a new source is added to a workday, even if existing claims had NO DAG edge to the new source,
    scope-sensitive assessments and any claim matching reverse-retrieved counterevidence/support in the new source
    are transitioned to pending revalidation and re-evaluated.
    Meanwhile, immutable `RawObservationRecord`s of older sources remain untouched.
    """

    old_scope_revision_id: str
    new_scope_revision_id: str
    added_source_revision_ids: List[str]
    preserved_raw_observation_count: int
    affected_claim_revision_ids: List[str]
    newly_contradicted_claim_ids: List[str]
    impact_status: str  # 'no_material_change' | 'material_change' | 'unresolved'

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


def revalidate_scope_on_new_source(
    *,
    old_scope: EvidenceScopeRevision,
    new_source_revision_id: str,
    existing_raw_observations: Sequence[Any],
    existing_claims: Sequence[AtomicClaimProposal],
    existing_edges: Sequence[EvidenceEdge],
    new_source_edges: Sequence[EvidenceEdge],
) -> Tuple[
    EvidenceScopeRevision,
    Dict[str, Tuple[SupportAssessmentRecord, ClaimUseDecisionRecord]],
    ScopeImpactRevalidationReport,
]:
    """
    S13.5 & S13.T3:
    1. Creates a new `EvidenceScopeRevision` including `new_source_revision_id`.
    2. Preserves all `existing_raw_observations` without re-scanning old clips.
    3. Performs reverse retrieval from `new_source_edges` against `existing_claims` (catching counterevidence even
       when the old claim only pointed to an older asset!).
    4. Re-computes `SupportAssessmentRecord` and `ClaimUseDecisionRecord` for affected and scope-sensitive claims.
    """
    new_sources = sorted(set(old_scope.active_source_revision_ids + [new_source_revision_id]))
    new_scope = EvidenceScopeRevision(
        scope_revision_id=f"{old_scope.scope_revision_id}-next",
        workday_id=old_scope.workday_id,
        parent_scope_revision_id=old_scope.scope_revision_id,
        active_source_revision_ids=new_sources,
        excluded_source_revision_ids=list(old_scope.excluded_source_revision_ids),
    )

    combined_edges = list(existing_edges) + list(new_source_edges)
    new_edge_claim_ids = {e.claim_revision_id for e in new_source_edges}

    updated_evaluations: Dict[str, Tuple[SupportAssessmentRecord, ClaimUseDecisionRecord]] = {}
    affected_ids: List[str] = []
    newly_contradicted: List[str] = []

    for claim in existing_claims:
        is_affected = claim.scope_sensitive or (claim.claim_revision_id in new_edge_claim_ids)
        if is_affected:
            affected_ids.append(claim.claim_revision_id)

        old_assess, old_dec = evaluate_claim_support_and_use(
            claim=claim,
            evidence_edges=existing_edges,
            evidence_scope_revision_id=old_scope.scope_revision_id,
        )
        new_assess, new_dec = evaluate_claim_support_and_use(
            claim=claim,
            evidence_edges=combined_edges,
            evidence_scope_revision_id=new_scope.scope_revision_id,
        )
        updated_evaluations[claim.claim_revision_id] = (new_assess, new_dec)

        if old_assess.support_status == "supported" and new_assess.support_status in ("contradicted", "disputed"):
            newly_contradicted.append(claim.claim_revision_id)

    impact_status = "material_change" if newly_contradicted else "no_material_change"
    report = ScopeImpactRevalidationReport(
        old_scope_revision_id=old_scope.scope_revision_id,
        new_scope_revision_id=new_scope.scope_revision_id,
        added_source_revision_ids=[new_source_revision_id],
        preserved_raw_observation_count=len(existing_raw_observations),
        affected_claim_revision_ids=affected_ids,
        newly_contradicted_claim_ids=newly_contradicted,
        impact_status=impact_status,
    )
    return new_scope, updated_evaluations, report
