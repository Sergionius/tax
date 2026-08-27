"""macOS Keychain storage for the tax remote E2EE key."""

from __future__ import annotations

import subprocess

SERVICE = "tax.remote.e2ee"
ACCOUNT = "host-key"


def store_e2ee_key(value: str) -> None:
    subprocess.run(
        ["security", "add-generic-password", "-U", "-s", SERVICE, "-a", ACCOUNT, "-w", value],
        check=True,
        capture_output=True,
        text=True,
    )


def load_e2ee_key() -> str:
    result = subprocess.run(
        ["security", "find-generic-password", "-s", SERVICE, "-a", ACCOUNT, "-w"],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()
