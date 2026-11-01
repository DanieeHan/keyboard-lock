#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_ROOT/.build/tests"
mkdir -p "$TEST_DIR"
xcrun clang -Wall -Wextra -Werror \
    -I "$PROJECT_ROOT/Sources/OfflineGuard/include" \
    "$PROJECT_ROOT/Sources/OfflineGuard/OfflineGuard.c" \
    "$PROJECT_ROOT/scripts/test-offline.c" \
    -lsandbox -o "$TEST_DIR/test-offline"
"$TEST_DIR/test-offline"
