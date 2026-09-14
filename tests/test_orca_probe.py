import json
import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests" / "fixtures" / "orca-runtime-1.4.188-sanitized.json"
PROBE = ROOT / "scripts" / "orca-runtime-probe.cjs"


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
