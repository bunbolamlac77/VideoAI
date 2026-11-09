#!/usr/bin/env bash
# AIVideo launcher: API-key-free entry point for the separately installed UI bridge.
# The runner is external to this repository and must be reviewed independently.
set -euo pipefail

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BRIDGE_DIR="${AIVIDEO_BRIDGE_DIR:-$HOME/.gemini/antigravity/scratch/chatgpt-antigravity-bridge}"
RUNNER="$BRIDGE_DIR/bridge_runner.py"
PYTHON="${AIVIDEO_PYTHON:-python3}"

GOAL="${1:-Sửa lỗi các bài test và hoàn thiện mã nguồn theo checklist PROGRESS_TRACKER.md}"
TEST_CMD="${2:-python3 tools/run_python_tests.py}"
MODE="${3:-hybrid}"
MAX_ROUNDS="${AIVIDEO_MAX_ROUNDS:-30}"
COOLDOWN="${AIVIDEO_COOLDOWN:-12}"
AUTO_PUSH="${AIVIDEO_AUTO_PUSH:-0}"
OPEN_CHATGPT="${AIVIDEO_OPEN_CHATGPT:-1}"
DRY_RUN="${AIVIDEO_DRY_RUN:-0}"

case "$MODE" in
  direct|hybrid) ;;
  *) fail "Mode không hợp lệ: $MODE (chỉ chấp nhận direct hoặc hybrid)." ;;
esac

[[ "$MAX_ROUNDS" =~ ^[1-9][0-9]*$ ]] || fail 'AIVIDEO_MAX_ROUNDS phải là số nguyên dương.'
[[ "$COOLDOWN" =~ ^[0-9]+$ ]] || fail 'AIVIDEO_COOLDOWN phải là số nguyên không âm.'

for var in AUTO_PUSH OPEN_CHATGPT DRY_RUN; do
  case "${!var}" in
    0|1) ;;
    *) fail "$var chỉ chấp nhận 0 hoặc 1." ;;
  esac
done

[[ -f "$PROJECT_DIR/PROGRESS_TRACKER.md" ]] ||
  fail "Không tìm thấy PROGRESS_TRACKER.md trong $PROJECT_DIR"

[[ -f "$RUNNER" ]] ||
  fail "Thiếu runner: $RUNNER. Đặt AIVIDEO_BRIDGE_DIR về thư mục chứa bridge_runner.py; không thể tự chuyển sang Bridge v2."

command -v "$PYTHON" >/dev/null 2>&1 ||
  fail "Không tìm thấy Python: $PYTHON"

# Check actual CLI capabilities before attempting execution.
if ! RUNNER_HELP="$("$PYTHON" "$RUNNER" --help 2>&1)"; then
  fail "Không đọc được --help từ $RUNNER. Hãy kiểm tra runner độc lập trước khi chạy."
fi

for option in --project-dir --goal --test-cmd --mode --max-rounds --cooldown; do
  grep -Fq -- "$option" <<< "$RUNNER_HELP" ||
    fail "Runner thiếu tham số $option"
done

if [[ "$MODE" == hybrid ]]; then
  grep -Eq '(^|[^[:alnum:]_])hybrid([^[:alnum:]_]|$)' <<< "$RUNNER_HELP" ||
    fail "Runner chưa công bố hỗ trợ hybrid; không tự động fallback sang direct."
fi

if [[ "$AUTO_PUSH" == 1 ]]; then
  grep -Fq -- '--auto-push' <<< "$RUNNER_HELP" ||
    fail 'Runner không hỗ trợ --auto-push.'
fi

CMD=("$PYTHON" "$RUNNER"
  --project-dir "$PROJECT_DIR"
  --goal "$GOAL"
  --test-cmd "$TEST_CMD"
  --mode "$MODE"
  --max-rounds "$MAX_ROUNDS"
  --cooldown "$COOLDOWN")

if [[ "$AUTO_PUSH" == 1 ]]; then
  CMD+=(--auto-push)
fi

printf 'AIVideo Bridge | mode=%s | rounds=%s | auto-push=%s\n' \
  "$MODE" "$MAX_ROUNDS" "$AUTO_PUSH"
printf 'Project: %s\nRunner: %s\n' "$PROJECT_DIR" "$RUNNER"

if [[ "$DRY_RUN" == 1 ]]; then
  printf 'DRY_RUN command: '
  printf '%q ' "${CMD[@]}"
  printf '\n'
  exit 0
fi

# Browser launch does not itself establish a ChatGPT control channel.
if [[ "$MODE" == hybrid && "$OPEN_CHATGPT" == 1 ]]; then
  command -v open >/dev/null 2>&1 ||
    fail 'Thiếu lệnh macOS open; đặt AIVIDEO_OPEN_CHATGPT=0 nếu đã mở trình duyệt.'

  open 'https://chatgpt.com' ||
    fail 'Không mở được ChatGPT Web.'
fi

cd "$PROJECT_DIR"
exec "${CMD[@]}"
