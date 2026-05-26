# enshittifier

## Source of truth
- GitHub: github.com/wr/enshittifier
- Linear project: Enshittifier (id: 824aa5a0-f41d-4d70-8332-240c24df9224, team: Personal)
- Branch prefix: wells/
- PR mode: ready

## What this is

Two artifacts under one repo:
- `enshittifier.py` (repo root) — the actual font patcher. CLI usable with
  `python3 enshittifier.py path/to/Font.ttf`. The native installer also
  bundles + shells out to it via `PythonFallbackPatcher`.
- `installer-swift/` — a native SwiftUI macOS app (Font Book–style grid)
  that drives the patcher across the user's installed font library.
  Signed + notarized DMGs ship via Sparkle to the appcast on `gh-pages`.

## Native installer build / release

```bash
# Regenerate Xcode project after editing project.yml or adding/removing files
cd installer-swift && xcodegen generate

# Local dev build (adhoc-signed, fast). Drops Enshittifier.app under
# installer-swift/build/ and a dev DMG at the repo root.
bash installer-swift/scripts/build-dev.sh

# Full release (Developer ID → notarize → staple → Sparkle-sign DMG → gh
# release → push gh-pages). Bumps MARKETING_VERSION + CURRENT_PROJECT_VERSION
# in project.yml, commits, tags vX.Y.Z. Env: APPLE_TEAM_ID, GH_REPO.
bash installer-swift/scripts/release.sh X.Y.Z
```

### Things that have bitten us

- **Run `xcodegen generate` after** touching `project.yml`, adding/removing
  `.swift` files, or moving anything under `Resources/`. `xcodebuild`
  will appear to succeed against a stale project without picking up the
  new files.
- **The bundle ID `com.enshittifier.installer.native` is load-bearing.**
  Sparkle's update channel is keyed off it; changing it orphans every
  existing install from future updates. Don't.
- **Sparkle helpers need re-signing after xcodebuild.** The SwiftPM build
  leaves Updater.app / XPC services signed with Sparkle's distribution
  identity, which Apple's notary rejects. `scripts/release.sh` re-signs
  them bottom-up with our Developer ID — don't strip that step.
- **`SUPublicEDKey` lives in `project.yml`**, not a separate file. The
  matching private key is in the developer's login Keychain (managed by
  `installer-swift/bin/{generate_keys,sign_update}`, vendored from
  Sparkle). Losing the private key permanently locks out auto-update for
  users on a prior version.
