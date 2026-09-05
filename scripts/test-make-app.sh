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
    echo "==> shellcheck scripts/make-app.sh"
    shellcheck scripts/make-app.sh
else
    echo "==> shellcheck not installed, skipping lint"
fi

echo "==> Running scripts/make-app.sh"
bash scripts/make-app.sh

APP_BIN="dist/MacMic.app/Contents/MacOS/MacMic"
INFO_PLIST="dist/MacMic.app/Contents/Info.plist"

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

echo "==> All checks passed"
