from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from server import main
from server.relay import RelayHub


AUTH = {"Authorization": "Bearer test-key"}


def make_client(monkeypatch, tmp_path: Path) -> TestClient:
    monkeypatch.setattr(main, "DB_PATH", str(tmp_path / "tax.db"))
    monkeypatch.setattr(main, "API_KEY", "test-key")
    monkeypatch.setattr(main, "relay_hub", RelayHub())
    return TestClient(main.app)


def test_relay_routes_binary_ciphertext_and_flushes_bounded_offline_queue(monkeypatch, tmp_path):
    with make_client(monkeypatch, tmp_path) as client:
        with client.websocket_connect("/relay/host?host_id=mac-1&device_id=phone-1", headers=AUTH) as host:
            host.send_bytes(b"encrypted-host-frame")
            with client.websocket_connect("/relay/device?host_id=mac-1&device_id=phone-1", headers=AUTH) as device:
                assert device.receive_bytes() == b"encrypted-host-frame"
                device.send_bytes(b"encrypted-device-frame")
                assert host.receive_bytes() == b"encrypted-device-frame"
                assert main.relay_hub.connection_count() == 2

    assert main.relay_hub.connection_count() == 0


def test_relay_closes_other_role_when_e2ee_session_peer_disconnects(monkeypatch, tmp_path):
    with make_client(monkeypatch, tmp_path) as client:
        with client.websocket_connect("/relay/host?host_id=mac&device_id=phone", headers=AUTH) as host:
            with client.websocket_connect("/relay/device?host_id=mac&device_id=phone", headers=AUTH) as device:
                device.close()
                with pytest.raises(WebSocketDisconnect) as closed:
                    host.receive_bytes()
                assert closed.value.code == 4010


def test_relay_rejects_unauthorized_invalid_and_plaintext_connections(monkeypatch, tmp_path):
    with make_client(monkeypatch, tmp_path) as client:
        with pytest.raises(WebSocketDisconnect) as unauthorized:
            with client.websocket_connect("/relay/host?host_id=mac&device_id=phone"):
                pass
        assert unauthorized.value.code == 4401

        with pytest.raises(WebSocketDisconnect) as invalid:
            with client.websocket_connect("/relay/unknown?host_id=mac&device_id=phone", headers=AUTH):
                pass
        assert invalid.value.code == 4400

        with client.websocket_connect("/relay/host?host_id=mac&device_id=phone", headers=AUTH) as socket:
            socket.send_text("plaintext is forbidden")
            with pytest.raises(WebSocketDisconnect) as plaintext:
                socket.receive_bytes()
            assert plaintext.value.code == 1003
