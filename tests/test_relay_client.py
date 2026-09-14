from collections import deque

from tax.e2ee import generate_key
from tax.relay_client import EncryptedRelayConnection


class FakeSocket:
    def __init__(self, inbound, outbound):
        self.inbound = inbound
        self.outbound = outbound
        self.closed = False

    def send(self, value):
        self.outbound.append(value)

    def recv(self, timeout=None):
        return self.inbound.popleft()

    def close(self):
        self.closed = True


def test_encrypted_relay_client_establishes_directional_session(monkeypatch):
    device_to_host = deque()
    host_to_device = deque()
    sockets = []

    def fake_connect(url, **kwargs):
        if "/relay/device" in url:
            socket = FakeSocket(host_to_device, device_to_host)
        else:
            socket = FakeSocket(device_to_host, host_to_device)
        sockets.append((url, kwargs, socket))
        return socket

    monkeypatch.setattr("tax.relay_client.connect", fake_connect)
    secret = generate_key()
    device = EncryptedRelayConnection.connect(
        "https://tax.example/base", "api-secret", secret, role="device", host_id="mac 1", device_id="phone/1"
    )
    host = EncryptedRelayConnection.connect(
        "https://tax.example/base", "api-secret", secret, role="host", host_id="mac 1", device_id="phone/1"
    )

    device.send(7, b"terminal input")
    assert host.receive() == (7, b"terminal input")
    host.send(8, b"terminal output")
    assert device.receive() == (8, b"terminal output")

    assert sockets[0][0].startswith("wss://tax.example/base/relay/device?")
    assert "mac%201" in sockets[0][0]
    assert sockets[0][1]["additional_headers"] == {"Authorization": "Bearer api-secret"}
