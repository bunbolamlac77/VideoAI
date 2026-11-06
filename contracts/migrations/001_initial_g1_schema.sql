-- ==============================================================================
-- 001_initial_g1_schema.sql — Canonical SQLite WAL Database Schema for Gate G1
-- Compliant with docs/05-ARCHITECTURE-AND-ROADMAP.md and docs/02-ANALYSIS-AND-DATA.md
-- ==============================================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

-- 1. Projects Table
CREATE TABLE IF NOT EXISTS projects (
    project_id TEXT PRIMARY KEY NOT NULL, -- UUID
    name TEXT NOT NULL,
    current_revision INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- 2. Workdays Table
CREATE TABLE IF NOT EXISTS workdays (
    workday_id TEXT PRIMARY KEY NOT NULL, -- UUID
    project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
    title TEXT NOT NULL,
    date TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- 3. Source Media Table
CREATE TABLE IF NOT EXISTS source_media (
    media_id TEXT PRIMARY KEY NOT NULL, -- UUID
    project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
    original_path TEXT NOT NULL,
    content_sha256 TEXT NOT NULL,
    byte_size INTEGER NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- 4. Source Revisions Table (Snapshots)
CREATE TABLE IF NOT EXISTS source_revisions (
    source_revision_id TEXT PRIMARY KEY NOT NULL, -- UUID
    media_id TEXT NOT NULL REFERENCES source_media(media_id) ON DELETE RESTRICT,
    snapshot_path TEXT NOT NULL,
    snapshot_sha256 TEXT NOT NULL,
    is_stable INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- 5. Claims Table (5 Orthogonal Axes & Append-Only Revision Immutability)
CREATE TABLE IF NOT EXISTS claims (
    revision_id TEXT PRIMARY KEY NOT NULL, -- UUID: Each revision is an immutable snapshot row
    claim_id TEXT NOT NULL, -- UUID: Logical identity shared across historical revisions
    workday_id TEXT NOT NULL REFERENCES workdays(workday_id) ON DELETE RESTRICT,
    text TEXT NOT NULL,
    origin TEXT NOT NULL CHECK(origin IN ('user', 'visual_model', 'asr', 'audio_detector', 'ocr', 'metadata', 'derived')),
    epistemic_status TEXT NOT NULL CHECK(epistemic_status IN ('observed', 'reported', 'inferred', 'unknown')),
    review_status TEXT NOT NULL CHECK(review_status IN ('unreviewed', 'auto_checked', 'needs_review', 'confirmed', 'rejected', 'superseded')),
    support_status TEXT NOT NULL CHECK(support_status IN ('supported', 'contradicted', 'insufficient', 'disputed')),
    allowed_use TEXT NOT NULL CHECK(allowed_use IN ('direct_claim', 'attributed_or_qualified', 'illustrative_only', 'exclude')),
    source_revision_id TEXT REFERENCES source_revisions(source_revision_id) ON DELETE RESTRICT,
    start_frame INTEGER,
    end_frame INTEGER,
    time_base_num INTEGER,
    time_base_den INTEGER,
    confirmation_id TEXT,
    confidence_raw REAL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- 6. Jobs Table
CREATE TABLE IF NOT EXISTS jobs (
    job_id TEXT PRIMARY KEY NOT NULL, -- UUID
    project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
    job_type TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('QUEUED', 'RUNNING', 'SUCCEEDED', 'FAILED', 'CANCELLED')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    completed_at TEXT
);

-- 7. Job Attempts Table (Fencing)
CREATE TABLE IF NOT EXISTS job_attempts (
    attempt_id TEXT PRIMARY KEY NOT NULL, -- UUID
    job_id TEXT NOT NULL REFERENCES jobs(job_id) ON DELETE CASCADE,
    fencing_token INTEGER NOT NULL,
    worker_session_id TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('PREPARED', 'RUNNING', 'SUCCEEDED', 'FAILED', 'CANCELLED')),
    started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    finished_at TEXT,
    UNIQUE(job_id, fencing_token)
);

-- 8. Artifact Publications Table (4 State Transitions)
CREATE TABLE IF NOT EXISTS artifact_publications (
    publication_id TEXT PRIMARY KEY NOT NULL, -- UUID
    project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
    job_id TEXT NOT NULL REFERENCES jobs(job_id) ON DELETE RESTRICT,
    attempt_id TEXT NOT NULL REFERENCES job_attempts(attempt_id) ON DELETE RESTRICT,
    fencing_token INTEGER NOT NULL,
    artifact_type TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('PREPARED', 'MATERIALIZED', 'VERIFIED', 'COMMITTED')),
    temp_path TEXT,
    canonical_path TEXT,
    sha256_hash TEXT,
    byte_size INTEGER,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- 9. Approvals Table
CREATE TABLE IF NOT EXISTS approvals (
    approval_id TEXT PRIMARY KEY NOT NULL, -- UUID
    project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
    approval_type TEXT NOT NULL CHECK(approval_type IN ('fact_confirmation', 'script_approval', 'preview_approval')),
    target_revision_id TEXT NOT NULL,
    is_superseded INTEGER NOT NULL DEFAULT 0,
    approved_by TEXT NOT NULL,
    approved_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- 10. Idempotency Journal Table
CREATE TABLE IF NOT EXISTS idempotency_journal (
    operation_id TEXT PRIMARY KEY NOT NULL,
    project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE RESTRICT,
    fencing_token INTEGER NOT NULL,
    result_payload TEXT NOT NULL,
    committed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Indexing for fast query & join performance
CREATE INDEX IF NOT EXISTS idx_claims_workday ON claims(workday_id);
CREATE INDEX IF NOT EXISTS idx_claims_claim_id ON claims(claim_id);
CREATE INDEX IF NOT EXISTS idx_artifact_publications_project ON artifact_publications(project_id, state);
CREATE INDEX IF NOT EXISTS idx_job_attempts_job ON job_attempts(job_id);
