#!/usr/bin/env bash
# Build, sign, notarize and staple the release DMG for Lanki.
#
# Usage: ./scripts/make-dmg.sh <version> [path-to-Lanki.app]
# Example: ./scripts/make-dmg.sh 1.0.0 /tmp/lanki-release/Lanki.app
#
# Prints the edSignature, length and sha256 needed for the appcast entry
# (Sparkle's `generate_appcast` computes these itself — see RELEASE.md).
#
# This script only works once you have a Developer ID Application certificate
# and a notarytool keychain profile set up. Until then, the early checks will
# stop it with a clear message instead of producing an un-notarized DMG.
set -euo pipefail

VERSION="${1:?Usage: ./scripts/make-dmg.sh <version> [path-to-Lanki.app]}"
APP="${2:-/tmp/lanki-release/Lanki.app}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Fill in your release identity. The string is exactly what `security
# --- find-identity -v -p codesigning` prints for your Developer ID cert.
IDENTITY="${DEVELOPER_ID_IDENTITY:-Developer ID Application: Your Name (TEAMID)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-lanki-notary}"
ED_KEY_FILE="${ED_KEY_FILE:-$REPO_ROOT/dsa_priv.pem}"
OUT_DIR="$HOME/Downloads/Lanki"
DMG="$OUT_DIR/Lankiv${VERSION}.dmg"
STAGING="$(mktemp -d)/staging"

[ -d "$APP" ] || { echo "App not found at: $APP" >&2; exit 1; }

# The app carries its version from build time. A DMG named 1.0.0 around a
# 0.9.0 build looks fine until Sparkle offers the same update forever.
APP_VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
if [ "$APP_VERSION" != "$VERSION" ]; then
  echo "Version mismatch: app is $APP_VERSION but building Lankiv${VERSION}.dmg" >&2
  echo "Bump MARKETING_VERSION in Lanki.xcodeproj and re-archive." >&2
  exit 1
fi

# Sparkle decides whether an update is newer by CFBundleVersion
# (CURRENT_PROJECT_VERSION), not by MARKETING_VERSION. Every release must bump
# it, or installed copies never see the update.
APP_BUILD="$(defaults read "$APP/Contents/Info" CFBundleVersion)"
case "$APP_BUILD" in
  '' | *[!0-9]*)
    echo "Build number '$APP_BUILD' is not a whole number." >&2
    exit 1
    ;;
esac

if [[ "$IDENTITY" == *"Your Name"* ]]; then
  echo "Set DEVELOPER_ID_IDENTITY to your 'Developer ID Application' identity first." >&2
  echo "  export DEVELOPER_ID_IDENTITY='Developer ID Application: Your Name (TEAMID)'" >&2
  exit 1
fi

# The Sparkle public key must be real before shipping: with a placeholder
# installed copies can never verify an update, so they silently never update.
PUBLIC_KEY="$(defaults read "$APP/Contents/Info" SUPublicEDKey 2>/dev/null || true)"
if [ -z "$PUBLIC_KEY" ] || [[ "$PUBLIC_KEY" == *"PASTE"* || "$PUBLIC_KEY" == *"HERE"* ]]; then
  echo "SUPublicEDKey in the built app is still a placeholder." >&2
  echo "Generate Sparkle keys and put the public key in Lanki-Info.plist (see RELEASE.md)." >&2
  exit 1
fi

echo "==> Verifying the exported app is signed"
codesign --verify --deep --strict "$APP"
# A release must be signed with a Developer ID certificate, not an
# "Apple Development" cert, or notarization and Gatekeeper reject it.
codesign -dv --verbose=4 "$APP" 2>&1 | grep -q "Authority=Developer ID Application" \
  || { echo "App is not signed with a 'Developer ID Application' certificate." >&2
       echo "Archive with CODE_SIGN_IDENTITY=\"$IDENTITY\" (see RELEASE.md)." >&2
       exit 1; }
for nested in Autoupdate Updater.app XPCServices/Installer.xpc XPCServices/Downloader.xpc; do
  path="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current/$nested"
  [ -e "$path" ] || continue
  info="$(codesign -dvvv "$path" 2>&1)"
  echo "$info" | grep -q "^Timestamp=" \
    || { echo "$nested has no secure timestamp; re-sign inside-out before continuing." >&2; exit 1; }
done

echo "==> Staging"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG"
mkdir -p "$OUT_DIR"
rm -f "$DMG"
hdiutil create \
  -volname "Lanki" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG" >/dev/null

echo "==> Signing the DMG (before notarizing)"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Notarizing"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

echo
echo "==> Appcast values"
if command -v generate_appcast >/dev/null 2>&1 && [ -f "$ED_KEY_FILE" ]; then
  generate_appcast --ed-key-file "$ED_KEY_FILE" "$DMG"
else
  echo "No Sparkle tool or key found. Install Sparkle (`brew install --cask sparkle`)" >&2
  echo "and set ED_KEY_FILE to your private key, then run generate_appcast on the DMG" >&2
  echo "(see RELEASE.md)." >&2
fi
echo "sparkle:version: $APP_BUILD"
echo "sha256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "dmg:    $DMG"
