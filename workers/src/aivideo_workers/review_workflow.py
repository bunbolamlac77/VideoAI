"""
workers/src/aivideo_workers/review_workflow.py

⚠️ NOT WIRED INTO PRODUCTION (audit P2-12, 2026-11-11).
The S14 targeted-review workflow that ships runs in Swift (`ProjectStore.listReviewItems` /
`resolveReviewItem`, driven by `G2ConsoleView`). This module is a pure-Python model of the
same rules; only `tests/test_s14_review_workflow.py` imports it. It must NOT be cited as S14
acceptance evidence, and `tests/test_p2_debt.py` fails if a production module starts
importing it without this note being updated.

Original header follows.

S14 Evidence-Backed Targeted Review Workflow,
Resolution Commands, Impact Propagation & Review Ergonomics Metrics.
Compliant with docs/01-PRODUCT.md, docs/02-ANALYSIS-AND-DATA.md (Sections 3, 11, 12),
docs/08-ACCURACY-FIRST.md (Section 14), docs/09-UPGRADES-AND-ACCEPTANCE.md (AI-09, DATA-05, UI-06..UI-13, UI-27),
and docs/11-CODING-WORKFLOW-AND-CHECKLIST.md (S14).
"""

from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple


class ReviewWorkflowError(RuntimeError):
    """Scoped error raised by S14 targeted review workflow."""

    def __init__(self, code: str, message: str, details: Optional[Dict[str, Any]] = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}


@dataclass(frozen=True)
class ReviewEvidenceAttachment:
    """
    S14.2 & S14.T2: Typed evidence reference for a review item.
    - `video_or_audio`: requires `source_revision_id`, `source_time_range_sec`, and optional `context_before_after_sec`.
      Strictly distinguishes `source_time_range_sec` from `timeline_time_range_sec`.
    - `still_photo`: requires `source_revision_id` and optional `crop_rect_normalized`, NEVER forces fake PTS/timecode.
    - `brief_span`: requires `brief_revision_id` and `char_span`, NEVER forces fake media clip attachment.
    """

    evidence_kind: str  # 'video_or_audio' | 'still_photo' | 'brief_span'
    role: str  # 'primary_question_target' | 'contradicting_evidence' | 'context_only'
    source_revision_id: Optional[str] = None
    brief_revision_id: Optional[str] = None
    source_time_range_sec: Optional[Tuple[float, float]] = None
    context_before_after_sec: Optional[Tuple[float, float]] = None
    timeline_time_range_sec: Optional[Tuple[float, float]] = None
    crop_rect_normalized: Optional[Tuple[float, float, float, float]] = None
    char_span: Optional[Tuple[int, int]] = None

    def __post_init__(self) -> None:
        if self.evidence_kind not in ("video_or_audio", "still_photo", "brief_span"):
            raise ReviewWorkflowError("INVALID_EVIDENCE_KIND", f"Unknown evidence_kind: {self.evidence_kind}")
        if self.role not in ("primary_question_target", "contradicting_evidence", "context_only"):
            raise ReviewWorkflowError("INVALID_ATTACHMENT_ROLE", f"Invalid role: {self.role}")

        if self.evidence_kind == "video_or_audio":
            if not self.source_revision_id or self.source_time_range_sec is None:
                raise ReviewWorkflowError(
                    "MISSING_VIDEO_TIME_RANGE",
                    "video_or_audio review attachment requires source_revision_id and source_time_range_sec.",
                )
        elif self.evidence_kind == "still_photo":
            if not self.source_revision_id:
                raise ReviewWorkflowError(
                    "MISSING_PHOTO_REVISION",
                    "still_photo review attachment requires source_revision_id.",
                )
            if self.source_time_range_sec is not None:
                raise ReviewWorkflowError(
                    "FAKE_TIMECODE_ON_PHOTO",
                    "still_photo review attachment must not carry fake media timecodes (S14.T2).",
                )
        elif self.evidence_kind == "brief_span":
            if not self.brief_revision_id or self.char_span is None:
                raise ReviewWorkflowError(
                    "MISSING_BRIEF_SPAN",
                    "brief_span review attachment requires brief_revision_id and char_span.",
                )
            if self.source_time_range_sec is not None:
                raise ReviewWorkflowError(
                    "FAKE_TIMECODE_ON_BRIEF",
                    "brief_span review attachment must not carry fake media timecodes (S14.T2).",
                )

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


@dataclass(frozen=True)
class TargetedReviewItem:
    """
    S14.2: A targeted review item with neutral wording, explicit scope, and dependent story concepts/beats.
    """

    review_item_id: str
    workday_id: str
    issue_key: str  # Deduplication key: (target_logical_id, target_revision_id, scope_revision_id)
    target_claim_revision_id: Optional[str]
    target_fact_revision_id: Optional[str]
    evidence_scope_revision_id: str
    is_critical: bool
    question_text: str
    reason_for_asking: str
    affected_story_concept_ids: List[str]
    affected_beat_ids: List[str]
    attachments: List[ReviewEvidenceAttachment]
    status: str = "open"  # 'open' | 'resolved' | 'superseded'

    def __post_init__(self) -> None:
        # Neutral question check (S14.2: must not suggest unverified causes as leading questions)
        lower_q = self.question_text.lower()
        leading_phrases = ("chắc chắn là vì", "có phải bạn cố tình", "đúng là do gps")
        for phrase in leading_phrases:
            if phrase in lower_q:
                raise ReviewWorkflowError(
                    "NON_NEUTRAL_LEADING_QUESTION",
                    f"Question text violates neutral wording policy (contains '{phrase}'): {self.question_text}",
                )

    def to_dict(self) -> Dict[str, Any]:
        return {
            "review_item_id": self.review_item_id,
            "workday_id": self.workday_id,
            "issue_key": self.issue_key,
            "target_claim_revision_id": self.target_claim_revision_id,
            "target_fact_revision_id": self.target_fact_revision_id,
            "evidence_scope_revision_id": self.evidence_scope_revision_id,
            "is_critical": self.is_critical,
            "question_text": self.question_text,
            "reason_for_asking": self.reason_for_asking,
            "affected_story_concept_ids": self.affected_story_concept_ids,
            "affected_beat_ids": self.affected_beat_ids,
            "attachments": [a.to_dict() for a in self.attachments],
            "status": self.status,
        }


@dataclass(frozen=True)
class ReviewResolutionRecord:
    """
    S14.3 & docs/02 Section 12:
    Supported actions:
    - `confirm_user_fact`: confirms exact displayed `fact_revision_id`; origin remains `user` (`reported`).
    - `edit_fact_or_claim`: creates a new revision and supersedes old revision without mutating history.
    - `reject_ai_observation`: rejects AI observation with reason/scope; keeps historical observation & counterevidence.
    - `answer_unknown`: closes the question without granting support (`allowed_use = exclude`); never re-asks unless new evidence arrives.
    - `drop_claim_or_detail`: excludes claim from all story concepts (including humorous commentary).
    - `exclude_asset_from_edit`: marks asset `must_not_use` in scope without deleting source snapshot.
    """

    resolution_id: str
    review_item_id: str
    workday_id: str
    action: str
    actor: str
    resolved_claim_revision_id: Optional[str]
    resolved_fact_revision_id: Optional[str]
    evidence_scope_revision_id: str
    new_fact_text: Optional[str]
    excluded_asset_id: Optional[str]
    resulting_origin: str
    resulting_epistemic_status: str
    resulting_support_status: str
    resulting_allowed_use: str
    blocked_story_concept_ids: List[str]
    viable_alternative_concept_ids: List[str]
    reask_allowed_without_new_evidence: bool

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


def apply_review_resolution(
    *,
    item: TargetedReviewItem,
    action: str,
    actor: str = "user_local",
    all_story_concept_ids: Sequence[str] = ("concept-A", "concept-B"),
    new_fact_text: Optional[str] = None,
    excluded_asset_id: Optional[str] = None,
) -> ReviewResolutionRecord:
    """
    S14.3 & S14.T1:
    Applies a user resolution command to a `TargetedReviewItem` and computes exact downstream impact:
    - Answering `answer_unknown` NEVER becomes agreement (`resulting_support_status = 'insufficient'`,
      `resulting_allowed_use = 'exclude'`, `reask_allowed_without_new_evidence = False`).
    - An unresolved or excluded critical issue blocks ONLY `item.affected_story_concept_ids`, leaving
      other story concepts in `viable_alternative_concept_ids` unblocked so the workflow can switch angles.
    """
    valid_actions = (
        "confirm_user_fact",
        "edit_fact_or_claim",
        "reject_ai_observation",
        "answer_unknown",
        "drop_claim_or_detail",
        "exclude_asset_from_edit",
    )
    if action not in valid_actions:
        raise ReviewWorkflowError("INVALID_RESOLUTION_ACTION", f"Unsupported resolution action: {action}")

    affected_set = set(item.affected_story_concept_ids)
    all_concepts = list(dict.fromkeys(all_story_concept_ids))

    if action == "confirm_user_fact":
        # Origin remains user, epistemic remains reported!
        return ReviewResolutionRecord(
            resolution_id=f"res-{item.review_item_id}-confirm",
            review_item_id=item.review_item_id,
            workday_id=item.workday_id,
            action=action,
            actor=actor,
            resolved_claim_revision_id=item.target_claim_revision_id,
            resolved_fact_revision_id=item.target_fact_revision_id,
            evidence_scope_revision_id=item.evidence_scope_revision_id,
            new_fact_text=None,
            excluded_asset_id=None,
            resulting_origin="user",
            resulting_epistemic_status="reported",
            resulting_support_status="supported",
            resulting_allowed_use="attributed_or_qualified",
            blocked_story_concept_ids=[],
            viable_alternative_concept_ids=all_concepts,
            reask_allowed_without_new_evidence=False,
        )

    if action == "edit_fact_or_claim":
        if not new_fact_text or not new_fact_text.strip():
            raise ReviewWorkflowError("EMPTY_EDIT_TEXT", "edit_fact_or_claim requires non-empty new_fact_text.")
        return ReviewResolutionRecord(
            resolution_id=f"res-{item.review_item_id}-edit",
            review_item_id=item.review_item_id,
            workday_id=item.workday_id,
            action=action,
            actor=actor,
            resolved_claim_revision_id=item.target_claim_revision_id,
            resolved_fact_revision_id=item.target_fact_revision_id,
            evidence_scope_revision_id=item.evidence_scope_revision_id,
            new_fact_text=new_fact_text.strip(),
            excluded_asset_id=None,
            resulting_origin="user",
            resulting_epistemic_status="reported",
            resulting_support_status="supported",
            resulting_allowed_use="attributed_or_qualified",
            blocked_story_concept_ids=[],
            viable_alternative_concept_ids=all_concepts,
            reask_allowed_without_new_evidence=False,
        )

    # For answer_unknown, reject_ai_observation, drop_claim_or_detail, exclude_asset_from_edit:
    # Claim is NOT allowed (`exclude`), and if critical, it blocks ONLY dependent story concepts.
    blocked_concepts = [c for c in all_concepts if c in affected_set] if item.is_critical else []
    viable_concepts = [c for c in all_concepts if c not in blocked_concepts]

    return ReviewResolutionRecord(
        resolution_id=f"res-{item.review_item_id}-{action}",
        review_item_id=item.review_item_id,
        workday_id=item.workday_id,
        action=action,
        actor=actor,
        resolved_claim_revision_id=item.target_claim_revision_id,
        resolved_fact_revision_id=item.target_fact_revision_id,
        evidence_scope_revision_id=item.evidence_scope_revision_id,
        new_fact_text=None,
        excluded_asset_id=excluded_asset_id if action == "exclude_asset_from_edit" else None,
        resulting_origin="user" if item.target_fact_revision_id else "visual_model",
        resulting_epistemic_status="unknown" if action == "answer_unknown" else "reported",
        resulting_support_status="contradicted" if action == "reject_ai_observation" else "insufficient",
        resulting_allowed_use="exclude",
        blocked_story_concept_ids=blocked_concepts,
        viable_alternative_concept_ids=viable_concepts,
        reask_allowed_without_new_evidence=False,
    )


def filter_Batch_confirmable_revisions(
    *,
    displayed_revision_ids: Sequence[str],
    user_selected_revision_ids: Sequence[str],
    current_store_revision_ids: Sequence[str],
) -> Tuple[List[str], List[str]]:
    """
    S14.1 & S14.T3 (UI-08):
    Batch confirmation strictly applies ONLY to the intersection of:
    - revisions that were actually displayed in the UI snapshot when the user reviewed them (`displayed_revision_ids`)
    - revisions explicitly selected by the user (`user_selected_revision_ids`)
    Any background items newly inserted by a worker (`current_store_revision_ids - displayed_revision_ids`)
    are returned in `skipped_background_arrival_ids` and NEVER auto-confirmed!
    """
    displayed_set = set(displayed_revision_ids)
    selected_set = set(user_selected_revision_ids)

    approved_for_batch = [rid for rid in displayed_revision_ids if rid in selected_set]
    skipped_background = [rid for rid in current_store_revision_ids if rid not in displayed_set]
    return approved_for_batch, skipped_background


def should_suppress_duplicate_question(
    *,
    candidate_item: TargetedReviewItem,
    existing_resolutions: Sequence[ReviewResolutionRecord],
    current_evidence_scope_revision_id: str,
) -> bool:
    """
    S14.4: Prevents re-asking the same question for the same claim/fact revision and evidence scope
    after the user already resolved it (including answering `answer_unknown`), unless `current_evidence_scope_revision_id`
    has advanced with new relevant evidence.
    """
    for res in existing_resolutions:
        same_target = (
            res.resolved_claim_revision_id == candidate_item.target_claim_revision_id
            and res.resolved_fact_revision_id == candidate_item.target_fact_revision_id
        )
        same_scope = res.evidence_scope_revision_id == current_evidence_scope_revision_id
        if same_target and same_scope and not res.reask_allowed_without_new_evidence:
            return True
    return False


def compute_review_ergonomics_metrics(
    *,
    presented_items: Sequence[TargetedReviewItem],
    resolutions: Sequence[ReviewResolutionRecord],
    active_interaction_seconds: Sequence[float],
) -> Dict[str, Any]:
    """
    S14.T4 & docs/09 Section 4.4:
    Computes `active_review_minutes_per_project`, `duplicate_question_rate`, and `useful_question_rate`.
    Includes unanswered, skipped, and `answer_unknown` items in the denominator.
    An `answer_unknown` or `drop_claim_or_detail` resolution that prevents a false claim or switches story angle
    is counted as useful.
    """
    total_q = len(presented_items)
    if total_q == 0:
        return {
            "total_presented_questions": 0,
            "duplicate_question_count": 0,
            "duplicate_question_rate": None,
            "useful_question_count": 0,
            "useful_question_rate": None,
            "active_review_minutes_per_project": 0.0,
        }

    seen_keys: Set[str] = set()
    dup_count = 0
    for item in presented_items:
        if item.issue_key in seen_keys:
            dup_count += 1
        seen_keys.add(item.issue_key)

    res_by_item = {r.review_item_id: r for r in resolutions}
    useful_count = 0
    for item in presented_items:
        res = res_by_item.get(item.review_item_id)
        if res is not None and res.action in (
            "confirm_user_fact",
            "edit_fact_or_claim",
            "reject_ai_observation",
            "answer_unknown",
            "drop_claim_or_detail",
            "exclude_asset_from_edit",
        ):
            useful_count += 1

    active_minutes = sum(max(0.0, float(s)) for s in active_interaction_seconds) / 60.0
    return {
        "total_presented_questions": total_q,
        "duplicate_question_count": dup_count,
        "duplicate_question_rate": round(dup_count / float(total_q), 6),
        "useful_question_count": useful_count,
        "useful_question_rate": round(useful_count / float(total_q), 6),
        "active_review_minutes_per_project": round(active_minutes, 4),
    }
