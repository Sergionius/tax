"""Versioned tax remote protocol limits and binary terminal framing."""

from __future__ import annotations

import json
import struct
from dataclasses import dataclass
from enum import IntEnum, StrEnum
from typing import Any, Optional

from pydantic import BaseModel, Field

PROTOCOL_VERSION = 1
MAX_CONTROL_BYTES = 256 * 1024
MAX_BINARY_FRAME_BYTES = 8 * 1024 * 1024
MAX_TERMINAL_PAYLOAD_BYTES = MAX_BINARY_FRAME_BYTES - 24
_HEADER = struct.Struct("!BBBBIQQ")


class MessageType(StrEnum):
    HOST_HELLO = "host.hello"
    HOST_SNAPSHOT = "host.snapshot"
    HOST_STATE = "host.state"
    WORKSPACE_LIST = "workspace.list"
    TERMINAL_LIST = "terminal.list"
    TERMINAL_SUBSCRIBE = "terminal.subscribe"
    TERMINAL_SNAPSHOT = "terminal.snapshot"
    TERMINAL_OUTPUT = "terminal.output"
    TERMINAL_INPUT = "terminal.input"
    TERMINAL_RESIZE = "terminal.resize"
    TERMINAL_CREATE = "terminal.create"
    TERMINAL_RENAME = "terminal.rename"
    TERMINAL_CLOSE = "terminal.close"
    FILE_LIST = "file.list"
    FILE_SEARCH = "file.search"
    FILE_READ = "file.read"
    FILE_WRITE = "file.write"
    OPERATION_RESULT = "operation.result"
    PROTOCOL_ERROR = "protocol.error"


class ControlMessage(BaseModel):
    version: int = Field(default=PROTOCOL_VERSION)
    type: MessageType
    request_id: str = Field(min_length=1, max_length=128)
    operation_id: Optional[str] = Field(default=None, min_length=1, max_length=128)
    payload: dict[str, Any] = Field(default_factory=dict)

    def encode(self) -> bytes:
        data = self.model_dump_json(exclude_none=True).encode("utf-8")
        if len(data) > MAX_CONTROL_BYTES:
            raise ValueError("control message exceeds the limit")
        return data

    @classmethod
    def decode(cls, data: bytes) -> "ControlMessage":
        if len(data) > MAX_CONTROL_BYTES:
            raise ValueError("control message exceeds the limit")
        try:
            raw = json.loads(data)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError("invalid control message JSON") from error
        message = cls.model_validate(raw)
        if message.version != PROTOCOL_VERSION:
            raise ValueError("unsupported remote protocol version")
        return message


class TerminalOpcode(IntEnum):
    SNAPSHOT = 1
    OUTPUT = 2
    INPUT = 3
    RESIZE = 4
    ACK = 5
    ERROR = 6


@dataclass(frozen=True, slots=True)
class TerminalFrame:
    opcode: TerminalOpcode
    stream_id: int
    generation: int
    sequence: int
    payload: bytes

    def encode(self) -> bytes:
        if not 0 <= self.stream_id <= 0xFFFFFFFF:
            raise ValueError("stream_id is out of range")
        if not 0 <= self.generation <= 0xFFFFFFFFFFFFFFFF or not 0 <= self.sequence <= 0xFFFFFFFFFFFFFFFF:
            raise ValueError("generation or sequence is out of range")
        if len(self.payload) > MAX_TERMINAL_PAYLOAD_BYTES:
            raise ValueError("terminal payload exceeds the limit")
        return _HEADER.pack(PROTOCOL_VERSION, int(self.opcode), 0, 0, self.stream_id, self.generation, self.sequence) + self.payload

    @classmethod
    def decode(cls, data: bytes) -> "TerminalFrame":
        if len(data) < _HEADER.size or len(data) > MAX_BINARY_FRAME_BYTES:
            raise ValueError("invalid terminal frame size")
        version, opcode, reserved_a, reserved_b, stream_id, generation, sequence = _HEADER.unpack_from(data)
        if version != PROTOCOL_VERSION or reserved_a or reserved_b:
            raise ValueError("unsupported terminal frame header")
        try:
            parsed_opcode = TerminalOpcode(opcode)
        except ValueError as error:
            raise ValueError("unknown terminal opcode") from error
        return cls(parsed_opcode, stream_id, generation, sequence, data[_HEADER.size :])
