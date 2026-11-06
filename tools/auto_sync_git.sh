#!/usr/bin/env bash
# ==============================================================================
# tools/auto_sync_git.sh — Automated Verification, Review Packaging & Git Push
# ==============================================================================
# Usage:
#   ./tools/auto_sync_git.sh                  # Uses auto-generated commit message
#   ./tools/auto_sync_git.sh "feat: my message" # Uses custom commit message
#   ./tools/auto_sync_git.sh --skip-tests    # Skips test run before pushing
# ==============================================================================

set -euo pipefail

COMMIT_MSG="${1:-}"
SKIP_TESTS=false

if [ "$COMMIT_MSG" = "--skip-tests" ]; then
    SKIP_TESTS=true
    COMMIT_MSG="${2:-}"
fi

echo "======================================================="
echo "AIVIDEO v3.1 — AUTOMATED GIT SYNCHRONIZATION WORKFLOW"
echo "======================================================="

# 1. Verify working directory
if [ ! -d ".git" ]; then
    echo "❌ Lỗi: Thư mục hiện tại không phải là git repository." >&2
    exit 1
fi

# 2. Check for uncommitted changes
STATUS_OUTPUT="$(git status --porcelain)"
if [ -z "$STATUS_OUTPUT" ]; then
    echo "ℹ️ Working tree sạch sẽ. Không có thay đổi nào cần commit."
    
    # Check if local is ahead of remote
    LOCAL_REV="$(git rev-parse HEAD)"
    REMOTE_REV="$(git rev-parse origin/main 2>/dev/null || true)"
    if [ "$LOCAL_REV" = "$REMOTE_REV" ]; then
        echo "✅ Mã nguồn local đã đồng bộ hoàn toàn với GitHub (origin/main)."
        exit 0
    else
        echo "Đang đẩy các commit local chưa push lên remote..."
        git push origin main
        echo "✅ Đã đồng bộ lên remote thành công!"
        exit 0
    fi
fi

echo "Phát hiện các file thay đổi / mới:"
git status -s

# 3. Run regression tests unless skipped
if [ "$SKIP_TESTS" = false ]; then
    echo ""
    echo "=== [1/3] Đang chạy kiểm thử hồi quy trước khi commit ==="
    if [ -x "tools/run_tests.sh" ]; then
        ./tools/run_tests.sh
    fi
else
    echo "ℹ️ Bỏ qua bước kiểm thử theo yêu cầu (--skip-tests)."
fi

# 4. Generate Review Package & Summary
echo ""
echo "=== [2/3] Cập nhật gói thẩm định REVIEW_SUMMARY.md & AIVideo-review.zip ==="
if [ -f "tools/package_review.py" ]; then
    python3 tools/package_review.py
fi

# 5. Safety check: Block large files or secrets
echo ""
echo "=== [3/3] Kiểm tra an toàn & Đẩy lên GitHub ==="

# Check staged candidate sizes (protect against accidentally staging large weights > 10MB)
LARGE_FILES="$(git status --porcelain | awk '{print $2}' | while read -r f; do
    if [ -f "$f" ]; then
        SZ="$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)"
        if [ "$SZ" -gt 10485760 ]; then
            echo "$f ($((SZ / 1024 / 1024)) MB)"
        fi
    fi
done)"

if [ -n "$LARGE_FILES" ]; then
    echo "❌ CẢNH BÁO AN TOÀN: Phát hiện file vượt quá 10 MB:"
    echo "$LARGE_FILES"
    echo "Vui lòng kiểm tra lại .gitignore trước khi commit." >&2
    exit 1
fi

# Check for accidental secret files
SECRET_FILES="$(git status --porcelain | awk '{print $2}' | grep -E '\.(env|key|pem|secret|token)$' || true)"
if [ -n "$SECRET_FILES" ]; then
    echo "❌ CẢNH BÁO AN TOÀN: Phát hiện file chứa bí mật tiềm ẩn:"
    echo "$SECRET_FILES" >&2
    exit 1
fi

# Stage files
git add -A

# Determine commit message
if [ -z "$COMMIT_MSG" ]; then
    TS="$(date '+%Y-%m-%d %H:%M:%S')"
    COMMIT_MSG="chore(sync): automated update and review bundle refresh ($TS)"
fi

git commit -m "$COMMIT_MSG"

# Push to origin main
echo ""
echo "Đang đẩy commit lên GitHub (origin/main)..."
git push origin main

NEW_COMMIT="$(git rev-parse --short HEAD)"
REMOTE_URL="$(git remote get-url origin)"

echo ""
echo "======================================================="
echo "✅ ĐÃ ĐỒNG BỘ THÀNH CÔNG LÊN GIT!"
echo "   Commit: $NEW_COMMIT"
echo "   Message: \"$COMMIT_MSG\""
echo "   Remote: $REMOTE_URL"
echo "======================================================="
