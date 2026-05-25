import shutil
import pytest
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen


def _empty_glyph():
    """Return an empty (no-contour) TTF glyph via pen."""
    pen = TTGlyphPen(None)
    return pen.glyph()


def _build_minimal_ttf(path, family_name="Test Font"):
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


@pytest.fixture(scope="session")
def minimal_ttf_path(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("fonts")
    p = tmp / "test.ttf"
    _build_minimal_ttf(p)
    return p


@pytest.fixture
def patched_font(minimal_ttf_path, tmp_path):
    """Copy the minimal TTF into a per-test temp dir and patch it in-place."""
    import types
    from enshittifier import patch_one

    src = tmp_path / "test.ttf"
    shutil.copy(minimal_ttf_path, src)

    args = types.SimpleNamespace(
        output=None,
        no_backup=True,
        no_alias=False,
        alias=[],
        demo=False,
    )
    patch_one(src, args, None, None)

    from fontTools.ttLib import TTFont
    return TTFont(str(src))


def build_font_at(path, family_name="Test Font"):
    """Helper to build a fresh minimal TTF at a given path."""
    _build_minimal_ttf(path, family_name=family_name)
