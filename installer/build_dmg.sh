#!/usr/bin/env bash
# Build Enshittifier.dmg
#
# Usage: bash installer/build_dmg.sh
# Output: Enshittifier.dmg at the repository root.
#
# Requires: macOS, Python 3, pip, py2app, hdiutil (built into macOS).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$SCRIPT_DIR/build_work"
DMG_STAGE="$WORK_DIR/dmg_stage"
DMG_OUT="$REPO_ROOT/Enshittifier.dmg"

echo "==> Installing py2app..."
pip3 install py2app --quiet

# --- Build Enshittifier Installer.app ---
echo "==> Building Enshittifier Installer.app..."
cd "$SCRIPT_DIR"
rm -rf build dist
python3 setup_installer.py py2app --dist-dir "$WORK_DIR/installer_dist" 2>&1 | tail -5

# --- Build Unshittifier.app ---
echo "==> Building Unshittifier.app..."
rm -rf build dist
python3 setup_unshittifier.py py2app --dist-dir "$WORK_DIR/unshittifier_dist" 2>&1 | tail -5
rm -rf build

# --- Assemble DMG staging area ---
echo "==> Assembling DMG staging area..."
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"

cp -R "$WORK_DIR/installer_dist/Enshittifier Installer.app" "$DMG_STAGE/"
cp -R "$WORK_DIR/unshittifier_dist/Unshittifier.app" "$DMG_STAGE/"
cp "$SCRIPT_DIR/README.txt" "$DMG_STAGE/"

# Optional: symlink to /Applications for drag-install convenience
ln -s /Applications "$DMG_STAGE/Applications"

# --- Create the DMG ---
echo "==> Creating $DMG_OUT..."
rm -f "$DMG_OUT"
hdiutil create \
    -volname "Enshittifier" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$DMG_OUT"

echo ""
echo "Done: $DMG_OUT"
echo "Mount it with: open '$DMG_OUT'"
