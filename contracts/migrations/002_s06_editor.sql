-- S06 canonical data extensions.
-- Apply atomically under BEGIN IMMEDIATE.

CREATE TABLE IF NOT EXISTS brief_revisions (
    brief_revision_id TEXT PRIMARY KEY NOT NULL,
    workday_id TEXT NOT NULL
        REFERENCES workdays(workday_id) ON DELETE RESTRICT,
    base_workday_revision INTEGER NOT NULL
        CHECK(base_workday_revision >= 1),
    content TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (
        strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
    )
);

CREATE TABLE IF NOT EXISTS workday_active_briefs (
    workday_id TEXT PRIMARY KEY NOT NULL
        REFERENCES workdays(workday_id) ON DELETE RESTRICT,
    brief_revision_id TEXT NOT NULL
        REFERENCES brief_revisions(brief_revision_id)
        ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS extraction_proposals (
    proposal_id TEXT PRIMARY KEY NOT NULL,
    workday_id TEXT NOT NULL
        REFERENCES workdays(workday_id) ON DELETE RESTRICT,
    brief_revision_id TEXT NOT NULL
        REFERENCES brief_revisions(brief_revision_id)
        ON DELETE RESTRICT,
    proposal_text TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'proposed'
        CHECK(status IN ('proposed', 'dismissed')),
    created_at TEXT NOT NULL DEFAULT (
        strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
    )
);

CREATE TABLE IF NOT EXISTS script_revisions (
    script_revision_id TEXT PRIMARY KEY NOT NULL,
    workday_id TEXT NOT NULL
        REFERENCES workdays(workday_id) ON DELETE RESTRICT,
    brief_revision_id TEXT NOT NULL
        REFERENCES brief_revisions(brief_revision_id)
        ON DELETE RESTRICT,
    content TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (
        strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
    )
);

CREATE TABLE IF NOT EXISTS script_selections (
    selection_id TEXT PRIMARY KEY NOT NULL,
    workday_id TEXT NOT NULL
        REFERENCES workdays(workday_id) ON DELETE RESTRICT,
    script_revision_id TEXT NOT NULL
        REFERENCES script_revisions(script_revision_id)
        ON DELETE RESTRICT,
    created_at TEXT NOT NULL DEFAULT (
        strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
    )
);

CREATE TABLE IF NOT EXISTS workday_active_scripts (
    workday_id TEXT PRIMARY KEY NOT NULL
        REFERENCES workdays(workday_id) ON DELETE RESTRICT,
    selection_id TEXT NOT NULL
        REFERENCES script_selections(selection_id)
        ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_briefs_workday
    ON brief_revisions(workday_id);

CREATE INDEX IF NOT EXISTS idx_proposals_workday
    ON extraction_proposals(workday_id, brief_revision_id);

CREATE INDEX IF NOT EXISTS idx_scripts_workday
    ON script_revisions(workday_id);

CREATE INDEX IF NOT EXISTS idx_selections_workday
    ON script_selections(workday_id);
