#!/usr/bin/env bash
# Build Enshittifier.app from the Swift package, then assemble a DMG.
#
# Usage: bash installer-swift/build-app.sh
# Output:
#   installer-swift/build/Enshittifier.app
#   Enshittifier-native.dmg (at repo root)
#
# Requires: macOS, Swift toolchain (Xcode or Command Line Tools), hdiutil.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$BUILD_DIR/Enshittifier.app"
DMG_OUT="$REPO_ROOT/Enshittifier-native.dmg"
BUNDLE_ID="com.enshittifier.installer.native"
ICON_SOURCE="$SCRIPT_DIR/Enshittifier.icon"

cd "$SCRIPT_DIR"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/EnshittifierInstaller"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "ERROR: build produced no binary at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/EnshittifierInstaller"
chmod +x "$APP_DIR/Contents/MacOS/EnshittifierInstaller"

# Bundle the Python patcher as a Resource so PythonFallbackPatcher can find it.
cp "$REPO_ROOT/enshittifier.py" "$APP_DIR/Contents/Resources/enshittifier.py"

# ---- App icon ----
# Compile Enshittifier.icon (Xcode 26 Liquid Glass icon package) into both
# an Assets.car (for Tahoe's full Liquid Glass treatment) and a flat .icns
# (fallback). Both land in Contents/Resources and the Info.plist points at
# them via CFBundleIconName / CFBundleIconFile.
HAS_ICON=0
if [[ -d "$ICON_SOURCE" ]]; then
    echo "==> Compiling app icon..."
    ICON_BUILD="$BUILD_DIR/icon"
    rm -rf "$ICON_BUILD" && mkdir -p "$ICON_BUILD"
    actool \
        --compile "$ICON_BUILD" \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --app-icon Enshittifier \
        --output-partial-info-plist "$ICON_BUILD/_partial.plist" \
        "$ICON_SOURCE" >/dev/null 2>&1 || {
            echo "WARN: actool failed to compile $ICON_SOURCE — continuing without icon." >&2
        }
    if [[ -f "$ICON_BUILD/Enshittifier.icns" ]]; then
        cp "$ICON_BUILD/Enshittifier.icns" "$APP_DIR/Contents/Resources/"
        HAS_ICON=1
    fi
    if [[ -f "$ICON_BUILD/Assets.car" ]]; then
        cp "$ICON_BUILD/Assets.car" "$APP_DIR/Contents/Resources/"
        HAS_ICON=1
    fi
fi

# Bundle a Python venv with the patcher's deps so end users don't have to
# pip-install fontTools themselves. The venv symlinks to the build-host's
# python3 — works on Wells' machine; cross-machine distribution would need
# a relocatable Python (Phase 3).
echo "==> Bundling Python venv with fontTools..."
VENV_DIR="$APP_DIR/Contents/Resources/venv"
rm -rf "$VENV_DIR"
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet fonttools svgpathtools cu2qu

# Minimal Info.plist — no code-signing, no notarization yet.
ICON_KEYS=""
if [[ $HAS_ICON -eq 1 ]]; then
    ICON_KEYS="    <key>CFBundleIconFile</key><string>Enshittifier</string>
    <key>CFBundleIconName</key><string>Enshittifier</string>"
fi

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Enshittifier</string>
    <key>CFBundleDisplayName</key><string>Enshittifier</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>EnshittifierInstaller</string>
    <key>CFBundleVersion</key><string>1.0.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026</string>
${ICON_KEYS}
</dict>
</plist>
EOF

# Touch the bundle so Launch Services re-reads it (some Finder caches are sticky).
touch "$APP_DIR"

echo "==> $APP_DIR built"

# ---- DMG ----
DMG_STAGE="$BUILD_DIR/dmg_stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP_DIR" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

echo "==> Creating $DMG_OUT"
rm -f "$DMG_OUT"
hdiutil create \
    -volname "Enshittifier (native)" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$DMG_OUT" >/dev/null

echo ""
echo "Done."
echo "  App:  $APP_DIR"
echo "  DMG:  $DMG_OUT"
echo "  Open: open '$APP_DIR'"
