#!/usr/bin/env bash
# ==============================================================================
# tools/setup_git_hooks.sh — Install git hooks for AIVideo development
# ==============================================================================
set -euo pipefail

HOOK_DIR=".git/hooks"
mkdir -p "$HOOK_DIR"

if [ -f "tools/git_hooks/pre-commit" ]; then
    cp "tools/git_hooks/pre-commit" "$HOOK_DIR/pre-commit"
    chmod +x "$HOOK_DIR/pre-commit"
    echo "✅ Đã cài đặt pre-commit hook an toàn thành công!"
fi
