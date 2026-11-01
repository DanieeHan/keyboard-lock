#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build/release"
DIST_DIR="$PROJECT_ROOT/dist"
DEVELOPMENT_APP="$DIST_DIR/键盘锁.app"
ZIP_PATH="$DIST_DIR/键盘锁.zip"
# FileProvider can reattach FinderInfo moments after signing in an iCloud
# folder. Assemble and sign outside that folder; the ZIP is the stable artifact.
STAGING_DIR="$(mktemp -d /private/tmp/keyboard-lock-build.XXXXXX)"
SIGNING_KEYCHAIN=""
cleanup_build() {
    local result=$?
    if [[ -n "$SIGNING_KEYCHAIN" ]]; then
        if ! /usr/bin/security lock-keychain "$SIGNING_KEYCHAIN" >/dev/null 2>&1; then
            echo "Could not lock the dedicated signing keychain after the build." >&2
            result=1
        fi
    fi
    rm -rf "$STAGING_DIR"
    exit "$result"
}
trap cleanup_build EXIT
PACKAGE_DIR="$STAGING_DIR/package"
APP_PATH="$PACKAGE_DIR/键盘锁.app"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
DEPLOYMENT_TARGET="13.0"
SIGNING_OPTIONS=(--options runtime)
if [[ "${CODE_SIGN_IDENTITY+x}" == x ]]; then
    SIGNING_IDENTITY="$CODE_SIGN_IDENTITY"
    if [[ -z "$SIGNING_IDENTITY" ]]; then
        echo "CODE_SIGN_IDENTITY is empty. Omit it for stable local signing or select an existing identity." >&2
        exit 1
    fi
    if [[ "$SIGNING_IDENTITY" == "-" ]]; then
        echo "Intentional ad-hoc signing: changed builds may require removing and re-adding Accessibility permission."
    else
        echo "Signing with existing identity: $SIGNING_IDENTITY"
    fi
else
    SIGNING_METADATA="$(python3 "$PROJECT_ROOT/scripts/local-signing.py")"
    SIGNING_KEYCHAIN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["keychain"])' <<< "$SIGNING_METADATA")"
    SIGNING_IDENTITY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["identity_sha1"])' <<< "$SIGNING_METADATA")"
    SIGNING_OPTIONS=(--options runtime --keychain "$SIGNING_KEYCHAIN" --timestamp=none)
    echo "Signing with stable local certificate: $SIGNING_IDENTITY"
fi

# Native host architecture keeps the personal build small. For distribution:
# ARCHS="arm64 x86_64" ./scripts/build.sh
read -r -a BUILD_ARCHS <<< "${ARCHS:-$(uname -m)}"
mkdir -p "$BUILD_DIR" "$DIST_DIR" "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

SWIFT_SOURCES=()
while IFS= read -r -d '' source_file; do
    SWIFT_SOURCES+=("$source_file")
done < <(find "$PROJECT_ROOT/Sources/KeyboardLock" -name '*.swift' -print0)

BINARIES=()
for build_arch in "${BUILD_ARCHS[@]}"; do
    if [[ "$build_arch" != "arm64" && "$build_arch" != "x86_64" ]]; then
        echo "Unsupported architecture: $build_arch" >&2
        exit 1
    fi
    ARCH_DIR="$BUILD_DIR/$build_arch"
    mkdir -p "$ARCH_DIR"
    xcrun clang -Os -Wall -Wextra -Werror \
        -arch "$build_arch" -isysroot "$SDK_PATH" \
        -mmacosx-version-min="$DEPLOYMENT_TARGET" \
        -I "$PROJECT_ROOT/Sources/OfflineGuard/include" \
        -c "$PROJECT_ROOT/Sources/OfflineGuard/OfflineGuard.c" \
        -o "$ARCH_DIR/OfflineGuard.o"
    xcrun swiftc -Osize -whole-module-optimization -swift-version 5 \
        -target "$build_arch-apple-macosx$DEPLOYMENT_TARGET" \
        -sdk "$SDK_PATH" -module-name KeyboardLock \
        -I "$PROJECT_ROOT/Sources/OfflineGuard/include" \
        "${SWIFT_SOURCES[@]}" "$ARCH_DIR/OfflineGuard.o" \
        -framework SwiftUI -framework AppKit -framework ApplicationServices \
        -lsandbox -o "$ARCH_DIR/KeyboardLock"
    xcrun strip -x "$ARCH_DIR/KeyboardLock"
    BINARIES+=("$ARCH_DIR/KeyboardLock")
done

if [[ ${#BINARIES[@]} -gt 1 ]]; then
    xcrun lipo -create "${BINARIES[@]}" -output "$APP_PATH/Contents/MacOS/KeyboardLock"
else
    cp "${BINARIES[0]}" "$APP_PATH/Contents/MacOS/KeyboardLock"
fi
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
if [[ -f "$PROJECT_ROOT/Resources/AppIcon.icns" ]]; then
    cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"
# Finder/iCloud metadata can be inherited by generated files in a synced
# workspace. Only strip signing-incompatible attributes from this app bundle.
/usr/bin/xattr -r -d com.apple.FinderInfo "$APP_PATH" 2>/dev/null || true
/usr/bin/xattr -r -d com.apple.ResourceFork "$APP_PATH" 2>/dev/null || true
# Preserve codesign's signer-derived designated requirement. A certificate
# identity failure stops the build; never silently fall back to ad-hoc signing.
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "${SIGNING_OPTIONS[@]}" "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"

# Metadata-free ZIP contents remain stable even when the archive itself lives
# in a synced folder. Re-extract the actual deliverable and verify its signature.
cp "$PROJECT_ROOT/LICENSE" "$PACKAGE_DIR/LICENSE"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
    -c -k "$PACKAGE_DIR" "$ZIP_PATH"
VERIFICATION_DIR="$STAGING_DIR/verified"
mkdir -p "$VERIFICATION_DIR"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl \
    -x -k "$ZIP_PATH" "$VERIFICATION_DIR"
/usr/bin/codesign --verify --deep --strict "$VERIFICATION_DIR/键盘锁.app"
cmp "$PROJECT_ROOT/LICENSE" "$VERIFICATION_DIR/LICENSE"

# Keep a convenient development copy, but never claim its signature remains
# valid after the sync provider adds bundle metadata. Install from the ZIP.
COPY_DEVELOPMENT_APP=true
if DEVELOPMENT_PROCESSES="$(/bin/ps -ww -axo comm=)"; then
    while IFS= read -r process_executable; do
        if [[ "$process_executable" == "$DEVELOPMENT_APP/Contents/MacOS/KeyboardLock" ]]; then
            COPY_DEVELOPMENT_APP=false
            echo "Skipping development copy: that exact app is running. Quit it before replacing it."
            break
        fi
    done <<< "$DEVELOPMENT_PROCESSES"
else
    COPY_DEVELOPMENT_APP=false
    echo "Skipping development copy: running processes could not be checked safely."
fi
if [[ "$COPY_DEVELOPMENT_APP" == true ]]; then
    rm -rf "$DEVELOPMENT_APP"
    /usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$APP_PATH" "$DEVELOPMENT_APP"
    echo "Development copy (synced folder metadata may affect signing): $DEVELOPMENT_APP"
fi
echo "Built and verified ZIP: $ZIP_PATH"
/usr/bin/du -sh "$APP_PATH"
/usr/bin/du -h "$ZIP_PATH"
