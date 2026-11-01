#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/keyboard-lock-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -swift-version 5 -O \
    "$PROJECT_ROOT/Sources/KeyboardLock/LockPolicy.swift" \
    "$PROJECT_ROOT/Tests/LockPolicyTests.swift" -o "$TEST_DIR/PolicyTests"
"$TEST_DIR/PolicyTests"
xcrun swiftc -swift-version 5 -O \
    "$PROJECT_ROOT/Sources/KeyboardLock/PermissionPolicy.swift" \
    "$PROJECT_ROOT/Tests/PermissionPolicyTests.swift" -o "$TEST_DIR/PermissionTests"
"$TEST_DIR/PermissionTests"
"$PROJECT_ROOT/scripts/test-offline.sh"
