from pathlib import Path

import pytest

from tax.file_service import FileServiceError, ScopedFileService


def service(root: Path, workspace_id: str = "workspace") -> ScopedFileService:
    return ScopedFileService(lambda: {workspace_id: root})


def test_lists_searches_and_reads_text_and_images(tmp_path):
    (tmp_path / "Sources").mkdir()
    (tmp_path / "Sources" / "Main.swift").write_text("print('hello')")
    (tmp_path / "image.png").write_bytes(b"\x89PNG fixture")
    files = service(tmp_path)

    entries = files.list("workspace")
    assert [(entry.name, entry.is_directory) for entry in entries] == [("Sources", True), ("image.png", False)]
    assert [entry.path for entry in files.search("workspace", "main")] == ["Sources/Main.swift"]

    text = files.read("workspace", "Sources/Main.swift")
    image = files.read("workspace", "image.png")
    assert text.kind == "text" and text.data == b"print('hello')"
    assert image.kind == "image" and image.data.startswith(b"\x89PNG")


def test_write_detects_conflict_and_supports_explicit_force(tmp_path):
    path = tmp_path / "file.txt"
    path.write_text("first")
    files = service(tmp_path)
    original = files.read("workspace", "file.txt")

    revision = files.write("workspace", "file.txt", b"second", expected_revision=original.revision)
    assert files.read("workspace", "file.txt").revision == revision

    with pytest.raises(FileServiceError) as conflict:
        files.write("workspace", "file.txt", b"third", expected_revision=original.revision)
    assert conflict.value.code == "file_conflict"
    files.write("workspace", "file.txt", b"forced", expected_revision=original.revision, force=True)
    assert path.read_text() == "forced"


def test_rejects_traversal_absolute_paths_escaping_symlinks_and_binary_writes(tmp_path):
    root = tmp_path / "root"
    outside = tmp_path / "outside"
    root.mkdir()
    outside.mkdir()
    (outside / "secret.txt").write_text("secret")
    (root / "escape").symlink_to(outside, target_is_directory=True)
    files = service(root)
    assert files.list("workspace") == []

    for path in ("../outside/secret.txt", str(outside / "secret.txt"), "escape/secret.txt"):
        with pytest.raises(FileServiceError) as rejected:
            files.read("workspace", path)
        assert rejected.value.code == "path_outside_workspace"

    (root / "binary.dat").write_bytes(b"\x00\xff")
    with pytest.raises(FileServiceError) as binary:
        files.read("workspace", "binary.dat")
    assert binary.value.code == "binary_file"
    with pytest.raises(FileServiceError) as write:
        files.write("workspace", "new.txt", b"\xff", expected_revision=None)
    assert write.value.code == "binary_file"


def test_workspace_closure_revokes_access_immediately(tmp_path):
    roots = {"workspace": tmp_path}
    (tmp_path / "file.txt").write_text("visible")
    files = ScopedFileService(lambda: roots)
    assert files.read("workspace", "file.txt").data == b"visible"

    roots.clear()
    with pytest.raises(FileServiceError) as closed:
        files.read("workspace", "file.txt")
    assert closed.value.code == "workspace_closed"
