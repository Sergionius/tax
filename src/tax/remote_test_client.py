"""Command-line E2E client used to validate Phase 2 without iOS."""

from __future__ import annotations

import base64
import secrets
import time
import uuid
from dataclasses import dataclass, field
from typing import Any

from tax.e2ee import decode_key
from tax.relay_client import EncryptedRelayConnection
from tax.remote_host import CONTROL_CHANNEL, TERMINAL_CHANNEL
from tax.remote_protocol import ControlMessage, MessageType, TerminalFrame, TerminalOpcode


@dataclass(slots=True)
class RemoteTestClient:
    connection: EncryptedRelayConnection
    terminal_frames: list[TerminalFrame] = field(default_factory=list)
    events: list[ControlMessage] = field(default_factory=list)

    def request(
        self,
        message_type: MessageType,
        payload: dict[str, Any] | None = None,
        *,
        operation_id: str | None = None,
        timeout: float = 15.0,
    ) -> dict[str, Any]:
        request_id = str(uuid.uuid4())
        message = ControlMessage(
            type=message_type,
            request_id=request_id,
            operation_id=operation_id,
            payload=payload or {},
        )
        self.connection.send(CONTROL_CHANNEL, message.encode())
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            channel, data = self.connection.receive(timeout=max(0.1, deadline - time.monotonic()))
            if channel == TERMINAL_CHANNEL:
                self.terminal_frames.append(TerminalFrame.decode(data))
                continue
            response = ControlMessage.decode(data)
            if response.request_id == request_id and response.type in {
                MessageType.OPERATION_RESULT,
                MessageType.PROTOCOL_ERROR,
            }:
                if response.type is MessageType.PROTOCOL_ERROR or response.payload.get("ok") is not True:
                    raise RuntimeError(
                        f"{response.payload.get('code', 'remote_error')}: {response.payload.get('message', '')}"
                    )
                return response.payload
            self.events.append(response)
        raise TimeoutError(f"timed out waiting for {message_type}")

    def wait_for_output(self, stream_id: int, generation: int, needle: bytes, timeout: float = 15.0) -> bytes:
        accumulated = bytearray()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            frames = self.terminal_frames
            self.terminal_frames = []
            if not frames:
                channel, data = self.connection.receive(timeout=max(0.1, deadline - time.monotonic()))
                if channel == CONTROL_CHANNEL:
                    self.events.append(ControlMessage.decode(data))
                    continue
                frames = [TerminalFrame.decode(data)]
            for frame in frames:
                if frame.stream_id != stream_id or frame.generation != generation:
                    continue
                if frame.opcode in {TerminalOpcode.SNAPSHOT, TerminalOpcode.OUTPUT}:
                    accumulated.extend(frame.payload)
                    if needle in accumulated:
                        return bytes(accumulated)
        raise TimeoutError("timed out waiting for terminal output")


def run_remote_smoke(
    *,
    server: str,
    api_key: str,
    host_id: str,
    device_id: str,
    e2ee_key: str,
    start_pi: bool = False,
) -> dict[str, Any]:
    secret = decode_key(e2ee_key)
    with EncryptedRelayConnection.connect(
        server, api_key, secret, role="device", host_id=host_id, device_id=device_id
    ) as connection:
        client = RemoteTestClient(connection)
        workspaces = client.request(MessageType.WORKSPACE_LIST)["workspaces"]
        if not workspaces:
            raise RuntimeError("host returned no open Orca workspaces")
        operation_id = str(uuid.uuid4())
        created = client.request(
            MessageType.TERMINAL_CREATE,
            {"workspace_id": workspaces[0]["id"], "title": "tax remote smoke"},
            operation_id=operation_id,
        )["terminal"]
        terminal_id = created["id"]
        try:
            subscribed = client.request(MessageType.TERMINAL_SUBSCRIBE, {"terminal_id": terminal_id})
            stream_id = subscribed["stream_id"]
            generation = subscribed["generation"]
            marker = f"TAX_REMOTE_{secrets.token_hex(8)}".encode()
            client.request(
                MessageType.TERMINAL_INPUT,
                {"terminal_id": terminal_id, "data_b64": base64.b64encode(b"printf '" + marker + b"\\n'\r").decode()},
                operation_id=str(uuid.uuid4()),
            )
            client.wait_for_output(stream_id, generation, marker)
            pi_observed = False
            if start_pi:
                client.request(
                    MessageType.TERMINAL_INPUT,
                    {"terminal_id": terminal_id, "data_b64": base64.b64encode(b"pi\r").decode()},
                    operation_id=str(uuid.uuid4()),
                )
                client.wait_for_output(stream_id, generation, b"Pi", timeout=30)
                pi_observed = True
                client.request(
                    MessageType.TERMINAL_INPUT,
                    {"terminal_id": terminal_id, "data_b64": base64.b64encode(b"\x03").decode()},
                    operation_id=str(uuid.uuid4()),
                )
            return {
                "workspaces": len(workspaces),
                "terminal_id": terminal_id,
                "stream_id": stream_id,
                "generation": generation,
                "marker_observed": True,
                "pi_observed": pi_observed,
            }
        finally:
            client.request(
                MessageType.TERMINAL_CLOSE,
                {"terminal_id": terminal_id},
                operation_id=str(uuid.uuid4()),
            )
