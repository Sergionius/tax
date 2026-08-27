import base64
import json
from pathlib import Path

import pytest
from cryptography.exceptions import InvalidTag

from tax.e2ee import E2EESession, decode_key, encode_key, generate_key, new_session_parameters
from tax.remote_protocol import ControlMessage, MessageType, TerminalFrame, TerminalOpcode


FIXTURE = Path(__file__).with_name("fixtures") / "remote-protocol-v1.json"


def make_sessions():
    secret = generate_key()
    session_id, salt = new_session_parameters()
    common = dict(host_id="mac-1", device_id="iphone-1", session_id=session_id, salt=salt)
    return (
        E2EESession.derive(secret, role="device", **common),
        E2EESession.derive(secret, role="host", **common),
    )


def test_key_encoding_and_directional_encryption_round_trip():
    secret = generate_key()
    assert decode_key(encode_key(secret)) == secret
    device, host = make_sessions()

    request = device.encrypt(1, b"terminal.input")
    assert host.decrypt(request) == (1, b"terminal.input")
    response = host.encrypt(2, b"terminal.output")
    assert device.decrypt(response) == (2, b"terminal.output")


def test_encryption_authenticates_context_and_rejects_replay():
    device, host = make_sessions()
    frame = device.encrypt(1, b"secret")

    assert host.decrypt(frame)[1] == b"secret"
    with pytest.raises(ValueError, match="duplicate"):
        host.decrypt(frame)

    other_device, _ = make_sessions()
    tampered = bytearray(other_device.encrypt(1, b"secret"))
    tampered[-1] ^= 1
    with pytest.raises((InvalidTag, ValueError)):
        host.decrypt(bytes(tampered))


def test_shared_remote_protocol_fixture_round_trips():
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
    control = ControlMessage.decode(json.dumps(fixture["control"]).encode())
    binary = fixture["terminal_frame"]
    frame = TerminalFrame(
        TerminalOpcode[binary["opcode"]],
        binary["stream_id"],
        binary["generation"],
        binary["sequence"],
        base64.b64decode(binary["payload_base64"]),
    )

    assert control.type is MessageType.TERMINAL_CREATE
    assert base64.b64encode(frame.encode()).decode() == binary["encoded_base64"]
    assert TerminalFrame.decode(frame.encode()) == frame


def test_terminal_binary_frame_round_trip_and_limits():
    frame = TerminalFrame(TerminalOpcode.OUTPUT, 7, 3, 42, b"ansi-bytes")

    assert TerminalFrame.decode(frame.encode()) == frame

    damaged = bytearray(frame.encode())
    damaged[0] = 99
    with pytest.raises(ValueError, match="unsupported"):
        TerminalFrame.decode(bytes(damaged))
    with pytest.raises(ValueError, match="size"):
        TerminalFrame.decode(b"short")


def test_rejects_invalid_keys_and_session_parameters():
    with pytest.raises(ValueError):
        decode_key("short")
    with pytest.raises(ValueError):
        encode_key(b"short")
    with pytest.raises(ValueError):
        E2EESession.derive(
            b"short", host_id="h", device_id="d", session_id=b"short", salt=b"short", role="host"
        )
