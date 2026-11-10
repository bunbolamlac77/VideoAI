"""
tests/test_s15_g2_benchmark.py — Unit & Gate Evaluation Tests for S15 Gate G2 Benchmark Harness,
Anti-Leakage Split Verifier, Reject-Everything Gaming Protection, Wilson/Bootstrap Uncertainty & Gate G2 Closure.
Covers S15.T1, S15.T2, S15.T3, and S15.T4.
"""

from __future__ import annotations

import copy
from pathlib import Path
import sys
import unittest

_ROOT = Path(__file__).resolve().parents[1]
for _p in (_ROOT, _ROOT / "workers" / "src"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

from workers.src.aivideo_workers.g2_benchmark_runner import (
    FrozenG2EvaluationManifest,
    G2BenchmarkError,
    LabeledClaimOpportunity,
    build_canonical_g2_benchmark_fixture,
    run_g2_analysis_eligible_benchmark,
    run_real_video_corpus_g2_benchmark,
    verify_split_and_anti_leakage,
)
from workers.src.aivideo_workers.semantic_verifier import AtomicClaimProposal, EvidenceEdge


class TestS15G2Benchmark(unittest.TestCase):
    def test_s15_canonical_g2_benchmark_passes_all_v0_1_targets(self) -> None:
        """
        Verifies the full canonical Gate G2 benchmark suite (5 independent holdout trip groups,
        105 claim opportunities, 50 observable events, 60 adversarial verifier cases) passes all
        `acceptance-targets-v0.1` criteria and explicitly reports `NOT_RUN` for deferred G3/G5 metrics.
        """
        fix = build_canonical_g2_benchmark_fixture()
        report = run_g2_analysis_eligible_benchmark(
            manifest=fix["manifest"],
            asset_to_group_map=fix["asset_to_group_map"],
            dev_asset_ids=fix["dev_assets"],
            holdout_asset_ids=fix["holdout_assets"],
            claim_opportunities=fix["claim_opportunities"],
            observable_events=fix["observable_events"],
            verifier_adversarial_suite=fix["verifier_suite"],
            frame_coverage_by_group=fix["synthetic_coverage_by_group"],
        )

        self.assertEqual(report["g2_gate_decision"], "PASS")
        self.assertEqual(report["independent_holdout_group_count"], 5)

        prec = report["metrics"]["accepted_claim_support_precision"]
        self.assertEqual(prec["numerator"], 80)
        self.assertEqual(prec["denominator"], 80)
        self.assertEqual(prec["point_estimate"], 1.0)
        self.assertEqual(report["metrics"]["critical_false_accept_count"]["count"], 0)

        rec = report["metrics"]["important_observable_event_recall"]
        self.assertEqual(rec["numerator"], 48)
        self.assertEqual(rec["denominator"], 50)
        self.assertEqual(rec["point_estimate"], 0.96)

        vfar = report["metrics"]["verifier_false_accept_rate"]
        self.assertEqual(vfar["unsupported_denominator"], 50)
        self.assertEqual(vfar["critical_unsupported_count"], 25)
        self.assertEqual(vfar["false_accept_numerator"], 0)
        self.assertEqual(vfar["point_estimate"], 0.0)
        self.assertEqual(vfar["false_reject_rate_on_supported_controls"], 0.0)

        # Verify deferred metrics are explicitly NOT_RUN (S15.G)
        deferred = report["deferred_stage_metrics"]
        self.assertTrue(deferred["G3_script_ready_claim_precision"].startswith("NOT_RUN"))
        self.assertTrue(deferred["AI_07_exact_photo_use_precision"].startswith("NOT_RUN"))
        self.assertTrue(deferred["G5_eligible_project_completion_rate"].startswith("NOT_RUN"))

    def test_s15_t1_runner_catches_schema_valid_but_mislabeled_source_or_relation(self) -> None:
        """
        S15.T1: The runner detects a fixture that is 100% schema-valid and passes mechanical checks
        but has a mislabeled provenance/relation according to the independent ground-truth oracle,
        recording a critical false accept and failing Gate G2.
        """
        fix = build_canonical_g2_benchmark_fixture()
        corrupted_opps = list(fix["claim_opportunities"])

        # Inject a schema-valid visual claim that the model claims is supported, but the independent oracle knows is FALSE
        bad_cid = "opp-corrupted-oracle-001"
        bad_rev = f"{bad_cid}-r1"
        bad_claim = AtomicClaimProposal(
            claim_id=bad_cid,
            claim_revision_id=bad_rev,
            workday_id="wd-trip-holdout-01-dalat",
            claim_type="atomic_action",
            subject="nhân_vật_chính",
            predicate_text="Lên phà qua sông (nhưng thực tế video chỉ quay đứng nhìn bờ sông)",
            parent_compound_id=None,
            component_claim_ids=[bad_cid],
            is_critical=True,
            origin="visual_model",
            epistemic_status="observed",
            review_status="auto_checked",
        )
        bad_edge = EvidenceEdge(
            edge_id="edge-mislabeled-valid-schema",
            claim_revision_id=bad_rev,
            evidence_revision_id="obs-riverbank",
            evidence_kind="visual_observation",
            role="supports",
            covered_component_ids=[bad_cid],
            schema_and_hash_valid=True,
        )
        corrupted_opps.append(
            LabeledClaimOpportunity(
                opportunity_id=bad_cid,
                trip_group_id="trip-holdout-01-dalat",
                workday_id="wd-trip-holdout-01-dalat",
                claim=bad_claim,
                evidence_edges=[bad_edge],
                proposed_narrative_type="observed",
                oracle_is_truthfully_supported=False,  # Oracle knows the source does NOT support this!
                oracle_allowed_use_set=["exclude"],
            )
        )

        report = run_g2_analysis_eligible_benchmark(
            manifest=fix["manifest"],
            asset_to_group_map=fix["asset_to_group_map"],
            dev_asset_ids=fix["dev_assets"],
            holdout_asset_ids=fix["holdout_assets"],
            claim_opportunities=corrupted_opps,
            observable_events=fix["observable_events"],
            verifier_adversarial_suite=fix["verifier_suite"],
            frame_coverage_by_group=fix["synthetic_coverage_by_group"],
        )
        self.assertEqual(report["g2_gate_decision"], "FAIL")
        self.assertEqual(report["metrics"]["critical_false_accept_count"]["count"], 1)
        self.assertIn(bad_cid, report["metrics"]["accepted_claim_support_precision"]["false_accept_case_ids"])

    def test_s15_t2_reject_everything_harness_cannot_pass_gate_by_precision_alone(self) -> None:
        """
        S15.T2: A harness that rejects all (or almost all) claims cannot claim 100% precision or pass Gate G2;
        when 0 claims are accepted, `point_estimate` is `None` (not 1.0) and `non_trivial_claim_usage` is False.
        """
        fix = build_canonical_g2_benchmark_fixture()
        # Filter opportunities to only those that get excluded -> 0 accepted claims
        excluded_only = [opp for opp in fix["claim_opportunities"] if not opp.oracle_is_truthfully_supported]

        report = run_g2_analysis_eligible_benchmark(
            manifest=fix["manifest"],
            asset_to_group_map=fix["asset_to_group_map"],
            dev_asset_ids=fix["dev_assets"],
            holdout_asset_ids=fix["holdout_assets"],
            claim_opportunities=excluded_only,
            observable_events=fix["observable_events"],
            verifier_adversarial_suite=fix["verifier_suite"],
            frame_coverage_by_group=fix["synthetic_coverage_by_group"],
        )
        prec = report["metrics"]["accepted_claim_support_precision"]
        self.assertEqual(prec["denominator"], 0)
        self.assertIsNone(prec["point_estimate"])
        self.assertFalse(report["gate_checks"]["non_trivial_claim_usage"])
        self.assertEqual(report["g2_gate_decision"], "FAIL")

    def test_s15_t3_anti_leakage_blocks_cross_split_sibling_clips_and_holdout_prompt_examples(self) -> None:
        """
        S15.T3: Detects and blocks data leakage when:
        1. Two clips from the same trip/workday group are split across development and holdout.
        2. Prompt examples or cached summaries reference a holdout trip group.
        """
        fix = build_canonical_g2_benchmark_fixture()
        manifest: FrozenG2EvaluationManifest = fix["manifest"]

        # 1. Sibling clip from holdout group leaked into dev_asset_ids
        leaked_dev_assets = list(fix["dev_assets"]) + [fix["holdout_assets"][0]]
        with self.assertRaises(G2BenchmarkError) as ctx1:
            verify_split_and_anti_leakage(
                manifest=manifest,
                asset_to_group_map=fix["asset_to_group_map"],
                dev_asset_ids=leaked_dev_assets,
                holdout_asset_ids=fix["holdout_assets"],
            )
        self.assertEqual(ctx1.exception.code, "SIBLING_CLIP_SPLIT_LEAKAGE")

        # 2. Prompt example leaked from holdout group
        bad_manifest = dataclasses.replace(
            manifest,
            prompt_example_group_ids=["trip-dev-01", "trip-holdout-02-halong"],
        )
        with self.assertRaises(G2BenchmarkError) as ctx2:
            verify_split_and_anti_leakage(
                manifest=bad_manifest,
                asset_to_group_map=fix["asset_to_group_map"],
                dev_asset_ids=fix["dev_assets"],
                holdout_asset_ids=fix["holdout_assets"],
            )
        self.assertEqual(ctx2.exception.code, "HOLDOUT_PROMPT_LEAKAGE")

    def test_s15_real_video_corpus_holdout_benchmark_end_to_end(self) -> None:
        """
        S15.T4: Real video corpus benchmark rejects synthetic generation and requires genuine artifacts.
        """
        import tempfile
        from pathlib import Path

        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(G2BenchmarkError) as ctx:
                run_real_video_corpus_g2_benchmark(work_dir=Path(tmp))
            self.assertIn(ctx.exception.code, ("REAL_CORPUS_REQUIRED", "MODEL_NOT_INSTALLED"))

    def test_s15_real_video_corpus_passes_with_verified_held_out_clips(self) -> None:
        """
        S15 real-corpus SMOKE run: genuine 5 held-out clips are processed by the offline
        Qwen3-VL pipeline with declared 8/16 sampling. Claim/event metrics are still graded
        against the synthetic harness fixture, so the run must never report Gate G2 acceptance.
        """
        from pathlib import Path
        import os
        corpus_dir = Path(__file__).resolve().parents[1] / "fixtures" / "corpus"
        models_root = Path.home() / "Library/Application Support/AIVideo/Models"
        if os.environ.get("AIVIDEO_RUN_HEAVY_G2") != "1":
            self.skipTest("Heavy real-corpus VLM run; set AIVIDEO_RUN_HEAVY_G2=1 to execute")
        if not corpus_dir.is_dir() or not (models_root / "visual_analysis_primary" / "model.safetensors").is_file():
            self.skipTest("Real corpus or model not installed")
        report = run_real_video_corpus_g2_benchmark(corpus_dir, models_root_dir=models_root)
        self.assertEqual(report["g2_gate_decision"], "SMOKE_ONLY")
        self.assertFalse(report["real_video_corpus_verified"])
        self.assertFalse(report["acceptance_eligible"])
        self.assertEqual(report["label_source"], "synthetic_decision_harness_fixture")
        self.assertEqual(report["real_video_groups_count"], 5)
        coverage = report["metrics"]["frame_input_coverage"]["point_estimate"]
        self.assertGreater(coverage, 0.0)
        self.assertLess(coverage, 1.0)  # declared sampling is 8/16, never "full frame"
        # The synthetic decision harness itself still passes; it just is not acceptance evidence.
        self.assertTrue(report["synthetic_harness_gate_passed"])



import dataclasses

if __name__ == "__main__":
    unittest.main()
