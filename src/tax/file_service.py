"""Workspace-scoped, conflict-safe file access for the Mac remote host."""

from __future__ import annotations

import hashlib
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Callable, Optional

MAX_DIRECTORY_PAGE_SIZE = 200
MAX_SEARCH_RESULTS = 200
MAX_EDITABLE_TEXT_BYTES = 2 * 1024 * 1024
MAX_IMAGE_BYTES = 10 * 1024 * 1024
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic"}


class FileServiceError(RuntimeError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


@dataclass(frozen=True, slots=True)
class FileEntry:
    name: str
    path: str
    is_directory: bool
    size: Optional[int]


@dataclass(frozen=True, slots=True)
class FileContent:
    path: str
    kind: str
    data: bytes
    revision: str


class ScopedFileService:
    def __init__(self, roots: Callable[[], dict[str, Path]]):
        self._roots = roots

    def list(self, workspace_id: str, relative_path: str = "", *, offset: int = 0, limit: int = 100) -> list[FileEntry]:
        if not 1 <= limit <= MAX_DIRECTORY_PAGE_SIZE or offset < 0:
            raise FileServiceError("invalid_argument", "invalid directory page")
        target, normalized = self._resolve(workspace_id, relative_path)
        if not target.is_dir():
            raise FileServiceError("not_directory", "path is not a directory")
        try:
            children = sorted(target.iterdir(), key=lambda item: (not item.is_dir(), item.name.lower()))
        except OSError as error:
            raise FileServiceError("read_failed", "directory could not be read") from error
        result = []
        for child in children[offset : offset + limit]:
            try:
                resolved = self._contained_child(workspace_id, child)
            except FileServiceError as error:
                if error.code in {"path_outside_workspace", "not_found"}:
                    continue
                raise
            stat = resolved.stat()
            child_path = str(PurePosixPath(normalized) / child.name) if normalized else child.name
            result.append(FileEntry(child.name, child_path, resolved.is_dir(), None if resolved.is_dir() else stat.st_size))
        return result

    def search(self, workspace_id: str, query: str, *, limit: int = 100) -> list[FileEntry]:
        query = query.strip().lower()
        if not query or not 1 <= limit <= MAX_SEARCH_RESULTS:
            raise FileServiceError("invalid_argument", "invalid filename search")
        root, _ = self._resolve(workspace_id, "")
        result: list[FileEntry] = []
        for directory, names, files in os.walk(root, followlinks=False):
            names[:] = [name for name in names if name not in {".git", ".build", "DerivedData", "node_modules"}]
            for name in sorted([*names, *files], key=str.lower):
                if query not in name.lower():
                    continue
                try:
                    candidate = self._contained_child(workspace_id, Path(directory) / name)
                except FileServiceError as error:
                    if error.code in {"path_outside_workspace", "not_found"}:
                        continue
                    raise
                relative = candidate.relative_to(root).as_posix()
                result.append(FileEntry(name, relative, candidate.is_dir(), None if candidate.is_dir() else candidate.stat().st_size))
                if len(result) >= limit:
                    return result
        return result

    def read(self, workspace_id: str, relative_path: str) -> FileContent:
        target, normalized = self._resolve(workspace_id, relative_path)
        if not target.is_file():
            raise FileServiceError("not_file", "path is not a file")
        size = target.stat().st_size
        kind = "image" if target.suffix.lower() in IMAGE_EXTENSIONS else "text"
        maximum = MAX_IMAGE_BYTES if kind == "image" else MAX_EDITABLE_TEXT_BYTES
        if size > maximum:
            raise FileServiceError("file_too_large", "file exceeds the supported size")
        try:
            data = target.read_bytes()
        except OSError as error:
            raise FileServiceError("read_failed", "file could not be read") from error
        if kind == "text":
            try:
                data.decode("utf-8")
            except UnicodeDecodeError as error:
                raise FileServiceError("binary_file", "binary files cannot be edited") from error
        return FileContent(normalized, kind, data, self._revision(data))

    def write(
        self,
        workspace_id: str,
        relative_path: str,
        data: bytes,
        *,
        expected_revision: Optional[str],
        force: bool = False,
    ) -> str:
        if len(data) > MAX_EDITABLE_TEXT_BYTES:
            raise FileServiceError("file_too_large", "text file exceeds the editable size")
        try:
            data.decode("utf-8")
        except UnicodeDecodeError as error:
            raise FileServiceError("binary_file", "binary writes are forbidden") from error
        target, _ = self._resolve(workspace_id, relative_path, allow_missing=True)
        current = target.read_bytes() if target.exists() else b""
        current_revision = self._revision(current)
        if not force and expected_revision != current_revision:
            raise FileServiceError("file_conflict", "file changed since it was read")
        descriptor, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
        try:
            with os.fdopen(descriptor, "wb") as output:
                output.write(data)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, target)
        except OSError as error:
            raise FileServiceError("write_failed", "file could not be saved") from error
        finally:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
        return self._revision(data)

    def _resolve(self, workspace_id: str, relative_path: str, *, allow_missing: bool = False) -> tuple[Path, str]:
        roots = self._roots()
        root = roots.get(workspace_id)
        if root is None:
            raise FileServiceError("workspace_closed", "workspace is not open")
        root = root.resolve(strict=True)
        pure = PurePosixPath(relative_path)
        if pure.is_absolute() or ".." in pure.parts:
            raise FileServiceError("path_outside_workspace", "path escapes the workspace")
        normalized = "" if str(pure) == "." else pure.as_posix()
        candidate = root.joinpath(*pure.parts)
        try:
            resolved = candidate.resolve(strict=not allow_missing)
        except OSError as error:
            raise FileServiceError("not_found", "path does not exist") from error
        if allow_missing:
            try:
                parent = candidate.parent.resolve(strict=True)
            except OSError as error:
                raise FileServiceError("not_found", "parent directory does not exist") from error
            if candidate.is_symlink():
                raise FileServiceError("path_outside_workspace", "symlink writes are forbidden")
            resolved = parent / candidate.name
        if resolved != root and root not in resolved.parents:
            raise FileServiceError("path_outside_workspace", "path escapes the workspace")
        return resolved, normalized

    def _contained_child(self, workspace_id: str, child: Path) -> Path:
        root = self._roots().get(workspace_id)
        if root is None:
            raise FileServiceError("workspace_closed", "workspace is not open")
        root = root.resolve(strict=True)
        try:
            resolved = child.resolve(strict=True)
        except OSError as error:
            raise FileServiceError("not_found", "path does not exist") from error
        if resolved != root and root not in resolved.parents:
            raise FileServiceError("path_outside_workspace", "symlink escapes the workspace")
        return resolved

    @staticmethod
    def _revision(data: bytes) -> str:
        return hashlib.sha256(data).hexdigest()
