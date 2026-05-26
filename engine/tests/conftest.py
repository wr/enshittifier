import shutil
import pytest

from tests.helpers import build_minimal_ttf


@pytest.fixture(scope="session")
def minimal_ttf_path(tmp_path_factory):
    tmp = tmp_path_factory.mktemp("fonts")
    p = tmp / "test.ttf"
    build_minimal_ttf(p)
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
        quiet=True,
    )
    patch_one(src, args, None, None)

    from fontTools.ttLib import TTFont
    return TTFont(str(src))
