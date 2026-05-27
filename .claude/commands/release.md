---
description: Build, notarize, and ship a new Enshittifier release
argument-hint: <version> e.g. 0.3.0
---

# Release Enshittifier

Drive a full release of Enshittifier end-to-end: pre-flight checks → build & sign → bundle Python → notarize → Sparkle-sign → GitHub release → appcast update on `gh-pages`.

The user invoked: `/release $ARGUMENTS`

If `$ARGUMENTS` is empty, ask the user for the target version (e.g. `0.3.0`) and stop. Otherwise treat `$ARGUMENTS` as `<version>` (strip a leading `v` if present).

The heavy lifting is in `scripts/release.sh` — this skill is a thin wrapper that does pre-flight, collects release notes, runs the script, and verifies.

---

## Step 1 — Pre-flight (read-only; bail loudly if anything fails)

Run these in parallel, then report the results:

```bash
# Working tree must be clean — release.sh refuses to run otherwise.
git status --porcelain

# Must be on main and up to date.
git rev-parse --abbrev-ref HEAD
git fetch origin main --quiet && git rev-list --left-right --count main...origin/main

# Required tools.
command -v xcodebuild xcodegen create-dmg gh python3
xcrun --find notarytool stapler

# Required env vars (mirror scripts/release.sh).
printenv APPLE_TEAM_ID GH_REPO

# Notarytool keychain profile exists. Default profile name is
# enshittifier-notarize unless NOTARY_PROFILE is set.
xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-enshittifier-notarize}" 2>&1 | head -3

# Sparkle keypair: public key must be embedded.
plutil -extract SUPublicEDKey raw Resources/Info.plist

# What version are we coming from?
grep -E "MARKETING_VERSION|CURRENT_PROJECT_VERSION" project.yml
```

**Fail-fast checks** — stop and report if any of these are true:

- Working tree has any uncommitted changes. release.sh refuses to start dirty.
- Branch is not `main`, or local main is behind `origin/main`.
- Any required tool is missing — tell the user to `brew install xcodegen create-dmg gh` or install Xcode CLT.
- `APPLE_TEAM_ID` or `GH_REPO` is unset.
- `notarytool history` errors with "keychain item not found" — instruct the user to run once:
  `xcrun notarytool store-credentials enshittifier-notarize --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID"`
- `SUPublicEDKey` is missing or null — instruct the user to run `./bin/generate_keys`, paste the public key into `project.yml`, then `xcodegen generate`.
- Requested version is not strictly greater than the current `MARKETING_VERSION` (semver compare). If it isn't, ask the user to confirm a downgrade or correction.

## Step 2 — Collect release notes (optional)

`release.sh` auto-generates release notes from `git log $PREV_TAG..HEAD` and uses them for the GitHub Release. That's usually fine for a small project. If the user wants to write their own notes, save them to a temp file path now and `gh release edit` them in after the script finishes (Step 4).

Show the user the commit list and ask whether the auto-generated notes are sufficient:

```bash
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [[ -n "$LAST_TAG" ]]; then
    git log --oneline "$LAST_TAG..HEAD"
fi
```

Don't proceed without confirming.

## Step 3 — Run release.sh

```bash
bash scripts/release.sh <version>
```

This script:

1. Bumps `MARKETING_VERSION` to `<version>` and auto-increments `CURRENT_PROJECT_VERSION` in `project.yml`.
2. Runs `xcodegen generate`.
3. Builds Release with `Developer ID Application` signing + hardened runtime + secure timestamp.
4. Calls `scripts/bundle-python.sh` to embed a relocatable CPython + fontTools + cu2qu + svgpathtools into `Contents/Resources/venv/`.
5. Walks the venv and codesigns every `.dylib` / `.so` / executable Mach-O with hardened runtime + timestamp (required for notarization).
6. Re-signs every helper inside `Sparkle.framework` (XPC services, `Updater.app`, `Autoupdate`) — SwiftPM's default Sparkle signatures are rejected by Apple notary.
7. Wraps `Enshittifier.app` in a DMG via `create-dmg`.
8. Submits to `notarytool` (waits ~2–10 min), then staples both DMG and app.
9. Calls `./bin/sign_update` to produce an EdDSA signature for the DMG.
10. Commits the `project.yml` / `Info.plist` / `project.pbxproj` version-bump as `Release v<version>`, tags `v<version>`, pushes both to origin.
11. Creates a GitHub Release with the DMG attached + notes from `git log $PREV_TAG..HEAD`.
12. Adds a `gh-pages` worktree under `build/gh-pages/`, runs `scripts/update_appcast.py` to prepend the new release entry, commits, pushes, removes the worktree.

Do **not** suppress output — surface the script's progress so the user can see notarization timing. If the script exits non-zero at any step, stop the skill and report the failure with the last 30 lines of output.

## Step 4 — (Optional) Replace auto-generated release notes

Only if the user wrote custom notes in Step 2:

```bash
gh release edit "v<version>" --repo "$GH_REPO" --notes-file <path-from-step-2>
gh release view "v<version>" --repo "$GH_REPO"
```

## Step 5 — Post-release verification

Run in parallel and report results:

```bash
# Release exists with the DMG attached.
gh release view "v<version>" --repo "$GH_REPO" --json assets,name,tagName

# Appcast contains the new entry.
curl -sf "https://wr.github.io/enshittifier/appcast.xml" | head -40

# Sparkle EdDSA signature on the appcast matches what was uploaded.
curl -sf "https://wr.github.io/enshittifier/appcast.xml" | grep -A1 "v<version>" | grep -o 'sparkle:edSignature="[^"]*"'

# Pages workflow picked up the gh-pages push.
gh run list --workflow=pages.yml --limit 1 --json status,conclusion,createdAt
```

Confirm to the user:

- Release URL: `https://github.com/$GH_REPO/releases/tag/v<version>`
- DMG path on disk: `build/Enshittifier.dmg`
- Reminder: to test the update flow, launch a previously-installed older copy of Enshittifier and use **Enshittifier → Check for Updates** — Sparkle should offer the new version.

---

## Gotchas

- **Apple Notary can be slow.** Step 3 may hang for 5–15 min on `notarytool submit`. Don't kill it. If it actually fails, `xcrun notarytool log <submission-id> --keychain-profile enshittifier-notarize` shows why.
- **`spctl` pre-notarization assessment failure is expected** on the first signing of a build. The script's `codesign --verify` is the authoritative check; the post-stapling DMG is what matters end-to-end.
- **Sparkle private key.** The script reads it from your login keychain by default (where `./bin/generate_keys` stashed it). If you've moved machines, restore the keychain item or set `SPARKLE_PRIVATE_KEY_PATH=/path/to/exported.key`. Losing the key means anyone on a prior version can never auto-update again.
- **Bundled Python signing.** If you've added Python deps in `engine/requirements.txt` that ship native extensions (`.so` files), double-check they got picked up by release.sh's `find … -name "*.so"` walk. Notary will reject the DMG if any embedded Mach-O is unsigned.
- **Pages workflow.** Pushing to `gh-pages` should auto-trigger `pages.yml`, but has occasionally failed to do so. If the appcast at `https://wr.github.io/enshittifier/appcast.xml` is stale after a release, run `gh workflow run pages.yml` manually.
- **gh-pages worktree cleanup.** release.sh removes `build/gh-pages` on success. If the script dies mid-flight, `git worktree list` will show the leftover — clean up with `git worktree remove build/gh-pages` before retrying.
