#!/usr/bin/env bash
# Tự động hoá 100% Zero-Touch: ChatGPT Web (Brain) <-> Bridge <-> Git Repo VideoAI
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="/Users/phuthanh/.gemini/antigravity/scratch/chatgpt-antigravity-bridge"
REPO_URL="https://github.com/bunbolamlac77/VideoAI.git"

GOAL="${1:-Sửa lỗi các bài test và hoàn thiện mã nguồn theo checklist PROGRESS_TRACKER.md}"
TEST_CMD="${2:-python3 tools/run_python_tests.py}"

echo "=========================================================="
echo "  🚀 TỰ ĐỘNG HOÁ 100% (ZERO-TOUCH) AIVIDEO BRIDGE"
echo "  📁 Thư mục local: $PROJECT_DIR"
echo "  🔗 GitHub Remote: $REPO_URL"
echo "  🧪 Lệnh test: $TEST_CMD"
echo "=========================================================="

# 1. Tự động mở ChatGPT Web trên trình duyệt (Tampermonkey sẽ tự chạy)
echo "🌐 Đang mở trình duyệt vào https://chatgpt.com..."
open "https://chatgpt.com"
sleep 2

# 2. Khởi chạy Bridge Orchestrator (Tự động nạp task, tự nhận code, tự test, tự git commit & push)
python3 "$BRIDGE_DIR/bridge_runner.py" \
    --project-dir "$PROJECT_DIR" \
    --goal "$GOAL" \
    --test-cmd "$TEST_CMD" \
    --mode direct \
    --max-rounds 30 \
    --cooldown 12 \
    --auto-push
