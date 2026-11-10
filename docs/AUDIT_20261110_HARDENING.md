# AIVideo safety hardening audit — 2026-11-10

Source snapshot: user-supplied `AIVideo_handoff.zip` (sha256 `b2d379869a6a1f6b65dd2c556a8d6ccf7575b593690d2a807fede6f04c8fd34f`). Archive metadata references `92762facc60fde5dd4cb8ab3749c64ffd9a4a54a`, but that is **not** proof of synchronization with GitHub HEAD.

This audit patched the S11 installer, G0 installer, `.app` install step, release preflight, strict Python JSON-RPC framing, and CI coverage; added failure-injection tests. It did **not** install model weights, build the macOS GUI app, run DaVinci Resolve Studio, or certify field-video E0/E1.

Verified in Linux audit environment: 152 Python tests PASS (3 skipped), 21 bridge tests PASS, Swift syntax parse PASS, Swift G1 contracts 5/5 PASS, bash installer syntax PASS. Readiness **NO-GO**, intentionally and truthfully. Do **not** use these Linux results to close macOS field gates.

For complete local-agent handoff and acceptance checklist, read files `01_BAO_CAO_KIEM_TOAN.md`, `02_LENH_CHO_AI_LOCAL.md`, `03_BANG_KIEM_NGHIEM_THU.md` in the audit ZIP distributed alongside this patched tree.

## Critical follow-ups

1. On macOS M1 Pro, build and launch `.app` from Finder and test Resolve Studio through full preview/final export.
2. Reinstall previously installed S11 only after backup; new `--verify` requires pinned model weights SHA256 plus a full per-artifact installation manifest.
3. Worker Python must be 3.12 (per `workers/pyproject.toml`). The environment running audit unit tests is not necessarily the worker runtime.
4. `WorkerClient.swift` stdout currently uses `AsyncStream` `.unbounded`. Design and test real backpressure without dropping frame fragments.
5. `.app` installer uses staging and rollback but full app relocation/embedded Python dependencies and Developer ID notarization remain unverified.
6. `setup_g0_model.py` still writes `contracts/g0_model.lock.json` during finalization; migrate mutable machine registry out of immutable source lock after dedicated tests.
7. After abrupt process kill during rename, inspect leftover `.aivideo-s11-backup-*`, `.g0-backup_*` and `.aivideo-install.*` before retry or cleanup. Never delete without checksum verification.
8. E0/E1 actual field corpus, model downloads, CI runner on GitHub and M1 16GB performance remain release blockers until evidence is supplied.

No automatic push or model download is initiated by this document. Commit/push/release require explicit user approval.
