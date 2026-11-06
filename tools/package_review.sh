#!/bin/bash
set -euo pipefail

# tools/package_review.sh — Script đóng gói dự án thành AIVideo-review.zip
# Sử dụng: ./tools/package_review.sh [ten_file_zip]

OUTPUT_ZIP="${1:-AIVideo-review.zip}"

echo "Đang khởi chạy script đóng gói AIVideo v3.1..."
python3 tools/package_review.py "$OUTPUT_ZIP"
