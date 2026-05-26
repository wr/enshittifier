# Sparkle

Sparkle wiring for the native installer. The Sparkle Swift package itself
is declared in `installer-swift/project.yml` under `packages:`; Xcode (via
xcodegen) resolves + embeds `Sparkle.framework` automatically.

## Files

- `appcast.template.xml` — bootstrap template for the live appcast.
  Used the first time a release is cut to seed an orphan `gh-pages`
  branch; subsequent releases just prepend a new `<item>` to the
  already-published `appcast.xml`.

The Sparkle EdDSA **public** key is committed directly in
`installer-swift/project.yml` under `SUPublicEDKey` (it's not secret —
verifies signatures, doesn't create them). The matching **private** key
lives in the developer's login Keychain, managed by
`installer-swift/bin/{generate_keys,sign_update}` (vendored from
Sparkle's binary artifact).

## Live URL

`https://wr.github.io/enshittifier/appcast.xml` (served from the
`gh-pages` branch root via `.github/workflows/pages.yml`).

After the first release lands and `gh-pages` exists, enable GitHub Pages
in repo settings → Pages → Source → GitHub Actions. Until that's done,
the in-app updater will fail silently ("Sparkle could not load update
info") — by design, since there's literally nothing to download yet.

## One-shot setup checklist (per developer machine)

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
3. Confirm Sparkle private key exists in Keychain (idempotent):
   `installer-swift/bin/generate_keys`
   (Prints the existing public key if one is already stored. If a fresh
   key is generated, paste the printed public key into `project.yml`
   under `SUPublicEDKey` and `xcodegen generate`. Never regenerate
   without coordinating — losing the private key permanently locks out
   auto-update for users on a prior version.)
4. `gh auth status` — must show authenticated for `github.com`.
