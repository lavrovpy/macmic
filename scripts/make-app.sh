#!/usr/bin/env bash
# MacMic - Native macOS RGB control for HyperX QuadCast S
# Copyright (C) 2026 Andrii Lavreniuk
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 2 of the License ONLY.
# See LICENSE for the full license text.
#
# Builds the release binary and assembles it into dist/MacMic.app, an
# ad-hoc-signed, LSUIElement (menu-bar-only, no Dock icon) app bundle.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="MacMic"
BUNDLE_ID="dev.alavreniuk.macmic"
VERSION="1.0.0"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

echo "==> Building release binary"
swift build -c release --product "$APP_NAME"

RELEASE_BIN="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"
if [[ ! -x "$RELEASE_BIN" ]]; then
    echo "error: release binary not found at $RELEASE_BIN" >&2
    exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$RELEASE_BIN" "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Code signing (ad-hoc)"
codesign --force --sign - "$APP_DIR"

echo "==> Verifying code signature"
codesign --verify --verbose "$APP_DIR"

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
