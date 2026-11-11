# AIVideo Agent Operating Guidelines

Full rules: [GEMINI.md](GEMINI.md). Current state: [README.md](README.md),
[audit 2026-11-11](docs/AUDIT_20261111_REVIEW_AND_TEST_PLAN.md).

## Key Directives

1. **100% local.** Never call a cloud AI API or add a cloud fallback. Models come from the pinned
   registry; `state=verified` needs the pinned weights hash, not just a size match.
2. **Swift core is the only SQLite writer.** Python and gate stores read with
   `SQLITE_OPEN_READONLY`; reads use `BEGIN DEFERRED`, writes use `BEGIN IMMEDIATE`. Never hash a
   file or run ffprobe inside a write transaction.
3. **Evidence first.** Every claim, cut and approval links to `sha256` + timecode + publication id.
   `Unknown` is a valid answer; never invent.
4. **No caller-chosen paths/identities over RPC.** `checkpoint_dir`, `models_root_dir`,
   `registry_path`, `staging_root`, `allow_overwrite`, `inspector_factory` are rejected. Roots come
   from the app environment (`AIVIDEO_APP_SUPPORT`, `AIVIDEO_RENDER_ROOT`, …).
5. **Planning files.** Keep `task_plan.md`, `findings.md`, `progress.md` current, with real command
   output — not narration. Never claim completion without a verification run.
6. **Gates G0–G5 / steps S00–S26** (`docs/11-CODING-WORKFLOW-AND-CHECKLIST.md`). G2 and S25 stay
   open until a real field corpus and a real fault run exist; `fixtures/smoke` is not evidence.
7. **Build from globbed sources.** `tools/build_macos_app.sh` and `tools/run_tests.sh` already glob
   `packages/AIVideoCore/Sources` and `apps/macos/Sources`; never reintroduce a hand-written list.
8. **SDK.** Always pass `-sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`.

## Verify before you say "done"

```bash
workers/.venv/bin/python3 tools/run_python_tests.py   # 428 run, 0 fail
./tools/run_tests.sh                                  # exit 0, 23 blocks
./tools/build_macos_app.sh                            # BUILD SUCCESSFUL
```
