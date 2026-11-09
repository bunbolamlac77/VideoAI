"""
tests/test_s13_semantic_verifier.py — Unit Tests for S13 Brief Parser, Atomic Claims,
Section 6 Decision Table, Partial-Order Event Graph & Scope-Sensitive Revalidation.
Covers S13.T1, S13.T2, S13.T3, and S13.T4.
"""

from __future__ import annotations

import unittest

from workers.src.aivideo_workers.semantic_verifier import (
    AtomicClaimProposal,
    EvidenceEdge,
    EvidenceScopeRevision,
    EventNode,
    EventRelationEdge,
    analyze_partial_order_event_graph,
    decompose_causal_or_compound_statement,
    evaluate_claim_support_and_use,
    parse_raw_brief_to_drafts,
    revalidate_scope_on_new_source,
)


class TestS13SemanticVerifier(unittest.TestCase):
    def test_s13_1_brief_parser_facts_preferences_constraints_and_time_precision(self) -> None:
        raw_brief = (
            "Khởi hành khoảng 3 giờ sáng từ Đà Lạt; "
            "Tôi thích nhạc vui và nhịp dựng nhanh; "
            "Không dùng cảnh trượt chân ở bãi đá."
        )
        drafts = parse_raw_brief_to_drafts(
            brief_revision_id="brief-rev-001",
            workday_id="wd-001",
            raw_brief_text=raw_brief,
            explicit_timezone_iana=None,  # Must NOT auto-fill system timezone!
        )
        self.assertEqual(len(drafts), 3)

        # 1. Event fact with approximate time and preserved character span
        d0 = drafts[0]
        self.assertEqual(d0.item_kind, "event_fact")
        self.assertEqual(raw_brief[d0.start_char : d0.end_char], d0.raw_span_text)
        self.assertTrue(d0.is_uncertain)
        self.assertEqual(d0.time_precision, "approximate")
        self.assertIn("3 giờ sáng", d0.reported_time_text or "")
        self.assertIsNone(d0.timezone_iana)

        # 2. Style preference
        d1 = drafts[1]
        self.assertEqual(d1.item_kind, "style_preference")
        self.assertEqual(d1.constraint_type, "preferred")

        # 3. Usage constraint (must_not_use) with negation
        d2 = drafts[2]
        self.assertEqual(d2.item_kind, "usage_constraint")
        self.assertEqual(d2.constraint_type, "must_not_use")
        self.assertTrue(d2.is_negated)

    def test_s13_t1_causal_claim_split_blocked_without_cause_evidence_and_user_confirmed_stays_reported(self) -> None:
        """
        S13.T1: "Quay đầu vì GPS báo nhầm" is decomposed into action, cause, and causal_relation.
        - If only visual evidence of turning around exists, the causal claim is blocked (`insufficient` / `exclude`).
        - When user confirms the reason, `origin` stays `user` (`reported`), and `allowed_use` becomes
          `attributed_or_qualified` (never `observed` / `direct_claim`).
        """
        proposals = decompose_causal_or_compound_statement(
            compound_id="claim-turn-gps",
            workday_id="wd-001",
            raw_statement="Quay đầu xe vì GPS báo nhầm đường",
            is_critical=True,
        )
        self.assertEqual(len(proposals), 3)
        act_claim, cause_claim, rel_claim = proposals[0], proposals[1], proposals[2]
        self.assertEqual(act_claim.claim_type, "atomic_action")
        self.assertEqual(cause_claim.claim_type, "off_camera_fact")
        self.assertEqual(rel_claim.claim_type, "causal_relation")
        self.assertEqual(rel_claim.component_claim_ids, [act_claim.claim_id, cause_claim.claim_id])

        # Only visual evidence of turning around (`act_claim.claim_id`)
        visual_only_edge = EvidenceEdge(
            edge_id="edge-vis-turn",
            claim_revision_id=rel_claim.claim_revision_id,
            evidence_revision_id="obs-turn-01",
            evidence_kind="visual_observation",
            role="supports",
            covered_component_ids=[act_claim.claim_id],
        )
        assess_1, dec_1 = evaluate_claim_support_and_use(
            claim=rel_claim,
            evidence_edges=[visual_only_edge],
            evidence_scope_revision_id="scope-01",
            narrative_type="observed",
        )
        self.assertEqual(assess_1.support_status, "insufficient")
        self.assertEqual(dec_1.allowed_use, "exclude")

        # Now user confirms the off-camera GPS reason (`origin=user, epistemic_status=reported, review_status=confirmed`)
        confirmed_rel_claim = AtomicClaimProposal(
            claim_id=rel_claim.claim_id,
            claim_revision_id="claim-turn-gps-causal-rel-r2",
            workday_id="wd-001",
            claim_type="causal_relation",
            subject=rel_claim.subject,
            predicate_text=rel_claim.predicate_text,
            parent_compound_id=None,
            component_claim_ids=[act_claim.claim_id, cause_claim.claim_id],
            is_critical=True,
            origin="user",
            epistemic_status="reported",
            review_status="confirmed",
        )
        edges_with_user = [
            EvidenceEdge(
                edge_id="edge-vis-turn-2",
                claim_revision_id=confirmed_rel_claim.claim_revision_id,
                evidence_revision_id="obs-turn-01",
                evidence_kind="visual_observation",
                role="supports",
                covered_component_ids=[act_claim.claim_id],
            ),
            EvidenceEdge(
                edge_id="edge-user-gps",
                claim_revision_id=confirmed_rel_claim.claim_revision_id,
                evidence_revision_id="fact-gps-confirmed",
                evidence_kind="user_fact",
                role="supports",
                covered_component_ids=[cause_claim.claim_id],
            ),
        ]

        # If narrated as `observed`, it MUST be blocked (INV-02: user confirmation is still reported!)
        _, dec_illegal_obs = evaluate_claim_support_and_use(
            claim=confirmed_rel_claim,
            evidence_edges=edges_with_user,
            evidence_scope_revision_id="scope-01",
            narrative_type="observed",
        )
        self.assertEqual(dec_illegal_obs.allowed_use, "exclude")

        # When narrated as `reported_by_user`, it is allowed as `attributed_or_qualified`
        assess_2, dec_2 = evaluate_claim_support_and_use(
            claim=confirmed_rel_claim,
            evidence_edges=edges_with_user,
            evidence_scope_revision_id="scope-01",
            narrative_type="reported_by_user",
        )
        self.assertEqual(confirmed_rel_claim.origin, "user")
        self.assertEqual(confirmed_rel_claim.epistemic_status, "reported")
        self.assertEqual(assess_2.support_status, "supported")
        self.assertEqual(dec_2.allowed_use, "attributed_or_qualified")

    def test_s13_t2_multi_clause_partial_support_and_context_only_never_upgrade(self) -> None:
        """
        S13.T2: A multi-clause sentence with evidence for only one clause does NOT pass the full-sentence gate;
        adding a valid `context_only` citation does NOT upgrade support.
        """
        proposals = decompose_causal_or_compound_statement(
            compound_id="claim-multi",
            workday_id="wd-001",
            raw_statement="Dựng lều bên hồ và nướng cá lúc nửa đêm",
            is_critical=True,
            origin="visual_model",
            epistemic_status="observed",
            review_status="auto_checked",
        )
        self.assertEqual(len(proposals), 3)
        c1, c2, compound = proposals[0], proposals[1], proposals[2]

        edges = [
            EvidenceEdge(
                edge_id="e-tent-supports",
                claim_revision_id=compound.claim_revision_id,
                evidence_revision_id="obs-tent",
                evidence_kind="visual_observation",
                role="supports",
                covered_component_ids=[c1.claim_id],
            ),
            EvidenceEdge(
                edge_id="e-lake-context-only",
                claim_revision_id=compound.claim_revision_id,
                evidence_revision_id="obs-lake-broll",
                evidence_kind="visual_observation",
                role="context_only",  # Valid citation, but context_only!
                covered_component_ids=[c2.claim_id],
            ),
        ]
        assess, dec = evaluate_claim_support_and_use(
            claim=compound,
            evidence_edges=edges,
            evidence_scope_revision_id="scope-01",
            narrative_type="observed",
        )
        self.assertEqual(assess.support_status, "insufficient")
        self.assertEqual(dec.allowed_use, "exclude")

    def test_s13_t3_new_counterevidence_clip_revalidates_scope_without_old_dag_edge(self) -> None:
        """
        S13.T3 (DATA-05): Adding a new clip containing counterevidence re-evaluates claims in the workday scope
        even when the old claim only had edges to an older asset; old raw observations are preserved.
        """
        old_scope = EvidenceScopeRevision(
            scope_revision_id="scope-v1",
            workday_id="wd-001",
            parent_scope_revision_id=None,
            active_source_revision_ids=["src-01"],
            excluded_source_revision_ids=[],
        )
        claim = AtomicClaimProposal(
            claim_id="claim-sunny-all-morning",
            claim_revision_id="claim-sunny-r1",
            workday_id="wd-001",
            claim_type="atomic_action",
            subject="weather",
            predicate_text="Trời nắng ráo suốt buổi sáng không mưa",
            parent_compound_id=None,
            component_claim_ids=["claim-sunny-all-morning"],
            is_critical=True,
            origin="visual_model",
            epistemic_status="observed",
            review_status="auto_checked",
            scope_sensitive=True,
        )
        old_edges = [
            EvidenceEdge(
                edge_id="e-src01-sunny",
                claim_revision_id=claim.claim_revision_id,
                evidence_revision_id="obs-src01-sunny",
                evidence_kind="visual_observation",
                role="supports",
                covered_component_ids=["claim-sunny-all-morning"],
            )
        ]
        # New clip `src-02` arrives later showing heavy rain during the same morning
        new_source_edges = [
            EvidenceEdge(
                edge_id="e-src02-rain-contra",
                claim_revision_id=claim.claim_revision_id,
                evidence_revision_id="obs-src02-heavy-rain",
                evidence_kind="visual_observation",
                role="contradicts",
                covered_component_ids=["claim-sunny-all-morning"],
            )
        ]
        existing_raw_obs = [{"obs_id": "obs-src01-1"}, {"obs_id": "obs-src01-2"}]

        new_scope, evals, impact = revalidate_scope_on_new_source(
            old_scope=old_scope,
            new_source_revision_id="src-02",
            existing_raw_observations=existing_raw_obs,
            existing_claims=[claim],
            existing_edges=old_edges,
            new_source_edges=new_source_edges,
        )
        self.assertEqual(new_scope.active_source_revision_ids, ["src-01", "src-02"])
        self.assertEqual(impact.preserved_raw_observation_count, 2)
        self.assertEqual(impact.impact_status, "material_change")
        self.assertIn(claim.claim_revision_id, impact.newly_contradicted_claim_ids)

        new_assess, new_dec = evals[claim.claim_revision_id]
        self.assertEqual(new_assess.support_status, "disputed")
        self.assertEqual(new_dec.allowed_use, "exclude")

    def test_s13_t4_event_graph_cycle_detection_clock_drift_and_reject_filename_merge(self) -> None:
        """
        S13.T4 (AI-06): Two days at the same location, drifted camera clocks, and a cycle in `before` relations
        are kept ambiguous/flagged for review instead of forcing a convenient linear chronology or merging by filename/costume.
        """
        nodes = [
            EventNode(
                event_id="ev-A",
                workday_id="wd-day1",
                source_revision_id="src-1",
                camera_session_id="cam-gopro",
                location_tag="deo_prenn_checkpoint",
                action_summary="Qua trạm kiểm soát đèo Prenn lần 1",
                start_pts_sec=100.0,
                end_pts_sec=120.0,
                clock_uncertainty_sec=300.0,
            ),
            EventNode(
                event_id="ev-B",
                workday_id="wd-day1",
                source_revision_id="src-2",
                camera_session_id="cam-iphone",
                location_tag="deo_prenn_checkpoint",
                action_summary="Dừng uống cà phê",
                start_pts_sec=250.0,
                end_pts_sec=280.0,
                clock_uncertainty_sec=300.0,
            ),
            EventNode(
                event_id="ev-C",
                workday_id="wd-day2",
                source_revision_id="src-3",
                camera_session_id="cam-gopro",
                location_tag="deo_prenn_checkpoint",
                action_summary="Quay lại trạm đèo Prenn ngày hôm sau",
                start_pts_sec=90.0,
                end_pts_sec=110.0,
                clock_uncertainty_sec=60.0,
            ),
        ]
        # Conflicting cycle: ev-A -> ev-B -> ev-C -> ev-A
        edges = [
            EventRelationEdge("r1", "ev-A", "ev-B", "before", "clock_heuristic", is_uncertain=True),
            EventRelationEdge("r2", "ev-B", "ev-C", "before", "narrative_guess", is_uncertain=True),
            EventRelationEdge("r3", "ev-C", "ev-A", "before", "raw_pts_order", is_uncertain=True),
        ]

        res = analyze_partial_order_event_graph(
            nodes=nodes,
            edges=edges,
            proposed_filename_or_costume_merges=[
                ("ev-A", "ev-C", "same_costume"),
                ("ev-A", "ev-B", "filename_order"),
            ],
        )
        self.assertTrue(res.requires_chronology_review)
        self.assertGreaterEqual(len(res.detected_before_cycles), 1)
        self.assertGreaterEqual(len(res.ambiguous_chronology_pairs), 2)
        self.assertEqual(len(res.rejected_filename_or_costume_merges), 2)


if __name__ == "__main__":
    unittest.main()
