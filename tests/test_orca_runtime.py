from pathlib import Path

import pytest

from tax.orca_runtime import OrcaRuntimeAdapter, OrcaRuntimeError, QuickCommand


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


def test_quick_commands_keep_order_fields_and_full_text():
    transport = FakeTransport(
        {
            "settings.getTerminalQuickCommands": {
                "ok": True,
                "result": {
                    "terminalQuickCommands": [
                        {
                            "id": "qc-1",
                            "label": "Status",
                            "scope": {"type": "global"},
                            "action": "terminal-command",
                            "command": "git status",
                            "appendEnter": True,
                        },
                        {
                            "id": "qc-2",
                            "label": "Paste plan",
                            "scope": {"type": "repo", "repoId": "repo"},
                            "action": "terminal-command",
                            "command": "echo one\n\necho two\n",
                            "appendEnter": False,
                        },
                        {
                            "id": "qc-3",
                            "label": "Review",
                            "scope": {"type": "repo", "repoId": "repo"},
                            "action": "agent-prompt",
                            "agent": "pi",
                            "prompt": "Review\r\nthe diff  ",
                        },
                        {"id": "broken", "label": "Broken", "action": "agent-prompt", "agent": "pi"},
                        "garbage",
                    ]
                },
            }
        }
    )

    commands = OrcaRuntimeAdapter(transport).list_quick_commands()

    assert [command.id for command in commands] == ["qc-1", "qc-2", "qc-3"]
    assert transport.calls == [("settings.getTerminalQuickCommands", {})]
    assert commands[0].scope == "global"
    assert commands[0].repo_id is None
    assert commands[0].command == "git status"
    assert commands[0].append_enter is True
    assert commands[1].scope == "repo"
    assert commands[1].repo_id == "repo"
    assert commands[1].command == "echo one\n\necho two\n"
    assert commands[1].append_enter is False
    assert commands[2].action == "agent-prompt"
    assert commands[2].agent == "pi"
    assert commands[2].prompt == "Review\r\nthe diff  "


def test_quick_commands_report_bad_response_and_runtime_errors_instead_of_empty_list(monkeypatch):
    malformed = FakeTransport(
        {"settings.getTerminalQuickCommands": {"ok": True, "result": {"settings": {}}}}
    )
    with pytest.raises(OrcaRuntimeError) as caught:
        OrcaRuntimeAdapter(malformed).list_quick_commands()
    assert caught.value.code == "invalid_runtime_response"

    incompatible = FakeTransport(
        failures=[OrcaRuntimeError("method_not_found", "unknown method")]
    )
    with pytest.raises(OrcaRuntimeError) as caught:
        OrcaRuntimeAdapter(incompatible).list_quick_commands()
    assert caught.value.code == "method_not_found"
    assert len(incompatible.calls) == 1

    flaky = FakeTransport(
        responses={"settings.getTerminalQuickCommands": {"ok": True, "result": {"terminalQuickCommands": []}}},
        failures=[OrcaRuntimeError("runtime_unavailable", "offline", retryable=True), None],
    )
    monkeypatch.setattr("tax.orca_runtime.time.sleep", lambda _seconds: None)

    assert OrcaRuntimeAdapter(flaky).list_quick_commands() == []
    assert len(flaky.calls) == 2


def test_launch_quick_command_maps_to_session_tab_rpc():
    transport = FakeTransport(
        {
            "session.tabs.createTerminal": {
                "ok": True,
                "result": {
                    "tab": {"type": "terminal", "id": "tab-1", "terminal": "term_new", "title": "Status"}
                },
            }
        }
    )
    adapter = OrcaRuntimeAdapter(transport)

    executed = adapter.launch_quick_command(
        "repo::/workspace",
        QuickCommand("qc-1", "Lines", "global", None, "terminal-command", command="echo one\n\necho two"),
    )
    assert executed.terminal.id == "term_new"
    assert executed.terminal.workspace_id == "repo::/workspace"
    assert executed.terminal.title == "Status"
    assert executed.insert_text is None
    assert transport.calls[0] == (
        "session.tabs.createTerminal",
        {
            "worktree": "id:repo::/workspace",
            "command": "echo one; echo two",
            "startupCommandDelivery": "shell-ready",
        },
    )

    agent = adapter.launch_quick_command(
        "repo::/workspace",
        QuickCommand("qc-3", "Review", "repo", "repo", "agent-prompt", agent="pi", prompt="Review the diff"),
    )
    assert agent.terminal.id == "term_new"
    assert agent.insert_text is None
    assert transport.calls[1][1] == {
        "worktree": "id:repo::/workspace",
        "agent": "pi",
        "agentPrompt": "Review the diff",
    }


    transport.responses["session.tabs.createTerminal"] = {
        "ok": True,
        "result": {"tab": {"type": "terminal", "id": "tab-2", "terminal": "term_paste", "title": "Paste plan"}},
    }
    pasted = adapter.launch_quick_command(
        "repo::/workspace",
        QuickCommand(
            "qc-2",
            "Paste plan",
            "global",
            None,
            "terminal-command",
            command="echo one\n\necho two\n",
            append_enter=False,
        ),
    )
    assert pasted.terminal.id == "term_paste"
    assert pasted.insert_text == "echo one\n\necho two\n"
    assert "command" not in transport.calls[2][1]
    assert "startupCommandDelivery" not in transport.calls[2][1]


def test_launch_quick_command_rejects_incomplete_and_bad_responses():
    adapter = OrcaRuntimeAdapter(FakeTransport())

    with pytest.raises(ValueError):
        adapter.launch_quick_command(
            "repo::/workspace",
            QuickCommand("qc-1", "Empty", "global", None, "terminal-command", command="   "),
        )
    with pytest.raises(ValueError):
        adapter.launch_quick_command(
            "repo::/workspace",
            QuickCommand("qc-2", "Prompt", "global", None, "agent-prompt", agent="pi", prompt="  "),
        )

    transport = FakeTransport(
        {"session.tabs.createTerminal": {"ok": True, "result": {"tab": {"type": "terminal", "id": "tab"}}}}
    )
    with pytest.raises(OrcaRuntimeError) as caught:
        OrcaRuntimeAdapter(transport).launch_quick_command(
            "repo::/workspace",
            QuickCommand("qc-1", "Status", "global", None, "terminal-command", command="git status"),
        )
    assert caught.value.code == "invalid_runtime_response"

    incompatible = FakeTransport(failures=[OrcaRuntimeError("method_not_found", "unknown method")])
    with pytest.raises(OrcaRuntimeError) as caught:
        OrcaRuntimeAdapter(incompatible).launch_quick_command(
            "repo::/workspace",
            QuickCommand("qc-1", "Status", "global", None, "terminal-command", command="git status"),
        )
    assert caught.value.code == "method_not_found"
    assert len(incompatible.calls) == 1


def test_stream_requires_protected_pairing_configuration(tmp_path: Path):
    adapter = OrcaRuntimeAdapter(FakeTransport())

    with pytest.raises(OrcaRuntimeError) as caught:
        adapter.subscribe_terminal("term_1", 80, 24)

    assert caught.value.code == "pairing_required"


def test_rejects_invalid_terminal_input_and_dimensions():
    adapter = OrcaRuntimeAdapter(FakeTransport())

    with pytest.raises(ValueError):
        adapter.send_terminal_input("term_1", b"a\x00b")
    with pytest.raises(ValueError):
        adapter.resize_terminal("term_1", 0, 24)
    with pytest.raises(ValueError):
        adapter.subscribe_terminal("term_1", 1001, 24)
    with pytest.raises(ValueError):
        adapter.rename_terminal("term_1", "  ")
