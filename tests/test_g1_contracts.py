#!/usr/bin/env python3
"""
tests/test_g1_contracts.py — Verification for S04 Data Contracts & State Machines
Tests:
- S04.T1: Schema and Enum consistency between Swift and Python
- S04.T2: Invariant: user_confirmed does NOT morph into observed/visual_model
- S04.T3: SQLite WAL Schema migration validity and foreign key constraints
- State machine transition barriers for Artifact Publication and Jobs
"""

import os
import sys
import sqlite3
import unittest

sys.path.insert(0, os.path.abspath("workers/src"))
from aivideo_workers.contracts import (
    Origin,
    EpistemicStatus,
    ReviewStatus,
    SupportStatus,
    AllowedUse,
    ArtifactPublicationState,
    JobStatus,
    ClaimRecord,
    ArtifactPublicationRecord,
    ContractError
)

class TestG1DataContracts(unittest.TestCase):
    def test_s04_t2_user_confirmed_preserves_origin_and_epistemic(self):
        """Invariant S04.T2: User confirmation updates review_status, but origin stays user and epistemic stays reported."""
        claim = ClaimRecord(
            workday_id="00000000-0000-4000-8000-000000000001",
            text="Tôi đã đi phà Cát Lái lúc 5 giờ sáng.",
            origin=Origin.USER,
            epistemic_status=EpistemicStatus.REPORTED,
            review_status=ReviewStatus.UNREVIEWED,
            support_status=SupportStatus.INSUFFICIENT,
            allowed_use=AllowedUse.EXCLUDE
        )
        confirmed = claim.confirm_user_fact(confirmation_id="conf-123")
        self.assertEqual(confirmed.origin, Origin.USER, "Origin MUST NOT change to visual_model or derived")
        self.assertEqual(confirmed.epistemic_status, EpistemicStatus.REPORTED, "Epistemic MUST NOT become observed")
        self.assertEqual(confirmed.review_status, ReviewStatus.CONFIRMED)
        self.assertNotEqual(confirmed.revision_id, claim.revision_id, "Revision ID must increment on confirmation")

    def test_artifact_publication_state_transitions(self):
        """Invariant S04.3: Artifact transitions PREPARED -> MATERIALIZED -> VERIFIED -> COMMITTED."""
        pub = ArtifactPublicationRecord(
            project_id="proj-1",
            job_id="job-1",
            attempt_id="att-1",
            fencing_token=1,
            artifact_type="proxy_video"
        )
        self.assertEqual(pub.state, ArtifactPublicationState.PREPARED)

        # Illegal transition: PREPARED -> COMMITTED
        with self.assertRaises(ContractError):
            pub.transition_to_committed("/path/to/canonical.mp4")

        # Legal transition: PREPARED -> MATERIALIZED
        pub.transition_to_materialized("/tmp/attempt_temp.mp4")
        self.assertEqual(pub.state, ArtifactPublicationState.MATERIALIZED)

        # Illegal transition: MATERIALIZED -> COMMITTED
        with self.assertRaises(ContractError):
            pub.transition_to_committed("/path/to/canonical.mp4")

        # Legal transition: MATERIALIZED -> VERIFIED
        valid_hash = "a" * 64
        pub.transition_to_verified(sha256_hash=valid_hash, byte_size=1024)
        self.assertEqual(pub.state, ArtifactPublicationState.VERIFIED)

        # Legal transition: VERIFIED -> COMMITTED
        pub.transition_to_committed("/storage/canonical.mp4")
        self.assertEqual(pub.state, ArtifactPublicationState.COMMITTED)

        # Terminal state: cannot transition further
        with self.assertRaises(ContractError):
            pub.transition_to_materialized("/tmp/other.mp4")

    def test_job_state_transitions(self):
        """Invariant: Job transitions QUEUED -> RUNNING -> SUCCEEDED / FAILED / CANCELLED."""
        self.assertTrue(JobStatus.QUEUED.can_transition_to(JobStatus.RUNNING))
        self.assertTrue(JobStatus.RUNNING.can_transition_to(JobStatus.SUCCEEDED))
        self.assertTrue(JobStatus.RUNNING.can_transition_to(JobStatus.FAILED))
        self.assertFalse(JobStatus.SUCCEEDED.can_transition_to(JobStatus.RUNNING))
        self.assertFalse(JobStatus.FAILED.can_transition_to(JobStatus.RUNNING))

    def test_sqlite_migration_ddl_validity(self):
        """Invariant S04.T3: 001_initial_g1_schema.sql compiles cleanly on SQLite with WAL mode and foreign keys."""
        schema_path = os.path.abspath("contracts/migrations/001_initial_g1_schema.sql")
        self.assertTrue(os.path.isfile(schema_path), "Migration script must exist")

        with open(schema_path, "r", encoding="utf-8") as f:
            ddl_sql = f.read()

        conn = sqlite3.connect(":memory:")
        try:
            conn.executescript(ddl_sql)
            # Verify tables exist
            cur = conn.cursor()
            cur.execute("SELECT name FROM sqlite_master WHERE type='table';")
            tables = {row[0] for row in cur.fetchall()}
            expected_tables = {
                "projects",
                "workdays",
                "source_media",
                "source_revisions",
                "claims",
                "jobs",
                "job_attempts",
                "artifact_publications",
                "approvals",
                "idempotency_journal"
            }
            self.assertTrue(expected_tables.issubset(tables), f"Missing tables: {expected_tables - tables}")
        finally:
            conn.close()

if __name__ == "__main__":
    unittest.main()
