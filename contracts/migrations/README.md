# Schema: one source of truth

**Swift is the only writer and the only schema owner.** `ProjectStore` (and its G3/G4/G5
extensions) create the runtime schema and stamp `PRAGMA user_version`; additive columns are
applied in place by `ProjectStore.migrateAdditiveColumns` when an older database is opened.

This directory does **not** contain runtime migrations. It holds:

- `fixtures/g1_schema_fixture.sql` — a plain-SQL copy of the ten G1 tables, used by
  `tests/test_g1_contracts.py` to prove the same DDL works on a real WAL database opened by a
  another process. It is a *test fixture*; no production code reads it.

Rules:

1. Never open a second writer. Python and shell scripts read SQLite read-only at most.
2. A schema change is a change to the Swift DDL plus (when needed) an entry in
   `ProjectStore.additiveColumns`, and it must bump `ProjectStore.canonicalSchemaVersion`.
3. When the fixture stops reflecting the tables it claims to cover, update it in the same
   commit — `tests/test_p2_debt.py` checks that every fixture table exists in the runtime
   schema and that no production module imports this directory.
