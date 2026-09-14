"""Synchronous encrypted client for the tax WebSocket relay."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal
from urllib.parse import quote, urlparse, urlunparse

from websockets.sync.client import ClientConnection, connect

from tax.e2ee import E2EESession, SESSION_ID_BYTES, SESSION_SALT_BYTES, new_session_parameters

_SESSION_HELLO = b"TAX-E2EE-1\0"
Role = Literal["host", "device"]


@dataclass(slots=True)
class EncryptedRelayConnection:
    socket: ClientConnection
    session: E2EESession

    @classmethod
    def connect(
        cls,
        server: str,
        api_key: str,
        secret: bytes,
        *,
        role: Role,
        host_id: str,
        device_id: str,
        timeout: float = 15.0,
    ) -> "EncryptedRelayConnection":
        parsed = urlparse(server)
        scheme = "wss" if parsed.scheme == "https" else "ws"
        path = f"{parsed.path.rstrip('/')}/relay/{role}"
        query = f"host_id={quote(host_id, safe='')}&device_id={quote(device_id, safe='')}"
        url = urlunparse((scheme, parsed.netloc, path, "", query, ""))
        socket = connect(
            url,
            additional_headers={"Authorization": f"Bearer {api_key}"},
            open_timeout=timeout,
            max_size=8 * 1024 * 1024,
        )
        try:
            if role == "device":
                session_id, salt = new_session_parameters()
                socket.send(_SESSION_HELLO + session_id + salt)
            else:
                hello = socket.recv(timeout=timeout)
                if not isinstance(hello, bytes) or not hello.startswith(_SESSION_HELLO):
                    raise ValueError("invalid E2EE session hello")
                parameters = hello[len(_SESSION_HELLO) :]
                if len(parameters) != SESSION_ID_BYTES + SESSION_SALT_BYTES:
                    raise ValueError("invalid E2EE session parameters")
                session_id, salt = parameters[:SESSION_ID_BYTES], parameters[SESSION_ID_BYTES:]
            session = E2EESession.derive(
                secret,
                host_id=host_id,
                device_id=device_id,
                session_id=session_id,
                salt=salt,
                role=role,
            )
            return cls(socket, session)
        except Exception:
            socket.close()
            raise

    def send(self, channel: int, payload: bytes) -> None:
        self.socket.send(self.session.encrypt(channel, payload))

    def receive(self, timeout: float | None = None) -> tuple[int, bytes]:
        frame = self.socket.recv(timeout=timeout)
        if not isinstance(frame, bytes):
            raise ValueError("relay returned a plaintext frame")
        return self.session.decrypt(frame)

    def close(self) -> None:
        self.socket.close()

    def __enter__(self) -> "EncryptedRelayConnection":
        return self

    def __exit__(self, *_args) -> None:
        self.close()
