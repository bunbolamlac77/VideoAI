#!/bin/bash
# ==============================================================================
# tools/package_review.sh — Script đóng gói và đồng bộ AIVideo v3.1 Review Bundle
# ==============================================================================
# Sử dụng:
#   ./tools/package_review.sh              -> Đóng gói ra AIVideo-review.zip
#   ./tools/package_review.sh --push       -> Đẩy Git lên GitHub trước, sau đó đóng gói
#   ./tools/package_review.sh [ten_file]   -> Đóng gói với tên file tùy chỉnh
# ==============================================================================

set -euo pipefail

DO_PUSH=false
OUTPUT_ZIP="AIVideo-review.zip"

for arg in "$@"; do
    case "$arg" in
        --push)
            DO_PUSH=true
            ;;
        *)
            OUTPUT_ZIP="$arg"
            ;;
    esac
done

if [ "$DO_PUSH" = true ]; then
    echo "=== [1/2] Đang đồng bộ thay đổi lên GitHub (origin main) ==="
    git add -A
    # Only commit if there are staged changes
    if ! git diff --cached --quiet; then
        COMMIT_MSG="chore: update progress reports and review bundle [$(date '+%Y-%m-%d %H:%M:%S')]"
        git commit -m "$COMMIT_MSG"
    fi
    git push origin main
    echo "=== Đã đồng bộ thành công lên GitHub ==="
fi

echo "=== [2/2] Đang khởi chạy script đóng gói AIVideo v3.1 ==="
python3 tools/package_review.py "$OUTPUT_ZIP"
