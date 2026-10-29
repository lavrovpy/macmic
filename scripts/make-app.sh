#!/usr/bin/env bash
# MacMic - Native macOS RGB control for HyperX QuadCast S
# Copyright (C) 2026 Andrii Lavreniuk
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 2 of the License ONLY.
# See LICENSE for the full license text.
#
# Builds the universal (arm64 + x86_64) release binary and assembles it into
# dist/MacMic.app, an LSUIElement (menu-bar-only, no Dock icon) app bundle
# whose Info.plist is Sources/MacMic/Info.plist plus the version keys, signed
# with the hardened runtime and scripts/MacMic.entitlements.
#
# Environment:
#   MACMIC_VERSION        CFBundleShortVersionString (default 1.0.0)
#   MACMIC_BUILD          CFBundleVersion, must only grow (default: commit count)
#   MACMIC_SIGN_IDENTITY  codesign identity (default "-", ad-hoc); scripts/release.sh
#                         passes a "Developer ID Application" identity
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="MacMic"
VERSION="${MACMIC_VERSION:-1.0.0}"
BUILD="${MACMIC_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_IDENTITY="${MACMIC_SIGN_IDENTITY:--}"
INFO_PLIST="$ROOT_DIR/Sources/MacMic/Info.plist"
ENTITLEMENTS="$ROOT_DIR/scripts/MacMic.entitlements"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

# SwiftPM's default build system (Swift 6.4+) links without SDKROOT set, so
# clang can't read the SDK version and stamps the deployment target (13.0) as
# the binary's SDK in LC_BUILD_VERSION; macOS then runs the app in its old-SDK
# compatibility mode. An explicit -isysroot on the link restores the real SDK.
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
BUILD_ARGS=(
    -c release --product "$APP_NAME" --arch arm64 --arch x86_64
    -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK_PATH"
)

echo "==> Building universal release binary"
swift build "${BUILD_ARGS[@]}"

RELEASE_BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/$APP_NAME"
if [[ ! -x "$RELEASE_BIN" ]]; then
    echo "error: release binary not found at $RELEASE_BIN" >&2
    exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$RELEASE_BIN" "$MACOS_DIR/$APP_NAME"

cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$CONTENTS_DIR/Info.plist"
plutil -insert CFBundleVersion -string "$BUILD" "$CONTENTS_DIR/Info.plist"

# Under the hardened runtime (required for notarization) TCC silently denies
# the microphone unless the signature carries the audio-input entitlement.
SIGN_ARGS=(--force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--timestamp)
fi

echo "==> Code signing ($SIGN_IDENTITY, hardened runtime)"
codesign "${SIGN_ARGS[@]}" "$APP_DIR"

echo "==> Verifying code signature"
codesign --verify --strict --verbose=2 "$APP_DIR"

echo "==> Launch check"
"$MACOS_DIR/$APP_NAME" &
LAUNCH_PID=$!
sleep 3
if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
    echo "error: $APP_NAME exited within 3 seconds of launch" >&2
    exit 1
fi
kill "$LAUNCH_PID"
wait "$LAUNCH_PID" 2>/dev/null || true

echo "==> Built $APP_DIR"
