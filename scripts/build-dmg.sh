#!/bin/bash
# Builds GitHub Activity in Release and packages it as build/GitHubActivity-<version>.dmg
# (the app plus an Applications shortcut to drag it onto).
#
#   scripts/build-dmg.sh
#
# Without settings it signs ad hoc ("Sign to Run Locally"): fine on this Mac, but other
# Macs will warn that the app can't be checked. For a download anyone can open, set:
#
#   DEVELOPMENT_TEAM=ABCDE12345          your Apple Developer team ID
#   SIGN_IDENTITY="Developer ID Application: Your Name (ABCDE12345)"
#   NOTARY_PROFILE=github-activity       from: xcrun notarytool store-credentials github-activity
#
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="github_contribution_widget.xcodeproj"
SCHEME="GitHubActivity"
APP_NAME="GitHubActivity"
VOLUME_NAME="GitHub Activity"
BUILD_DIR="build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
STAGING="$BUILD_DIR/dmg"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

step() { printf '\n==> %s\n' "$1"; }

step "Building $SCHEME (Release)"
# No injected debug entitlements (get-task-allow): release builds shouldn't carry them,
# and notarization rejects them.
signing=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SIGN_IDENTITY" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
if [[ -n "$DEVELOPMENT_TEAM" ]]; then
    signing+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    # Notarization needs a secure timestamp on every signature.
    signing+=("OTHER_CODE_SIGN_FLAGS=--timestamp")
fi
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    "${signing[@]}" \
    clean build 2>&1 \
    | grep -E "error:|warning:|\*\* BUILD" || true

APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "Build failed: $APP not found" >&2; exit 1; }

step "Checking the signature"
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Signature|TeamIdentifier)=" || true

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

step "Packaging $DMG"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov "$DMG" >/dev/null
rm -rf "$STAGING"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
    step "Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

step "Verifying $DMG"
hdiutil verify "$DMG" >/dev/null && echo "Checksum OK"

echo
echo "Done: $DMG ($(du -h "$DMG" | cut -f1 | xargs))"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "Signed ad hoc: other Macs will need System Settings > Privacy & Security > Open Anyway."
fi
