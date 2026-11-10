"""
tests/test_s14_review_workflow.py — Unit Tests for S14 Evidence-Backed Targeted Review Workflow,
Resolution Commands, Batch Confirmation Isolation & Ergonomics Metrics.
Covers S14.T1, S14.T2, S14.T3, and S14.T4.
"""

from __future__ import annotations

from pathlib import Path
import sys
import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from workers.src.aivideo_workers.review_workflow import (
    ReviewEvidenceAttachment,
    ReviewWorkflowError,
    TargetedReviewItem,
    apply_review_resolution,
    compute_review_ergonomics_metrics,
    filter_Batch_confirmable_revisions,
    should_suppress_duplicate_question,
)


class TestS14ReviewWorkflow(unittest.TestCase):
    def test_s14_t1_answer_unknown_is_not_agreement_and_critical_issue_blocks_only_dependent_branch(self) -> None:
        """
        S14.T1 (AI-09):
        - Answering `answer_unknown` closes the question with `resulting_allowed_use = 'exclude'` (never agreement).
        - A critical issue on `concept-A-gps` blocks ONLY `concept-A-gps`, leaving `concept-B-scenic` viable.
        - Suppresses duplicate re-asking unless the evidence scope revision changes.
        """
        att = ReviewEvidenceAttachment(
            evidence_kind="brief_span",
            role="primary_question_target",
            brief_revision_id="brief-r1",
            char_span=(0, 32),
        )
        item = TargetedReviewItem(
            review_item_id="rev-item-001",
            workday_id="wd-01",
            issue_key="claim-gps-r1:scope-v1",
            target_claim_revision_id="claim-gps-r1",
            target_fact_revision_id="fact-gps-r1",
            evidence_scope_revision_id="scope-v1",
            is_critical=True,
            question_text="Bạn có muốn xác nhận nguyên nhân quay đầu xe trong đoạn ghi chú này không?",
            reason_for_asking="Chỉ có hình quay đầu xe, chưa có bằng chứng nguyên nhân ngoài camera.",
            affected_story_concept_ids=["concept-A-gps"],
            affected_beat_ids=["beat-02"],
            attachments=[att],
        )

        res = apply_review_resolution(
            item=item,
            action="answer_unknown",
            all_story_concept_ids=["concept-A-gps", "concept-B-scenic"],
        )
        self.assertEqual(res.resulting_epistemic_status, "unknown")
        self.assertEqual(res.resulting_support_status, "insufficient")
        self.assertEqual(res.resulting_allowed_use, "exclude")
        self.assertEqual(res.blocked_story_concept_ids, ["concept-A-gps"])
        self.assertEqual(res.viable_alternative_concept_ids, ["concept-B-scenic"])
        self.assertFalse(res.reask_allowed_without_new_evidence)

        # Same scope -> suppress duplicate question
        self.assertTrue(
            should_suppress_duplicate_question(
                candidate_item=item,
                existing_resolutions=[res],
                current_evidence_scope_revision_id="scope-v1",
            )
        )
        # New scope after adding a new clip -> allow re-evaluation
        self.assertFalse(
            should_suppress_duplicate_question(
                candidate_item=item,
                existing_resolutions=[res],
                current_evidence_scope_revision_id="scope-v2-new-clip",
            )
        )

    def test_s14_t2_photo_and_brief_reviews_reject_fake_timecodes_and_video_distinguishes_source_vs_timeline(self) -> None:
        """
        S14.T2:
        - Still photo and brief-only reviews use exact photo revision/crop or brief span and reject fake media timecodes.
        - Video/audio reviews keep `source_time_range_sec` and `timeline_time_range_sec` strictly distinct.
        """
        # 1. Valid still photo attachment without timecode
        photo_att = ReviewEvidenceAttachment(
            evidence_kind="still_photo",
            role="primary_question_target",
            source_revision_id="src-photo-01",
            crop_rect_normalized=(0.1, 0.2, 0.5, 0.6),
        )
        self.assertIsNone(photo_att.source_time_range_sec)

        # 2. Fake timecode on still photo -> must raise FAKE_TIMECODE_ON_PHOTO
        with self.assertRaises(ReviewWorkflowError) as ctx_p:
            ReviewEvidenceAttachment(
                evidence_kind="still_photo",
                role="primary_question_target",
                source_revision_id="src-photo-01",
                source_time_range_sec=(10.0, 12.0),
            )
        self.assertEqual(ctx_p.exception.code, "FAKE_TIMECODE_ON_PHOTO")

        # 3. Fake timecode on brief_span -> must raise FAKE_TIMECODE_ON_BRIEF
        with self.assertRaises(ReviewWorkflowError) as ctx_b:
            ReviewEvidenceAttachment(
                evidence_kind="brief_span",
                role="primary_question_target",
                brief_revision_id="brief-r1",
                char_span=(5, 20),
                source_time_range_sec=(0.0, 5.0),
            )
        self.assertEqual(ctx_b.exception.code, "FAKE_TIMECODE_ON_BRIEF")

        # 4. Video attachment keeps source time and timeline time distinct
        vid_att = ReviewEvidenceAttachment(
            evidence_kind="video_or_audio",
            role="primary_question_target",
            source_revision_id="src-vid-01",
            source_time_range_sec=(125.5, 130.0),
            context_before_after_sec=(120.0, 135.0),
            timeline_time_range_sec=(12.0, 16.5),
        )
        self.assertEqual(vid_att.source_time_range_sec, (125.5, 130.0))
        self.assertEqual(vid_att.timeline_time_range_sec, (12.0, 16.5))

    def test_s14_t3_batch_confirmation_excludes_background_arrivals_and_preserves_vietnamese_edit(self) -> None:
        """
        S14.T3 (UI-08):
        - Batch confirmation only confirms items that were displayed in the UI snapshot AND selected by the user;
          background items that arrived from a worker during review (`fact-r3-bg-new`) are never auto-confirmed.
        - Editing a fact in Vietnamese preserves NFC diacritics and creates a new revision.
        """
        displayed = ["fact-r1", "fact-r2"]
        selected = ["fact-r1", "fact-r2", "fact-r3-bg-new"]
        store_current = ["fact-r1", "fact-r2", "fact-r3-bg-new", "fact-r4-bg-new"]

        approved, skipped_bg = filter_Batch_confirmable_revisions(
            displayed_revision_ids=displayed,
            user_selected_revision_ids=selected,
            current_store_revision_ids=store_current,
        )
        self.assertEqual(approved, ["fact-r1", "fact-r2"])
        self.assertEqual(skipped_bg, ["fact-r3-bg-new", "fact-r4-bg-new"])

        # Vietnamese edit test
        att = ReviewEvidenceAttachment(
            evidence_kind="brief_span",
            role="primary_question_target",
            brief_revision_id="brief-r1",
            char_span=(0, 25),
        )
        item = TargetedReviewItem(
            review_item_id="rev-vn-edit",
            workday_id="wd-01",
            issue_key="fact-r1:scope-v1",
            target_claim_revision_id="claim-r1",
            target_fact_revision_id="fact-r1",
            evidence_scope_revision_id="scope-v1",
            is_critical=True,
            question_text="Kiểm tra lại tên đèo trong ghi chú ngày làm việc?",
            reason_for_asking="Cần xác nhận tên địa điểm chính xác.",
            affected_story_concept_ids=["concept-A"],
            affected_beat_ids=["beat-1"],
            attachments=[att],
        )
        res_edit = apply_review_resolution(
            item=item,
            action="edit_fact_or_claim",
            new_fact_text="Đèo Omega (Khánh Lê - Lâm Đồng) lúc 6 giờ 15 phút sáng",
        )
        self.assertEqual(res_edit.new_fact_text, "Đèo Omega (Khánh Lê - Lâm Đồng) lúc 6 giờ 15 phút sáng")
        self.assertEqual(res_edit.resulting_origin, "user")
        self.assertEqual(res_edit.resulting_epistemic_status, "reported")

    def test_s14_t4_review_ergonomics_metrics_measurement(self) -> None:
        """
        S14.T4: Measures duplicate question rate, useful question rate (including `answer_unknown` that helps prune
        unsupported claims), and active review minutes without imposing an arbitrary hard cap to hide critical issues.
        """
        att = ReviewEvidenceAttachment(
            evidence_kind="brief_span",
            role="primary_question_target",
            brief_revision_id="brief-r1",
            char_span=(0, 10),
        )
        q1 = TargetedReviewItem(
            review_item_id="q1",
            workday_id="wd-01",
            issue_key="issue-1",
            target_claim_revision_id="c1",
            target_fact_revision_id="f1",
            evidence_scope_revision_id="scope-1",
            is_critical=True,
            question_text="Câu hỏi làm rõ sự kiện 1?",
            reason_for_asking="Thiếu bằng chứng",
            affected_story_concept_ids=["concept-A"],
            affected_beat_ids=["b1"],
            attachments=[att],
        )
        q2 = TargetedReviewItem(
            review_item_id="q2",
            workday_id="wd-01",
            issue_key="issue-2",
            target_claim_revision_id="c2",
            target_fact_revision_id="f2",
            evidence_scope_revision_id="scope-1",
            is_critical=True,
            question_text="Câu hỏi làm rõ sự kiện 2?",
            reason_for_asking="Mâu thuẫn thời gian",
            affected_story_concept_ids=["concept-B"],
            affected_beat_ids=["b2"],
            attachments=[att],
        )
        r1 = apply_review_resolution(item=q1, action="confirm_user_fact")
        r2 = apply_review_resolution(item=q2, action="answer_unknown")

        metrics = compute_review_ergonomics_metrics(
            presented_items=[q1, q2],
            resolutions=[r1, r2],
            active_interaction_seconds=[18.0, 24.0],
        )
        self.assertEqual(metrics["total_presented_questions"], 2)
        self.assertEqual(metrics["duplicate_question_count"], 0)
        self.assertEqual(metrics["duplicate_question_rate"], 0.0)
        self.assertEqual(metrics["useful_question_count"], 2)
        self.assertEqual(metrics["useful_question_rate"], 1.0)
        self.assertEqual(metrics["active_review_minutes_per_project"], 0.7)


if __name__ == "__main__":
    unittest.main()
