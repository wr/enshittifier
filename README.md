# Enshittifier

Patches any TTF, OTF, WOFF, or WOFF2 font so the standalone word **"ai"** (in any case combination — `ai`, `AI`, `Ai`, `aI`) is rendered as 💩. Untouched everywhere else: `painter`, `rain`, `said`, `email`, `naïve`, `Hawaii`, etc.

Requires macOS 14 or later.

## Install

Download the latest DMG from the [Releases page](https://github.com/wr/enshittifier/releases) and drag Enshittifier to Applications. Updates arrive automatically via Sparkle.

## How it works

Font Book–style grid of every installed family. Select one or more fonts, click **Enshittify**, the app shells out to a bundled Python patching engine that rewrites each font in place (originals preserved as `.bak`). **Restore** swaps the originals back.

Per font, the patcher:

1. **Adds a glyph** — a monochrome poop silhouette (parsed from an embedded SVG) mapped to U+1F4A9. For TTF, cubics are converted to quadratics via cu2qu and written to the `glyf` table. For OTF, cubics go directly into `CFF ` as Type 2 CharStrings.
2. **Adds a format-12 cmap subtable** — required because U+1F4A9 lives in the supplementary plane, beyond what the standard format-4 subtables can encode.
3. **Compiles GSUB lookups** in `calt` and `liga` features. The core rule is a chained contextual ligature with two `ignore` guards:

    ```
    lookup ai_to_poop {
        sub a i by poop;
        sub A I by poop;
        sub A i by poop;
        sub a I by poop;
    } ai_to_poop;

    feature calt {
        ignore sub @letter [a A]' [i I]';
        ignore sub [a A]' [i I]' @letter;
        sub [a A]' lookup ai_to_poop [i I]';
    } calt;
    ```

   `@letter` is built dynamically from the font's cmap (Basic Latin + Latin-1 Supplement + Latin Extended-A letters). The two `ignore` rules suppress the substitution when "ai" sits next to another letter on either side.

4. **Saves atomically.** The patched font is written to a sibling temp file first, then the original is moved to `.bak`, then the temp is renamed to the final destination. If anything fails before the rename step, the original is untouched.

## Caveats

- **CFF2 (variable OTF) not yet supported.** Static TTF (`glyf`) and static OTF (`CFF `) both work. CFF2 uses a different charstring format and would need different plumbing.
- **Existing GSUB is extended, not replaced.** All other features (fractions, small caps, old-style figures, etc.) are preserved. The enshittification lookups are appended to the font's existing `calt` and `liga` feature records. GPOS (kerning) is preserved.
- **Monochrome glyph.** No COLR/CPAL/SVG color tables. The poop renders in whatever color the surrounding text uses.
- **Lowercase Latin only.** The substitution targets Basic Latin `a/A/i/I` — Cyrillic, Greek, fullwidth, etc. don't trigger.

## Privacy

Enshittifier reads the fonts you tell it to patch and writes them back. Nothing is logged or sent anywhere. The only outbound request is the Sparkle update check.

## Credits

fontTools, cu2qu, svgpathtools, and Sparkle.

## License

[AGPL-3.0](LICENSE). © 2026 Wells Riley.

### Fonts you patch

Patch your own fonts. Don't redistribute patched copies of fonts you aren't licensed to redistribute — the patched file carries the original font's name, metadata, and license terms, so it inherits the original's restrictions. Many commercial font EULAs explicitly prohibit modification or the creation of derivative works.
