#!/usr/bin/env python3
"""
tests/test_g1_contracts.py — Verification for S04 Data Contracts & State Machines
Tests:
- S04.T1: Schema and Enum consistency between Swift and Python with bi-directional golden tests
- S04.T2: Invariant: user_confirmed does NOT morph into observed/visual_model
- S04.T3: SQLite WAL Schema migration validity, revision immutability, and foreign key constraints on disk
- S04.T4: RPC Envelope strictness: reject bare {"jsonrpc": "2.0"} or envelopes lacking method/result/error
- State machine transition barriers for Artifact Publication and Jobs
"""

import os
import re
import sys
import json
import sqlite3
import tempfile
import unittest
from jsonschema import Draft202012Validator, FormatChecker

sys.path.insert(0, os.path.abspath("workers/src"))
from aivideo_workers.contracts import (
    Origin,
    EpistemicStatus,
    ReviewStatus,
    SupportStatus,
    AllowedUse,
    ArtifactPublicationState,
    JobStatus,
    TimeRange,
    ClaimRecord,
    ArtifactPublicationRecord,
    ContractError
)

UUID_PATTERN = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
ISO8601_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$")

def validate_rpc_envelope_dict(
    envelope: dict, schema: dict
) -> bool:
    """Validate against the actual JSON Schema 2020-12."""
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(
        schema, format_checker=FormatChecker()
    )
    return validator.is_valid(envelope)

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
        confirmed = claim.confirm_user_fact(
            confirmation_id="55555555-5555-4555-8555-555555555555"
        )
        self.assertEqual(confirmed.origin, Origin.USER, "Origin MUST NOT change to visual_model or derived")
        self.assertEqual(confirmed.epistemic_status, EpistemicStatus.REPORTED, "Epistemic MUST NOT become observed")
        self.assertEqual(confirmed.review_status, ReviewStatus.CONFIRMED)
        self.assertNotEqual(confirmed.revision_id, claim.revision_id, "Revision ID must increment on confirmation")
        self.assertEqual(confirmed.confirmation_id, "55555555-5555-4555-8555-555555555555")

    def test_invalid_confirmation_uuid_rejected(self):
        claim = ClaimRecord(
            workday_id="00000000-0000-4000-8000-000000000001",
            text="A verified user statement",
            origin=Origin.USER,
            epistemic_status=EpistemicStatus.REPORTED
        )
        with self.assertRaises(ContractError):
            claim.confirm_user_fact(
                confirmation_id="conf-123"
            )
        with self.assertRaises(ContractError):
            claim.confirm_user_fact(
                confirmation_id=""
            )
        confirmed = claim.confirm_user_fact()
        self.assertIsNotNone(confirmed.confirmation_id)
        self.assertEqual(
            confirmed.origin, Origin.USER
        )

    def test_claim_from_dict_rejects_invalid_uuid(self):
        claim = ClaimRecord(
            workday_id="00000000-0000-4000-8000-000000000001",
            text="Valid claim",
            origin=Origin.USER,
            epistemic_status=EpistemicStatus.REPORTED
        )
        data = claim.to_dict()
        data["confirmation_id"] = "invalid-uuid"
        with self.assertRaises(ContractError):
            ClaimRecord.from_dict(data)

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
        """Invariant S04.T3: Real SQLite WAL on disk file with multiple revisions per claim_id and FK enforcement."""
        schema_path = os.path.abspath("contracts/migrations/fixtures/g1_schema_fixture.sql")
        self.assertTrue(os.path.isfile(schema_path), "Migration script must exist")

        with open(schema_path, "r", encoding="utf-8") as f:
            ddl_sql = f.read()

        with tempfile.TemporaryDirectory() as tmpdir:
            db_path = os.path.join(tmpdir, "test_g1_wal_store.db")
            conn = sqlite3.connect(db_path)
            try:
                conn.executescript(ddl_sql)
                cur = conn.cursor()

                # 1. Verify WAL journal mode on real disk file
                cur.execute("PRAGMA journal_mode;")
                journal_mode = cur.fetchone()[0]
                self.assertEqual(journal_mode.lower(), "wal", f"Journal mode must be WAL on disk file, got {journal_mode}")

                # 2. Verify all 10 expected tables
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

                # 3. Verify Foreign Keys are active
                cur.execute("PRAGMA foreign_keys;")
                fk_active = cur.fetchone()[0]
                self.assertEqual(fk_active, 1, "PRAGMA foreign_keys must be active")

                # 4. Insert Project and Workday
                proj_id = "00000000-0000-4000-8000-000000000001"
                workday_id = "00000000-0000-4000-8000-000000000002"
                cur.execute("INSERT INTO projects (project_id, name) VALUES (?, ?);", (proj_id, "AIVideo WAL Test"))
                cur.execute("INSERT INTO workdays (workday_id, project_id, title, date) VALUES (?, ?, ?, ?);",
                            (workday_id, proj_id, "Ngay lam viec 1", "2026-11-06"))

                # 5. Requirement 2: Multiple revisions for the same logical claim_id
                claim_id = "00000000-0000-4000-8000-000000000010"
                rev1_id = "00000000-0000-4000-8000-000000000011"
                rev2_id = "00000000-0000-4000-8000-000000000012"

                cur.execute("""
                    INSERT INTO claims (
                        revision_id, claim_id, workday_id, text, origin, epistemic_status,
                        review_status, support_status, allowed_use
                    ) VALUES (?, ?, ?, ?, 'user', 'reported', 'unreviewed', 'insufficient', 'exclude');
                """, (rev1_id, claim_id, workday_id, "Ban ghi ban dau (Revision 1)"))

                cur.execute("""
                    INSERT INTO claims (
                        revision_id, claim_id, workday_id, text, origin, epistemic_status,
                        review_status, support_status, allowed_use, confirmation_id
                    ) VALUES (?, ?, ?, ?, 'user', 'reported', 'confirmed', 'supported', 'direct_claim', ?);
                """, (rev2_id, claim_id, workday_id, "Ban ghi da xac nhan (Revision 2)", "55555555-5555-4555-8555-555555555555"))
                conn.commit()

                # Query both revisions under the same claim_id
                cur.execute("SELECT revision_id, text, review_status FROM claims WHERE claim_id = ? ORDER BY revision_id ASC;", (claim_id,))
                rows = cur.fetchall()
                self.assertEqual(len(rows), 2, "Both revisions of same logical claim_id must exist in SQLite")
                self.assertEqual(rows[0][0], rev1_id)
                self.assertEqual(rows[0][1], "Ban ghi ban dau (Revision 1)")
                self.assertEqual(rows[0][2], "unreviewed")
                self.assertEqual(rows[1][0], rev2_id)
                self.assertEqual(rows[1][1], "Ban ghi da xac nhan (Revision 2)")
                self.assertEqual(rows[1][2], "confirmed")

                # 6. Verify Foreign Key constraint violation is rejected
                with self.assertRaises(sqlite3.IntegrityError):
                    cur.execute("""
                        INSERT INTO claims (
                            revision_id, claim_id, workday_id, text, origin, epistemic_status,
                            review_status, support_status, allowed_use
                        ) VALUES ('rev-bad', 'claim-bad', 'non-existent-workday', 'Text', 'user', 'reported', 'unreviewed', 'insufficient', 'exclude');
                    """)

                # 7. Verify Check constraints on origin and review_status
                with self.assertRaises(sqlite3.IntegrityError):
                    cur.execute("""
                        INSERT INTO claims (
                            revision_id, claim_id, workday_id, text, origin, epistemic_status,
                            review_status, support_status, allowed_use
                        ) VALUES ('rev-bad-enum', 'claim-bad-enum', ?, 'Text', 'invalid_origin', 'reported', 'unreviewed', 'insufficient', 'exclude');
                    """, (workday_id,))

            finally:
                conn.close()

    def test_rpc_envelope_schema_strictness(self):
        """Invariant S04.T4: Reject bare {"jsonrpc": "2.0"} or message lacking method/result/error."""
        schema_path = os.path.abspath("contracts/schemas/rpc_envelope_schema.json")
        self.assertTrue(os.path.isfile(schema_path), "RPC Schema must exist")
        with open(schema_path, "r", encoding="utf-8") as f:
            schema = json.load(f)

        # 1. Bare {"jsonrpc": "2.0"} MUST BE REJECTED
        bare_envelope = {"jsonrpc": "2.0"}
        self.assertFalse(validate_rpc_envelope_dict(bare_envelope, schema), "Bare jsonrpc message MUST be rejected")

        # 2. {"jsonrpc": "2.0", "id": 123} without method/result/error MUST BE REJECTED
        id_only_envelope = {"jsonrpc": "2.0", "id": 123}
        self.assertFalse(validate_rpc_envelope_dict(id_only_envelope, schema), "Envelope with only id MUST be rejected")

        # 3. {"jsonrpc": "2.0", "result": "ok"} without id MUST BE REJECTED
        result_no_id = {"jsonrpc": "2.0", "result": "ok"}
        self.assertFalse(validate_rpc_envelope_dict(result_no_id, schema), "Result without id MUST be rejected")

        # 4. Valid Request MUST PASS
        valid_request = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"client_name": "AIVideoCore"}}
        self.assertTrue(validate_rpc_envelope_dict(valid_request, schema))

        # 5. Valid Notification MUST PASS
        valid_notification = {"jsonrpc": "2.0", "method": "shutdown"}
        self.assertTrue(validate_rpc_envelope_dict(valid_notification, schema))

        # 6. Valid Success Response MUST PASS
        valid_response = {"jsonrpc": "2.0", "id": 1, "result": {"status": "ok"}}
        self.assertTrue(validate_rpc_envelope_dict(valid_response, schema))

        # 7. Valid Error Response MUST PASS
        valid_err_response = {"jsonrpc": "2.0", "id": 1, "error": {"code": -32600, "message": "Invalid Request"}}
        self.assertTrue(validate_rpc_envelope_dict(valid_err_response, schema))

        # Invalid JSON-RPC version
        self.assertFalse(validate_rpc_envelope_dict(
            {"jsonrpc": "1.0", "id": 1, "method": "ping"},
            schema
        ))
        # Invalid session UUID
        self.assertFalse(validate_rpc_envelope_dict(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "result": {},
                "session_id": "invalid-uuid"
            },
            schema
        ))
        # Request must not also contain a result
        self.assertFalse(validate_rpc_envelope_dict(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "ping",
                "result": {}
            },
            schema
        ))
        # Extra properties are forbidden
        self.assertFalse(validate_rpc_envelope_dict(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "result": {},
                "unexpected_field": True
            },
            schema
        ))

    def test_bidirectional_golden_contracts(self):
        """Invariant S04.T1: Bi-directional Golden Tests Swift <-> Python with snake_case and ISO-8601 formatting."""
        fixtures_dir = os.path.abspath("contracts/fixtures")
        py_claim_file = os.path.join(fixtures_dir, "golden_claim_python.json")
        py_artifact_file = os.path.join(fixtures_dir, "golden_artifact_python.json")
        swift_claim_file = os.path.join(fixtures_dir, "golden_claim_swift.json")
        swift_artifact_file = os.path.join(fixtures_dir, "golden_artifact_swift.json")

        self.assertTrue(os.path.isfile(py_claim_file), "Python claim golden fixture must exist")
        self.assertTrue(os.path.isfile(py_artifact_file), "Python artifact golden fixture must exist")
        self.assertTrue(os.path.isfile(swift_claim_file), "Swift claim golden fixture must exist")
        self.assertTrue(os.path.isfile(swift_artifact_file), "Swift artifact golden fixture must exist")

        # 1. Read & Validate Python Claim Golden
        with open(py_claim_file, "r", encoding="utf-8") as f:
            py_claim_data = json.load(f)
        for key in py_claim_data.keys():
            self.assertTrue(key.islower() and "_" in key or key in ["text", "origin"], f"Python Claim key '{key}' must be snake_case")
        self.assertTrue(UUID_PATTERN.match(py_claim_data["claim_id"]))
        self.assertTrue(ISO8601_PATTERN.match(py_claim_data["created_at"]))

        claim_py = ClaimRecord.from_dict(py_claim_data)
        self.assertEqual(claim_py.origin, Origin.VISUAL_MODEL)
        self.assertEqual(claim_py.epistemic_status, EpistemicStatus.INFERRED)
        self.assertEqual(claim_py.review_status, ReviewStatus.UNREVIEWED)
        self.assertEqual(claim_py.time_range.start_frame, 100)
        self.assertEqual(claim_py.time_range.end_frame, 240)

        # 2. Read & Validate Swift Claim Golden into Python
        with open(swift_claim_file, "r", encoding="utf-8") as f:
            swift_claim_data = json.load(f)
        for key in swift_claim_data.keys():
            self.assertTrue(key.islower() and "_" in key or key in ["text", "origin"], f"Swift Claim key '{key}' must be snake_case")
        self.assertTrue(UUID_PATTERN.match(swift_claim_data["claim_id"]))
        self.assertTrue(ISO8601_PATTERN.match(swift_claim_data["created_at"]))

        claim_from_swift = ClaimRecord.from_dict(swift_claim_data)
        self.assertEqual(claim_from_swift.origin, Origin.USER)
        self.assertEqual(claim_from_swift.epistemic_status, EpistemicStatus.REPORTED)
        self.assertEqual(claim_from_swift.review_status, ReviewStatus.CONFIRMED)
        self.assertEqual(claim_from_swift.allowed_use, AllowedUse.ATTRIBUTED_OR_QUALIFIED)
        self.assertEqual(claim_from_swift.time_range.start_frame, 240)
        self.assertEqual(claim_from_swift.time_range.end_frame, 480)
        self.assertEqual(claim_from_swift.confirmation_id, "22222222-2222-4222-8222-222222222222")

        # 3. Read & Validate Python Artifact Golden
        with open(py_artifact_file, "r", encoding="utf-8") as f:
            py_art_data = json.load(f)
        for key in py_art_data.keys():
            self.assertTrue(key.islower() and "_" in key or key == "state", f"Python Artifact key '{key}' must be snake_case")
        self.assertTrue(UUID_PATTERN.match(py_art_data["publication_id"]))
        self.assertTrue(ISO8601_PATTERN.match(py_art_data["created_at"]))
        self.assertTrue(ISO8601_PATTERN.match(py_art_data["updated_at"]))

        art_py = ArtifactPublicationRecord.from_dict(py_art_data)
        self.assertEqual(art_py.state, ArtifactPublicationState.COMMITTED)
        self.assertEqual(art_py.fencing_token, 1)
        self.assertEqual(art_py.sha256_hash, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")

        # 4. Read & Validate Swift Artifact Golden into Python
        with open(swift_artifact_file, "r", encoding="utf-8") as f:
            swift_art_data = json.load(f)
        for key in swift_art_data.keys():
            self.assertTrue(key.islower() and "_" in key or key == "state", f"Swift Artifact key '{key}' must be snake_case")
        self.assertTrue(UUID_PATTERN.match(swift_art_data["publication_id"]))
        self.assertTrue(ISO8601_PATTERN.match(swift_art_data["created_at"]))
        self.assertTrue(ISO8601_PATTERN.match(swift_art_data["updated_at"]))

        art_from_swift = ArtifactPublicationRecord.from_dict(swift_art_data)
        self.assertEqual(art_from_swift.state, ArtifactPublicationState.COMMITTED)
        self.assertEqual(art_from_swift.fencing_token, 2)
        self.assertEqual(art_from_swift.artifact_type, "preview_render")
        self.assertEqual(art_from_swift.byte_size, 2097152)

if __name__ == "__main__":
    unittest.main()
