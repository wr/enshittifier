# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Source of truth
- GitHub: github.com/wr/enshittifier
- Linear project: Enshittifier (id: 824aa5a0-f41d-4d70-8332-240c24df9224, team: Personal)
- Branch prefix: wells/
- PR mode: ready

## What this is

Enshittifier is a macOS app (`com.enshittifier.installer.native`, deployment target 14.0). Font Book–style grid of every installed family, multi-select install / restore, signed + notarized DMGs with Sparkle in-app auto-updates. The patching engine is a bundled Python script + relocatable CPython + fontTools under `Contents/Resources/`; the Swift app shells out to it via `PythonPatcher`. From the user's perspective the app is the product.

## Commands

```bash
# Regenerate Xcode project after editing project.yml or adding/removing Swift files
xcodegen generate

# Local dev build (adhoc-signed, fast). Drops Enshittifier.app under
# build/. Pass --dmg to also build Enshittifier-dev.dmg at the repo root.
bash scripts/build-dev.sh

# Full release (Developer ID → notarize → staple → Sparkle-sign DMG → gh
# release → push gh-pages). Bumps MARKETING_VERSION + CURRENT_PROJECT_VERSION
# in project.yml, commits, tags vX.Y.Z. Env: APPLE_TEAM_ID, GH_REPO.
bash scripts/release.sh X.Y.Z

# Run the Python engine's pytest suite. Also wired into the pre-push hook
# below — activate once per clone with the line under it.
bash scripts/run-tests.sh
git config core.hooksPath .githooks
```

## First-time developer setup (per machine)

Required to cut a release; not required for dev builds or running tests.

1. Confirm signing identity is in Keychain:
   `security find-identity -v -p codesigning | grep "Developer ID"`
2. Confirm notarytool keychain profile exists:
   `xcrun notarytool history --keychain-profile enshittifier-notarize`
   If not, create with:
   ```
   xcrun notarytool store-credentials enshittifier-notarize \
       --apple-id <your-apple-id> \
       --team-id P3V9EZ525M
   ```
3. Confirm Sparkle private key exists in Keychain (idempotent — prints the existing public key if one's already stored):
   `bin/generate_keys`
   If a fresh key is generated, paste the printed public key into `project.yml` under `SUPublicEDKey` and `xcodegen generate`. **Never regenerate without coordinating** — losing the private key permanently locks out auto-update for users on a prior version.
4. `gh auth status` — must show authenticated for `github.com`.
5. **After the first release lands** and `gh-pages` exists, enable GitHub Pages in repo settings → Pages → Source → **GitHub Actions**. Until that's done, the in-app updater will fail silently ("Sparkle could not load update info") — by design, since there's literally nothing to download yet.

## Testing

Pure-logic tests for the font patcher live under `engine/tests/` and use pytest. `scripts/run-tests.sh` runs the suite against `engine/enshittifier.py`; the `.githooks/pre-push` hook calls it, so a failing test blocks `git push` once the hook is enabled.

What's worth testing here: anything pure-logic on the font binary side — glyph addition, cmap subtable shape, GSUB lookup structure, the `ignore` guards, the atomic save / `.bak` flow, CLI arg handling, alias mode, the `--demo` rendering. What's NOT worth testing in this repo: the SwiftUI app shell (`AppModel`, `FamilyListView`, `InstallProgressView`) — those touch `NSFontManager`, `CTFontManagerCopyAvailableFontFamilyNames`, the real `Library/Fonts` filesystem, and `NSWorkspace`. Stand them up by hand in a dev build instead.

The Swift `Patcher/` directory contains read-only scaffolding for a hypothetical future native port (`Patcher.swift`, `CmapTablePatcher.swift`, `NameTablePatcher.swift`, `BinaryReader.swift`, `OpenTypeFile.swift`). Nothing in there is wired into the production path — production routes through `PythonPatcher.swift` shelling out to the bundled engine. Don't write tests for that scaffolding; it's not load-bearing.

### Things that have bitten us

- **Run `xcodegen generate` after** touching `project.yml`, adding/removing `.swift` files, or moving anything under `Resources/`. `xcodebuild` will appear to succeed against a stale project without picking up the new files.
- **The bundle ID `com.enshittifier.installer.native` is load-bearing.** Sparkle's update channel is keyed off it; changing it orphans every existing install from future updates. The `.native` legacy in the string is from an earlier era and is not worth chasing.
- **Sparkle helpers need re-signing after xcodebuild.** The SwiftPM build leaves Updater.app / XPC services signed with Sparkle's distribution identity, which Apple's notary rejects. `scripts/release.sh` re-signs them bottom-up with our Developer ID — don't strip that step.
- **Every Mach-O inside the bundled Python venv must be individually re-signed** with hardened runtime + timestamp before notarization, or the notary rejects with a wall of "code object is not signed at all" errors. `release.sh` walks `Contents/Resources/venv` and signs every `.dylib` / `.so` / executable; if you add new Python deps that ship native extensions, double-check they got picked up by the walk.
- **`SUPublicEDKey` lives in `project.yml`**, not a separate file. The matching private key is in the developer's login Keychain (managed by `bin/{generate_keys,sign_update}`, vendored from Sparkle). Losing the private key permanently locks out auto-update for users on a prior version.
- **Pushing to `gh-pages` should auto-trigger the Pages workflow** but has occasionally failed to do so; if a release lands and the appcast isn't updating, run `gh workflow run pages.yml` manually.
- **The appcast lives on the `gh-pages` branch in this repo**, not on a separate site repo. `release.sh` checks out a gh-pages worktree under `build/gh-pages/`, prepends a new `<item>`, commits, and pushes. If something interrupts the script mid-flight, `git worktree list` will show the leftover — remove with `git worktree remove build/gh-pages`.

## Architecture

### Patching pipeline

The Swift app drives everything; the Python script does the actual font surgery.

```
FamilyListView (multi-select grid)
   ↓
AppModel.enshittify(selected:)
   ↓
InstallService — for each font file:
   ↓
PythonPatcher.patch(fontURL:) — shells out to bundled engine
   ↓
Resources/venv/bin/python3 engine/enshittifier.py <font>
   ↓ writes patched .ttf/.otf/.woff/.woff2 atomically, originals → .bak
FontCacheFlusher.flush() — atsutil databases destroy
```

`PythonPatcher` is the only Swift code path that runs in production. The `Sources/Enshittifier/Patcher/` Swift files (`Patcher`, `CmapTablePatcher`, `NameTablePatcher`, `OpenTypeFile`, `BinaryReader`) are exploratory scaffolding for a hypothetical future native port; nothing in there is wired into the install path. Leave them alone unless you're actually doing the port.

### Bundled Python

`scripts/bundle-python.sh` copies a relocatable [python-build-standalone](https://github.com/astral-sh/python-build-standalone) interpreter into `Contents/Resources/venv/`, then `pip install`s `fontTools`, `cu2qu`, and `svgpathtools` into it. At runtime, `PythonPatcher` invokes the bundled interpreter directly via `Bundle.main.url(forResource:)`. No system Python required, no `PATH` lookups.

The engine source file (`engine/enshittifier.py`) is also copied in as a Resource via `project.yml`'s `engine/enshittifier.py → buildPhase: resources` entry. So the Swift binary lives in `Contents/MacOS/Enshittifier`, the engine lives in `Contents/Resources/enshittifier.py`, and the Python interpreter + deps live in `Contents/Resources/venv/`.

### Sparkle wiring

`UpdaterController.swift` instantiates `SPUStandardUpdaterController` with `SUEnableAutomaticChecks=true` + a 24-hour `SUScheduledCheckInterval`. The appcast feed is `https://wr.github.io/enshittifier/appcast.xml` (served from the `gh-pages` branch via the `pages.yml` workflow). Each appcast `<item>` carries:

- `sparkle:version` — the integer `CURRENT_PROJECT_VERSION` (monotonic build number). **This is what Sparkle compares**, not `MARKETING_VERSION`.
- `sparkle:shortVersionString` — the user-visible semver string.
- `sparkle:edSignature` — EdDSA signature over the DMG bytes, produced by `bin/sign_update` against the private key in the login keychain. `SUPublicEDKey` in `Info.plist` is the matching public anchor.

`release.sh` produces all three and prepends a new `<item>` into `appcast.xml` on `gh-pages`.

### Origins manifest

`Resources/OriginsManifest.json` (managed by `OriginsManifest.swift`) records, per patched font, the original `.bak` path so **Restore** knows which file to swap back. Without it, restore is ambiguous when the user has multiple copies of a family. The manifest is rewritten atomically each time a patch / restore completes.

### Font cache flush

After install or restore, `FontCacheFlusher.flush()` runs `atsutil databases -remove` so macOS picks up the new bytes immediately. Without it, already-rendered text keeps showing the cached glyphs until next login.

## File layout (where to look)

- `Sources/Enshittifier/App.swift` / `ContentView.swift` — entry point + root view.
- `Sources/Enshittifier/Model/` — `AppModel` (top-level state), `FontFamily`, `FontStyle`, `OriginsManifest`.
- `Sources/Enshittifier/Views/` — `FamilyListView` (multi-select grid), `InstallProgressView`, `PoopGlyph` (the SVG-derived 💩 used in the UI).
- `Sources/Enshittifier/Services/` — `FontDiscovery` (lists installed families), `InstallService` / `RestoreService` (drive `PythonPatcher`), `DataFontCache`, `FontCacheFlusher`, `Paths`, `UpdaterController`.
- `Sources/Enshittifier/Patcher/` — read-only scaffolding for a hypothetical future native port. Not wired in.
- `engine/enshittifier.py` — the Python patching engine. Bundled into the app at build time.
- `engine/tests/` — pytest suite for the engine.
- `Resources/` — `Info.plist` (xcodegen-generated), entitlements, `AppIcon.icon`.
- `scripts/` — `build-dev.sh`, `release.sh`, `bundle-python.sh`, `run-tests.sh`, `update_appcast.py`.
- `bin/` — vendored Sparkle `generate_keys` + `sign_update` so release doesn't depend on `.build/artifacts/` being intact.
- `.githooks/pre-push` — runs `scripts/run-tests.sh`; activate with `git config core.hooksPath .githooks`.

## Style guidelines

### Code comments

Be brief. Comment only when the *why* isn't obvious from the code itself — hidden constraints, subtle invariants, workarounds for specific bugs, behavior that would surprise a reader. Describe what the code *is*, not what you did or which user request prompted it. Don't reference tasks, fixes, or callers ("added for X", "handles the case from W-NN") — that belongs in commit messages / PR descriptions and rots as the code evolves. If removing the comment wouldn't confuse a future reader, don't write it.

## Issue tracking & workflow

Linear + Git workflow lives in `~/.claude/CLAUDE.md` (Linear SSOT + Git workflow sections). The `## Source of truth` block at the top of this file scopes those behaviors to this repo.

Enshittifier-specific notes:

- **Project URL:** https://linear.app/wells-riley/project/enshittifier-824aa5a0f41d
- **Statuses available:** Backlog, Todo, Todo (AI), In Progress, In Review, Done, Canceled, Duplicate.
- **Branches:** `wells/w-NN-short-slug` (lowercase `w-NN` + kebab slug — matches Linear's auto-generated `gitBranchName`).
- **Commits / PR titles:** reference the uppercase ID (e.g. `W-42: fix glyph rounding on variable fonts`) so Linear auto-links.
- **Always open a PR**, even for solo work — don't push directly to `main`. One commit per logical change.
