import shutil
import types
from pathlib import Path

import pytest
from fontTools.ttLib import TTFont

from enshittifier import patch_one, PatchError
from tests.helpers import build_font_at


def _args(**kwargs):
    defaults = dict(output=None, no_backup=True, no_alias=False, alias=[], demo=False)
    defaults.update(kwargs)
    return types.SimpleNamespace(**defaults)


# ---------------------------------------------------------------------------
# Glyph & cmap
# ---------------------------------------------------------------------------

def test_poop_glyph_added(patched_font):
    assert "poop" in patched_font.getGlyphNames()


def test_cmap_updated(patched_font):
    assert patched_font.getBestCmap()[0x1F4A9] == "poop"


# ---------------------------------------------------------------------------
# GSUB structure
# ---------------------------------------------------------------------------

def test_gsub_calt_liga_features(patched_font):
    gsub = patched_font["GSUB"].table
    feature_tags = {r.FeatureTag for r in gsub.FeatureList.FeatureRecord}
    assert "calt" in feature_tags
    assert "liga" in feature_tags


def test_ligature_rules_all_four_cases(patched_font):
    gsub = patched_font["GSUB"].table
    sequences = set()
    for record in gsub.LookupList.Lookup:
        if record.LookupType == 4:  # LigatureSubst
            for subtable in record.SubTable:
                for first_glyph, lig_set in subtable.ligatures.items():
                    for lig in lig_set:
                        seq = (first_glyph,) + tuple(lig.Component)
                        sequences.add(seq)
    assert len(sequences) == 4, f"Expected 4 ligature sequences, got: {sequences}"


def test_ignore_rules_count(patched_font):
    gsub = patched_font["GSUB"].table
    ignore_count = 0
    for lookup in gsub.LookupList.Lookup:
        if lookup.LookupType == 6:  # ChainedContextSubst
            for subtable in lookup.SubTable:
                # LookupType 6 format 2/3: SubClassSet / RuleSet
                # count rules that have no SubstLookupRecord (ignore rules)
                if hasattr(subtable, "SubRuleSet"):
                    for ruleset in (subtable.SubRuleSet or []):
                        if ruleset:
                            for rule in ruleset.SubRule:
                                if not rule.SubstLookupRecord:
                                    ignore_count += 1
                elif hasattr(subtable, "SubClassSet"):
                    for ruleset in (subtable.SubClassSet or []):
                        if ruleset:
                            for rule in ruleset.SubClassRule:
                                if not rule.SubstLookupRecord:
                                    ignore_count += 1
                elif hasattr(subtable, "SubstLookupRecord"):
                    if not subtable.SubstLookupRecord:
                        ignore_count += 1
                # Format 3: coverage-based (BacktrackCoverage at subtable level)
                elif hasattr(subtable, "BacktrackCoverage"):
                    if not getattr(subtable, "SubstLookupRecord", [True]):
                        ignore_count += 1
    # 2 ignore rules (letter-before, letter-after) × 2 features (calt, liga)
    # = 4 ChainedContextSubst ignore subtables
    assert ignore_count == 4


# ---------------------------------------------------------------------------
# CLI / IO
# ---------------------------------------------------------------------------

def test_backup_created(minimal_ttf_path, tmp_path):
    src = tmp_path / "test.ttf"
    shutil.copy(minimal_ttf_path, src)
    patch_one(src, _args(no_backup=False), None, None)
    assert (tmp_path / "test.ttf.bak").exists()


def test_no_backup_flag(minimal_ttf_path, tmp_path):
    src = tmp_path / "test.ttf"
    shutil.copy(minimal_ttf_path, src)
    patch_one(src, _args(no_backup=True), None, None)
    assert not (tmp_path / "test.ttf.bak").exists()


def test_output_flag(minimal_ttf_path, tmp_path):
    src = tmp_path / "test.ttf"
    out = tmp_path / "out.ttf"
    shutil.copy(minimal_ttf_path, src)
    orig_mtime = src.stat().st_mtime
    patch_one(src, _args(output=str(out)), None, None)
    assert out.exists()
    assert src.stat().st_mtime == orig_mtime


def test_refuses_existing_bak(minimal_ttf_path, tmp_path):
    src = tmp_path / "test.ttf"
    bak = tmp_path / "test.ttf.bak"
    shutil.copy(minimal_ttf_path, src)
    bak.write_bytes(b"sentinel")
    with pytest.raises(PatchError, match="Refusing"):
        patch_one(src, _args(no_backup=False), None, None)


def test_directory_mode(minimal_ttf_path, tmp_path):
    font_a = tmp_path / "a.ttf"
    font_b = tmp_path / "b.ttf"
    shutil.copy(minimal_ttf_path, font_a)
    shutil.copy(minimal_ttf_path, font_b)

    from enshittifier import PATCHABLE_EXTS
    args = _args(no_backup=True, output=None, alias=[], no_alias=False, demo=False)
    targets = sorted(p for p in tmp_path.iterdir()
                     if p.is_file() and p.suffix.lower() in PATCHABLE_EXTS
                     and not p.name.endswith(".bak"))
    for p in targets:
        patch_one(p, args, None, None)

    for p in [font_a, font_b]:
        font = TTFont(str(p))
        assert "poop" in font.getGlyphNames()


# ---------------------------------------------------------------------------
# Error paths
# ---------------------------------------------------------------------------

def test_cff2_rejected(minimal_ttf_path, tmp_path):
    import enshittifier
    from unittest.mock import patch

    src = tmp_path / "test.ttf"
    shutil.copy(minimal_ttf_path, src)

    base = enshittifier.TTFont

    class CFF2Font(base):
        def ensureDecompiled(self): pass
        def __contains__(self, tag):
            return True if tag == "CFF2" else super().__contains__(tag)

    with patch.object(enshittifier, "TTFont", CFF2Font):
        with pytest.raises(PatchError, match="CFF2"):
            patch_one(src, _args(), None, None)


def test_missing_required_glyphs(tmp_path):
    p = tmp_path / "noglyph.ttf"
    # Build a font without 'a'
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    fb = FontBuilder(1000, isTTF=True)
    order = [".notdef", "space", "i", "I"]
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({0x0020: "space", 0x0069: "i", 0x0049: "I"})
    fb.setupGlyf({name: TTGlyphPen(None).glyph() for name in order})
    fb.setupHorizontalMetrics({".notdef": (500, 0), "space": (250, 0),
                                "i": (300, 0), "I": (300, 0)})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": "NoA", "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, sTypoLineGap=0,
                usWinAscent=800, usWinDescent=200)
    fb.setupPost()
    fb.setupHead(unitsPerEm=1000)
    fb.font.save(str(p))

    with pytest.raises(PatchError, match="missing glyph"):
        patch_one(p, _args(), None, None)


# ---------------------------------------------------------------------------
# Name-table aliases
# ---------------------------------------------------------------------------

def test_auto_alias_added(tmp_path):
    p = tmp_path / "spaced.ttf"
    build_font_at(p, family_name="Test Font")  # has a space
    patch_one(p, _args(no_alias=False), None, None)
    font = TTFont(str(p))
    names = {r.toUnicode() for r in font["name"].names
             if r.nameID in (1, 16)}
    assert "TestFont" in names


def test_no_alias_flag(tmp_path):
    p = tmp_path / "noalias.ttf"
    build_font_at(p, family_name="Test Font")
    patch_one(p, _args(no_alias=True), None, None)
    font = TTFont(str(p))
    names = {r.toUnicode() for r in font["name"].names
             if r.nameID in (1, 16)}
    assert "TestFont" not in names
