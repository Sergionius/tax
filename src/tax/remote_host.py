"""Mac remote host connecting Orca Runtime to the ciphertext relay."""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import threading
import uuid
from dataclasses import asdict
from pathlib import Path
from typing import Any, Optional

from tax.e2ee import decode_key
from tax.logging_utils import configure_logging, log_event
from tax.orca_runtime import OrcaRuntimeAdapter, OrcaRuntimeError, TerminalEventStream, WorkspaceRuntime
from tax.relay_client import EncryptedRelayConnection
from tax.remote_protocol import ControlMessage, MessageType, TerminalFrame, TerminalOpcode

CONTROL_CHANNEL = 1
TERMINAL_CHANNEL = 2
logger = configure_logging("tax-remote-host")


class OperationDeduplicator:
    """Bounded in-memory cache for stable mutating operation IDs."""

    def __init__(self, limit: int = 1024):
        self.limit = limit
        self._results: dict[str, bytes] = {}
        self._order: list[str] = []
        self._lock = threading.Lock()

    def get(self, operation_id: str) -> Optional[bytes]:
        with self._lock:
            return self._results.get(operation_id)

    def put(self, operation_id: str, result: bytes) -> None:
        with self._lock:
            if operation_id in self._results:
                return
            self._results[operation_id] = result
            self._order.append(operation_id)
            while len(self._order) > self.limit:
                self._results.pop(self._order.pop(0), None)


class RemoteHost:
    def __init__(self, runtime: WorkspaceRuntime, connection: EncryptedRelayConnection):
        self.runtime = runtime
        self.connection = connection
        self.operations = OperationDeduplicator()
        self._subscriptions: dict[int, TerminalEventStream] = {}
        self._subscription_threads: dict[int, threading.Thread] = {}
        self._stream_terminal_ids: dict[int, str] = {}
        self._stream_generations: dict[int, int] = {}
        self._send_lock = threading.Lock()
        self._stop = threading.Event()
        self._next_stream_id = 1
        self._generation = 0

    def run(self) -> None:
        self._send_control(
            ControlMessage(
                type=MessageType.HOST_HELLO,
                request_id=str(uuid.uuid4()),
                payload={"diagnostic": asdict(self.runtime.diagnostic())},
            )
        )
        try:
            while not self._stop.is_set():
                channel, payload = self.connection.receive()
                if channel == CONTROL_CHANNEL:
                    self._handle_control(payload)
                elif channel == TERMINAL_CHANNEL:
                    self._handle_terminal_frame(payload)
                else:
                    raise ValueError("unsupported encrypted channel")
        finally:
            self.close()

    def close(self) -> None:
        if self._stop.is_set():
            return
        self._stop.set()
        for subscription in list(self._subscriptions.values()):
            subscription.close()
        self._subscriptions.clear()
        self._stream_terminal_ids.clear()
        self._stream_generations.clear()
        self.connection.close()

    def _handle_control(self, payload: bytes) -> None:
        try:
            request = ControlMessage.decode(payload)
        except (ValueError, TypeError) as error:
            self._send_error("unknown", "invalid_message", str(error))
            return

        if request.operation_id:
            cached = self.operations.get(request.operation_id)
            if cached is not None:
                self._send(CONTROL_CHANNEL, cached)
                return

        try:
            response_payload = self._dispatch(request)
            response = ControlMessage(
                type=MessageType.OPERATION_RESULT,
                request_id=request.request_id,
                operation_id=request.operation_id,
                payload={"ok": True, **response_payload},
            ).encode()
        except (OrcaRuntimeError, ValueError, KeyError, TypeError) as error:
            code = error.code if isinstance(error, OrcaRuntimeError) else "invalid_request"
            response = ControlMessage(
                type=MessageType.PROTOCOL_ERROR,
                request_id=request.request_id,
                operation_id=request.operation_id,
                payload={"ok": False, "code": code, "message": str(error)},
            ).encode()

        if request.operation_id:
            self.operations.put(request.operation_id, response)
        self._send(CONTROL_CHANNEL, response)

    def _dispatch(self, request: ControlMessage) -> dict[str, Any]:
        payload = request.payload
        if request.type is MessageType.HOST_STATE:
            return {"diagnostic": asdict(self.runtime.diagnostic())}
        if request.type is MessageType.WORKSPACE_LIST:
            return {"workspaces": [asdict(item) for item in self.runtime.list_workspaces()]}
        if request.type is MessageType.TERMINAL_LIST:
            workspace_id = payload.get("workspace_id")
            return {
                "workspace_id": workspace_id,
                "terminals": [asdict(item) for item in self.runtime.list_terminals(workspace_id)],
            }
        if request.type is MessageType.TERMINAL_SUBSCRIBE:
            return self._subscribe(str(payload["terminal_id"]))
        if request.type is MessageType.TERMINAL_INPUT:
            terminal_id = str(payload["terminal_id"])
            data = base64.b64decode(str(payload["data_b64"]), validate=True)
            self.runtime.send_terminal_input(terminal_id, data)
            return {"accepted": True}
        if request.type is MessageType.TERMINAL_RESIZE:
            self.runtime.resize_terminal(
                str(payload["terminal_id"]), int(payload["columns"]), int(payload["rows"])
            )
            return {"accepted": True}
        if request.type is MessageType.TERMINAL_CREATE:
            terminal = self.runtime.create_terminal(str(payload["workspace_id"]), payload.get("title"))
            return {"terminal": asdict(terminal)}
        if request.type is MessageType.TERMINAL_RENAME:
            self.runtime.rename_terminal(str(payload["terminal_id"]), str(payload["title"]))
            return {"accepted": True}
        if request.type is MessageType.TERMINAL_CLOSE:
            terminal_id = str(payload["terminal_id"])
            self._close_terminal_subscription(terminal_id)
            self.runtime.close_terminal(terminal_id)
            return {"accepted": True}
        raise ValueError(f"unsupported message type: {request.type}")

    def _subscribe(self, terminal_id: str) -> dict[str, Any]:
        self._close_terminal_subscription(terminal_id)
        stream_id = self._next_stream_id
        self._next_stream_id += 1
        self._generation += 1
        generation = self._generation
        subscription = self.runtime.subscribe_terminal(terminal_id)
        self._subscriptions[stream_id] = subscription
        self._stream_terminal_ids[stream_id] = terminal_id
        self._stream_generations[stream_id] = generation
        thread = threading.Thread(
            target=self._forward_terminal_events,
            args=(stream_id, generation, terminal_id, subscription),
            name=f"tax-terminal-{stream_id}",
            daemon=True,
        )
        self._subscription_threads[stream_id] = thread
        thread.start()
        return {"terminal_id": terminal_id, "stream_id": stream_id, "generation": generation}

    def _forward_terminal_events(
        self, stream_id: int, generation: int, terminal_id: str, subscription: TerminalEventStream
    ) -> None:
        sequence = 0
        try:
            for event in subscription:
                if self._stop.is_set() or self._subscriptions.get(stream_id) is not subscription:
                    return
                if event.kind in {"snapshot", "output"}:
                    sequence += 1
                    opcode = TerminalOpcode.SNAPSHOT if event.kind == "snapshot" else TerminalOpcode.OUTPUT
                    frame = TerminalFrame(opcode, stream_id, generation, sequence, event.data)
                    self._send(TERMINAL_CHANNEL, frame.encode())
                elif event.kind == "resized":
                    self._send_control(
                        ControlMessage(
                            type=MessageType.HOST_STATE,
                            request_id=str(uuid.uuid4()),
                            payload={
                                "event": "terminal.resized",
                                "terminal_id": terminal_id,
                                "stream_id": stream_id,
                                "generation": generation,
                                "columns": event.columns,
                                "rows": event.rows,
                            },
                        )
                    )
                elif event.kind in {"error", "write_unavailable"}:
                    self._send_error(
                        str(uuid.uuid4()),
                        event.kind,
                        event.message or "terminal stream failed",
                        terminal_id=terminal_id,
                    )
                elif event.kind == "closed":
                    return
        except Exception as error:
            log_event(logger, "terminal_forward_failed", level=logging.WARNING, terminal_id=terminal_id, error=str(error))
        finally:
            if self._subscriptions.get(stream_id) is subscription:
                self._subscriptions.pop(stream_id, None)
                self._subscription_threads.pop(stream_id, None)
                self._stream_terminal_ids.pop(stream_id, None)
                self._stream_generations.pop(stream_id, None)

    def _handle_terminal_frame(self, payload: bytes) -> None:
        try:
            frame = TerminalFrame.decode(payload)
            subscription = self._subscriptions.get(frame.stream_id)
            if not subscription or frame.generation != self._stream_generations.get(frame.stream_id):
                raise ValueError("stale terminal stream generation")
            if frame.opcode is TerminalOpcode.INPUT:
                if not subscription.send_input(frame.payload):
                    raise ValueError("terminal input delivery is unavailable")
            elif frame.opcode is TerminalOpcode.RESIZE:
                dimensions = json.loads(frame.payload)
                if not subscription.resize(int(dimensions["columns"]), int(dimensions["rows"])):
                    raise ValueError("terminal resize delivery is unavailable")
            elif frame.opcode is TerminalOpcode.ACK:
                return
            else:
                raise ValueError("unsupported client terminal opcode")
        except (ValueError, TypeError, KeyError, json.JSONDecodeError) as error:
            self._send_error(str(uuid.uuid4()), "invalid_terminal_frame", str(error))

    def _close_terminal_subscription(self, terminal_id: str) -> None:
        for stream_id, subscription in list(self._subscriptions.items()):
            thread = self._subscription_threads.get(stream_id)
            if self._stream_terminal_ids.get(stream_id) != terminal_id:
                continue
            self._subscriptions.pop(stream_id, None)
            self._subscription_threads.pop(stream_id, None)
            self._stream_terminal_ids.pop(stream_id, None)
            self._stream_generations.pop(stream_id, None)
            subscription.close()
            if thread and thread is not threading.current_thread():
                thread.join(timeout=1)

    def _send_control(self, message: ControlMessage) -> None:
        self._send(CONTROL_CHANNEL, message.encode())

    def _send_error(self, request_id: str, code: str, message: str, **payload: Any) -> None:
        self._send_control(
            ControlMessage(
                type=MessageType.PROTOCOL_ERROR,
                request_id=request_id,
                payload={"ok": False, "code": code, "message": message, **payload},
            )
        )

    def _send(self, channel: int, payload: bytes) -> None:
        with self._send_lock:
            self.connection.send(channel, payload)


def run_remote_host(
    *,
    server: str,
    api_key: str,
    host_id: str,
    device_id: str,
    e2ee_key: str,
    orca_pairing_code_file: Path,
) -> None:
    secret = decode_key(e2ee_key)
    runtime = OrcaRuntimeAdapter(pairing_code_file=orca_pairing_code_file)
    diagnostic = runtime.diagnostic()
    if diagnostic.state == "incompatible":
        missing = ", ".join(diagnostic.missing_capabilities)
        raise OrcaRuntimeError("runtime_incompatible", f"Orca Runtime is incompatible; missing: {missing}")
    with EncryptedRelayConnection.connect(
        server, api_key, secret, role="host", host_id=host_id, device_id=device_id
    ) as connection:
        RemoteHost(runtime, connection).run()


def stable_generation(value: str) -> int:
    """Fixture helper for mapping opaque generations without leaking them."""
    return int.from_bytes(hashlib.sha256(value.encode()).digest()[:8], "big")
