"""Pre-shared-key E2EE sessions for tax relay payloads."""

from __future__ import annotations

import base64
import os
import struct
from dataclasses import dataclass, field
from typing import Literal

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

E2EE_KEY_BYTES = 32
SESSION_ID_BYTES = 16
SESSION_SALT_BYTES = 32
E2EE_VERSION = 1
_HEADER = struct.Struct("!BBQ")
Role = Literal["host", "device"]


def generate_key() -> bytes:
    return os.urandom(E2EE_KEY_BYTES)


def encode_key(key: bytes) -> str:
    if len(key) != E2EE_KEY_BYTES:
        raise ValueError("E2EE key must be 256 bits")
    return base64.urlsafe_b64encode(key).decode("ascii").rstrip("=")


def decode_key(value: str) -> bytes:
    try:
        key = base64.urlsafe_b64decode(value.strip() + "=" * (-len(value.strip()) % 4))
    except (ValueError, TypeError) as error:
        raise ValueError("invalid E2EE key") from error
    if len(key) != E2EE_KEY_BYTES:
        raise ValueError("E2EE key must decode to 256 bits")
    return key


def new_session_parameters() -> tuple[bytes, bytes]:
    return os.urandom(SESSION_ID_BYTES), os.urandom(SESSION_SALT_BYTES)


@dataclass(slots=True)
class E2EESession:
    send_key: bytes
    receive_key: bytes
    host_id: str
    device_id: str
    session_id: bytes
    send_direction: int
    receive_direction: int
    send_sequence: int = 0
    receive_sequence: int = -1
    _seen: set[int] = field(default_factory=set)

    @classmethod
    def derive(
        cls,
        secret: bytes,
        *,
        host_id: str,
        device_id: str,
        session_id: bytes,
        salt: bytes,
        role: Role,
    ) -> "E2EESession":
        if len(secret) != E2EE_KEY_BYTES or len(session_id) != SESSION_ID_BYTES or len(salt) != SESSION_SALT_BYTES:
            raise ValueError("invalid E2EE session parameters")
        context = b"tax-remote-v1\0" + host_id.encode() + b"\0" + device_id.encode() + b"\0" + session_id
        material = HKDF(algorithm=hashes.SHA256(), length=64, salt=salt, info=context).derive(secret)
        device_to_host, host_to_device = material[:32], material[32:]
        if role == "device":
            return cls(device_to_host, host_to_device, host_id, device_id, session_id, 1, 2)
        return cls(host_to_device, device_to_host, host_id, device_id, session_id, 2, 1)

    def _aad(self, channel: int, sequence: int, direction: int) -> bytes:
        return (
            bytes((E2EE_VERSION, channel, direction))
            + sequence.to_bytes(8, "big")
            + self.session_id
            + self.host_id.encode()
            + b"\0"
            + self.device_id.encode()
        )

    @staticmethod
    def _nonce(direction: int, sequence: int) -> bytes:
        return direction.to_bytes(4, "big") + sequence.to_bytes(8, "big")

    def encrypt(self, channel: int, plaintext: bytes) -> bytes:
        if not 0 <= channel <= 255 or self.send_sequence >= 0xFFFFFFFFFFFFFFFF:
            raise ValueError("invalid channel or exhausted E2EE sequence")
        sequence = self.send_sequence
        self.send_sequence += 1
        ciphertext = ChaCha20Poly1305(self.send_key).encrypt(
            self._nonce(self.send_direction, sequence), plaintext, self._aad(channel, sequence, self.send_direction)
        )
        return _HEADER.pack(E2EE_VERSION, channel, sequence) + ciphertext

    def decrypt(self, frame: bytes) -> tuple[int, bytes]:
        if len(frame) < _HEADER.size + 16:
            raise ValueError("encrypted frame is too short")
        version, channel, sequence = _HEADER.unpack_from(frame)
        if version != E2EE_VERSION or sequence <= self.receive_sequence or sequence in self._seen:
            raise ValueError("duplicate, stale, or incompatible encrypted frame")
        plaintext = ChaCha20Poly1305(self.receive_key).decrypt(
            self._nonce(self.receive_direction, sequence),
            frame[_HEADER.size :],
            self._aad(channel, sequence, self.receive_direction),
        )
        self.receive_sequence = sequence
        self._seen.add(sequence)
        if len(self._seen) > 1024:
            self._seen = {value for value in self._seen if value >= sequence - 128}
        return channel, plaintext
