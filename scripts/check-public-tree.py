#!/usr/bin/env python3
"""Public-tree safety check for the TAX repository.

The published set is derived from ``git ls-files``: only tracked files are
read. Ignored local files (private skills, internal plans, local
configuration) are never traversed, so a clean result means exactly "the
tracked snapshot is publishable".

The check rejects:
- tracked files inside internal directories (local plans, local skills,
  .pi);
- generated artifacts and secret-bearing file types by path (build output,
  databases, key files, caches, environment files);
- private key material in tracked text files;
- private absolute paths (``/Users/<name>/`` and ``/home/<name>/``) outside
  the documented generic deployment examples;
- personal metadata: e-mail addresses outside documentation domains and
  dynamic-DNS hostnames;
- Cyrillic text outside pinpoint allowlisted lines.

Scope: the check covers the current tracked snapshot only. A clean result
does not validate the private Git history that predates publication and
makes no claim about it.

Detected findings are reported as ``path:line: rule``. Matched content is
never printed, so the checker is safe to run with sensitive input.

Usage:
    python3 scripts/check-public-tree.py [--repo-root DIR]

Exit codes: 0 clean; 1 findings; 2 usage or environment error.
"""

from __future__ import annotations

import argparse
import pathlib
import posixpath
import re
import subprocess
import sys

# Internal material that must never be tracked again. Prefixes are matched
# against the tracked path relative to the repository root.
INTERNAL_DIRECTORIES = (
    ".pi/",
    "docs/plans/",
    "ios/docs/plans/",
    "ios/skills/",
    "plans/",
)

# Generated artifacts and files that may hold secrets, rejected by path.
GENERATED_DIRECTORIES = (
    ".idea/",
    ".pytest_cache/",
    ".ruff_cache/",
    ".venv/",
    ".vscode/",
    "__pycache__/",
    "DerivedData/",
    "build/",
    "data/",
    "dist/",
    "keys/",
    "logs/",
    "node_modules/",
    "venv/",
    "xcuserdata/",
)

GENERATED_SUFFIXES = (
    ".db",
    ".dSYM",
    ".DS_Store",
    ".env",
    ".ipa",
    ".key",
    ".p8",
    ".pem",
    ".pyc",
    ".pyo",
    ".so",
    ".sqlite",
    ".sqlite3",
    ".swp",
    ".xcresult",
    ".xcuserstate",
)

# Private key material anywhere in a tracked text file.
PRIVATE_KEY_RE = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")

# E-mail addresses are personal metadata; only documentation domains are
# allowed (generic examples such as deploy@tax.example.com).
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
ALLOWED_EMAIL_DOMAINS = frozenset({"example.com", "example.org", "example.net"})

# Machine-specific home directories. /home/<user> is allowed only for the
# documented generic deployment user from the example configuration.
PRIVATE_PATH_RE = re.compile(r"/(?P<kind>Users|home)/(?P<user>[A-Za-z0-9._-]+)")
GENERIC_UNIX_USERS = frozenset({"deploy"})

# Dynamic-DNS hostnames resolve to private infrastructure.
DYNAMIC_DNS_SUFFIXES = (".nip.io", ".sslip.io")

# Non-English text must not leak into the published set.
CYRILLIC_RE = re.compile(r"[\u0400-\u04FF]")

# Pinpoint allowlist: exact tracked path -> exact allowed line content.
# Used for documented generic examples and mandatory third-party material
# only; never for whole source directories.
LINE_EXCEPTIONS: dict[str, frozenset[str]] = {
    # Synthetic demo path rendered by the screenshot fixture, not a real
    # machine path (see the ScreenshotFixtures/docs references).
    "ios/tax/tax/Views/WorkspaceTheme.swift": frozenset(
        {
            '                Text("/Users/dev/work/very-long-project-directory/'
            'sources/feature/deeply/nested/module/Implementation/File.swift")',
        }
    ),
}


def tracked_files(repo_root: pathlib.Path) -> list[str]:
    """Return the published set: all files tracked by Git, nothing else."""
    proc = subprocess.run(
        ["git", "-C", str(repo_root), "ls-files", "-z"],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        print(f"error: git ls-files failed: {detail}", file=sys.stderr)
        raise SystemExit(2)
    return [name for name in proc.stdout.decode("utf-8", "surrogateescape").split("\0") if name]


def path_findings(path: str) -> list[tuple[str, int, str]]:
    findings: list[tuple[str, int, str]] = []
    for rule_dir in INTERNAL_DIRECTORIES:
        if path.startswith(rule_dir):
            findings.append((path, 0, f"internal directory '{rule_dir}'"))
            break
    lowered = path.lower()
    for part in posixpath.dirname(lowered).split("/"):
        if f"{part}/" in GENERATED_DIRECTORIES:
            findings.append((path, 0, f"generated artifact directory '{part}/'"))
            break
    if not lowered.endswith(".example"):
        for suffix in GENERATED_SUFFIXES:
            if lowered.endswith(suffix):
                findings.append((path, 0, f"generated or secret-bearing file type '{suffix}'"))
                break
    return findings


def line_rule_hits(line: str) -> list[str]:
    hits: list[str] = []
    if PRIVATE_KEY_RE.search(line):
        hits.append("private key material")
    for match in EMAIL_RE.finditer(line):
        domain = match.group(0).rsplit("@", 1)[1].lower().rstrip(".")
        if not any(
            domain == allowed or domain.endswith(f".{allowed}")
            for allowed in ALLOWED_EMAIL_DOMAINS
        ):
            hits.append("e-mail address outside documentation domains")
            break
    for match in PRIVATE_PATH_RE.finditer(line):
        if match.group("kind") == "Users" or match.group("user") not in GENERIC_UNIX_USERS:
            hits.append("private absolute path")
            break
    lowered = line.lower()
    if any(suffix in lowered for suffix in DYNAMIC_DNS_SUFFIXES):
        hits.append("dynamic-DNS hostname")
    if CYRILLIC_RE.search(line):
        hits.append("Cyrillic text")
    return hits


def content_findings(repo_root: pathlib.Path, path: str) -> list[tuple[str, int, str]]:
    try:
        raw = (repo_root / path).read_bytes()
    except OSError as exc:
        print(f"warning: cannot read tracked file {path}: {exc}", file=sys.stderr)
        return []
    if b"\x00" in raw:
        return []  # binary asset; path rules above already applied
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return []
    allowed_lines = LINE_EXCEPTIONS.get(path, frozenset())
    findings: list[tuple[str, int, str]] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if line in allowed_lines:
            continue
        for rule in line_rule_hits(line):
            findings.append((path, lineno, rule))
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    default_root = pathlib.Path(__file__).resolve().parent.parent
    parser.add_argument(
        "--repo-root",
        type=pathlib.Path,
        default=default_root,
        help=f"repository root (default: {default_root})",
    )
    args = parser.parse_args(argv)
    repo_root = args.repo_root.resolve()

    files = tracked_files(repo_root)
    findings: list[tuple[str, int, str]] = []
    for path in files:
        findings.extend(path_findings(path))
        findings.extend(content_findings(repo_root, path))

    if findings:
        print(f"public-tree: {len(findings)} finding(s) in the tracked snapshot")
        for path, lineno, rule in findings:
            print(f"{path}:{lineno}: {rule}")
        print("Scope: tracked snapshot only; Git history is not validated.")
        return 1

    print(f"public-tree: ok ({len(files)} tracked files checked)")
    print("Scope: tracked snapshot only; Git history is not validated.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
