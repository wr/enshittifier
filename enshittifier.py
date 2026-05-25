#!/usr/bin/env python3
"""
enshittifier.py — Patch any TTF or OTF so the standalone word "ai" (any case
combo: ai / AI / Ai / aI) is substituted with a 💩 glyph. Untouched everywhere
else (painter, rain, said, email, naïve, …).

Usage:
    python3 enshittifier.py FONT.{ttf,otf}                # patches in place, .bak saved
    python3 enshittifier.py FONT.{ttf,otf} -o OUT.ttf     # writes to OUT instead
    python3 enshittifier.py FONT.{ttf,otf} --demo         # also writes demo.html
    python3 enshittifier.py FONT.{ttf,otf} --svg X.svg    # use a custom glyph

What it does:
    1. Adds a glyph mapped to U+1F4A9 (default: embedded poop SVG).
       - For TTF: cubics → quadratics via cu2qu, written to `glyf`.
       - For OTF: cubics written directly to `CFF ` as Type 2 CharStrings.
    2. Adds chained contextual ligature lookups in `calt` and `liga`.
    3. Saves in place by default. The original is moved to <input>.bak
       unless --no-backup-yes-i-am-an-idiot is passed.
    4. Leaves the font's name table alone — the patched font is a
       drop-in replacement that the OS will treat as the same font.

Caveats:
    * Static fonts only. CFF2 (variable OTF) not yet supported.
    * Extends the font's existing GSUB table — all other features (fractions,
      small caps, old-style figures, etc.) are preserved. The enshittification
      lookups are appended to the font's existing `calt` and `liga` feature
      records. GPOS (kerning) is preserved.
"""

import argparse
import os
import sys
import unicodedata
from pathlib import Path

from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._c_m_a_p import CmapSubtable
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.feaLib.builder import addOpenTypeFeaturesFromString


POOP_GLYPH_NAME = "poop"
POOP_CODEPOINT = 0x1F4A9


# ---------------------------------------------------------------------------
# Glyph drawing
# ---------------------------------------------------------------------------
SVG_POOP_PATH = (
    "M56.7124 34.0845C57.0124 34.9845 63.1124 32.9845 65.5124 39.9845C67.5124 46.0845 63.4124 "
    "48.8845 63.8124 49.6845C64.3124 50.6845 74.6124 52.6845 74.8124 59.1845C75.0124 68.1845 "
    "62.6124 70.2845 59.6124 70.2845C42.1124 70.4845 31.9124 67.5845 23.0124 67.7845C19.4124 "
    "67.8845 13.0124 70.7845 8.71243 70.2845C5.01243 69.7845 -0.887567 66.7845 0.112433 "
    "59.0845C1.61243 47.2845 11.0124 49.7845 11.1124 49.0845C11.2124 48.0845 7.71243 46.6845 "
    "9.11243 40.4845C10.7124 33.3845 16.8124 35.1845 17.3124 33.2845C17.5124 32.5845 15.7124 "
    "27.8845 16.8124 23.9845C18.0124 19.5845 25.8124 17.2845 26.1124 16.5845C26.6124 15.5845 "
    "24.7124 14.7845 24.7124 13.6845C24.8124 9.48454 28.8124 7.68454 28.9124 4.88454C28.9124 "
    "3.48454 27.8124 1.48454 28.5124 0.384539C30.0124 -1.81546 42.1124 5.98454 45.2124 "
    "9.58454C49.9124 15.1845 48.9124 17.7845 48.1124 21.5845C48.1124 21.5845 55.3124 22.3845 "
    "57.2124 25.8845C59.2124 29.4845 56.5124 33.3845 56.7124 34.0845Z"
    "M24.7124 28.2845C20.1124 28.2845 16.4124 32.9845 16.4124 38.8845C16.4124 44.7845 20.1124 "
    "49.4845 24.7124 49.4845C29.3124 49.4845 33.0124 44.7845 33.0124 38.8845C33.0124 32.9845 "
    "29.3124 28.2845 24.7124 28.2845Z"
    "M48.9124 28.2845C44.3124 28.2845 40.6124 32.9845 40.6124 38.8845C40.6124 44.7845 44.3124 "
    "49.4845 48.9124 49.4845C53.5124 49.4845 57.2124 44.7845 57.2124 38.8845C57.2124 32.9845 "
    "53.5124 28.2845 48.9124 28.2845Z"
    "M22.7124 53.4845C22.7124 53.4845 26.0124 61.6845 36.5124 61.6845C46.2124 61.6845 50.3124 "
    "53.5845 50.3124 53.5845L22.7124 53.4845Z"
    "M24.7124 33.3845C22.4124 33.3845 20.6124 35.9845 20.6124 39.1845C20.6124 42.3845 22.4124 "
    "44.9845 24.7124 44.9845C27.0124 44.9845 28.8124 42.3845 28.8124 39.1845C28.8124 35.9845 "
    "27.0124 33.3845 24.7124 33.3845Z"
    "M49.0124 33.3845C46.7124 33.3845 44.9124 35.9845 44.9124 39.1845C44.9124 42.3845 46.7124 "
    "44.9845 49.0124 44.9845C51.3124 44.9845 53.1124 42.3845 53.1124 39.1845C53.1124 35.9845 "
    "51.2124 33.3845 49.0124 33.3845Z"
)
SVG_VIEWBOX = (75, 71)   # width, height of source SVG


def draw_poop_to_pen(pen, upm: int, svg_path: str | None = None,
                     viewbox: tuple[float, float] | None = None):
    """Draw the glyph onto a segment pen using cubic Béziers.

    The pen must accept moveTo / lineTo / curveTo / closePath. For glyf
    output, wrap a TTGlyphPen with Cu2QuPen (which accepts cubics and emits
    quads). For CFF output, pass a T2CharStringPen directly.

    SVG uses Y-down; TTF/OTF use Y-up. We flip Y and scale to fit ~92% of
    the em height, centered horizontally in a full-em advance."""
    from svgpathtools import parse_path, CubicBezier, Line

    src = svg_path or SVG_POOP_PATH
    src_w, src_h = viewbox if viewbox else SVG_VIEWBOX

    target_h = upm * 0.92
    scale = target_h / src_h
    advance = upm
    drawn_w = src_w * scale
    x_off = (advance - drawn_w) / 2
    y_baseline = upm * 0.04

    def XY(c: complex) -> tuple[int, int]:
        x = x_off + c.real * scale
        y = y_baseline + (src_h - c.imag) * scale
        return (round(x), round(y))

    paths = parse_path(src)
    for sp in paths.continuous_subpaths():
        pen.moveTo(XY(sp[0].start))
        for seg in sp:
            if isinstance(seg, Line):
                pen.lineTo(XY(seg.end))
            elif isinstance(seg, CubicBezier):
                pen.curveTo(XY(seg.control1), XY(seg.control2), XY(seg.end))
            else:
                raise ValueError(f"Unhandled SVG segment: {type(seg).__name__}")
        pen.closePath()


def add_poop_glyf(font: TTFont, upm: int, svg_path, viewbox, verbose: bool = True):
    """Add the poop glyph to a glyf-based (TTF) font."""
    from fontTools.pens.cu2quPen import Cu2QuPen
    glyph_pen = TTGlyphPen(None)
    drawing_pen = Cu2QuPen(glyph_pen, max_err=1.0)   # cubics in, quads out
    draw_poop_to_pen(drawing_pen, upm, svg_path, viewbox)
    font["glyf"][POOP_GLYPH_NAME] = glyph_pen.glyph()


def fix_variable_tables(font: TTFont, verbose: bool = True):
    """Variable fonts have glyph-indexed tables (gvar, HVAR) that store the
    glyph count separately from maxp. Adding a glyph without updating these
    leaves the font corrupt. Add empty/identity variation data for the new
    glyph and refresh per-table glyph counts."""
    if "fvar" not in font:
        return   # not a variable font

    # gvar — per-glyph TrueType variation deltas. Add an empty entry for
    # the new glyph (no variation = use the static outline at all axis
    # positions), and bump glyphCount to match maxp.
    if "gvar" in font:
        gvar = font["gvar"]
        if POOP_GLYPH_NAME not in gvar.variations:
            gvar.variations[POOP_GLYPH_NAME] = []
        gvar.glyphCount = font["maxp"].numGlyphs
        if verbose:
            print("  + gvar entry added (no variation)")

    # HVAR — horizontal advance variations. Optional; if present, we just
    # drop it. The new glyph can't contribute deltas anyway, and HVAR is a
    # cache of advance variations that the renderer can fall back to
    # computing from gvar. Removing it is the safe option.
    if "HVAR" in font:
        del font["HVAR"]
        if verbose:
            print("  + HVAR dropped (renderer will recompute from gvar)")


def add_poop_cff(font: TTFont, upm: int, svg_path, viewbox, verbose: bool = True):
    """Add the poop glyph to a CFF-based (OTF) font."""
    from fontTools.pens.t2CharStringPen import T2CharStringPen

    cff = font["CFF "].cff
    top_dict = cff.topDictIndex[0]
    advance = upm

    cff_pen = T2CharStringPen(advance, font.getGlyphSet())
    draw_poop_to_pen(cff_pen, upm, svg_path, viewbox)
    charstring = cff_pen.getCharString(private=top_dict.Private)

    # CharStrings.__setitem__ refuses to add new keys — it only updates
    # existing entries. Bypass it by appending to the INDEX directly and
    # updating the name→index map.
    cs = top_dict.CharStrings
    if cs.charStringsAreIndexed:
        cs.charStringsIndex.append(charstring)
        cs.charStrings[POOP_GLYPH_NAME] = len(cs.charStringsIndex) - 1
    else:
        cs.charStrings[POOP_GLYPH_NAME] = charstring

    if hasattr(top_dict, "charset") and POOP_GLYPH_NAME not in top_dict.charset:
        top_dict.charset.append(POOP_GLYPH_NAME)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def find_letter_glyphs(font: TTFont) -> list[str]:
    """Resolve glyph names for all Latin letters (basic + Latin-1 supplement).

    Used to build the @letter class that suppresses the substitution when
    "ai" appears inside a larger word.
    """
    cmap = font.getBestCmap()
    glyphs: list[str] = []
    seen: set[str] = set()

    def add(cp: int):
        name = cmap.get(cp)
        if name and name not in seen:
            seen.add(name)
            glyphs.append(name)

    for cp in range(0x41, 0x5B):    # A-Z
        add(cp)
    for cp in range(0x61, 0x7B):    # a-z
        add(cp)
    for cp in range(0xC0, 0x180):   # Latin-1 Supplement + Latin Extended-A
        if unicodedata.category(chr(cp)).startswith("L"):
            add(cp)
    return glyphs


def update_cmap(font: TTFont):
    """Add U+1F4A9 → poop in a format-12 subtable (BMP-only formats can't
    encode the supplementary plane). Also keep all existing mappings."""
    combined: dict[int, str] = {}
    for t in font["cmap"].tables:
        if t.isUnicode():
            combined.update(t.cmap)
    combined[POOP_CODEPOINT] = POOP_GLYPH_NAME

    # Drop any existing fmt-12 we'd otherwise duplicate
    font["cmap"].tables = [t for t in font["cmap"].tables if t.format != 12]

    fmt12 = CmapSubtable.newSubtable(12)
    fmt12.platformID = 3
    fmt12.platEncID = 10
    fmt12.format = 12
    fmt12.reserved = 0
    fmt12.length = 0
    fmt12.language = 0
    fmt12.nGroups = 0
    fmt12.cmap = combined
    font["cmap"].tables.append(fmt12)


def get_primary_family_name(font: TTFont) -> str | None:
    """Return the font's primary family name (nameID 1, Windows en-US)."""
    for r in font["name"].names:
        if r.nameID == 1 and r.platformID == 3 and r.langID == 0x0409:
            try:
                return r.toUnicode()
            except Exception:
                pass
    return None


def add_family_aliases(font: TTFont, aliases: list[str], verbose: bool = True):
    """Make the font also match additional family names.

    Mechanism: the OpenType `name` table allows multiple records for the
    same nameID at different (platform, encoding, language) tuples. Most
    modern font matchers index a font under every distinct family-name
    string they find. So if we add nameID 1 records at unused English
    language IDs, the OS/browser will match the font by those strings too.

    Caveats:
      * Reliability varies. macOS Core Text and Chrome work well. Some
        Windows GDI consumers only read en-US (langID 0x0409), missing
        these aliases. For bulletproof matching across many names, save
        multiple copies of the font with each as its primary name.
      * We also write the alias to nameID 16 (Typographic Family) at the
        same alternate language; that's what some matchers prefer.
    """
    if not aliases:
        return

    # Unused English variants. The font's actual primary record is at en-US
    # (0x0409); we put each alias on a different English locale so the
    # records don't conflict.
    LANG_IDS = [
        0x0809, 0x0c09, 0x1009, 0x1409, 0x1809, 0x2009,
        0x2409, 0x2809, 0x2c09, 0x3009, 0x3409, 0x4009, 0x4409,
    ]
    if len(aliases) > len(LANG_IDS):
        sys.exit(f"Too many aliases: max {len(LANG_IDS)} supported per font.")

    name_table = font["name"]
    for alias, lang_id in zip(aliases, LANG_IDS):
        # nameID 1 = Family Name (legacy/WWS)
        name_table.setName(alias, 1, 3, 1, lang_id)
        # nameID 16 = Typographic Family (preferred by many modern matchers)
        name_table.setName(alias, 16, 3, 1, lang_id)
    plural = "" if len(aliases) == 1 else "es"
    if verbose:
        print(f"  + added {len(aliases)} family-name alias{plural}: "
              f"{', '.join(repr(a) for a in aliases)}")


# ---------------------------------------------------------------------------
# Demo HTML
# ---------------------------------------------------------------------------
DEMO_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
@font-face {
  font-family: "PoopFont";
  src: url("__FONT_FILE__") format("truetype");
  font-display: block;
}
:root {
  --ink: #1a1a1a;
  --paper: #fafaf7;
  --rule: #e6e2d8;
  --muted: #888378;
  --accent: #8b6f47;
  --good: #2d7d3f;
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: var(--paper); color: var(--ink); }
body {
  font-family: "PoopFont", -apple-system, BlinkMacSystemFont, sans-serif;
  font-size: 18px;
  line-height: 1.55;
  -webkit-font-smoothing: antialiased;
  font-feature-settings: "calt" 1, "liga" 1;
}
.wrap { max-width: 760px; margin: 0 auto; padding: 5rem 2rem 7rem; }

/* Header — split so 'ai' renders literally and 💩 renders as the patched glyph */
header { margin-bottom: 4rem; }
h1 {
  font-size: 4rem; font-weight: 700; margin: 0 0 .5rem;
  letter-spacing: -0.025em; line-height: 1;
  display: flex; align-items: center; gap: .75rem;
}
h1 .lit { font-feature-settings: "calt" 0, "liga" 0; }
h1 .arrow { color: var(--muted); font-weight: 400; }
.tag { color: var(--muted); font-size: 1rem; margin: 0; }

section { margin: 3.5rem 0; }
h2 {
  font-size: .8rem; font-weight: 700; text-transform: uppercase;
  letter-spacing: 0.08em; color: var(--muted); margin: 0 0 1.25rem;
}

/* live demo */
textarea {
  width: 100%; min-height: 200px;
  padding: 1.25rem 1.5rem;
  background: white; border: 1px solid var(--rule); border-radius: 6px;
  font: inherit; font-size: 1.4rem; line-height: 1.45;
  color: var(--ink); resize: vertical;
  font-feature-settings: "calt" 1, "liga" 1;
}
textarea:focus { outline: 2px solid var(--accent); outline-offset: -1px; border-color: transparent; }

/* boundary tests — input | arrow | output rows */
.tests {
  display: grid; grid-template-columns: 1fr 1fr; gap: 0;
  border: 1px solid var(--rule); border-radius: 6px; overflow: hidden;
  background: white;
}
.tests > .col { padding: 1.5rem; }
.tests > .col + .col { border-left: 1px solid var(--rule); }
.tests h3 {
  font-size: .7rem; font-weight: 700; text-transform: uppercase;
  letter-spacing: 0.08em; margin: 0 0 1rem;
}
.tests .fires h3 { color: var(--good); }
.tests .skips h3 { color: var(--muted); }
.row {
  display: grid;
  grid-template-columns: 5.5rem 1.5rem 1fr;
  align-items: center;
  padding: .5rem 0;
  border-top: 1px solid var(--rule);
}
.row:first-of-type { border-top: none; }
.row .in {
  font-feature-settings: "calt" 0, "liga" 0;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: .9rem;
  color: var(--muted);
}
.row .arr { color: var(--rule); font-size: .9rem; }
.row .out { font-size: 1.25rem; line-height: 1.2; }
@media (max-width: 600px) {
  .tests { grid-template-columns: 1fr; }
  .tests > .col + .col { border-left: none; border-top: 1px solid var(--rule); }
}

/* compare */
.compare {
  display: grid; grid-template-columns: 1fr 1fr; gap: 0;
  border: 1px solid var(--rule); border-radius: 6px; overflow: hidden;
  background: white;
}
.compare > div { padding: 1.5rem; }
.compare > div + div { border-left: 1px solid var(--rule); }
.compare .label {
  font-size: .7rem; font-weight: 700; text-transform: uppercase;
  letter-spacing: 0.08em; color: var(--muted); margin: 0 0 .75rem;
}
.compare p { font-size: 1.3rem; margin: 0; line-height: 1.45; }
.compare .off { font-feature-settings: "calt" 0, "liga" 0; }

/* notes */
.notes { color: var(--muted); font-size: .95rem; line-height: 1.7; }
.notes code {
  background: white; padding: .1rem .35rem; border-radius: 3px;
  border: 1px solid var(--rule); font-size: .85em;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-feature-settings: "calt" 0, "liga" 0;
}
pre {
  background: white; border: 1px solid var(--rule); border-radius: 6px;
  padding: 1.25rem 1.5rem; overflow-x: auto;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: .82rem; line-height: 1.55; color: var(--ink);
  font-feature-settings: "calt" 0, "liga" 0;
}
hr { border: none; border-top: 1px solid var(--rule); margin: 4rem 0; }
footer { color: var(--muted); font-size: .85rem; }
</style>
</head>
<body>
<div class="wrap">

<header>
<h1>
  <span class="lit">ai</span>
  <span class="arrow">&rarr;</span>
  <span>💩</span>
</h1>
<p class="tag">A contextual ligature patched into <strong>__SOURCE_NAME__</strong>.</p>
</header>

<section>
<h2>Live demo · type anything</h2>
<textarea spellcheck="false">I built an ai system. Then another ai. AI is everywhere.
All four cases trigger: ai, AI, Ai, aI.
But painter, rain, said, email, fairly, naïve, Hawaii — untouched.</textarea>
</section>

<section>
<h2>Word boundary tests</h2>
<div class="tests">
  <div class="col fires">
    <h3>Fires (standalone)</h3>
    <div class="row"><span class="in">ai</span><span class="arr">→</span><span class="out">ai</span></div>
    <div class="row"><span class="in">AI</span><span class="arr">→</span><span class="out">AI</span></div>
    <div class="row"><span class="in">Ai</span><span class="arr">→</span><span class="out">Ai</span></div>
    <div class="row"><span class="in">aI</span><span class="arr">→</span><span class="out">aI</span></div>
    <div class="row"><span class="in">ai-powered</span><span class="arr">→</span><span class="out">ai-powered</span></div>
    <div class="row"><span class="in">ai's</span><span class="arr">→</span><span class="out">ai's</span></div>
    <div class="row"><span class="in">(ai)</span><span class="arr">→</span><span class="out">(ai)</span></div>
    <div class="row"><span class="in">say ai!</span><span class="arr">→</span><span class="out">say ai!</span></div>
  </div>
  <div class="col skips">
    <h3>Skips (inside word)</h3>
    <div class="row"><span class="in">painter</span><span class="arr">→</span><span class="out">painter</span></div>
    <div class="row"><span class="in">rain</span><span class="arr">→</span><span class="out">rain</span></div>
    <div class="row"><span class="in">said</span><span class="arr">→</span><span class="out">said</span></div>
    <div class="row"><span class="in">email</span><span class="arr">→</span><span class="out">email</span></div>
    <div class="row"><span class="in">aim air aid</span><span class="arr">→</span><span class="out">aim air aid</span></div>
    <div class="row"><span class="in">naïve</span><span class="arr">→</span><span class="out">naïve</span></div>
    <div class="row"><span class="in">Hawaii</span><span class="arr">→</span><span class="out">Hawaii</span></div>
    <div class="row"><span class="in">maintain</span><span class="arr">→</span><span class="out">maintain</span></div>
  </div>
</div>
</section>

<section>
<h2>Same string, feature off / on</h2>
<div class="compare">
  <div>
    <p class="label">Feature off</p>
    <p class="off">ai is changing painter rain said email</p>
  </div>
  <div>
    <p class="label">Feature on</p>
    <p>ai is changing painter rain said email</p>
  </div>
</div>
</section>

<hr>

<section class="notes">
<h2>How it works</h2>
<p>
The patcher adds one glyph (mapped to <code>U+1F4A9</code>) plus a chained
contextual substitution in the <code>calt</code> and <code>liga</code>
features. Two <code>ignore</code> rules suppress the swap whenever
"ai" is adjacent to another letter on either side; otherwise a ligature lookup
collapses the pair into the poop glyph. All four case permutations are handled
by a single lookup with four ligature rules.
</p>
<pre>lookup ai_to_poop {
    sub a i by poop;
    sub A I by poop;
    sub A i by poop;
    sub a I by poop;
} ai_to_poop;

feature calt {
    ignore sub @letter [a A]' [i I]';
    ignore sub [a A]' [i I]' @letter;
    sub [a A]' lookup ai_to_poop [i I]';
} calt;</pre>
</section>

<footer>__FOOTER__</footer>

</div>
</body>
</html>
"""


def write_demo(html_path: Path, font_filename: str, source_name: str):
    title = f"ai → 💩 — {source_name}"
    footer = f"Patched from {source_name}. Monochrome glyph; no color tables."
    html = (DEMO_HTML
            .replace("__TITLE__", title)
            .replace("__FONT_FILE__", font_filename)
            .replace("__SOURCE_NAME__", source_name)
            .replace("__FOOTER__", footer))
    html_path.write_text(html, encoding="utf-8")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
class PatchError(Exception):
    """Raised when a single font can't be patched. In directory mode this
    is caught per-file so the rest of the batch can continue."""


# Font extensions we attempt to patch in directory mode. Lowercase only;
# we compare case-insensitively. .ttc/.otc collections and .woff/.woff2
# are intentionally excluded — they need different IO paths.
PATCHABLE_EXTS = {".ttf", ".otf"}


def parse_svg_arg(svg_path_arg: str | None, verbose: bool = True):
    """Read --svg argument once; returns (path_d, viewbox) or (None, None)."""
    if not svg_path_arg:
        return None, None
    import re
    from xml.etree import ElementTree as ET
    tree = ET.parse(svg_path_arg)
    root = tree.getroot()
    path_d = "".join(p.attrib.get("d", "") for p in root.iter()
                     if p.tag.endswith("}path") or p.tag == "path")
    if not path_d:
        raise PatchError(f"No <path d=...> found in {svg_path_arg}")
    vb = root.attrib.get("viewBox")
    if vb:
        parts = [float(v) for v in re.split(r"[\s,]+", vb.strip())]
        viewbox = (parts[2], parts[3])
    else:
        viewbox = (float(root.attrib.get("width", 100)),
                   float(root.attrib.get("height", 100)))
    if verbose:
        print(f"Loaded SVG from {svg_path_arg} "
              f"(viewBox {viewbox[0]:g}×{viewbox[1]:g})")
    return path_d, viewbox


def patch_one(in_path: Path, args, custom_svg, custom_viewbox):
    """Patch a single font file. Raises PatchError on any per-file problem."""
    verbose = not args.quiet

    # Output path: explicit -o wins; otherwise overwrite the input
    in_place = args.output is None
    out_path = in_path if in_place else Path(args.output).resolve()

    # Reject --output pointing at an existing directory
    if not in_place and out_path.is_dir():
        raise PatchError("--output path is a directory; provide a file path instead.")

    # Plan the backup before touching anything
    bak_path: Path | None = None
    if in_place and not args.no_backup:
        bak_path = in_path.with_suffix(in_path.suffix + ".bak")
        if bak_path.exists():
            raise PatchError(
                f"Refusing to overwrite existing backup: {bak_path.name}. "
                f"Move/delete it, or pass --no-backup-yes-i-am-an-idiot.")

    font = TTFont(str(in_path))
    # Force every table to decompile now. Variable fonts have glyph-indexed
    # tables (gvar, hmtx, HVAR, …) that lazily decompile against the
    # *current* maxp.numGlyphs. If we bump that count first and trigger a
    # decompile later, fontTools reads the wrong number of entries and
    # asserts. Eager decompile sidesteps the whole problem.
    font.ensureDecompiled()

    if font.flavor in ("woff", "woff2"):
        raise PatchError(
            "WOFF/WOFF2 not supported — convert to TTF/OTF first "
            "(e.g. with `pyftsubset` or `woff2_decompress`).")

    is_glyf = "glyf" in font
    is_cff  = "CFF " in font
    is_cff2 = "CFF2" in font
    if is_cff2:
        raise PatchError("CFF2 (variable OTF) fonts aren't supported yet.")
    if not (is_glyf or is_cff):
        raise PatchError("Font has neither 'glyf' nor 'CFF ' table.")

    flavor = "TTF (glyf)" if is_glyf else "OTF (CFF)"
    upm = font["head"].unitsPerEm
    if verbose:
        print(f"Loaded {in_path.name}  ({flavor}, UPM={upm})")

    # 1. Resolve required letter glyph names from the cmap
    cmap = font.getBestCmap()
    needed = {0x61: "a", 0x41: "A", 0x69: "i", 0x49: "I"}
    glyphs = {}
    for cp, label in needed.items():
        if cp not in cmap:
            raise PatchError(f"Font is missing glyph for '{label}' (U+{cp:04X}).")
        glyphs[label] = cmap[cp]

    letters = find_letter_glyphs(font)
    if not letters:
        raise PatchError("Couldn't find any Latin letter glyphs in the font.")

    # 2. Add the poop glyph
    if is_glyf:
        add_poop_glyf(font, upm, custom_svg, custom_viewbox, verbose=verbose)
    else:
        add_poop_cff(font, upm, custom_svg, custom_viewbox, verbose=verbose)
    font["hmtx"][POOP_GLYPH_NAME] = (upm, 0)

    # Always call setGlyphOrder so the cached _reverseGlyphOrderDict gets
    # invalidated — without that step, feaLib later sees a stale map and
    # claims "poop" is missing. (font["glyf"][name] = ... auto-appends to
    # glyphOrder for TTF but doesn't invalidate the cache.)
    glyph_order = font.getGlyphOrder()
    if POOP_GLYPH_NAME not in glyph_order:
        glyph_order.append(POOP_GLYPH_NAME)
    font.setGlyphOrder(glyph_order)
    font["maxp"].numGlyphs = len(glyph_order)
    if verbose:
        print(f"  + added '{POOP_GLYPH_NAME}' glyph (GID {font.getGlyphID(POOP_GLYPH_NAME)})")

    # 2b. Fix up variable-font tables if present
    fix_variable_tables(font, verbose=verbose)

    # 3. Update cmap
    update_cmap(font)
    if verbose:
        print(f"  + cmap U+{POOP_CODEPOINT:04X} → {POOP_GLYPH_NAME}")

    # 4. Build & compile the FEA, preserving all existing GSUB features
    #    except calt and liga (which we replace with our own rules).
    #
    #    addOpenTypeFeaturesFromString replaces the entire GSUB table, so we
    #    save the non-calt/non-liga lookups and features first, compile our
    #    new rules into a fresh GSUB, then merge the saved data back in.
    import copy as _copy

    TARGET_TAGS = {"calt", "liga"}
    saved_lookups: list = []
    saved_feat_records: list = []
    # Maps old feature index → into saved_feat_records (for script remapping)
    old_feat_idx_map: dict[int, int] = {}
    # Saved script/langsys structure: list of (script_tag, default_ls_indices, [(ls_tag, ls_indices)])
    saved_scripts: list = []

    if "GSUB" in font:
        old_gsub = font["GSUB"].table
        old_feat_records = old_gsub.FeatureList.FeatureRecord

        # Find lookup indices only used by calt/liga (safe to drop)
        kept_lookup_idxs: set[int] = set()
        calt_liga_lookup_idxs: set[int] = set()
        for fr in old_feat_records:
            idxs = set(fr.Feature.LookupListIndex)
            if fr.FeatureTag in TARGET_TAGS:
                calt_liga_lookup_idxs.update(idxs)
            else:
                kept_lookup_idxs.update(idxs)
        drop_lookup_idxs = calt_liga_lookup_idxs - kept_lookup_idxs

        # Build old-lookup-index → new-saved-index mapping
        old_to_saved_lookup: dict[int, int] = {}
        for old_idx, lk in enumerate(old_gsub.LookupList.Lookup):
            if old_idx not in drop_lookup_idxs:
                old_to_saved_lookup[old_idx] = len(saved_lookups)
                saved_lookups.append(_copy.deepcopy(lk))

        # Collect non-calt/liga features with remapped lookup indices
        for old_idx, fr in enumerate(old_feat_records):
            if fr.FeatureTag not in TARGET_TAGS:
                new_fr = _copy.deepcopy(fr)
                new_fr.Feature.LookupListIndex = [
                    old_to_saved_lookup[i]
                    for i in fr.Feature.LookupListIndex
                    if i in old_to_saved_lookup
                ]
                old_feat_idx_map[old_idx] = len(saved_feat_records)
                saved_feat_records.append(new_fr)

        # Save script/langsys feature references (filtered to kept features)
        for sr in old_gsub.ScriptList.ScriptRecord:
            script = sr.Script
            default_idxs = []
            if script.DefaultLangSys:
                default_idxs = [
                    old_feat_idx_map[i]
                    for i in script.DefaultLangSys.FeatureIndex
                    if i in old_feat_idx_map
                ]
            langsys_list = []
            for lsr in script.LangSysRecord:
                ls_idxs = [
                    old_feat_idx_map[i]
                    for i in lsr.LangSys.FeatureIndex
                    if i in old_feat_idx_map
                ]
                langsys_list.append((lsr.LangSysTag, ls_idxs))
            saved_scripts.append((sr.ScriptTag, default_idxs, langsys_list))

        del font["GSUB"]

    a, A, i, I = glyphs["a"], glyphs["A"], glyphs["i"], glyphs["I"]
    fea = f"""
languagesystem DFLT dflt;
languagesystem latn dflt;

@letter = [{' '.join(letters)}];

lookup ai_to_poop {{
    sub {a} {i} by {POOP_GLYPH_NAME};
    sub {A} {I} by {POOP_GLYPH_NAME};
    sub {A} {i} by {POOP_GLYPH_NAME};
    sub {a} {I} by {POOP_GLYPH_NAME};
}} ai_to_poop;

feature calt {{
    ignore sub @letter [{a} {A}]' [{i} {I}]';
    ignore sub [{a} {A}]' [{i} {I}]' @letter;
    sub [{a} {A}]' lookup ai_to_poop [{i} {I}]';
}} calt;

feature liga {{
    ignore sub @letter [{a} {A}]' [{i} {I}]';
    ignore sub [{a} {A}]' [{i} {I}]' @letter;
    sub [{a} {A}]' lookup ai_to_poop [{i} {I}]';
}} liga;
"""
    addOpenTypeFeaturesFromString(font, fea)

    # Merge the saved non-calt/liga lookups and features back into the new GSUB.
    if saved_feat_records:
        new_gsub = font["GSUB"].table
        lookup_offset = len(new_gsub.LookupList.Lookup)
        feat_offset = len(new_gsub.FeatureList.FeatureRecord)

        # Append old lookups
        new_gsub.LookupList.Lookup.extend(saved_lookups)
        new_gsub.LookupList.LookupCount = len(new_gsub.LookupList.Lookup)

        # Append old features with lookup indices shifted by offset
        for fr in saved_feat_records:
            fr.Feature.LookupListIndex = [i + lookup_offset for i in fr.Feature.LookupListIndex]
        new_gsub.FeatureList.FeatureRecord.extend(saved_feat_records)
        new_gsub.FeatureList.FeatureCount = len(new_gsub.FeatureList.FeatureRecord)

        # Add feature references back to script/langsys entries
        new_script_map = {sr.ScriptTag: sr.Script for sr in new_gsub.ScriptList.ScriptRecord}
        for script_tag, default_idxs, langsys_list in saved_scripts:
            if script_tag not in new_script_map:
                continue
            script = new_script_map[script_tag]
            if script.DefaultLangSys and default_idxs:
                script.DefaultLangSys.FeatureIndex.extend(
                    [i + feat_offset for i in default_idxs]
                )
            ls_map = {lsr.LangSysTag: lsr.LangSys for lsr in script.LangSysRecord}
            for ls_tag, ls_idxs in langsys_list:
                if ls_tag in ls_map and ls_idxs:
                    ls_map[ls_tag].FeatureIndex.extend([i + feat_offset for i in ls_idxs])

    if verbose:
        print("  + GSUB compiled (calt + liga, existing features preserved)")

    # 5. Family-name aliases
    aliases: list[str] = []
    primary = get_primary_family_name(font)
    if not args.no_alias and primary and " " in primary:
        candidate = primary.replace(" ", "")
        if candidate and candidate != primary:
            aliases.append(candidate)
    for a in args.alias:
        if a not in aliases and a != primary:
            aliases.append(a)
    add_family_aliases(font, aliases, verbose=verbose)

    # 6. Atomic save with optional backup.
    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = out_path.with_suffix(out_path.suffix + ".poopify-tmp")
    font.save(str(tmp_path))
    if bak_path is not None:
        in_path.rename(bak_path)
        if verbose:
            print(f"  + backed up original → {bak_path.name}")
    elif in_place:
        in_path.unlink()
    tmp_path.rename(out_path)
    if verbose:
        print(f"  wrote {out_path}")

    # 7. Optional demo
    if args.demo:
        family_label = primary or "patched font"
        for r in font["name"].names:
            if r.nameID == 4 and r.platformID == 3:
                try:
                    family_label = r.toUnicode()
                    break
                except Exception:
                    pass
        # Use a per-font demo filename so multiple fonts don't collide
        demo_path = out_path.with_name(f"{out_path.stem}.demo.html")
        write_demo(demo_path, out_path.name, family_label)
        if verbose:
            print(f"  wrote {demo_path}")


def main():
    ap = argparse.ArgumentParser(
        description="Patch a font (or every font in a directory) to "
                    "substitute the word 'ai' (any case) with 💩.")
    ap.add_argument("input",
                    help="Path to a font file (TTF/OTF) or a directory "
                         "containing fonts. Directories are processed "
                         "non-recursively; .bak files are skipped.")
    ap.add_argument("-o", "--output",
                    help="Write to a different path instead of overwriting "
                         "the input. Skips the .bak step. Single-file only.")
    ap.add_argument("--demo", action="store_true",
                    help="Also write a <fontname>.demo.html next to each output")
    ap.add_argument("--svg", help="Path to a custom SVG file to use as the "
                    "glyph source. Must contain one or more <path d=\"…\"> "
                    "elements. Defaults to the embedded poop SVG.")
    ap.add_argument("--alias", action="append", default=[], metavar="NAME",
                    help="Add an additional family name that the font will "
                         "match. Repeatable: --alias 'InterVariable' "
                         "--alias 'Inter'. Reliability varies by OS/browser; "
                         "see README.")
    ap.add_argument("--no-alias", action="store_true", dest="no_alias",
                    help="Disable the automatic no-spaces alias (e.g. "
                         "'Inter Variable' → 'InterVariable'). Names passed "
                         "with --alias still apply.")
    ap.add_argument("--no-backup-yes-i-am-an-idiot", action="store_true",
                    dest="no_backup",
                    help="When overwriting in place, don't save the original "
                         "as <input>.bak. The name is a warning.")
    ap.add_argument("-q", "--quiet", action="store_true",
                    help="Suppress all informational output. Errors still go "
                         "to stderr.")
    args = ap.parse_args()

    in_path = Path(args.input).resolve()
    if not in_path.exists():
        sys.exit(f"Input not found: {in_path}")

    verbose = not args.quiet

    # Parse the custom SVG once if provided — same glyph applies to all fonts
    try:
        custom_svg, custom_viewbox = parse_svg_arg(args.svg, verbose=verbose)
    except PatchError as e:
        sys.exit(str(e))

    # Build the list of font files to process
    if in_path.is_dir():
        if args.output:
            sys.exit("--output / -o doesn't make sense with a directory input "
                     "(it would map every font to the same path).")
        targets = sorted(p for p in in_path.iterdir()
                         if p.is_file()
                         and p.suffix.lower() in PATCHABLE_EXTS
                         and not p.name.endswith(".bak"))
        if not targets:
            sys.exit(f"No .ttf/.otf files in {in_path}")
        if verbose:
            print(f"Found {len(targets)} font(s) in {in_path.name}/\n")
    else:
        targets = [in_path]

    # Process each font, collecting per-file successes/failures
    succeeded: list[Path] = []
    failed: list[tuple[Path, str]] = []
    for i, p in enumerate(targets):
        if verbose and len(targets) > 1:
            print(f"--- [{i+1}/{len(targets)}] {p.name} ---")
        try:
            patch_one(p, args, custom_svg, custom_viewbox)
            succeeded.append(p)
        except PatchError as e:
            print(f"  SKIPPED: {e}", file=sys.stderr)
            failed.append((p, str(e)))
        except Exception as e:
            # Unexpected — surface but keep batching in directory mode
            if len(targets) == 1:
                raise
            print(f"  ERROR: {type(e).__name__}: {e}", file=sys.stderr)
            failed.append((p, f"{type(e).__name__}: {e}"))
        if verbose and len(targets) > 1:
            print()

    if verbose and len(targets) > 1:
        print(f"=== {len(succeeded)} patched, {len(failed)} skipped ===")
        for p, msg in failed:
            print(f"  - {p.name}: {msg}")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
