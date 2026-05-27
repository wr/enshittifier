#!/usr/bin/env bash
#
# Local dev build of Enshittifier.app. Adhoc-signed, no notarization, no
# Sparkle signature — for quick iteration only. Output:
#
#   build/Enshittifier.app           (adhoc-signed)
#   Enshittifier-dev.dmg             (unsigned DMG, repo root)
#
# For a shippable signed/notarized release, use scripts/release.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$REPO_ROOT/build"
DD_DIR="$BUILD_DIR/dd"
APP_NAME="Enshittifier"
DMG_OUT="$REPO_ROOT/Enshittifier-dev.dmg"

cd "$REPO_ROOT"

if ! command -v xcodegen >/dev/null; then
    echo "error: xcodegen not installed (brew install xcodegen)" >&2
    exit 1
fi

echo "==> xcodegen generate"
xcodegen generate

echo "==> xcodebuild Debug"
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DD_DIR" \
    build >/dev/null

BUILT_APP="$DD_DIR/Build/Products/Debug/$APP_NAME.app"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "error: build produced no app at $BUILT_APP" >&2
    exit 1
fi

# Copy to a stable path under build/ so users have a predictable location.
DEV_APP="$BUILD_DIR/$APP_NAME.app"
rm -rf "$DEV_APP"
cp -R "$BUILT_APP" "$DEV_APP"

echo "==> Bundling embedded Python"
"$SCRIPT_DIR/bundle-python.sh" "$DEV_APP"

# Re-sign the app after dropping the Python tree in. Adhoc — dev only.
codesign --force --sign - --deep "$DEV_APP" >/dev/null

echo "==> Creating $DMG_OUT"
rm -f "$DMG_OUT"
if command -v create-dmg >/dev/null; then
    DMG_STAGE="$BUILD_DIR/dmg_stage"
    rm -rf "$DMG_STAGE" && mkdir -p "$DMG_STAGE"
    cp -R "$DEV_APP" "$DMG_STAGE/"
    create-dmg \
        --volname "Enshittifier (dev)" \
        --window-pos 200 120 \
        --window-size 540 360 \
        --icon-size 96 \
        --icon "$APP_NAME.app" 140 180 \
        --hide-extension "$APP_NAME.app" \
        --app-drop-link 400 180 \
        "$DMG_OUT" \
        "$DMG_STAGE" >/dev/null
else
    # Fallback if create-dmg isn't installed — no fancy layout.
    DMG_STAGE="$BUILD_DIR/dmg_stage"
    rm -rf "$DMG_STAGE" && mkdir -p "$DMG_STAGE"
    cp -R "$DEV_APP" "$DMG_STAGE/"
    ln -s /Applications "$DMG_STAGE/Applications"
    hdiutil create \
        -volname "Enshittifier (dev)" \
        -srcfolder "$DMG_STAGE" \
        -ov -format UDZO \
        "$DMG_OUT" >/dev/null
fi

echo
echo "Done."
echo "  App:  $DEV_APP"
echo "  DMG:  $DMG_OUT"
echo "  Open: open '$DEV_APP'"
