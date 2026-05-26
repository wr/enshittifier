#!/usr/bin/env bash
#
# Bundle a relocatable CPython + fontTools into an Enshittifier.app's
# Contents/Resources/venv/. Idempotent — re-running with an existing venv
# is a no-op.
#
# Why python-build-standalone instead of `python3 -m venv`: a venv's
# bin/python3 is a symlink to the host's Homebrew/system interpreter. That
# symlink points outside the .app bundle, Apple's notary rejects it, and
# `codesign --deep --strict` won't sign across it. python-build-standalone
# is a fully relocatable distribution — all libs are inside the tree.
#
# Usage:  bundle-python.sh <path-to-Enshittifier.app>
set -euo pipefail

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" ]]; then
    echo "usage: $0 <Enshittifier.app>" >&2
    exit 2
fi
if [[ ! -d "$APP_PATH" ]]; then
    echo "error: not a directory: $APP_PATH" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="$INSTALLER_DIR/build/cache"

# Pin to a specific python-build-standalone release. Bumping these requires
# checking the URL still resolves and that pip can still install the deps.
PYBS_VERSION="3.13.0"
PYBS_DATE="20241016"
PYBS_ARCH="aarch64-apple-darwin"
PYBS_TARBALL="cpython-${PYBS_VERSION}+${PYBS_DATE}-${PYBS_ARCH}-install_only_stripped.tar.gz"
PYBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYBS_DATE}/${PYBS_TARBALL}"
PYBS_CACHE="$CACHE_DIR/${PYBS_TARBALL}"

VENV_DIR="$APP_PATH/Contents/Resources/venv"

# Idempotency: if the venv exists and reports fontTools, skip.
if [[ -x "$VENV_DIR/bin/python3" ]] && "$VENV_DIR/bin/python3" -c "import fontTools" >/dev/null 2>&1; then
    echo "==> Python venv already bundled at $VENV_DIR (skipping)"
    exit 0
fi

mkdir -p "$CACHE_DIR"
if [[ ! -f "$PYBS_CACHE" ]]; then
    echo "==> Downloading python-build-standalone ${PYBS_VERSION} (${PYBS_ARCH})..."
    curl -fL --retry 3 -o "$PYBS_CACHE.tmp" "$PYBS_URL"
    mv "$PYBS_CACHE.tmp" "$PYBS_CACHE"
fi

echo "==> Extracting embedded Python ${PYBS_VERSION} into ${VENV_DIR}..."
rm -rf "$VENV_DIR"
mkdir -p "$VENV_DIR"
# strip-components=1 drops the tarball's top-level `python/` dir so the
# layout lands directly under Contents/Resources/venv/ — matches what
# PythonFallbackPatcher expects (Contents/Resources/venv/bin/python3).
tar -xzf "$PYBS_CACHE" -C "$VENV_DIR" --strip-components=1

echo "==> Installing fontTools + svgpathtools + cu2qu..."
"$VENV_DIR/bin/python3" -m pip install --quiet --no-warn-script-location \
    fonttools svgpathtools cu2qu

echo "==> Python bundle ready at $VENV_DIR"
