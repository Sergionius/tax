import assert from "node:assert/strict";
import { afterEach, test } from "node:test";

import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

import registerExtension from "../../extensions/tax-push-omp.ts";

const ORIGINAL_FETCH = globalThis.fetch;
const ENV_KEYS = [
  "TAX_API_KEY",
  "TAX_SERVER",
  "TAX_HOST_ID",
  "TAX_PUSH_DEBUG",
  "ORCA_TERMINAL_HANDLE",
  "ORCA_WORKTREE_ID",
  "ORCA_WORKSPACE_ID",
  "ORCA_TAB_ID",
  "ORCA_PANE_KEY",
] as const;
type EnvKey = (typeof ENV_KEYS)[number];
const ORIGINAL_ENV: Record<EnvKey, string | undefined> = {
  TAX_API_KEY: process.env.TAX_API_KEY,
  TAX_SERVER: process.env.TAX_SERVER,
  TAX_HOST_ID: process.env.TAX_HOST_ID,
  TAX_PUSH_DEBUG: process.env.TAX_PUSH_DEBUG,
  ORCA_TERMINAL_HANDLE: process.env.ORCA_TERMINAL_HANDLE,
  ORCA_WORKTREE_ID: process.env.ORCA_WORKTREE_ID,
  ORCA_WORKSPACE_ID: process.env.ORCA_WORKSPACE_ID,
  ORCA_TAB_ID: process.env.ORCA_TAB_ID,
  ORCA_PANE_KEY: process.env.ORCA_PANE_KEY,
};

type Handler = (event: unknown, ctx: unknown) => Promise<void> | void;

function registerTestExtension(): Map<string, Handler> {
  const handlers = new Map<string, Handler>();
  const fakeApi = {
    on(event: string, handler: Handler) {
      handlers.set(event, handler);
    },
  };
  // The test double implements only the registration method used by this extension.
  registerExtension(fakeApi as unknown as ExtensionAPI);
  return handlers;
}

function completionEvent() {
  return {
    session_id: "session-1",
    session_file: "/tmp/session.jsonl",
    turn_id: 7,
    messages: [
      { role: "user", content: [{ type: "text", text: "run checks" }] },
      { role: "assistant", content: [{ type: "text", text: "all green" }] },
    ],
    last_assistant_message: { role: "assistant", content: [{ type: "text", text: "all green" }] },
  };
}

afterEach(() => {
  globalThis.fetch = ORIGINAL_FETCH;
  for (const key of ENV_KEYS) {
    const value = ORIGINAL_ENV[key];
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
});

test("posts one Tax push from OMP session_stop with terminal routing", async () => {
  const handlers = registerTestExtension();
  process.env.TAX_API_KEY = "secret";
  process.env.TAX_SERVER = "https://tax.example/";
  process.env.TAX_HOST_ID = "test-host";
  process.env.ORCA_TERMINAL_HANDLE = "terminal-123";
  process.env.ORCA_WORKTREE_ID = "worktree-456";
  process.env.ORCA_TAB_ID = "tab-789";
  process.env.ORCA_PANE_KEY = "pane-abc";

  const requests: Array<{ url: string; init: RequestInit }> = [];
  globalThis.fetch = async (input, init) => {
    requests.push({ url: String(input), init: init ?? {} });
    return new Response(JSON.stringify({ task_id: "task-1" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  };

  await handlers.get("before_agent_start")?.({ prompt: "run checks" }, {});
  const event = completionEvent();
  const context = { cwd: "/workspace", hasUI: false };
  await handlers.get("session_stop")?.(event, context);
  await handlers.get("session_stop")?.(event, context);

  assert.equal(requests.length, 1);
  assert.equal(requests[0]?.url, "https://tax.example/push");
  assert.equal(new Headers(requests[0]?.init.headers).get("Authorization"), "Bearer secret");
  const payload = JSON.parse(String(requests[0]?.init.body)) as Record<string, string>;
  assert.deepEqual(payload, {
    title: "omp completed",
    body: "all green",
    context: [
      "Command: omp -p run checks",
      "Outcome: completed",
      "Attempts: 1",
      "Directory: /workspace",
      "Session: /tmp/session.jsonl",
    ].join("\n"),
    logs: "all green",
    source: "omp-extension",
    agent: "omp",
    app: "tax",
    host_id: "test-host",
    orca_terminal_handle: "terminal-123",
    orca_worktree_id: "worktree-456",
    orca_tab_id: "tab-789",
    orca_pane_key: "pane-abc",
  });
});

test("does not call the backend when OMP has no server URL", async () => {
  const handlers = registerTestExtension();
  process.env.TAX_API_KEY = "secret";
  process.env.ORCA_TERMINAL_HANDLE = "terminal-123";
  delete process.env.TAX_SERVER;
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    return new Response(JSON.stringify({ task_id: "unexpected" }));
  };
  await handlers.get("session_stop")?.(completionEvent(), { cwd: "/workspace", hasUI: false });
  assert.equal(calls, 0);
});

test("OMP delivery errors do not fail the agent and allow a later retry", async () => {
  const handlers = registerTestExtension();
  process.env.TAX_API_KEY = "secret";
  process.env.TAX_SERVER = "https://tax.example";
  process.env.ORCA_TERMINAL_HANDLE = "terminal-123";
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    if (calls === 1) throw new Error("synthetic delivery failure");
    return new Response(JSON.stringify({ task_id: "task-1" }));
  };
  const ctx = { cwd: "/workspace", hasUI: false };
  await handlers.get("session_stop")?.(completionEvent(), ctx);
  await handlers.get("session_stop")?.(completionEvent(), ctx);
  await handlers.get("session_stop")?.(completionEvent(), ctx);
  assert.equal(calls, 2);
});

test("does not call the backend when OMP has no Orca terminal handle", async () => {
  const handlers = registerTestExtension();
  process.env.TAX_API_KEY = "secret";
  process.env.TAX_SERVER = "https://tax.example";
  delete process.env.ORCA_TERMINAL_HANDLE;

  let fetchCalled = false;
  globalThis.fetch = async () => {
    fetchCalled = true;
    return new Response(JSON.stringify({ task_id: "unexpected" }));
  };

  await handlers.get("session_stop")?.(completionEvent(), { cwd: "/workspace", hasUI: false });
  assert.equal(fetchCalled, false);
});
