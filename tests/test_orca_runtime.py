from pathlib import Path

import pytest

from tax.orca_runtime import OrcaRuntimeAdapter, OrcaRuntimeError


class FakeTransport:
    def __init__(self, responses=None, failures=None):
        self.responses = responses or {}
        self.failures = list(failures or [])
        self.calls = []

    def request(self, method, params=None):
        self.calls.append((method, params))
        if self.failures:
            error = self.failures.pop(0)
            if error:
                raise error
        return self.responses.get(method, {"ok": True, "result": {}})


def test_diagnostic_reports_compatible_runtime():
    transport = FakeTransport(
        {
            "status.get": {
                "ok": True,
                "result": {
                    "runtimeId": "runtime-1",
                    "appVersion": "1.4.188",
                    "graphStatus": "ready",
                    "capabilities": [
                        "runtime.status.compat.v1",
                        "terminal.binary-stream.v1",
                        "terminal.multiplex.v1",
                    ],
                },
            }
        }
    )

    diagnostic = OrcaRuntimeAdapter(transport).diagnostic()

    assert diagnostic.state == "online"
    assert diagnostic.runtime_id == "runtime-1"
    assert diagnostic.missing_capabilities == ()


def test_diagnostic_reports_missing_capabilities():
    transport = FakeTransport(
        {
            "status.get": {
                "ok": True,
                "result": {"graphStatus": "ready", "capabilities": ["runtime.status.compat.v1"]},
            }
        }
    )

    diagnostic = OrcaRuntimeAdapter(transport).diagnostic()

    assert diagnostic.state == "incompatible"
    assert diagnostic.missing_capabilities == ("terminal.binary-stream.v1", "terminal.multiplex.v1")


def test_maps_only_open_workspaces_and_terminals():
    transport = FakeTransport(
        {
            "worktree.ps": {
                "ok": True,
                "result": {
                    "worktrees": [
                        {
                            "worktreeId": "repo::/workspace",
                            "repoId": "repo",
                            "repo": "tax",
                            "path": "/workspace",
                            "branch": "refs/heads/main",
                            "displayName": "main",
                            "liveTerminalCount": 1,
                            "status": "working",
                            "isArchived": False,
                        },
                        {"worktreeId": "archived", "isArchived": True},
                    ]
                },
            },
            "terminal.list": {
                "ok": True,
                "result": {
                    "terminals": [
                        {
                            "handle": "term_1",
                            "worktreeId": "repo::/workspace",
                            "title": "Pi",
                            "connected": True,
                            "writable": True,
                        }
                    ]
                },
            },
        }
    )
    adapter = OrcaRuntimeAdapter(transport)

    workspaces = adapter.list_workspaces()
    terminals = adapter.list_terminals(workspaces[0].id)

    assert [workspace.id for workspace in workspaces] == ["repo::/workspace"]
    assert workspaces[0].agent_state == "working"
    assert [terminal.id for terminal in terminals] == ["term_1"]
    assert transport.calls[-1][1]["worktree"] == "id:repo::/workspace"


def test_read_retries_with_backoff_but_mutation_is_never_retried(monkeypatch):
    retryable = OrcaRuntimeError("runtime_unavailable", "offline", retryable=True)
    reads = FakeTransport(
        responses={"worktree.ps": {"ok": True, "result": {"worktrees": []}}},
        failures=[retryable, None],
    )
    sleeps = []
    monkeypatch.setattr("tax.orca_runtime.time.sleep", sleeps.append)

    assert OrcaRuntimeAdapter(reads, retry_base_delay=0.25).list_workspaces() == []
    assert sleeps == [0.25]
    assert len(reads.calls) == 2

    mutations = FakeTransport(failures=[retryable])
    with pytest.raises(OrcaRuntimeError):
        OrcaRuntimeAdapter(mutations).rename_terminal("term_1", "Renamed")
    assert len(mutations.calls) == 1


def test_terminal_operations_map_to_private_rpc_without_replaying_input():
    transport = FakeTransport(
        {
            "terminal.create": {
                "ok": True,
                "result": {
                    "terminal": {
                        "handle": "term_new",
                        "worktreeId": "repo::/workspace",
                        "title": "Remote",
                        "connected": True,
                        "writable": True,
                    }
                },
            }
        }
    )
    adapter = OrcaRuntimeAdapter(transport)

    created = adapter.create_terminal("repo::/workspace", "Remote")
    adapter.send_terminal_input(created.id, b"pi\r")
    adapter.send_terminal_input(created.id, b"\x03")
    adapter.resize_terminal(created.id, 100, 40)
    adapter.rename_terminal(created.id, "Pi")
    adapter.close_terminal(created.id)

    assert created.id == "term_new"
    assert transport.calls[1][1]["text"] == "pi"
    assert transport.calls[1][1]["enter"] is True
    assert transport.calls[2][1]["interrupt"] is True
    assert transport.calls[3][0] == "terminal.updateViewport"
    assert transport.calls[-1] == ("terminal.close", {"terminal": "term_new"})


def test_stream_requires_protected_pairing_configuration(tmp_path: Path):
    adapter = OrcaRuntimeAdapter(FakeTransport())

    with pytest.raises(OrcaRuntimeError) as caught:
        adapter.subscribe_terminal("term_1")

    assert caught.value.code == "pairing_required"


def test_rejects_invalid_terminal_input_and_dimensions():
    adapter = OrcaRuntimeAdapter(FakeTransport())

    with pytest.raises(ValueError):
        adapter.send_terminal_input("term_1", b"a\x00b")
    with pytest.raises(ValueError):
        adapter.resize_terminal("term_1", 0, 24)
    with pytest.raises(ValueError):
        adapter.rename_terminal("term_1", "  ")
