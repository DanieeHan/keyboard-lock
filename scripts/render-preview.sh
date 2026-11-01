#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREVIEW_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/keyboard-lock-render.XXXXXX")"
trap 'rm -rf "$PREVIEW_BUILD"' EXIT
xcrun swiftc -swift-version 5 -O \
    -framework AppKit -framework SwiftUI -framework Carbon \
    "$PROJECT_ROOT/Sources/KeyboardLock/ContentView.swift" \
    "$PROJECT_ROOT/Sources/KeyboardLock/KeyboardLockService.swift" \
    "$PROJECT_ROOT/Sources/KeyboardLock/LockPolicy.swift" \
    "$PROJECT_ROOT/Sources/KeyboardLock/PermissionPolicy.swift" \
    "$PROJECT_ROOT/Tests/RenderPreview.swift" -o "$PREVIEW_BUILD/RenderPreview"
"$PREVIEW_BUILD/RenderPreview" "${1:-$PROJECT_ROOT/docs/previews}"
