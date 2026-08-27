import base64
import time

from tax.file_service import ScopedFileService
from tax.orca_runtime import RuntimeDiagnostic, Terminal, TerminalEvent, Workspace
from tax.remote_host import CONTROL_CHANNEL, TERMINAL_CHANNEL, RemoteHost
from tax.remote_protocol import ControlMessage, MessageType, TerminalFrame, TerminalOpcode


class FakeConnection:
    def __init__(self):
        self.sent = []
        self.closed = False

    def send(self, channel, payload):
        self.sent.append((channel, payload))

    def close(self):
        self.closed = True


class FakeStream:
    def __init__(self, terminal_id, events):
        self.terminal_id = terminal_id
        self.events = events
        self.inputs = []
        self.sizes = []
        self.closed = False

    def __iter__(self):
        yield from self.events

    def send_input(self, data):
        self.inputs.append(data)
        return True

    def resize(self, columns, rows):
        self.sizes.append((columns, rows))
        return True

    def request_snapshot(self):
        return True

    def close(self):
        self.closed = True


class FakeRuntime:
    def __init__(self):
        self.created = 0
        self.input = []
        self.closed = []
        self.stream = None

    def diagnostic(self):
        return RuntimeDiagnostic("online", orca_version="1.4.188", runtime_id="runtime")

    def list_workspaces(self):
        return [Workspace("workspace", "repo", "tax", "/workspace", "main", "main", 1, "active")]

    def list_terminals(self, workspace_id=None):
        return [Terminal("term", workspace_id or "workspace", "Pi", True, True)]

    def create_terminal(self, workspace_id, title=None):
        self.created += 1
        return Terminal("created", workspace_id, title or "Terminal", True, True)

    def rename_terminal(self, terminal_id, title):
        pass

    def close_terminal(self, terminal_id):
        self.closed.append(terminal_id)

    def send_terminal_input(self, terminal_id, data):
        self.input.append((terminal_id, data))

    def resize_terminal(self, terminal_id, columns, rows):
        pass

    def subscribe_terminal(self, terminal_id):
        self.stream = FakeStream(
            terminal_id,
            [
                TerminalEvent("snapshot", terminal_id, data=b"snapshot"),
                TerminalEvent("output", terminal_id, data=b"incremental"),
            ],
        )
        return self.stream


def request(message_type, payload=None, operation_id=None, request_id="request"):
    return ControlMessage(
        type=message_type,
        request_id=request_id,
        operation_id=operation_id,
        payload=payload or {},
    ).encode()


def response_messages(connection):
    return [ControlMessage.decode(payload) for channel, payload in connection.sent if channel == CONTROL_CHANNEL]


def test_remote_host_inventory_and_mutation_deduplication():
    runtime = FakeRuntime()
    connection = FakeConnection()
    host = RemoteHost(runtime, connection)

    host._handle_control(request(MessageType.WORKSPACE_LIST))
    create = request(
        MessageType.TERMINAL_CREATE,
        {"workspace_id": "workspace", "title": "Remote"},
        operation_id="stable-operation",
    )
    host._handle_control(create)
    host._handle_control(create)

    messages = response_messages(connection)
    assert messages[0].payload["workspaces"][0]["id"] == "workspace"
    assert messages[1].payload["terminal"]["id"] == "created"
    assert messages[1].encode() == messages[2].encode()
    assert runtime.created == 1


def test_remote_host_forwards_snapshot_output_and_stream_input():
    runtime = FakeRuntime()
    connection = FakeConnection()
    host = RemoteHost(runtime, connection)

    host._handle_control(request(MessageType.TERMINAL_SUBSCRIBE, {"terminal_id": "term"}))
    deadline = time.monotonic() + 2
    while len([item for item in connection.sent if item[0] == TERMINAL_CHANNEL]) < 2 and time.monotonic() < deadline:
        time.sleep(0.01)

    subscribed = next(
        message for message in response_messages(connection) if message.type is MessageType.OPERATION_RESULT
    ).payload
    frames = [TerminalFrame.decode(payload) for channel, payload in connection.sent if channel == TERMINAL_CHANNEL]
    assert [frame.opcode for frame in frames] == [TerminalOpcode.SNAPSHOT, TerminalOpcode.OUTPUT]
    assert [frame.sequence for frame in frames] == [1, 2]
    assert all(frame.generation == subscribed["generation"] for frame in frames)

    # Use a held stream because the finite fixture stream has already ended.
    stream = FakeStream("term", [])
    host._subscriptions[subscribed["stream_id"]] = stream
    host._stream_generations[subscribed["stream_id"]] = subscribed["generation"]
    input_frame = TerminalFrame(
        TerminalOpcode.INPUT,
        subscribed["stream_id"],
        subscribed["generation"],
        1,
        b"pi\r",
    )
    host._handle_terminal_frame(input_frame.encode())
    assert stream.inputs == [b"pi\r"]


def test_remote_host_control_input_acknowledges_after_runtime_accepts():
    runtime = FakeRuntime()
    connection = FakeConnection()
    host = RemoteHost(runtime, connection)

    host._handle_control(
        request(
            MessageType.TERMINAL_INPUT,
            {"terminal_id": "term", "data_b64": base64.b64encode(b"pi\r").decode()},
            operation_id="input-once",
        )
    )

    assert runtime.input == [("term", b"pi\r")]
    assert response_messages(connection)[-1].payload == {"ok": True, "accepted": True}


def test_remote_host_file_round_trip_and_conflict(tmp_path):
    path = tmp_path / "README.md"
    path.write_text("first")
    runtime = FakeRuntime()
    connection = FakeConnection()
    host = RemoteHost(runtime, connection, ScopedFileService(lambda: {"workspace": tmp_path}))

    host._handle_control(request(MessageType.FILE_LIST, {"workspace_id": "workspace", "path": ""}))
    host._handle_control(request(MessageType.FILE_READ, {"workspace_id": "workspace", "path": "README.md"}))
    messages = response_messages(connection)
    assert messages[0].payload["entries"][0]["name"] == "README.md"
    read = messages[1].payload
    host._handle_control(
        request(
            MessageType.FILE_WRITE,
            {
                "workspace_id": "workspace",
                "path": "README.md",
                "data_b64": base64.b64encode(b"second").decode(),
                "expected_revision": read["revision"],
            },
            operation_id="write-once",
        )
    )
    assert path.read_text() == "second"


def test_remote_host_rejects_plaintext_and_unknown_control_messages():
    runtime = FakeRuntime()
    connection = FakeConnection()
    host = RemoteHost(runtime, connection)

    host._handle_control(b"not json")
    host._handle_control(request(MessageType.FILE_READ, {"path": "README.md"}, request_id="files"))

    errors = response_messages(connection)
    assert errors[0].type is MessageType.PROTOCOL_ERROR
    assert errors[1].request_id == "files"
    assert errors[1].payload["ok"] is False
