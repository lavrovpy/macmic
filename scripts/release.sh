#!/usr/bin/env bash
# MacMic - Native macOS RGB control for HyperX QuadCast S
# Copyright (C) 2026 Andrii Lavreniuk
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 2 of the License ONLY.
# See LICENSE for the full license text.
#
# Builds a release of MacMic for GitHub and Homebrew: dist/MacMic.app signed
# with a Developer ID, notarized and stapled, zipped as
# dist/MacMic-<version>.zip, plus dist/macmic.rb, the Homebrew cask for that
# zip once it is uploaded to the v<version> GitHub release.
#
# One-time setup: a "Developer ID Application" certificate in the login
# keychain, and notarytool credentials stored under a keychain profile:
#   xcrun notarytool store-credentials macmic-notary \
#       --apple-id <apple id> --team-id <team id> --password <app-specific password>
#
# Usage:
#   MACMIC_VERSION=1.0.0 \
#   MACMIC_SIGN_IDENTITY="Developer ID Application: <name> (<team id>)" \
#   scripts/release.sh
# MACMIC_NOTARY_PROFILE overrides the keychain profile name (default macmic-notary).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

: "${MACMIC_VERSION:?set MACMIC_VERSION, e.g. MACMIC_VERSION=1.0.0}"
: "${MACMIC_SIGN_IDENTITY:?set MACMIC_SIGN_IDENTITY to a \"Developer ID Application: …\" identity}"
NOTARY_PROFILE="${MACMIC_NOTARY_PROFILE:-macmic-notary}"
REPO="lavrovpy/macmic"
BUNDLE_ID="dev.alavreniuk.macmic"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/MacMic.app"
ZIP="$DIST_DIR/MacMic-$MACMIC_VERSION.zip"
CASK="$DIST_DIR/macmic.rb"

# Notarization only accepts Developer ID signatures; an "Apple Development"
# certificate signs fine locally and is then rejected after the upload.
if [[ "$MACMIC_SIGN_IDENTITY" != "Developer ID Application:"* ]]; then
    echo "error: MACMIC_SIGN_IDENTITY must be a \"Developer ID Application: …\" identity" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: the working tree has uncommitted changes; release from a clean checkout" >&2
    exit 1
fi

export MACMIC_VERSION MACMIC_SIGN_IDENTITY
bash scripts/make-app.sh

echo "==> Submitting for notarization (profile $NOTARY_PROFILE)"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP"
SUBMISSION="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
STATUS="$(plutil -extract status raw - <<<"$SUBMISSION")"
if [[ "$STATUS" != "Accepted" ]]; then
    SUBMISSION_ID="$(plutil -extract id raw - <<<"$SUBMISSION")"
    echo "error: notarization finished with status '$STATUS'" >&2
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    exit 1
fi

echo "==> Stapling the notarization ticket"
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"
spctl --assess --type execute --verbose=2 "$APP_DIR"

echo "==> Packaging $ZIP"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP"
SHA256="$(shasum -a 256 "$ZIP" | awk '{ print $1 }')"

cat > "$CASK" <<CASK
cask "macmic" do
  version "$MACMIC_VERSION"
  sha256 "$SHA256"

  url "https://github.com/$REPO/releases/download/v#{version}/MacMic-#{version}.zip"
  name "MacMic"
  desc "Menu bar app for HyperX QuadCast S lighting and audio controls"
  homepage "https://github.com/$REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "MacMic.app"

  uninstall quit: "$BUNDLE_ID"

  zap trash: "~/Library/Preferences/$BUNDLE_ID.plist"
end
CASK

echo "==> Release artifacts"
echo "  $ZIP (sha256 $SHA256)"
echo "  $CASK"
echo "Upload the zip to the v$MACMIC_VERSION GitHub release, e.g.:"
echo "  gh release create v$MACMIC_VERSION \"$ZIP\" --title \"MacMic $MACMIC_VERSION\""
echo "then copy $CASK to Casks/macmic.rb in the Homebrew tap."
