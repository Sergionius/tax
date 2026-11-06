import json
import os
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests" / "fixtures" / "orca-runtime-1.4.188-sanitized.json"
PROBE = ROOT / "scripts" / "orca-runtime-probe.cjs"
BRIDGE = ROOT / "src" / "tax" / "resources" / "orca-runtime-terminal-bridge.cjs"

HELPERS = (
    ("shared/pairing.js", "shared/remote-runtime/pairing/pairing.js"),
    ("shared/remote-runtime-client.js", "shared/remote-runtime/remote-runtime-client.js"),
    ("shared/terminal-stream-protocol.js", "shared/terminal/stream/terminal-stream-protocol.js"),
)


def test_orca_runtime_fixture_is_sanitized_and_versioned():
    raw = FIXTURE.read_text(encoding="utf-8")
    fixture = json.loads(raw)

    assert fixture["fixture_version"] == 1
    assert fixture["sanitized"] is True
    assert fixture["orca"]["version"] == "1.4.188"
    assert "terminal.multiplex.v1" in fixture["orca"]["required_capabilities"]
    assert fixture["terminal_stream"]["initial_opcodes"][-1] == "SnapshotEnd"

    forbidden = (
        "/Users/",
        "deviceToken",
        "authToken",
        "secretKey",
        "orca://pair",
        "TAX_ORCA_PAIRING_CODE=",
    )
    assert not any(value in raw for value in forbidden)


def test_orca_runtime_probe_is_executable_and_never_accepts_pairing_code_argument():
    source = PROBE.read_text(encoding="utf-8")

    assert os.access(PROBE, os.X_OK)
    assert "--pairing-code-file" in source
    assert "TAX_ORCA_PAIRING_CODE" in source
    assert "'--pairing-code'" not in source
    assert "terminal.multiplex" in source
    assert "TerminalStreamOpcode" in source


@pytest.mark.parametrize("layout", [0, 1], ids=["legacy", "current"])
@pytest.mark.parametrize("script", [BRIDGE, PROBE], ids=["bridge", "probe"])
def test_orca_helpers_resolve_in_both_layouts(tmp_path, layout, script):
    root = tmp_path / "Orca.app" / "Contents" / "Resources" / "app.asar.unpacked" / "out"
    for paths in HELPERS:
        helper = root / paths[layout]
        helper.parent.mkdir(parents=True, exist_ok=True)
        helper.write_text("module.exports = { parsePairingCode: () => null };\n", encoding="utf-8")
    credential = tmp_path / "pairing"
    credential.write_text("invalid", encoding="utf-8")
    credential.chmod(0o600)
    args = ["node", str(script)]
    if script == PROBE:
        args.append("stream")
    args += ["--terminal", "term_fixture", "--pairing-code-file", str(credential)]
    if script == BRIDGE:
        args += ["--columns", "80", "--rows", "24"]
    result = subprocess.run(args, env={**os.environ, "ORCA_APP_PATH": str(tmp_path / "Orca.app")}, capture_output=True, text=True, timeout=10)
    assert result.returncode != 0
    assert "invalid Orca pairing code" in result.stdout + result.stderr
    assert "unavailable" not in result.stdout + result.stderr
