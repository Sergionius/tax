import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";

process.env.TAX_SERVER = "http://backend.test";
const { default: registerExtension, analyzeTurn, truncatePayloadText } = await import("../../extensions/tax-push.ts");
delete process.env.TAX_SERVER;

const ISOLATED_ENV_KEYS = [
  "TAX_API_KEY",
  "TAX_SERVER",
  "TAX_PUSH_DEBUG",
  "TAX_HOST_ID",
  "ORCA_TERMINAL_HANDLE",
  "ORCA_WORKTREE_ID",
  "ORCA_WORKSPACE_ID",
  "ORCA_TAB_ID",
  "ORCA_PANE_KEY",
  "PI_SESSION_FILE",
  "HOME",
  "XDG_STATE_HOME",
];

type Handler = (event: unknown, ctx: unknown) => Promise<void> | void;

type FetchCall = { url: string; init: RequestInit };

type FetchMock = {
  calls: FetchCall[];
  setResponder(responder: (url: string, init: RequestInit) => Response): void;
  restore(): void;
};

const savedEnv = new Map<string, string | undefined>();
let savedConsoleLog: typeof console.log;
let savedConsoleWarn: typeof console.warn;
let stateRoot = "";
let fetchMock: FetchMock | undefined;

beforeEach(() => {
  for (const key of ISOLATED_ENV_KEYS) {
    savedEnv.set(key, process.env[key]);
    delete process.env[key];
  }
  stateRoot = mkdtempSync(join(tmpdir(), "tax-push-test-"));
  process.env.HOME = stateRoot;
  process.env.XDG_STATE_HOME = join(stateRoot, "state");
  savedConsoleLog = console.log;
  savedConsoleWarn = console.warn;
});

afterEach(() => {
  fetchMock?.restore();
  fetchMock = undefined;
  console.log = savedConsoleLog;
  console.warn = savedConsoleWarn;
  const leftovers = readdirSync(stateRoot, { recursive: true });
  assert.deepEqual(leftovers, [], "extension must not write files into HOME or the state directory");
  rmSync(stateRoot, { recursive: true, force: true });
  for (const [key, value] of savedEnv) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
});

function captureConsole() {
  const logs: string[] = [];
  const warns: string[] = [];
  console.log = (...parts: unknown[]) => {
    logs.push(parts.map((part) => String(part)).join(" "));
  };
  console.warn = (...parts: unknown[]) => {
    warns.push(parts.map((part) => String(part)).join(" "));
  };
  return { logs, warns };
}

function installFetchMock(responder: (url: string, init: RequestInit) => Response): FetchMock {
  const calls: FetchCall[] = [];
  const state = { responder };
  const original = globalThis.fetch;
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : String(input);
    calls.push({ url, init: init ?? {} });
    return Promise.resolve(state.responder(url, init ?? {}));
  }) as typeof fetch;
  return {
    calls,
    setResponder(next) {
      state.responder = next;
    },
    restore() {
      globalThis.fetch = original;
    },
  };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(typeof body === "string" ? body : JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function pushBody(call: FetchCall): Record<string, string> {
  return JSON.parse(String(call.init.body)) as Record<string, string>;
}

const COMPLETION_ENTRIES = [
  { type: "message", id: "u1", message: { role: "user", content: "Fix the flaky test" } },
  { type: "message", id: "a1", message: { role: "assistant", content: "Fixed by removing the sleep" } },
];

function registerTestExtension(entries: unknown[]) {
  const handlers = new Map<string, Handler>();
  const register = registerExtension as unknown as (pi: { on: (event: string, handler: Handler) => void }) => void;
  register({ on: (event, handler) => handlers.set(event, handler) });
  const ctx = {
    cwd: "/tmp/project",
    hasUI: false,
    sessionManager: {
      buildContextEntries: () => entries,
      getSessionFile: () => "/tmp/project/.pi/session.jsonl",
    },
  };
  return {
    emit: (event: string, payload: unknown, context: unknown = ctx) => handlers.get(event)!(payload, context),
    settled: (context: unknown = ctx) => handlers.get("agent_settled")!({}, context),
  };
}

function enableSuccessEnv() {
  process.env.TAX_API_KEY = "key-123";
  process.env.TAX_SERVER = "http://backend.test";
  process.env.ORCA_TERMINAL_HANDLE = "term-1";
}

test("keeps text within the payload limit unchanged", () => {
  assert.equal(truncatePayloadText("context", 100), "context");
});

test("preserves the beginning and end when truncating", () => {
  const value = `${"a".repeat(80)}middle${"z".repeat(80)}`;
  const result = truncatePayloadText(value, 100);

  assert.equal(result.length, 100);
  assert.match(result, /^a+/);
  assert.match(result, /z+$/);
  assert.match(result, /\[truncated\]/);
});

test("never exceeds a limit smaller than the truncation marker", () => {
  assert.equal(truncatePayloadText("abcdefghij", 4), "abcd");
});

test("keeps oversized context within the backend limit", () => {
  const result = truncatePayloadText("x".repeat(100_001), 100_000);

  assert.equal(result.length, 100_000);
});

test("analyzes a successful turn", () => {
  const result = analyzeTurn(COMPLETION_ENTRIES, undefined, "fallback prompt");

  assert.equal(result.outcome, "completed");
  assert.equal(result.title, "pi completed");
  assert.equal(result.prompt, "Fix the flaky test");
  assert.equal(result.body, "Fixed by removing the sleep");
  assert.equal(result.attempts, 1);
});

test("analyzes a failed turn", () => {
  const entries = [
    { type: "message", id: "u1", message: { role: "user", content: "Ship it" } },
    {
      type: "message",
      id: "a1",
      message: { role: "assistant", content: "", stopReason: "error", errorMessage: "provider overloaded" },
    },
  ];
  const result = analyzeTurn(entries, undefined, "Ship it");

  assert.equal(result.outcome, "failed");
  assert.equal(result.title, "pi failed");
  assert.equal(result.category, "provider");
  assert.match(result.body, /provider error after 1 attempt/);
  assert.equal(result.logs, "Attempt 1: provider overloaded");
});

test("analyzes a stopped turn", () => {
  const entries = [
    { type: "message", id: "u1", message: { role: "user", content: "Do the thing" } },
  ];
  const result = analyzeTurn(entries, undefined, "Do the thing");

  assert.equal(result.outcome, "stopped");
  assert.equal(result.title, "pi stopped");
  assert.equal(result.category, "unknown");
  assert.equal(result.attempts, 0);
});

test("sends exactly one completion POST /push with the expected metadata", async () => {
  enableSuccessEnv();
  process.env.TAX_PUSH_DEBUG = "1";
  process.env.TAX_HOST_ID = "host-x";
  process.env.ORCA_WORKTREE_ID = "wt-1";
  process.env.ORCA_TAB_ID = "tab-1";
  process.env.ORCA_PANE_KEY = "pane-1";
  const output = captureConsole();
  fetchMock = installFetchMock(() => jsonResponse({ task_id: "task-abc" }));
  const harness = registerTestExtension(COMPLETION_ENTRIES);

  await harness.settled();

  assert.equal(fetchMock.calls.length, 1);
  const call = fetchMock.calls[0];
  assert.equal(call.url, "http://backend.test/push");
  assert.equal(call.init.method, "POST");
  assert.deepEqual(call.init.headers, {
    "Authorization": "Bearer key-123",
    "Content-Type": "application/json",
  });
  const body = pushBody(call);
  assert.equal(body.title, "pi completed");
  assert.equal(body.body, "Fixed by removing the sleep");
  assert.equal(body.source, "pi-extension");
  assert.equal(body.agent, "pi");
  assert.equal(body.app, "tax");
  assert.equal(body.host_id, "host-x");
  assert.equal(body.orca_terminal_handle, "term-1");
  assert.equal(body.orca_worktree_id, "wt-1");
  assert.equal(body.orca_tab_id, "tab-1");
  assert.equal(body.orca_pane_key, "pane-1");
  assert.match(body.context, /Command: pi -p Fix the flaky test/);
  assert.match(body.context, /Outcome: completed/);
  assert.match(body.context, /Directory: \/tmp\/project/);
  assert.match(body.context, /Session: \/tmp\/project\/\.pi\/session\.jsonl/);
  assert.equal(body.logs, "Fixed by removing the sleep");
  assert.ok(output.logs.includes("[tax-push] Push sent"));
  assert.deepEqual(output.warns, []);
});

test("applies metadata defaults when routing variables are unset", async () => {
  enableSuccessEnv();
  process.env.ORCA_WORKSPACE_ID = "workspace-9";
  fetchMock = installFetchMock(() => jsonResponse({ task_id: "task-abc" }));
  const harness = registerTestExtension(COMPLETION_ENTRIES);

  await harness.settled();

  assert.equal(fetchMock.calls.length, 1);
  const body = pushBody(fetchMock.calls[0]);
  assert.equal(body.host_id, "mac-main");
  assert.equal(body.orca_worktree_id, "workspace-9");
  assert.equal(body.orca_tab_id, "");
  assert.equal(body.orca_pane_key, "");
});

test("skips a sequential duplicate settled event", async () => {
  enableSuccessEnv();
  fetchMock = installFetchMock(() => jsonResponse({ task_id: "task-abc" }));
  const harness = registerTestExtension(COMPLETION_ENTRIES);

  await harness.settled();
  await harness.settled();

  assert.equal(fetchMock.calls.length, 1);
});

test("skips a concurrent duplicate settled event", async () => {
  enableSuccessEnv();
  fetchMock = installFetchMock(() => jsonResponse({ task_id: "task-abc" }));
  const harness = registerTestExtension(COMPLETION_ENTRIES);

  await Promise.all([harness.settled(), harness.settled()]);

  assert.equal(fetchMock.calls.length, 1);
});

test("skips the push without a terminal handle", async () => {
  process.env.TAX_API_KEY = "key-123";
  process.env.TAX_SERVER = "http://backend.test";
  delete process.env.ORCA_TERMINAL_HANDLE;
  const output = captureConsole();
  fetchMock = installFetchMock(() => jsonResponse({ task_id: "task-abc" }));
  const harness = registerTestExtension(COMPLETION_ENTRIES);

  await harness.settled();

  assert.equal(fetchMock.calls.length, 0);
  assert.ok(
    output.logs.some((line) => line.includes("ORCA_TERMINAL_HANDLE is not set; skip push notification")),
  );
});

test("skips the push without a backend URL and never opens a connection", async () => {
  process.env.TAX_API_KEY = "key-123";
  process.env.ORCA_TERMINAL_HANDLE = "term-1";
  delete process.env.TAX_SERVER;
  const output = captureConsole();
  fetchMock = installFetchMock(() => jsonResponse({ task_id: "task-abc" }));
  const harness = registerTestExtension(COMPLETION_ENTRIES);

  await harness.settled();

  assert.equal(fetchMock.calls.length, 0);
  assert.ok(output.logs.some((line) => line.includes("TAX_SERVER is not set; skip push notification")));
});

test("uses the configured backend URL per event", async () => {
  enableSuccessEnv();
  process.env.TAX_SERVER = "http://relay.example:8443/";
  fetchMock = installFetchMock(() => jsonResponse({ task_id: "task-abc" }));
  const harness = registerTestExtension(COMPLETION_ENTRIES);

  await harness.settled();

  assert.equal(fetchMock.calls.length, 1);
  assert.equal(fetchMock.calls[0].url, "http://relay.example:8443/push");
});

test("logs a failure and retries the next event after invalid JSON", async () => {
  enableSuccessEnv();
  process.env.TAX_PUSH_DEBUG = "1";
  const output = captureConsole();
  fetchMock = installFetchMock(() => jsonResponse("not json at all"));
  const harness = registerTestExtension(COMPLETION_ENTRIES);

  await harness.settled();
  assert.equal(fetchMock.calls.length, 1);
  assert.ok(output.logs.some((line) => line.includes("backend returned invalid JSON")));

  fetchMock.setResponder(() => jsonResponse({ task_id: "task-abc" }));
  await harness.settled();

  assert.equal(fetchMock.calls.length, 2);
  assert.ok(output.logs.includes("[tax-push] Push sent"));
});

test("treats a missing task id as a failure and retries", async () => {
  enableSuccessEnv();
  const output = captureConsole();
  fetchMock = installFetchMock(() => jsonResponse({}));
  const harness = registerTestExtension(COMPLETION_ENTRIES);

  await harness.settled();
  assert.ok(output.logs.some((line) => line.includes("backend response does not contain task_id")));

  await harness.settled();

  assert.equal(fetchMock.calls.length, 2);
});

test("treats an HTTP failure as a failed push", async () => {
  enableSuccessEnv();
  const output = captureConsole();
  fetchMock = installFetchMock(() => jsonResponse("server exploded", 500));
  const harness = registerTestExtension(COMPLETION_ENTRIES);

  await harness.settled();

  assert.equal(fetchMock.calls.length, 1);
  assert.ok(output.logs.some((line) => line.includes("HTTP 500")));
  assert.ok(output.logs.some((line) => line.includes("Failed to send push notification")));
});

test("does not log Push sent when debug is disabled", async () => {
  enableSuccessEnv();
  delete process.env.TAX_PUSH_DEBUG;
  const output = captureConsole();
  fetchMock = installFetchMock(() => jsonResponse({ task_id: "task-abc" }));
  const harness = registerTestExtension(COMPLETION_ENTRIES);

  await harness.settled();

  assert.equal(fetchMock.calls.length, 1);
  assert.ok(output.logs.every((line) => !line.includes("Push sent")));
  assert.deepEqual(output.warns, []);
});

test("uses before_agent_start and message_end as fallback context", async () => {
  enableSuccessEnv();
  fetchMock = installFetchMock(() => jsonResponse({ task_id: "task-abc" }));
  const harness = registerTestExtension([]);

  await harness.emit("before_agent_start", { prompt: "Deploy the service" });
  await harness.emit("message_end", { message: { role: "assistant", content: "Deployed successfully" } });
  await harness.settled();

  assert.equal(fetchMock.calls.length, 1);
  const body = pushBody(fetchMock.calls[0]);
  assert.equal(body.title, "pi completed");
  assert.equal(body.body, "Deployed successfully");
  assert.match(body.context, /Command: pi -p Deploy the service/);
});
