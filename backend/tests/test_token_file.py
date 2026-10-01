import os

import pytest

from tashbridge.server import load_token


def test_token_creation_and_reload(tmp_path):
    path = tmp_path / "private" / "server-token"
    token = load_token(path)
    assert len(token) >= 32
    assert load_token(path) == token
    assert path.stat().st_mode & 0o777 == 0o600


def test_token_symlink_is_rejected(tmp_path):
    actual = tmp_path / "actual"
    actual.write_text("a" * 32)
    actual.chmod(0o600)
    link = tmp_path / "linked"
    link.symlink_to(actual)
    with pytest.raises((ValueError, OSError)):
        load_token(link)


def test_world_readable_token_is_rejected(tmp_path):
    path = tmp_path / "server-token"
    path.write_text("a" * 32)
    path.chmod(0o644)
    with pytest.raises(ValueError):
        load_token(path)


def test_writable_parent_is_rejected(tmp_path):
    folder = tmp_path / "shared"
    folder.mkdir(mode=0o777)
    folder.chmod(0o777)
    with pytest.raises(ValueError):
        load_token(folder / "server-token")
