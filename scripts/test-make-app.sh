#!/usr/bin/env bash
# MacMic - Native macOS RGB control for HyperX QuadCast S
# Copyright (C) 2026 Andrii Lavreniuk
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 2 of the License ONLY.
# See LICENSE for the full license text.
#
# CI-style check for scripts/make-app.sh: lints it if shellcheck is
# available, runs it, then asserts the resulting bundle looks right.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if command -v shellcheck >/dev/null 2>&1; then
    echo "==> shellcheck scripts/*.sh"
    shellcheck scripts/*.sh
else
    echo "==> shellcheck not installed, skipping lint"
fi

echo "==> Running scripts/make-app.sh"
bash scripts/make-app.sh

APP_DIR="dist/MacMic.app"
APP_BIN="$APP_DIR/Contents/MacOS/MacMic"
INFO_PLIST="$APP_DIR/Contents/Info.plist"

if [[ ! -x "$APP_BIN" ]]; then
    echo "FAIL: $APP_BIN does not exist or is not executable" >&2
    exit 1
fi
echo "PASS: $APP_BIN exists"

if ! grep -q "LSUIElement" "$INFO_PLIST"; then
    echo "FAIL: $INFO_PLIST does not contain LSUIElement" >&2
    exit 1
fi
echo "PASS: $INFO_PLIST contains LSUIElement"

# Without this key macOS kills the app the moment "Test Microphone" opens the mic.
if ! grep -q "NSMicrophoneUsageDescription" "$INFO_PLIST"; then
    echo "FAIL: $INFO_PLIST does not contain NSMicrophoneUsageDescription" >&2
    exit 1
fi
echo "PASS: $INFO_PLIST contains NSMicrophoneUsageDescription"

if ! plutil -lint "$INFO_PLIST" >/dev/null; then
    echo "FAIL: $INFO_PLIST is not a well-formed property list" >&2
    exit 1
fi
echo "PASS: $INFO_PLIST is well-formed"

if ! plutil -extract CFBundleVersion raw "$INFO_PLIST" | grep -Eq '^[0-9]+$'; then
    echo "FAIL: CFBundleVersion in $INFO_PLIST is not a plain build number" >&2
    exit 1
fi
echo "PASS: CFBundleVersion is a build number"

for arch in arm64 x86_64; do
    if ! lipo -archs "$APP_BIN" | tr ' ' '\n' | grep -qx "$arch"; then
        echo "FAIL: $APP_BIN has no $arch slice ($(lipo -archs "$APP_BIN"))" >&2
        exit 1
    fi
done
echo "PASS: $APP_BIN is universal (arm64 + x86_64)"

# A binary stamped with an older SDK than the one it was built with runs in
# macOS's compatibility mode for that SDK (see the -isysroot note in make-app.sh).
EXPECTED_SDK="$(xcrun --sdk macosx --show-sdk-version)"
STAMPED_SDKS="$(vtool -show-build "$APP_BIN" | awk '$1 == "sdk" { print $2 }' | sort -u)"
if [[ "$STAMPED_SDKS" != "$EXPECTED_SDK" ]]; then
    echo "FAIL: $APP_BIN is stamped with SDK '$STAMPED_SDKS', expected $EXPECTED_SDK" >&2
    exit 1
fi
echo "PASS: $APP_BIN is stamped with SDK $EXPECTED_SDK"

if ! codesign --display --verbose "$APP_DIR" 2>&1 | grep -Eq '^CodeDirectory .*flags=.*runtime'; then
    echo "FAIL: $APP_DIR is not signed with the hardened runtime" >&2
    exit 1
fi
echo "PASS: $APP_DIR is signed with the hardened runtime"

# Under the hardened runtime, TCC denies the microphone without this entitlement.
if ! codesign --display --entitlements - --xml "$APP_DIR" 2>/dev/null | grep -q "com.apple.security.device.audio-input"; then
    echo "FAIL: $APP_DIR is not signed with com.apple.security.device.audio-input" >&2
    exit 1
fi
echo "PASS: $APP_DIR carries com.apple.security.device.audio-input"

echo "==> All checks passed"
