#!/usr/bin/env bash
# Build Enshittifier.app from the Swift package.
#
# Two modes:
#
#   Dev (default):
#       bash installer-swift/build-app.sh
#     → installer-swift/build/Enshittifier.app  (unsigned)
#     → Enshittifier-native.dmg                 (unsigned, dev only)
#
#   Release:
#       bash installer-swift/build-app.sh --release vX.Y.Z
#     → builds, codesigns with Developer ID, hardens runtime, notarizes,
#       staples, signs the DMG, signs with Sparkle EdDSA, creates a
#       GitHub release with the DMG, and updates the appcast on the
#       `gh-pages` branch worktree.
#
# Release-mode prerequisites:
#   * Keychain notarytool profile named  `enshittifier-notarize`
#     (created once via  xcrun notarytool store-credentials …)
#   * Sparkle EdDSA private key in Keychain (item created by
#     installer-swift/.build/checkouts/Sparkle/bin/generate_keys; the
#     matching public key lives in installer-swift/sparkle/public-key.txt
#     and gets embedded in Info.plist as SUPublicEDKey).
#   * `gh` CLI authenticated (gh auth status).
#   * Clean working tree, currently on the tag commit being released.

set -euo pipefail

# ----- args ---------------------------------------------------------------
RELEASE_TAG=""
RELEASE_MODE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            RELEASE_MODE=1
            RELEASE_TAG="${2:-}"
            if [[ -z "$RELEASE_TAG" ]]; then
                echo "ERROR: --release requires a tag, e.g. --release v1.2.3" >&2
                exit 2
            fi
            if [[ ! "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "ERROR: tag must look like vMAJOR.MINOR.PATCH (got '$RELEASE_TAG')" >&2
                exit 2
            fi
            shift 2
            ;;
        -h|--help)
            sed -n '2,30p' "$0"; exit 0
            ;;
        *)
            echo "ERROR: unknown arg '$1'" >&2; exit 2
            ;;
    esac
done

# ----- paths --------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/build"
APP_DIR="$BUILD_DIR/Enshittifier.app"
DMG_OUT="$REPO_ROOT/Enshittifier-native.dmg"
BUNDLE_ID="com.enshittifier.installer.native"
ICON_SOURCE="$SCRIPT_DIR/Enshittifier.icon"
ENTITLEMENTS="$SCRIPT_DIR/Enshittifier.entitlements"
SPARKLE_DIR="$SCRIPT_DIR/sparkle"
SPARKLE_PUBKEY_FILE="$SPARKLE_DIR/public-key.txt"
SPARKLE_APPCAST_TEMPLATE="$SPARKLE_DIR/appcast.template.xml"

# Sparkle CLI tools live inside the resolved SwiftPM artifact.
SPARKLE_ART="$SCRIPT_DIR/.build/artifacts/sparkle/Sparkle/bin"

# Release-only config
SIGN_IDENTITY="Developer ID Application: Wells Riley (P3V9EZ525M)"
TEAM_ID="P3V9EZ525M"
NOTARY_PROFILE="enshittifier-notarize"
GH_REPO="wr/enshittifier"
APPCAST_URL="https://wr.github.io/enshittifier/appcast.xml"

cd "$SCRIPT_DIR"

# ----- version ------------------------------------------------------------
if [[ $RELEASE_MODE -eq 1 ]]; then
    SHORT_VERSION="${RELEASE_TAG#v}"          # 1.2.3
    BUNDLE_VERSION="$(git rev-list --count HEAD)"  # monotonic build number
    BUILD_CONFIG=release
else
    SHORT_VERSION="0.0.0-dev"
    BUNDLE_VERSION="0"
    BUILD_CONFIG=release   # release config even for local builds — same binary as ships
fi

# Reusable Sparkle pubkey lookup (release builds embed it in Info.plist)
SPARKLE_PUBKEY=""
if [[ -f "$SPARKLE_PUBKEY_FILE" ]]; then
    SPARKLE_PUBKEY="$(tr -d '[:space:]' < "$SPARKLE_PUBKEY_FILE")"
fi

# ----- build --------------------------------------------------------------
echo "==> swift build -c $BUILD_CONFIG"
swift build -c "$BUILD_CONFIG"

BIN_PATH="$(swift build -c "$BUILD_CONFIG" --show-bin-path)/EnshittifierInstaller"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "ERROR: build produced no binary at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/EnshittifierInstaller"
chmod +x "$APP_DIR/Contents/MacOS/EnshittifierInstaller"

# Bundle the Python patcher as a Resource so PythonFallbackPatcher can find it.
cp "$REPO_ROOT/enshittifier.py" "$APP_DIR/Contents/Resources/enshittifier.py"

# Embed Sparkle.framework next to our binary so the dyld loader can find
# it via @rpath. SwiftPM gives us the xcframework — pull the macOS slice
# out into Contents/Frameworks/Sparkle.framework.
SPARKLE_XCF="$SCRIPT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework"
if [[ ! -d "$SPARKLE_XCF" ]]; then
    echo "ERROR: Sparkle.xcframework not found at $SPARKLE_XCF — run 'swift package resolve' first" >&2
    exit 1
fi
SPARKLE_SLICE=""
for slice in "$SPARKLE_XCF"/macos-arm64_x86_64 "$SPARKLE_XCF"/macos-*; do
    if [[ -d "$slice/Sparkle.framework" ]]; then
        SPARKLE_SLICE="$slice/Sparkle.framework"; break
    fi
done
if [[ -z "$SPARKLE_SLICE" ]]; then
    echo "ERROR: no macOS slice found inside $SPARKLE_XCF" >&2
    exit 1
fi
cp -R "$SPARKLE_SLICE" "$APP_DIR/Contents/Frameworks/Sparkle.framework"

# ---- App icon (unchanged) -----------------------------------------------
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

# ---- Python venv with fontTools (unchanged) -----------------------------
echo "==> Bundling Python venv with fontTools..."
VENV_DIR="$APP_DIR/Contents/Resources/venv"
rm -rf "$VENV_DIR"
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet fonttools svgpathtools cu2qu

# ---- Info.plist ---------------------------------------------------------
ICON_KEYS=""
if [[ $HAS_ICON -eq 1 ]]; then
    ICON_KEYS="    <key>CFBundleIconFile</key><string>Enshittifier</string>
    <key>CFBundleIconName</key><string>Enshittifier</string>"
fi
SPARKLE_KEYS=""
if [[ $RELEASE_MODE -eq 1 ]]; then
    if [[ -z "$SPARKLE_PUBKEY" ]]; then
        echo "ERROR: $SPARKLE_PUBKEY_FILE is missing or empty." >&2
        echo "       Run installer-swift/.build/checkouts/Sparkle/bin/generate_keys" >&2
        echo "       and save the printed public key to that file." >&2
        exit 1
    fi
    SPARKLE_KEYS="    <key>SUFeedURL</key><string>${APPCAST_URL}</string>
    <key>SUPublicEDKey</key><string>${SPARKLE_PUBKEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUEnableInstallerLauncherService</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>"
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
    <key>CFBundleVersion</key><string>${BUNDLE_VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026</string>
${ICON_KEYS}
${SPARKLE_KEYS}
</dict>
</plist>
EOF

# Touch the bundle so Launch Services re-reads it.
touch "$APP_DIR"

# =========================================================================
# Dev path stops here (unsigned .app + unsigned .dmg).
# =========================================================================
if [[ $RELEASE_MODE -eq 0 ]]; then
    echo "==> $APP_DIR built (unsigned, dev mode)"

    DMG_STAGE="$BUILD_DIR/dmg_stage"
    rm -rf "$DMG_STAGE" && mkdir -p "$DMG_STAGE"
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

    echo
    echo "Done."
    echo "  App:  $APP_DIR"
    echo "  DMG:  $DMG_OUT"
    echo "  Open: open '$APP_DIR'"
    exit 0
fi

# =========================================================================
# Release path: codesign → DMG → notarize → staple → Sparkle sign → publish
# =========================================================================
echo "==> Release pipeline for $RELEASE_TAG ($SHORT_VERSION / build $BUNDLE_VERSION)"

# --- safety checks
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    echo "ERROR: working tree dirty. Commit or stash before releasing." >&2
    exit 1
fi
EXPECTED_COMMIT="$(git -C "$REPO_ROOT" rev-list -n1 "$RELEASE_TAG" 2>/dev/null || true)"
HEAD_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
if [[ -z "$EXPECTED_COMMIT" ]]; then
    echo "ERROR: tag $RELEASE_TAG does not exist locally. Tag the commit first:" >&2
    echo "       git tag -a $RELEASE_TAG -m '$RELEASE_TAG'" >&2
    exit 1
fi
if [[ "$EXPECTED_COMMIT" != "$HEAD_COMMIT" ]]; then
    echo "ERROR: HEAD ($HEAD_COMMIT) is not the tag commit ($EXPECTED_COMMIT). Check out $RELEASE_TAG first." >&2
    exit 1
fi
if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "ERROR: signing identity not in keychain: $SIGN_IDENTITY" >&2
    exit 1
fi
if ! security find-generic-password -s "com.apple.gke.notary.tool.password" -a "$NOTARY_PROFILE" >/dev/null 2>&1 \
   && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "ERROR: notarytool keychain profile '$NOTARY_PROFILE' not found." >&2
    echo "       Create it with:" >&2
    echo "       xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id $TEAM_ID" >&2
    exit 1
fi
if ! command -v gh >/dev/null; then
    echo "ERROR: gh CLI not installed (brew install gh)." >&2
    exit 1
fi
if ! [[ -x "$SPARKLE_ART/sign_update" ]]; then
    echo "ERROR: Sparkle sign_update missing at $SPARKLE_ART/sign_update — run 'swift package resolve'." >&2
    exit 1
fi

# --- 1. codesign Sparkle helpers (deepest-first), then framework, then app
echo "==> Codesigning Sparkle helpers"
SPARKLE_FW="$APP_DIR/Contents/Frameworks/Sparkle.framework"
# Inner XPC services + Autoupdate need their own signatures with the runtime flag.
find "$SPARKLE_FW/Versions/Current" -name "*.xpc" -o -name "Autoupdate" -o -name "Updater.app" | \
while IFS= read -r helper; do
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$helper"
done
codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$SPARKLE_FW"

echo "==> Codesigning main app"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APP_DIR"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

# --- 2. DMG
DMG_STAGE="$BUILD_DIR/dmg_stage"
rm -rf "$DMG_STAGE" && mkdir -p "$DMG_STAGE"
cp -R "$APP_DIR" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

DMG_NAME="Enshittifier-${SHORT_VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
echo "==> Creating $DMG_PATH"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "Enshittifier ${SHORT_VERSION}" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

# --- 3. Notarize + staple
echo "==> Submitting to Apple notary (this can take several minutes)"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
echo "==> Stapling"
xcrun stapler staple "$DMG_PATH"
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$DMG_PATH"

# --- 4. Sparkle EdDSA signature for the DMG
echo "==> Signing DMG with Sparkle EdDSA"
SIG_OUTPUT="$("$SPARKLE_ART/sign_update" "$DMG_PATH")"
# sign_update prints e.g.:  sparkle:edSignature="..." length="12345"
echo "$SIG_OUTPUT"
ED_SIGNATURE="$(echo "$SIG_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
DMG_LENGTH="$(echo "$SIG_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
if [[ -z "$ED_SIGNATURE" || -z "$DMG_LENGTH" ]]; then
    echo "ERROR: failed to parse sign_update output" >&2
    exit 1
fi

# --- 5. GitHub release
echo "==> Creating GitHub release $RELEASE_TAG"
PREV_TAG="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 "${RELEASE_TAG}^" 2>/dev/null || echo "")"
NOTES_FILE="$BUILD_DIR/release-notes-${RELEASE_TAG}.md"
{
    echo "## $RELEASE_TAG"
    echo
    if [[ -n "$PREV_TAG" ]]; then
        echo "### Changes since $PREV_TAG"
        echo
        git -C "$REPO_ROOT" log --pretty='* %s (%h)' "$PREV_TAG..$RELEASE_TAG"
    else
        echo "Initial release."
    fi
} > "$NOTES_FILE"
gh release create "$RELEASE_TAG" "$DMG_PATH" \
    --repo "$GH_REPO" \
    --title "$RELEASE_TAG" \
    --notes-file "$NOTES_FILE"

DMG_URL="https://github.com/${GH_REPO}/releases/download/${RELEASE_TAG}/${DMG_NAME}"

# --- 6. Update appcast on gh-pages
echo "==> Updating appcast on gh-pages"
PAGES_WT="$BUILD_DIR/gh-pages"
rm -rf "$PAGES_WT"
if git -C "$REPO_ROOT" show-ref --verify --quiet refs/heads/gh-pages \
   || git -C "$REPO_ROOT" ls-remote --exit-code origin gh-pages >/dev/null 2>&1; then
    git -C "$REPO_ROOT" fetch origin gh-pages || true
    git -C "$REPO_ROOT" worktree add "$PAGES_WT" gh-pages
else
    # First-ever release: bootstrap an orphan gh-pages from the template.
    git -C "$REPO_ROOT" worktree add --detach "$PAGES_WT"
    git -C "$PAGES_WT" checkout --orphan gh-pages
    git -C "$PAGES_WT" rm -rf . >/dev/null 2>&1 || true
    cp "$SPARKLE_APPCAST_TEMPLATE" "$PAGES_WT/appcast.xml"
fi
if [[ ! -f "$PAGES_WT/appcast.xml" ]]; then
    cp "$SPARKLE_APPCAST_TEMPLATE" "$PAGES_WT/appcast.xml"
fi

PUB_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"
NEW_ITEM=$(cat <<EOF
        <item>
            <title>${RELEASE_TAG}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${BUNDLE_VERSION}</sparkle:version>
            <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url="${DMG_URL}"
                length="${DMG_LENGTH}"
                type="application/octet-stream"
                sparkle:edSignature="${ED_SIGNATURE}" />
        </item>
EOF
)

python3 - "$PAGES_WT/appcast.xml" "$NEW_ITEM" <<'PYEOF'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
new_item = sys.argv[2]
text = path.read_text()
marker = "<!-- ENSHITTIFIER_APPCAST_INSERT_BEFORE -->"
if marker in text:
    text = text.replace(marker, new_item + "\n        " + marker, 1)
else:
    # Fallback: insert before </channel>
    text = text.replace("</channel>", new_item + "\n    </channel>", 1)
path.write_text(text)
PYEOF

git -C "$PAGES_WT" add appcast.xml
git -C "$PAGES_WT" commit -m "Appcast: ${RELEASE_TAG}"
git -C "$PAGES_WT" push origin gh-pages
git -C "$REPO_ROOT" worktree remove "$PAGES_WT"

echo
echo "==> Release ${RELEASE_TAG} published."
echo "    DMG:     $DMG_URL"
echo "    Appcast: $APPCAST_URL"
