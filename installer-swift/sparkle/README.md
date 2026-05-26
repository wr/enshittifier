# Sparkle

Sparkle wiring for the native installer. This dir holds the public-key
reference and the appcast template; everything else is handled by
`installer-swift/build-app.sh --release` and SwiftPM.

## Files

- `public-key.txt` — EdDSA **public** key, base64. Embedded as
  `SUPublicEDKey` in `Info.plist` at release-build time. The matching
  **private** key lives in Wells' login Keychain (managed entirely by
  Sparkle's `generate_keys` / `sign_update`). One key per developer
  across all Sparkle-using apps — don't regenerate without coordinating.
- `appcast.template.xml` — bootstrap template for the live appcast.
  Used the first time a release is cut to seed an orphan `gh-pages`
  branch; subsequent releases just prepend a new `<item>` to the
  already-published `appcast.xml`.

## Live URL

`https://wr.github.io/enshittifier/appcast.xml` (served from the
`gh-pages` branch root).

After the first release lands and `gh-pages` exists, enable GitHub
Pages in the repo settings → Pages → Source → `gh-pages` branch /
root. Until that's done, the in-app updater will fail silently
("Sparkle could not load update info") — by design, since there's
literally nothing to download yet.

## Tooling

`generate_keys` and `sign_update` are part of the Sparkle Swift Package
binary artifact, resolved into
`installer-swift/.build/artifacts/sparkle/Sparkle/bin/`. The release
script invokes `sign_update <dmg>` after notarization to produce the
EdDSA signature that appears as `sparkle:edSignature` in the appcast.

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
   `installer-swift/.build/checkouts/Sparkle/bin/generate_keys`
   (Prints the existing public key if one is already stored.)
4. `gh auth status` — must show authenticated for `github.com`.
