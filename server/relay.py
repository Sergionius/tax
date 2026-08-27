"""Bounded, ciphertext-only WebSocket relay for one host and its devices."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from typing import Literal

from fastapi import WebSocket
from starlette.websockets import WebSocketDisconnect, WebSocketState

MAX_RELAY_FRAME_BYTES = 8 * 1024 * 1024
MAX_RELAY_QUEUE_FRAMES = 64
Role = Literal["host", "device"]


@dataclass(slots=True)
class RelayPeer:
    socket: WebSocket
    send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    pending: asyncio.Queue[bytes] = field(default_factory=lambda: asyncio.Queue(MAX_RELAY_QUEUE_FRAMES))


@dataclass(slots=True)
class RelayPair:
    host: RelayPeer | None = None
    device: RelayPeer | None = None


class RelayHub:
    def __init__(self):
        self._pairs: dict[tuple[str, str], RelayPair] = {}
        self._lock = asyncio.Lock()

    async def connect(self, role: Role, host_id: str, device_id: str, socket: WebSocket) -> RelayPeer:
        await socket.accept()
        peer = RelayPeer(socket)
        async with self._lock:
            pair = self._pairs.setdefault((host_id, device_id), RelayPair())
            previous = pair.host if role == "host" else pair.device
            if role == "host":
                pair.host = peer
            else:
                pair.device = peer
            opposite = pair.device if role == "host" else pair.host
        if previous and previous.socket.client_state == WebSocketState.CONNECTED:
            await previous.socket.close(code=4009, reason="connection replaced")
        if opposite:
            await self._flush(opposite)
        return peer

    async def disconnect(self, role: Role, host_id: str, device_id: str, peer: RelayPeer) -> None:
        async with self._lock:
            key = (host_id, device_id)
            pair = self._pairs.get(key)
            if not pair:
                return
            if role == "host" and pair.host is peer:
                pair.host = None
            elif role == "device" and pair.device is peer:
                pair.device = None
            if pair.host is None and pair.device is None:
                self._pairs.pop(key, None)

    async def run(self, role: Role, host_id: str, device_id: str, peer: RelayPeer) -> None:
        while True:
            message = await peer.socket.receive()
            if message.get("type") == "websocket.disconnect":
                raise WebSocketDisconnect(message.get("code", 1000))
            payload = message.get("bytes")
            if not isinstance(payload, bytes):
                await peer.socket.close(code=1003, reason="binary ciphertext required")
                return
            if len(payload) > MAX_RELAY_FRAME_BYTES:
                await peer.socket.close(code=1009, reason="frame too large")
                return
            target = await self._target(role, host_id, device_id)
            if target and target.socket.client_state == WebSocketState.CONNECTED:
                async with target.send_lock:
                    await target.socket.send_bytes(payload)
            elif not peer.pending.full():
                await peer.pending.put(payload)
            else:
                await peer.socket.close(code=1013, reason="relay queue overflow")
                return

    async def _target(self, role: Role, host_id: str, device_id: str) -> RelayPeer | None:
        async with self._lock:
            pair = self._pairs.get((host_id, device_id))
            if not pair:
                return None
            return pair.device if role == "host" else pair.host

    async def _flush(self, source: RelayPeer) -> None:
        # Frames queued by source were waiting for the peer that just connected.
        target = None
        async with self._lock:
            for pair in self._pairs.values():
                if pair.host is source:
                    target = pair.device
                    break
                if pair.device is source:
                    target = pair.host
                    break
        if not target:
            return
        while not source.pending.empty():
            payload = source.pending.get_nowait()
            async with target.send_lock:
                await target.socket.send_bytes(payload)

    def connection_count(self) -> int:
        return sum(int(pair.host is not None) + int(pair.device is not None) for pair in self._pairs.values())
