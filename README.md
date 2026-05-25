# enshittifier

Patches any TTF or OTF font so the standalone word **"ai"** (in any case
combination — `ai`, `AI`, `Ai`, `aI`) is rendered as 💩. Untouched everywhere
else: `painter`, `rain`, `said`, `email`, `naïve`, `Hawaii`, etc.

## Usage

```bash
python3 enshittifier.py path/to/Font.ttf       # or .otf
```

By default the script **patches the font in place**, leaving its original
name intact (so the OS treats the patched font as the same font). The
original is moved to `Font.ttf.bak` first.

If `Font.ttf.bak` already exists, the script refuses to overwrite it. Move
or delete that file, or pass `--no-backup-yes-i-am-an-idiot` to skip the
backup entirely.

## Options

```text
-o OUT.ttf                          Write to a different path instead of
                                    overwriting the input. Skips the .bak step.
--demo                              Also write a demo.html next to the output.
--svg PATH.svg                      Use a custom SVG as the glyph source.
--alias NAME                        Add an additional family name to match.
                                    Repeatable. See "Aliases" below.
--no-alias                          Disable the automatic no-spaces alias.
--no-backup-yes-i-am-an-idiot       When overwriting in place, skip the .bak.
-q, --quiet                         Suppress all informational output (stdout).
                                    Errors still go to stderr.
```

## Aliases

The same font often gets referenced by different family-name strings on
the web. For example, Inter's variable file is named "Inter Variable" but
many sites use `font-family: "InterVariable"` (no space).

**By default**, if the font's family name contains spaces, enshittifier
automatically adds a no-spaces alias. So patching `Inter Variable` makes
the file match both `"Inter Variable"` and `"InterVariable"` with no flags.
Pass `--no-alias` to skip this.

**`--alias`** adds further explicit aliases on top of (or instead of) the
auto one:

```bash
python3 enshittifier.py InterVariable.ttf --alias "Inter"
# Now matches "Inter Variable", "InterVariable", and "Inter".
```

The mechanism: each alias is written into the `name` table at an
additional language ID. Most font matchers index a font under every
distinct family-name string they find across language records. Caveats:

- **Reliable:** macOS Core Text, Chrome/Edge/Safari, iOS, modern Linux.
- **Mixed:** older Windows GDI consumers may only read en-US (the original
  family name).
- **Don't alias to names that already exist on your system.** OS-level
  font matching becomes ambiguous; you'll get whichever the font cache
  picked first.

For 100% reliable matching across many names, save the font multiple times
with each alias as the primary family name. That's two files instead of
one, but every consumer will agree on what each is called.

## Notes

The `--svg` flag accepts any SVG with one or more `<path>` elements. All
`d` attributes are concatenated; subpaths can be filled or holes (non-zero
winding rule applies, same as in browsers). Y is flipped automatically.

Requires `fonttools` and `svgpathtools` (`pip install fonttools svgpathtools`).

## How it works

1. **Adds a glyph** — a monochrome poop silhouette (parsed from an embedded
   SVG, or from your `--svg` file) mapped to U+1F4A9. For TTF, cubics are
   converted to quadratics via cu2qu and written to the `glyf` table. For
   OTF, cubics go directly into `CFF ` as Type 2 CharStrings.
2. **Adds a format-12 cmap subtable** — required because U+1F4A9 lives in the
   supplementary plane, beyond what the standard format-4 subtables can encode.
3. **Compiles GSUB lookups** in `calt` and `liga` features. The core rule is a
   chained contextual ligature with two `ignore` guards:

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

   `@letter` is built dynamically from the font's cmap (Basic Latin + Latin-1
   Supplement + Latin Extended-A letters). The two `ignore` rules suppress the
   substitution when "ai" sits next to another letter on either side.

4. **Saves atomically.** The patched font is written to a sibling temp
   file first, then the original is moved to `.bak` (unless skipped),
   then the temp is renamed to the final destination. If anything fails
   before the rename step, the original is untouched.

## Caveats

- **CFF2 (variable OTF) not yet supported.** Static TTF (glyf) and static OTF
  (CFF) both work. CFF2 uses a different charstring format and would need
  different plumbing.
- **WOFF/WOFF2 inputs are rejected** with a clear error message. Convert to
  TTF/OTF first using `pyftsubset` or `woff2_decompress`, then patch.
- **Only `calt` and `liga` features are replaced.** All other GSUB features
  (fractions, small caps, old-style figures, etc.) are preserved. GPOS
  (kerning) is also preserved.
- **Monochrome glyph.** No COLR/CPAL/SVG color tables. The poop renders in
  whatever color the surrounding text uses.
- **Lowercase Latin only.** The substitution targets Basic Latin `a/A/i/I`
  — Cyrillic, Greek, fullwidth, etc. don't trigger.

## Licensing

Patch your own fonts. Don't redistribute patched copies of fonts you aren't
licensed to redistribute. The patched font carries the original's name and
metadata, which means it inherits the original's license too.
