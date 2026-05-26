# Enshittifier

## Source of truth
- GitHub: github.com/wr/enshittifier
- Linear project: Enshittifier (id: 824aa5a0-f41d-4d70-8332-240c24df9224, team: Personal)
- Branch prefix: wells/
- PR mode: ready

## What this is

Enshittifier is a macOS app (`com.enshittifier.installer.native`,
deployment target 14.0). Font Book–style grid of every installed family,
multi-select install / restore, signed + notarized DMGs with Sparkle
in-app auto-updates. The patching engine is a bundled Python script +
relocatable CPython + fontTools under `Contents/Resources/`; the Swift
app shells out to it via `PythonPatcher`. From the user's perspective
the app is the product.

## Layout

- `Sources/Enshittifier/` — Swift app (App / ContentView / Views / Model
  / Services / Patcher). The `Patcher/` directory contains read-only
  scaffolding for a hypothetical future native port; nothing in there
  is wired into the production path.
- `Resources/` — `Info.plist` (xcodegen-generated), entitlements,
  `AppIcon.icon`.
- `engine/` — the Python patching engine: `enshittifier.py` plus its
  pytest suite under `engine/tests/`. Bundled into the app at build
  time via the `engine/enshittifier.py` resource entry in `project.yml`.
- `bin/` — vendored Sparkle `generate_keys` + `sign_update` so release
  doesn't depend on `.build/artifacts/` being intact.
- `scripts/` — `build-dev.sh`, `release.sh`, `bundle-python.sh`.
- `sparkle/` — appcast template + Sparkle setup notes.

## Build / release

```bash
# Regenerate Xcode project after editing project.yml or adding/removing files
xcodegen generate

# Local dev build (adhoc-signed, fast). Drops Enshittifier.app under
# build/ and a dev DMG at the repo root.
bash scripts/build-dev.sh

# Full release (Developer ID → notarize → staple → Sparkle-sign DMG → gh
# release → push gh-pages). Bumps MARKETING_VERSION + CURRENT_PROJECT_VERSION
# in project.yml, commits, tags vX.Y.Z. Env: APPLE_TEAM_ID, GH_REPO.
bash scripts/release.sh X.Y.Z

# Run the Python engine's tests
cd engine && python3 -m pytest tests/
```

### Things that have bitten us

- **Run `xcodegen generate` after** touching `project.yml`, adding/removing
  `.swift` files, or moving anything under `Resources/`. `xcodebuild`
  will appear to succeed against a stale project without picking up the
  new files.
- **The bundle ID `com.enshittifier.installer.native` is load-bearing.**
  Sparkle's update channel is keyed off it; changing it orphans every
  existing install from future updates. The `.native` legacy in the
  string is from an earlier era and is not worth chasing.
- **Sparkle helpers need re-signing after xcodebuild.** The SwiftPM build
  leaves Updater.app / XPC services signed with Sparkle's distribution
  identity, which Apple's notary rejects. `scripts/release.sh` re-signs
  them bottom-up with our Developer ID — don't strip that step.
- **`SUPublicEDKey` lives in `project.yml`**, not a separate file. The
  matching private key is in the developer's login Keychain (managed by
  `bin/{generate_keys,sign_update}`, vendored from Sparkle). Losing the
  private key permanently locks out auto-update for users on a prior
  version.
- **Pushing to `gh-pages` should auto-trigger the Pages workflow** but
  has occasionally failed to do so; if a release lands and the appcast
  isn't updating, run `gh workflow run pages.yml` manually.
