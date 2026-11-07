#!/usr/bin/env bash
set -u

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || exit 2

if [ -z "${GH_TOKEN:-}" ]; then
  _token="$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null | grep '^password=' | cut -d= -f2- || true)"
  if [ -n "$_token" ]; then
    export GH_TOKEN="$_token"
  fi
fi

sha="$(git rev-parse HEAD)"
logs="build/reports/s06-gate-${sha:0:12}"
mkdir -p "$logs"
failed=0

pass() {
  printf 'PASS  %s\n' "$1"
}

block() {
  printf 'BLOCK %s\n' "$1"
  failed=1
}

require_file() {
  if [ -f "$1" ]; then
    pass "$1"
  else
    block "Missing $1"
  fi
}

run_test() {
  local label="$1" logfile="$2"
  shift 2

  if "$@" > "$logs/$logfile" 2>&1; then
    pass "$label (log: $logs/$logfile)"
  else
    block "$label (log: $logs/$logfile)"
    tail -n 25 "$logs/$logfile"
  fi
}

printf 'S06 GATE AUDIT - %s\n' "$sha"

# 1. Verify source files
require_file \
  'packages/AIVideoCore/Sources/ProjectStore/ProjectStore.swift'
require_file \
  'packages/AIVideoCore/Sources/ProjectStore/SQLiteStoreDatabase.swift'
require_file \
  'packages/AIVideoCore/Sources/ProjectStore/ProjectStoreModels.swift'
require_file \
  'packages/AIVideoCore/Sources/ProjectStore/ProjectStoreRegistry.swift'
require_file \
  'packages/AIVideoCore/Sources/ProjectStore/SourceStoreBridge.swift'
require_file 'contracts/migrations/002_s06_editor.sql'
require_file 'tools/run_s06_tests.sh'
require_file 'tests/test_s06_project_store.swift'

# 2. Verify target platform
if [ "$(uname -s)" = Darwin ] &&
   [ "$(uname -m)" = arm64 ]; then
  pass 'macOS Apple Silicon host'
else
  block 'Must validate on macOS Apple Silicon'
fi

# 3. Check Git state
if git diff --check > "$logs/git-diff-check.log" 2>&1; then
  pass 'git diff --check'
else
  block 'git diff --check'
fi

if [ -z "$(git status --porcelain)" ]; then
  pass 'clean working tree'
else
  block 'Working tree differs from commit'
  git status --short
fi

# 4. Run S06 tests
if [ -f tools/run_s06_tests.sh ]; then
  run_test 'S06 SQLite tests' \
    s06.log bash tools/run_s06_tests.sh
fi

# 5. Regression G0-S05
if [ -f tools/run_tests.sh ]; then
  run_test 'G0-S05 regression' \
    regressions.log bash tools/run_tests.sh
fi

# 6. Build macOS app
if [ -f tools/build_macos_app.sh ]; then
  run_test 'macOS app build' \
    app-build.log bash tools/build_macos_app.sh

  if find . -type f \
    -path '*/AIVideo.app/Contents/Resources/contracts/migrations/002_s06_editor.sql' \
    -print -quit | grep -q .; then
    pass 'S06 migration bundled in .app'
  else
    block 'S06 migration missing from built .app'
  fi
else
  block 'tools/build_macos_app.sh missing'
fi

# 7. Verify GitHub CI on the exact commit
if command -v gh >/dev/null 2>&1; then
  if runs="$(gh run list \
      --repo bunbolamlac77/VideoAI \
      --commit "$sha" \
      --limit 30 \
      --json headSha,status,conclusion \
      2>"$logs/gh-error.log")"; then

    if RUNS_JSON="$runs" TARGET_SHA="$sha" python3 - <<'PY'
import json
import os
import sys

runs = json.loads(os.environ["RUNS_JSON"])
target = os.environ["TARGET_SHA"]

matching = [
    r for r in runs
    if r.get("headSha") == target
]

valid = bool(matching) and all(
    r.get("status") == "completed"
    and r.get("conclusion") == "success"
    for r in matching
)

print(f"CI runs for this commit: {len(matching)}")

for run in matching:
    print(
        run.get("status"),
        run.get("conclusion")
    )

sys.exit(0 if valid else 1)
PY
    then
      pass 'GitHub Actions SUCCESS for exact commit'
    else
      block 'GitHub Actions not green for exact commit'
    fi
  else
    block 'Cannot retrieve GitHub Actions'
    cat "$logs/gh-error.log"
  fi
else
  block 'gh CLI missing; CI not verified'
fi

# Final result
if [ "$failed" -eq 0 ]; then
  printf '\nS06 GATE: PASS - ready for S07\n'
else
  printf '\nS06 GATE: BLOCKED\n'
  printf 'Inspect logs: %s\n' "$logs"
fi

exit "$failed"
