"""Tests for the public-tree scanner.

The scanner is exercised on synthetic fixtures in temporary Git repositories.
No real owner data is embedded: every offending string below is invented.
"""

from __future__ import annotations

import importlib.util
import os
import pathlib
import subprocess
import sys

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SCANNER = REPO_ROOT / "scripts" / "check-public-tree.py"


def _load_scanner_module():
    spec = importlib.util.spec_from_file_location("check_public_tree", SCANNER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


scanner = _load_scanner_module()

# Hermetic Git environment: never read the user's Git configuration.
GIT_ENV = {
    key: value
    for key, value in os.environ.items()
    if not key.startswith("GIT_")
}
GIT_ENV["GIT_CONFIG_GLOBAL"] = os.devnull
GIT_ENV["GIT_CONFIG_SYSTEM"] = os.devnull


def git(repo: pathlib.Path, *args: str) -> None:
    subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        env=GIT_ENV,
    )


def make_repo(tmp_path: pathlib.Path) -> pathlib.Path:
    repo = tmp_path / "repo"
    repo.mkdir(parents=True)
    git(repo, "init", "-q")
    return repo


def track(repo: pathlib.Path, relpath: str, content: str | bytes) -> None:
    target = repo / relpath
    target.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(content, bytes):
        target.write_bytes(content)
    else:
        target.write_text(content, encoding="utf-8")
    git(repo, "add", "-A")


def run_scanner(repo: pathlib.Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCANNER), "--repo-root", str(repo)],
        capture_output=True,
        text=True,
        env=GIT_ENV,
    )


def ignore(repo: pathlib.Path, pattern: str) -> None:
    gitignore = repo / ".gitignore"
    current = gitignore.read_text(encoding="utf-8") if gitignore.exists() else ""
    gitignore.write_text(f"{current}{pattern}\n", encoding="utf-8")
    git(repo, "add", "-A")


def test_clean_tree_passes(tmp_path: pathlib.Path) -> None:
    repo = make_repo(tmp_path)
    track(repo, "README.md", "# demo\n\nA clean English project.\n")
    track(repo, "deploy.env.example", "TAX_DEPLOY_HOST=deploy@tax.example.com\n")
    track(repo, "docs/guide.md", "Deploy to /home/deploy/tax on your server.\n")
    proc = run_scanner(repo)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "tracked snapshot only" in proc.stdout


@pytest.mark.parametrize(
    "relpath",
    [
        "plans/internal-notes.md",
        "docs/plans/old-design.md",
        "ios/docs/plans/redesign.md",
        ".pi/skills/local-skill.md",
        "ios/skills/local-skill.md",
    ],
)
def test_internal_directories_are_rejected(tmp_path: pathlib.Path, relpath: str) -> None:
    repo = make_repo(tmp_path)
    track(repo, relpath, "internal\n")
    proc = run_scanner(repo)
    assert proc.returncode == 1
    assert "internal directory" in proc.stdout
    assert relpath in proc.stdout


@pytest.mark.parametrize(
    "relpath",
    [
        "server/.env",
        "deploy.env",
        "keys/AuthKey_ABCD1234.p8",
        "server/cert.pem",
        "id_ed25519.key",
        "data/tax.db",
        "data/tax.sqlite",
        "dist/tax-0.4.0-py3-none-any.whl",
        "src/module.pyc",
        "__pycache__/module.pyc",
        "ios/export/app.ipa",
    ],
)
def test_generated_and_secret_paths_are_rejected(tmp_path: pathlib.Path, relpath: str) -> None:
    repo = make_repo(tmp_path)
    track(repo, relpath, "x\n")
    proc = run_scanner(repo)
    assert proc.returncode == 1
    assert relpath in proc.stdout


def test_env_example_files_are_allowed(tmp_path: pathlib.Path) -> None:
    repo = make_repo(tmp_path)
    track(repo, "deploy.env.example", "TAX_DEPLOY_PORT=8000\n")
    track(repo, "server/.env.example", "TAX_API_KEY=\n")
    proc = run_scanner(repo)
    assert proc.returncode == 0, proc.stdout + proc.stderr


def test_private_key_content_is_rejected(tmp_path: pathlib.Path) -> None:
    repo = make_repo(tmp_path)
    track(
        repo,
        "docs/notes.md",
        "made-up key material\n-----BEGIN " "PRIVATE KEY-----\nZmFrZWtleQ==\n-----END PRIVATE KEY-----\n",
    )
    proc = run_scanner(repo)
    assert proc.returncode == 1
    assert "private key material" in proc.stdout
    # The matched content itself must not be printed.
    assert "ZmFrZWtleQ==" not in proc.stdout
    assert "BEGIN " "PRIVATE KEY" not in proc.stdout


def test_private_absolute_paths_are_rejected(tmp_path: pathlib.Path) -> None:
    repo = make_repo(tmp_path)
    track(
        repo,
        "docs/notes.md",
        "mac book path /" "Users/alice/Developer/app\nserver path /" "home/bob/app\n",
    )
    proc = run_scanner(repo)
    assert proc.returncode == 1
    assert proc.stdout.count("private absolute path") == 2


def test_documented_generic_user_is_allowed(tmp_path: pathlib.Path) -> None:
    repo = make_repo(tmp_path)
    track(repo, "deploy.env.example", "TAX_DEPLOY_PROJECT_DIR=/home/deploy/tax\n")
    proc = run_scanner(repo)
    assert proc.returncode == 0, proc.stdout + proc.stderr


def test_email_metadata_is_rejected_but_documentation_domains_pass(tmp_path: pathlib.Path) -> None:
    repo = make_repo(tmp_path)
    track(
        repo,
        "docs/contacts.md",
        "personal: someone" "@company.io\ngeneric: deploy@tax.example.com\nsubdomain: info@mail.example.org\n",
    )
    proc = run_scanner(repo)
    assert proc.returncode == 1
    assert "e-mail address outside documentation domains" in proc.stdout
    # Only the personal address is flagged, and its content is not printed.
    assert proc.stdout.count("docs/contacts.md:1:") == 1
    assert "someone" "@company.io" not in proc.stdout


def test_dynamic_dns_hostname_is_rejected(tmp_path: pathlib.Path) -> None:
    repo = make_repo(tmp_path)
    track(repo, "docs/notes.md", "reachable at https://server-01.host." "nip.io\n")
    proc = run_scanner(repo)
    assert proc.returncode == 1
    assert "dynamic-DNS hostname" in proc.stdout
    assert "server-01" not in proc.stdout


def test_cyrillic_is_rejected(tmp_path: pathlib.Path) -> None:
    repo = make_repo(tmp_path)
    cyrillic = "\u0412\u043d\u0443\u0442\u0440\u0435\u043d\u043d\u044f\u044f \u0437\u0430\u043c\u0435\u0442\u043a\u0430"
    track(repo, "docs/notes.md", f"English line\n{cyrillic}\n")
    proc = run_scanner(repo)
    assert proc.returncode == 1
    assert "Cyrillic text" in proc.stdout
    assert cyrillic not in proc.stdout


def test_findings_never_print_matched_line_content(tmp_path: pathlib.Path) -> None:
    repo = make_repo(tmp_path)
    cyrillic = "\u0412\u043d\u0443\u0442\u0440\u0435\u043d\u043d\u044f\u044f \u0437\u0430\u043c\u0435\u0442\u043a\u0430"
    secret_line = "TOKEN_VALUE=super-secret-made-up-token-0123456789"
    track(repo, "docs/notes.md", f"{cyrillic} {secret_line}\n")
    proc = run_scanner(repo)
    assert proc.returncode == 1
    assert "docs/notes.md:1" in proc.stdout
    assert secret_line not in proc.stdout
    assert cyrillic not in proc.stdout


def test_ignored_local_files_are_never_scanned(tmp_path: pathlib.Path) -> None:
    """The published set comes from git ls-files; ignored files stay unread."""
    repo = make_repo(tmp_path)
    track(repo, "README.md", "clean English content\n")
    ignore(repo, "plans/")
    private = repo / "plans" / "internal.md"
    private.parent.mkdir()
    private.write_text("\u0412\u043d\u0443\u0442\u0440\u0435\u043d\u043d\u0435\u0435\n-----BEGIN " "PRIVATE KEY-----\n", encoding="utf-8")
    assert private.exists()
    proc = run_scanner(repo)
    assert proc.returncode == 0, proc.stdout + proc.stderr


def test_binary_assets_are_not_content_scanned(tmp_path: pathlib.Path) -> None:
    repo = make_repo(tmp_path)
    track(repo, "docs/images/demo.png", b"\x89PNG\r\n\x1a\n\x00\x00binary")
    proc = run_scanner(repo)
    assert proc.returncode == 0, proc.stdout + proc.stderr


def test_pinpoint_exception_covers_only_the_exact_line(tmp_path: pathlib.Path) -> None:
    exception_path, allowed_lines = next(iter(scanner.LINE_EXCEPTIONS.items()))
    allowed_line = next(iter(allowed_lines))
    assert scanner.line_rule_hits(allowed_line), "the allowlisted line must still be a rule hit"

    repo = make_repo(tmp_path)
    track(repo, exception_path, f"{allowed_line}\n")
    assert run_scanner(repo).returncode == 0

    modified = allowed_line.replace("dev", "someone")
    track(repo, exception_path, f"{modified}\n")
    proc = run_scanner(repo)
    assert proc.returncode == 1
    assert "private absolute path" in proc.stdout

    # The exception is path-scoped: the same line elsewhere is rejected.
    other_repo = make_repo(tmp_path / "other")
    track(other_repo, "docs/demo.md", f"{allowed_line}\n")
    proc = run_scanner(other_repo)
    assert proc.returncode == 1
    assert "private absolute path" in proc.stdout


def test_missing_repository_is_a_usage_error(tmp_path: pathlib.Path) -> None:
    proc = run_scanner(tmp_path / "not-a-repo")
    assert proc.returncode == 2


def test_scanner_reports_line_numbers_not_content(tmp_path: pathlib.Path) -> None:
    repo = make_repo(tmp_path)
    track(repo, "docs/notes.md", "first\n\u0412\u0442\u043e\u0440\u0430\u044f \u0441\u0442\u0440\u043e\u043a\u0430\nthird\n")
    proc = run_scanner(repo)
    assert proc.returncode == 1
    assert "docs/notes.md:2: Cyrillic text" in proc.stdout
    for reported_line in ("first", "third"):
        assert reported_line not in proc.stdout
