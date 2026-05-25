#!/usr/bin/env bash
# Build Enshittifier.dmg
#
# Usage: bash installer/build_dmg.sh
# Output: Enshittifier.dmg at the repository root.
#
# Requires:
#   - macOS, Python 3, hdiutil (built into macOS)
#   - python-tk@<your-python-version> via Homebrew (needed because
#     Homebrew packages tkinter separately from python). For Homebrew
#     Python 3.14:  brew install python-tk@3.14

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$SCRIPT_DIR/build_work"
DMG_STAGE="$WORK_DIR/dmg_stage"
DMG_OUT="$REPO_ROOT/Enshittifier.dmg"
VENV_DIR="$WORK_DIR/.venv"

# Verify tkinter is available before building — py2app will happily bundle
# a broken app if it isn't, and the failure only shows up at .app launch.
if ! python3 -c "import tkinter" >/dev/null 2>&1; then
    PYVER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    cat >&2 <<EOF
ERROR: python3 cannot import tkinter.

Homebrew packages tkinter separately. Install it for your Python version:

    brew install python-tk@${PYVER}

Then re-run this script.
EOF
    exit 1
fi

# Homebrew Python enforces PEP 668, so we build inside a project-local venv.
echo "==> Creating build venv..."
mkdir -p "$WORK_DIR"
python3 -m venv "$VENV_DIR"
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet py2app fonttools svgpathtools cu2qu

# --- Build Enshittifier Installer.app ---
echo "==> Building Enshittifier Installer.app..."
cd "$SCRIPT_DIR"
rm -rf build dist
python setup_installer.py py2app --dist-dir "$WORK_DIR/installer_dist" 2>&1 | tail -5

# --- Build Unshittifier.app ---
echo "==> Building Unshittifier.app..."
rm -rf build dist
python setup_unshittifier.py py2app --dist-dir "$WORK_DIR/unshittifier_dist" 2>&1 | tail -5
rm -rf build

deactivate

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
