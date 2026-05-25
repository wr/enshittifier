from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen


def _empty_glyph():
    return TTGlyphPen(None).glyph()


def build_minimal_ttf(path, family_name="Test Font"):
    fb = FontBuilder(1000, isTTF=True)
    glyph_order = [".notdef", "space", "a", "A", "i", "I"]
    fb.setupGlyphOrder(glyph_order)
    fb.setupCharacterMap({
        0x0020: "space",
        0x0061: "a",
        0x0041: "A",
        0x0069: "i",
        0x0049: "I",
    })
    glyphs = {name: _empty_glyph() for name in glyph_order}
    fb.setupGlyf(glyphs)
    metrics = {
        ".notdef": (500, 0),
        "space":   (250, 0),
        "a":       (600, 0),
        "A":       (600, 0),
        "i":       (300, 0),
        "I":       (300, 0),
    }
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({
        "familyName":  family_name,
        "styleName":   "Regular",
    })
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, sTypoLineGap=0,
                usWinAscent=800, usWinDescent=200)
    fb.setupPost()
    fb.setupHead(unitsPerEm=1000)
    fb.font.save(str(path))
    return path


def build_font_at(path, family_name="Test Font"):
    """Build a fresh minimal TTF at the given path."""
    return build_minimal_ttf(path, family_name=family_name)
