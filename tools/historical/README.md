# Historical scripts — do not run

These scripts were one-off migrations that have already been applied to the tree. They are
kept only so the history of a change is auditable; they must not be run.

`fix_gate_integrity.py` embeds a copy of `check_readiness.check_field_corpus_and_certification`
from before the 2026-11-11 audit fixes (it still references `fixtures/corpus`, which was
renamed to `fixtures/smoke`). Running it would re-introduce two closed P0 findings, so the
file lives here rather than in `tools/`.

The regression suite (`tests/test_p2_debt.py`) treats this directory as data, not as live
code: broad-handler and import scans skip it, and a test asserts nothing under `workers/`,
`apps/` or `packages/` imports these modules.
