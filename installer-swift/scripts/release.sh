#!/usr/bin/env bash
#
# Full release pipeline for Enshittifier:
#   1. Bump MARKETING_VERSION + CURRENT_PROJECT_VERSION in project.yml,
#      regenerate the Xcode project.
#   2. xcodebuild Release with Developer ID + hardened runtime.
#   3. Bundle python-build-standalone + pip deps; deep-codesign every
#      embedded Mach-O.
#   4. Re-sign Sparkle helpers (XPC services, Updater.app, Autoupdate)
#      with our Developer ID — required because the SwiftPM-produced
#      framework comes signed with Sparkle's distribution identity, which
#      Apple's notary rejects.
#   5. Build a fancy DMG via create-dmg.
#   6. Notarize, staple, EdDSA-sign the DMG with Sparkle's sign_update.
#   7. Create the GitHub Release, attach the DMG.
#   8. Prepend a new <item> to appcast.xml on the gh-pages worktree.
#
# Usage:  scripts/release.sh <version>      (e.g. 1.2.3)
#
# Required env (set once, then forget — recommend ~/.zshrc):
#   APPLE_TEAM_ID            10-char team ID
#   GH_REPO                  e.g. wr/enshittifier
#
# Optional env:
#   NOTARY_PROFILE           keychain profile for `xcrun notarytool`,
#                            default: enshittifier-notarize
#   SIGN_IDENTITY            full code-signing identity string, default:
#                            "Developer ID Application: Wells Riley (P3V9EZ525M)"
#
# One-time per machine:
#   * Apple Developer Program membership + Developer ID Application cert
#     installed in the login keychain.
#   * Notarytool keychain profile created once:
#       xcrun notarytool store-credentials enshittifier-notarize \
#           --apple-id <appleid> --team-id $APPLE_TEAM_ID
#   * Sparkle EdDSA private key in keychain (idempotent):
#       installer-swift/bin/generate_keys
#     (The matching PUBLIC key is committed at SUPublicEDKey in project.yml.
#     Never regenerate without coordinating — losing the private key locks
#     out auto-update for everyone on a prior version.)
#   * `gh auth status` reports authenticated for github.com.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <version>  (e.g. 1.2.3)" >&2
    exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must look like MAJOR.MINOR.PATCH (got '$VERSION')" >&2
    exit 2
fi
TAG="v$VERSION"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$INSTALLER_DIR")"
BUILD_DIR="$INSTALLER_DIR/build"
DD_DIR="$BUILD_DIR/dd"
APP_NAME="Enshittifier"

NOTARY_PROFILE="${NOTARY_PROFILE:-enshittifier-notarize}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Wells Riley (P3V9EZ525M)}"
APPCAST_URL="https://wr.github.io/enshittifier/appcast.xml"

cd "$INSTALLER_DIR"

require() {
    if [[ -z "${!1:-}" ]]; then echo "error: $1 is not set" >&2; exit 1; fi
}
require APPLE_TEAM_ID
require GH_REPO

# --- preflight ------------------------------------------------------------
echo "==> Preflight"
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    echo "error: working tree dirty. Commit or stash before releasing." >&2
    exit 1
fi
if ! command -v xcodegen >/dev/null; then
    echo "error: xcodegen not installed (brew install xcodegen)" >&2
    exit 1
fi
if ! command -v create-dmg >/dev/null; then
    echo "error: create-dmg not installed (brew install create-dmg)" >&2
    exit 1
fi
if ! command -v gh >/dev/null; then
    echo "error: gh CLI not installed (brew install gh)" >&2
    exit 1
fi
if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "error: signing identity not in keychain: $SIGN_IDENTITY" >&2
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: notarytool profile '$NOTARY_PROFILE' missing." >&2
    echo "       xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
    echo "             --apple-id <id> --team-id $APPLE_TEAM_ID" >&2
    exit 1
fi
if ! [[ -x "$INSTALLER_DIR/bin/sign_update" ]]; then
    echo "error: $INSTALLER_DIR/bin/sign_update missing or not executable" >&2
    exit 1
fi

# --- bump versions --------------------------------------------------------
echo "==> Bumping version to $VERSION"
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
# Auto-bump CURRENT_PROJECT_VERSION (monotonic build number; Sparkle compares
# this, not the marketing string, when deciding whether to offer an update).
CURRENT_BUILD=$(sed -nE 's/.*CURRENT_PROJECT_VERSION: "([0-9]+)".*/\1/p' project.yml)
NEW_BUILD=$((CURRENT_BUILD + 1))
sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$NEW_BUILD\"/" project.yml
echo "    marketing: $VERSION"
echo "    build:     $NEW_BUILD"

echo "==> xcodegen generate"
xcodegen generate

# --- build ----------------------------------------------------------------
echo "==> xcodebuild Release"
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DD_DIR" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
    clean build >/dev/null

BUILT_APP="$DD_DIR/Build/Products/Release/$APP_NAME.app"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
rm -rf "$APP_PATH"
cp -R "$BUILT_APP" "$APP_PATH"

# --- bundled Python -------------------------------------------------------
"$SCRIPT_DIR/bundle-python.sh" "$APP_PATH"

echo "==> Codesigning embedded Python (every Mach-O)"
# Notarization requires every Mach-O inside the bundle carry its own
# hardened-runtime signature. Walk the venv top-down and sign anything
# that's a .dylib / .so / executable.
{
    find "$APP_PATH/Contents/Resources/venv" -type f -name "*.dylib"
    find "$APP_PATH/Contents/Resources/venv" -type f -name "*.so"
    find "$APP_PATH/Contents/Resources/venv/bin" -type f -perm +111
} | sort -u | while IFS= read -r mach_o; do
    [[ -f "$mach_o" ]] || continue
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$mach_o" 2>/dev/null \
        || echo "    ! skipped (not a Mach-O): $mach_o" >&2
done

# --- re-sign Sparkle helpers ---------------------------------------------
# xcodebuild signs Sparkle.framework with our identity, but the nested
# helpers (Updater.app, XPC services, Autoupdate) come pre-signed with
# Sparkle's distribution identity. Apple's notary rejects mixed identities.
# Re-sign bottom-up.
echo "==> Re-signing Sparkle helpers"
SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SPARKLE_VER="$SPARKLE_FW/Versions/Current"

for bundle in \
    "$SPARKLE_VER/Updater.app" \
    "$SPARKLE_VER/XPCServices/Downloader.xpc" \
    "$SPARKLE_VER/XPCServices/Installer.xpc"; do
    [[ -d "$bundle" ]] || continue
    inner="$bundle/Contents/MacOS/$(basename "$bundle" | sed 's/\.[^.]*$//')"
    if [[ -f "$inner" ]]; then
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$inner"
    fi
done
if [[ -f "$SPARKLE_VER/Autoupdate" ]]; then
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$SPARKLE_VER/Autoupdate"
fi
for bundle in \
    "$SPARKLE_VER/XPCServices/Downloader.xpc" \
    "$SPARKLE_VER/XPCServices/Installer.xpc" \
    "$SPARKLE_VER/Updater.app"; do
    [[ -d "$bundle" ]] || continue
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$bundle"
done
codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$SPARKLE_FW"

# --- final app re-sign ----------------------------------------------------
echo "==> Re-signing app shell"
codesign --force --options runtime --timestamp \
    --entitlements "$INSTALLER_DIR/Resources/Enshittifier.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# --- DMG ------------------------------------------------------------------
# Single DMG per release, named without a version suffix. The version is
# already encoded in the release tag (/v$VERSION/Enshittifier.dmg), so the
# marketing site can link to /releases/latest/download/Enshittifier.dmg.
DMG_NAME="Enshittifier.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
echo "==> Creating $DMG_NAME"
rm -f "$DMG_PATH"
DMG_STAGE="$BUILD_DIR/dmg_stage"
rm -rf "$DMG_STAGE" && mkdir -p "$DMG_STAGE"
cp -R "$APP_PATH" "$DMG_STAGE/"
create-dmg \
    --volname "Enshittifier $VERSION" \
    --window-pos 200 120 \
    --window-size 540 360 \
    --icon-size 96 \
    --icon "$APP_NAME.app" 140 180 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 400 180 \
    "$DMG_PATH" \
    "$DMG_STAGE" >/dev/null

# --- notarize + staple ----------------------------------------------------
echo "==> Submitting to Apple notary (this can take a few minutes)"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
echo "==> Stapling"
xcrun stapler staple "$DMG_PATH"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$DMG_PATH"

# --- Sparkle signature ----------------------------------------------------
echo "==> Signing DMG with Sparkle EdDSA"
SIG_OUTPUT="$("$INSTALLER_DIR/bin/sign_update" "$DMG_PATH")"
echo "$SIG_OUTPUT"
ED_SIGNATURE="$(echo "$SIG_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
DMG_LENGTH="$(echo "$SIG_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
if [[ -z "$ED_SIGNATURE" || -z "$DMG_LENGTH" ]]; then
    echo "error: could not parse sign_update output" >&2
    exit 1
fi

# --- commit version bump + tag --------------------------------------------
echo "==> Committing version bump and tagging $TAG"
# xcodegen rewrote project.pbxproj with the new MARKETING_VERSION /
# CURRENT_PROJECT_VERSION literals; include it so a fresh clone opens in
# Xcode at the released version without needing xcodegen installed.
git -C "$REPO_ROOT" add \
    installer-swift/project.yml \
    installer-swift/Resources/Info.plist \
    installer-swift/Enshittifier.xcodeproj/project.pbxproj
git -C "$REPO_ROOT" commit -m "Release ${TAG}"
git -C "$REPO_ROOT" tag -a "$TAG" -m "$TAG"
git -C "$REPO_ROOT" push origin HEAD "$TAG"
HEAD_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"

# --- GitHub release -------------------------------------------------------
echo "==> Creating GitHub release $TAG"
PREV_TAG="$(git -C "$REPO_ROOT" describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || echo "")"
NOTES_FILE="$BUILD_DIR/release-notes-${TAG}.md"
{
    echo "## $TAG"
    echo
    if [[ -n "$PREV_TAG" ]]; then
        echo "### Changes since $PREV_TAG"
        echo
        git -C "$REPO_ROOT" log --pretty='* %s (%h)' "$PREV_TAG..$TAG"
    else
        echo "Initial release."
    fi
} > "$NOTES_FILE"
gh release create "$TAG" "$DMG_PATH" \
    --repo "$GH_REPO" \
    --target "$HEAD_COMMIT" \
    --title "$TAG" \
    --notes-file "$NOTES_FILE"

DMG_URL="https://github.com/${GH_REPO}/releases/download/${TAG}/${DMG_NAME}"

# --- appcast update -------------------------------------------------------
echo "==> Updating appcast.xml on gh-pages"
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
    cp "$INSTALLER_DIR/sparkle/appcast.template.xml" "$PAGES_WT/appcast.xml"
fi
if [[ ! -f "$PAGES_WT/appcast.xml" ]]; then
    cp "$INSTALLER_DIR/sparkle/appcast.template.xml" "$PAGES_WT/appcast.xml"
fi

PUB_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"
NEW_ITEM=$(cat <<EOF
        <item>
            <title>${TAG}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${NEW_BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
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
    text = text.replace("</channel>", new_item + "\n    </channel>", 1)
path.write_text(text)
PYEOF

git -C "$PAGES_WT" add appcast.xml
git -C "$PAGES_WT" commit -m "Appcast: ${TAG}"
git -C "$PAGES_WT" push origin gh-pages
git -C "$REPO_ROOT" worktree remove "$PAGES_WT"

echo
echo "==> Release ${TAG} published."
echo "    DMG:     $DMG_URL"
echo "    Appcast: $APPCAST_URL"
