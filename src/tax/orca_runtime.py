"""Stable Mac-side boundary around Orca's private Runtime protocol."""

from __future__ import annotations

import base64
import json
import socket
import subprocess
import threading
import time
import uuid
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional, Protocol

REQUIRED_CAPABILITIES = frozenset({"runtime.status.compat.v1", "terminal.binary-stream.v1", "terminal.multiplex.v1"})
DEFAULT_ORCA_USER_DATA = Path.home() / "Library" / "Application Support" / "Orca"
DEFAULT_PROBE_BRIDGE = Path(__file__).with_name("resources") / "orca-runtime-terminal-bridge.cjs"
MAX_RPC_FRAME_BYTES = 8 * 1024 * 1024


class OrcaRuntimeError(RuntimeError):
    """A stable adapter error that does not expose Orca protocol internals."""

    def __init__(self, code: str, message: str, *, retryable: bool = False):
        super().__init__(message)
        self.code = code
        self.retryable = retryable


@dataclass(frozen=True, slots=True)
class Workspace:
    id: str
    project_id: str
    project_name: str
    path: str
    branch: str
    display_name: str
    terminal_count: int
    agent_state: str


@dataclass(frozen=True, slots=True)
class Terminal:
    id: str
    workspace_id: str
    title: str
    connected: bool
    writable: bool
    columns: Optional[int] = None
    rows: Optional[int] = None


@dataclass(frozen=True, slots=True)
class TerminalEvent:
    kind: str
    terminal_id: str
    data: bytes = b""
    generation: Optional[str] = None
    sequence: Optional[int] = None
    columns: Optional[int] = None
    rows: Optional[int] = None
    message: Optional[str] = None


@dataclass(frozen=True, slots=True)
class RuntimeDiagnostic:
    state: str
    orca_version: Optional[str] = None
    runtime_id: Optional[str] = None
    missing_capabilities: tuple[str, ...] = ()
    message: Optional[str] = None


class TerminalEventStream(Protocol):
    def __iter__(self) -> Iterator[TerminalEvent]: ...

    def send_input(self, data: bytes) -> bool: ...

    def resize(self, columns: int, rows: int) -> bool: ...

    def request_snapshot(self) -> bool: ...

    def close(self) -> None: ...


class WorkspaceRuntime(Protocol):
    def diagnostic(self) -> RuntimeDiagnostic: ...

    def list_workspaces(self) -> list[Workspace]: ...

    def watch_workspace_graph(self, interval: float = 1.0) -> Iterator[list[Workspace]]: ...

    def list_terminals(self, workspace_id: Optional[str] = None) -> list[Terminal]: ...

    def subscribe_terminal(self, terminal_id: str, columns: int, rows: int) -> TerminalEventStream: ...

    def send_terminal_input(self, terminal_id: str, data: bytes) -> None: ...

    def resize_terminal(self, terminal_id: str, columns: int, rows: int) -> None: ...

    def create_terminal(self, workspace_id: str, title: Optional[str] = None) -> Terminal: ...

    def rename_terminal(self, terminal_id: str, title: str) -> None: ...

    def close_terminal(self, terminal_id: str) -> None: ...


class OrcaLocalRPCTransport:
    """One-shot local Runtime RPC. Streaming is delegated to the paired bridge."""

    def __init__(self, user_data_path: Path = DEFAULT_ORCA_USER_DATA, timeout: float = 15.0):
        self.user_data_path = user_data_path
        self.timeout = timeout

    def _metadata(self) -> dict[str, Any]:
        try:
            metadata = json.loads((self.user_data_path / "orca-runtime.json").read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise OrcaRuntimeError("runtime_unavailable", "Orca runtime metadata is unavailable", retryable=True) from error
        transports = metadata.get("transports") or [metadata.get("transport")]
        transport = next(
            (item for item in transports if isinstance(item, dict) and item.get("kind") in {"unix", "named-pipe"}),
            None,
        )
        if not transport or not metadata.get("authToken"):
            raise OrcaRuntimeError("runtime_incompatible", "Orca has no compatible local Runtime transport")
        return {**metadata, "localTransport": transport}

    def request(self, method: str, params: Optional[dict[str, Any]] = None) -> dict[str, Any]:
        metadata = self._metadata()
        request_id = str(uuid.uuid4())
        payload = json.dumps(
            {"id": request_id, "authToken": metadata["authToken"], "method": method, "params": params or {}},
            separators=(",", ":"),
        ).encode() + b"\n"
        endpoint = metadata["localTransport"]["endpoint"]
        buffer = bytearray()
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(self.timeout)
                connection.connect(endpoint)
                connection.sendall(payload)
                while True:
                    chunk = connection.recv(65536)
                    if not chunk:
                        break
                    buffer.extend(chunk)
                    if len(buffer) > MAX_RPC_FRAME_BYTES:
                        raise OrcaRuntimeError("invalid_runtime_response", "Orca Runtime response exceeded the limit")
                    while b"\n" in buffer:
                        raw, _, remainder = buffer.partition(b"\n")
                        buffer = bytearray(remainder)
                        if not raw.strip():
                            continue
                        frame = json.loads(raw)
                        if frame.get("_keepalive") is True:
                            continue
                        if frame.get("id") != request_id:
                            raise OrcaRuntimeError("invalid_runtime_response", "Orca Runtime returned a mismatched response")
                        if frame.get("ok") is not True:
                            error = frame.get("error") if isinstance(frame.get("error"), dict) else {}
                            raise OrcaRuntimeError(
                                str(error.get("code") or "runtime_error"),
                                str(error.get("message") or "Orca Runtime request failed"),
                            )
                        return frame
        except OrcaRuntimeError:
            raise
        except (OSError, TimeoutError, json.JSONDecodeError) as error:
            raise OrcaRuntimeError("runtime_unavailable", "Could not communicate with Orca Runtime", retryable=True) from error
        raise OrcaRuntimeError("runtime_unavailable", "Orca Runtime closed before responding", retryable=True)


class OrcaTerminalSubscription:
    def __init__(self, terminal_id: str, pairing_code_file: Path, columns: int, rows: int, bridge_path: Path = DEFAULT_PROBE_BRIDGE):
        if not 1 <= columns <= 1000 or not 1 <= rows <= 1000:
            raise ValueError("terminal dimensions must be between 1 and 1000")
        self.terminal_id = terminal_id
        self._closed = False
        self._write_lock = threading.Lock()
        self._process = subprocess.Popen(
            [str(bridge_path), "--terminal", terminal_id, "--pairing-code-file", str(pairing_code_file), "--columns", str(columns), "--rows", str(rows)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )

    def _command(self, kind: str, **values: Any) -> bool:
        with self._write_lock:
            if self._closed or self._process.poll() is not None or self._process.stdin is None:
                return False
            try:
                self._process.stdin.write(json.dumps({"type": kind, **values}, separators=(",", ":")) + "\n")
                self._process.stdin.flush()
                return True
            except (BrokenPipeError, OSError):
                return False

    def __iter__(self) -> Iterator[TerminalEvent]:
        if self._process.stdout is None:
            return
        for raw in self._process.stdout:
            try:
                event = json.loads(raw)
                kind = str(event.get("type") or "")
                data = base64.b64decode(event.get("data_b64") or "", validate=True)
            except (json.JSONDecodeError, ValueError):
                yield TerminalEvent("error", self.terminal_id, message="invalid terminal bridge event")
                continue
            if kind in {"snapshot", "output"}:
                yield TerminalEvent(
                    kind,
                    self.terminal_id,
                    data=data,
                    generation=event.get("generation"),
                    sequence=event.get("sequence"),
                    columns=event.get("columns"),
                    rows=event.get("rows"),
                )
            elif kind in {"resized", "error", "closed", "write_unavailable"}:
                yield TerminalEvent(
                    kind,
                    self.terminal_id,
                    columns=event.get("columns"),
                    rows=event.get("rows"),
                    message=event.get("message"),
                )
            if kind == "closed":
                self._closed = True
                return

    def send_input(self, data: bytes) -> bool:
        return self._command("input", data_b64=base64.b64encode(data).decode("ascii"))

    def resize(self, columns: int, rows: int) -> bool:
        if not 1 <= columns <= 1000 or not 1 <= rows <= 1000:
            raise ValueError("terminal dimensions must be between 1 and 1000")
        return self._command("resize", columns=columns, rows=rows)

    def request_snapshot(self) -> bool:
        return self._command("snapshot")

    def close(self) -> None:
        if self._closed:
            return
        self._command("close")
        self._closed = True
        try:
            self._process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self._process.terminate()


class OrcaRuntimeAdapter:
    """Maps private Orca RPC values onto tax-owned stable models."""

    def __init__(
        self,
        transport: Optional[OrcaLocalRPCTransport] = None,
        *,
        pairing_code_file: Optional[Path] = None,
        retry_attempts: int = 3,
        retry_base_delay: float = 0.1,
    ):
        self.transport = transport or OrcaLocalRPCTransport()
        self.pairing_code_file = pairing_code_file
        self.retry_attempts = max(1, retry_attempts)
        self.retry_base_delay = max(0, retry_base_delay)
        self._diagnostic = RuntimeDiagnostic("connecting")

    def _read(self, method: str, params: Optional[dict[str, Any]] = None) -> dict[str, Any]:
        for attempt in range(self.retry_attempts):
            try:
                return self.transport.request(method, params)
            except OrcaRuntimeError as error:
                self._diagnostic = RuntimeDiagnostic("orca_offline", message=str(error))
                if not error.retryable or attempt + 1 == self.retry_attempts:
                    raise
                time.sleep(self.retry_base_delay * (2**attempt))
        raise AssertionError("unreachable")

    def _mutate(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        # Never retry a mutation: a disconnected response has an ambiguous outcome.
        return self.transport.request(method, params)

    def diagnostic(self) -> RuntimeDiagnostic:
        try:
            response = self._read("status.get")
        except OrcaRuntimeError:
            return self._diagnostic
        result = response.get("result", {})
        capabilities = set(result.get("capabilities") or [])
        missing = tuple(sorted(REQUIRED_CAPABILITIES - capabilities))
        state = "incompatible" if missing else ("online" if result.get("graphStatus") == "ready" else "orca_offline")
        self._diagnostic = RuntimeDiagnostic(
            state,
            orca_version=result.get("appVersion"),
            runtime_id=result.get("runtimeId"),
            missing_capabilities=missing,
            message="Required Orca Runtime capabilities are missing" if missing else None,
        )
        return self._diagnostic

    def list_workspaces(self) -> list[Workspace]:
        rows = self._read("worktree.ps", {"limit": 500}).get("result", {}).get("worktrees", [])
        return [
            Workspace(
                id=str(row["worktreeId"]),
                project_id=str(row.get("repoId") or ""),
                project_name=str(row.get("repo") or ""),
                path=str(row.get("path") or ""),
                branch=str(row.get("branch") or ""),
                display_name=str(row.get("displayName") or ""),
                terminal_count=int(row.get("liveTerminalCount") or 0),
                agent_state=str(row.get("status") or "idle"),
            )
            for row in rows
            if isinstance(row, dict) and row.get("worktreeId") and row.get("isArchived") is not True
        ]

    def watch_workspace_graph(self, interval: float = 1.0) -> Iterator[list[Workspace]]:
        previous: Optional[list[Workspace]] = None
        while True:
            current = self.list_workspaces()
            if current != previous:
                yield current
                previous = current
            time.sleep(max(0.05, interval))

    def list_terminals(self, workspace_id: Optional[str] = None) -> list[Terminal]:
        params: dict[str, Any] = {"includeVisualLayouts": False, "limit": 500}
        if workspace_id:
            params["worktree"] = f"id:{workspace_id}"
        rows = self._read("terminal.list", params).get("result", {}).get("terminals", [])
        return [self._terminal(row) for row in rows if isinstance(row, dict) and row.get("handle")]

    def subscribe_terminal(self, terminal_id: str, columns: int, rows: int) -> OrcaTerminalSubscription:
        if not 1 <= columns <= 1000 or not 1 <= rows <= 1000:
            raise ValueError("terminal dimensions must be between 1 and 1000")
        if not self.pairing_code_file:
            raise OrcaRuntimeError("pairing_required", "Orca pairing code is required for terminal streaming")
        return OrcaTerminalSubscription(terminal_id, self.pairing_code_file, columns, rows)

    def send_terminal_input(self, terminal_id: str, data: bytes) -> None:
        if b"\x00" in data:
            raise ValueError("terminal input cannot contain NUL")
        interrupt = data == b"\x03"
        text = "" if interrupt else data.decode("utf-8")
        enter = text.endswith(("\r", "\n"))
        if enter:
            text = text.rstrip("\r\n")
        self._mutate(
            "terminal.send",
            {
                "terminal": terminal_id,
                "text": text or None,
                "enter": enter,
                "interrupt": interrupt,
                "client": {"id": "tax-agent", "type": "desktop"},
            },
        )

    def resize_terminal(self, terminal_id: str, columns: int, rows: int) -> None:
        if not 1 <= columns <= 1000 or not 1 <= rows <= 1000:
            raise ValueError("terminal dimensions must be between 1 and 1000")
        self._mutate(
            "terminal.updateViewport",
            {
                "terminal": terminal_id,
                "client": {"id": "tax-agent", "type": "desktop"},
                "viewport": {"cols": columns, "rows": rows},
                "claim": True,
            },
        )

    def create_terminal(self, workspace_id: str, title: Optional[str] = None) -> Terminal:
        result = self._mutate(
            "terminal.create",
            {"worktree": f"id:{workspace_id}", "title": title, "focus": False},
        ).get("result", {})
        row = result.get("terminal") if isinstance(result.get("terminal"), dict) else result
        if not isinstance(row, dict) or not row.get("handle"):
            raise OrcaRuntimeError("invalid_runtime_response", "Orca did not return the created terminal")
        return self._terminal(row, workspace_id)

    def rename_terminal(self, terminal_id: str, title: str) -> None:
        if not title.strip():
            raise ValueError("terminal title is required")
        self._mutate("terminal.rename", {"terminal": terminal_id, "title": title.strip()})

    def close_terminal(self, terminal_id: str) -> None:
        self._mutate("terminal.close", {"terminal": terminal_id})

    @staticmethod
    def _terminal(row: dict[str, Any], workspace_id: str = "") -> Terminal:
        return Terminal(
            id=str(row["handle"]),
            workspace_id=str(row.get("worktreeId") or workspace_id),
            title=str(row.get("title") or "Terminal"),
            connected=bool(row.get("connected", True)),
            writable=bool(row.get("writable", True)),
            columns=row.get("cols"),
            rows=row.get("rows"),
        )
