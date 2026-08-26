import { appendFile, mkdir } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const BACKEND_URL = (process.env.TAX_SERVER?.trim() || "https://tax.138-249-127-23.nip.io").replace(/\/$/, "");
const PUSH_ENDPOINT = `${BACKEND_URL}/push`;
const LOCAL_AGENT_URL = process.env.TAX_AGENT_URL?.trim() || "http://127.0.0.1:17373";
const REQUEST_TIMEOUT_MS = 10_000;
const LOCAL_TIMEOUT_MS = 1_500;
const EXTENSION_NAME = "tax-push";

type AnyMessage = {
  role?: string;
  content?: unknown;
  stopReason?: string;
  errorMessage?: string;
  diagnostics?: unknown;
};

type TurnResult = {
  key: string;
  prompt: string;
  title: string;
  body: string;
  logs: string;
  outcome: "completed" | "failed" | "stopped";
  attempts: number;
  category?: string;
  suggestion?: string;
};

type SessionMessageEntry = {
  type?: string;
  id?: string;
  message?: AnyMessage;
};

type TaskHandoff = {
  task_id: string;
  orca_terminal_handle: string;
  orca_worktree_id: string;
  orca_tab_id: string;
  orca_pane_key: string;
  source: string;
  agent: string;
  app: string;
};

function partToText(part: unknown): string {
  if (typeof part === "string") return part;
  if (!part || typeof part !== "object") return "";

  const value = part as Record<string, unknown>;
  if (value.type === "text" && typeof value.text === "string") return value.text;
  if (value.type === "thinking" && typeof value.thinking === "string") return value.thinking;
  if (value.type === "image") return "[image]";
  if (value.type === "toolCall") {
    const name = typeof value.name === "string" ? value.name : "unknown";
    return `[toolCall:${name}]`;
  }
  return "";
}

function contentToText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map(partToText).filter((text) => text.length > 0).join("\n");
}

function cleanErrorText(value: string, maxLength = 500): string {
  let text = value;
  if (/<[a-z][\s\S]*>/i.test(text)) {
    text = text
      .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, " ")
      .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, " ")
      .replace(/<svg\b[^>]*>[\s\S]*?<\/svg>/gi, " ")
      .replace(/<head\b[^>]*>[\s\S]*?<\/head>/gi, " ")
      .replace(/<[^>]+>/g, " ");
  }
  text = text
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/\s+/g, " ")
    .trim();
  if (text.length <= maxLength) return text;
  return `${text.slice(0, maxLength - 1).trimEnd()}…`;
}

function diagnosticMessages(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const messages: string[] = [];
  for (const item of value) {
    if (!item || typeof item !== "object") continue;
    const diagnostic = item as Record<string, unknown>;
    if (typeof diagnostic.message === "string") messages.push(diagnostic.message);
    const error = diagnostic.error;
    if (error && typeof error === "object" && typeof (error as Record<string, unknown>).message === "string") {
      messages.push((error as Record<string, string>).message);
    }
  }
  return messages.map((message) => cleanErrorText(message)).filter(Boolean);
}

function messageFailure(message: AnyMessage): string | undefined {
  const diagnostics = diagnosticMessages(message.diagnostics);
  if (diagnostics.length > 0) return diagnostics[diagnostics.length - 1];
  if (typeof message.errorMessage === "string" && message.errorMessage.trim()) {
    return cleanErrorText(message.errorMessage);
  }
  if (message.stopReason === "error") return "Pi stopped with an unspecified provider error";
  return undefined;
}

function classifyFailure(errors: string[]): { category: string; suggestion: string } {
  const text = errors.join(" ").toLowerCase();
  if (/websocket|vpn|dns|ssl|timeout|timed out|connection|unable to load site|network|eof|resolve/.test(text)) {
    return { category: "network", suggestion: "Check VPN and network connection, then retry" };
  }
  if (/401|403|unauthori[sz]ed|authentication|api key|token expired|invalid token/.test(text)) {
    return { category: "auth", suggestion: "Check provider authentication and retry" };
  }
  if (/429|rate.?limit|too many requests|quota/.test(text)) {
    return { category: "rate_limit", suggestion: "Wait for the provider limit to reset, then retry" };
  }
  if (/cancel|abort|interrupt/.test(text)) {
    return { category: "cancelled", suggestion: "Retry if the cancellation was accidental" };
  }
  if (/\b5\d\d\b|provider|overloaded|unavailable/.test(text)) {
    return { category: "provider", suggestion: "Retry later or switch provider" };
  }
  return { category: "unknown", suggestion: "Inspect the error and retry" };
}

function makeNotificationBody(text: string, maxLength = 180): string {
  const oneLine = text.replace(/\s+/g, " ").trim();
  if (!oneLine) return "pi completed";
  if (oneLine.length <= maxLength) return oneLine;
  return `${oneLine.slice(0, maxLength - 1).trimEnd()}…`;
}

function getContextEntries(ctx: { sessionManager?: { buildContextEntries?: () => unknown[]; getBranch?: () => unknown[] } }) {
  return ctx.sessionManager?.buildContextEntries?.() ?? ctx.sessionManager?.getBranch?.() ?? [];
}

export function analyzeTurn(
  entries: unknown[],
  fallbackAssistant: { id?: string; message: AnyMessage } | undefined,
  fallbackPrompt: string,
): TurnResult {
  let userIndex = -1;
  let prompt = fallbackPrompt.trim();
  for (let index = entries.length - 1; index >= 0; index--) {
    const entry = entries[index] as SessionMessageEntry;
    if (entry?.type === "message" && entry.message?.role === "user") {
      userIndex = index;
      prompt = contentToText(entry.message.content).trim() || prompt;
      break;
    }
  }

  const assistants: Array<{ id?: string; message: AnyMessage }> = [];
  for (let index = userIndex + 1; index < entries.length; index++) {
    const entry = entries[index] as SessionMessageEntry;
    if (entry?.type === "message" && entry.message?.role === "assistant") {
      assistants.push({ id: entry.id, message: entry.message });
    }
  }
  if (assistants.length === 0 && fallbackAssistant?.message.role === "assistant") assistants.push(fallbackAssistant);

  const successful = [...assistants].reverse().find((item) => contentToText(item.message.content).trim());
  const failures: Array<{ id?: string; error: string }> = [];
  for (const item of assistants) {
    const error = messageFailure(item.message);
    if (error) failures.push({ id: item.id, error });
  }
  const last = assistants[assistants.length - 1];

  if (successful) {
    const logs = contentToText(successful.message.content).trim();
    return {
      key: `${last?.id ?? successful.id ?? "event"}:${prompt}:${logs.length}`,
      prompt,
      title: "pi completed",
      body: makeNotificationBody(logs),
      logs,
      outcome: "completed",
      attempts: Math.max(1, assistants.length),
    };
  }

  if (failures.length > 0) {
    const errors = failures.map((item) => item.error);
    const classification = classifyFailure(errors);
    const attempts = failures.length;
    const latest = errors[errors.length - 1];
    return {
      key: `${last?.id ?? "error"}:${prompt}:${attempts}:${latest}`,
      prompt,
      title: "pi failed",
      body: makeNotificationBody(`${classification.category} error after ${attempts} attempt${attempts === 1 ? "" : "s"}: ${latest}`),
      logs: errors.map((error, index) => `Attempt ${index + 1}: ${error}`).join("\n"),
      outcome: "failed",
      attempts,
      category: classification.category,
      suggestion: classification.suggestion,
    };
  }

  return {
    key: `${last?.id ?? "stopped"}:${prompt}:empty`,
    prompt,
    title: "pi stopped",
    body: "Pi stopped without a final response",
    logs: "Pi settled without assistant output or a reported error.",
    outcome: "stopped",
    attempts: assistants.length,
    category: "unknown",
    suggestion: "Inspect the session and retry",
  };
}

async function fetchWithTimeout(url: string, init: RequestInit, timeoutMs: number): Promise<Response> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

async function postPush(payload: Record<string, string>, apiKey: string): Promise<string> {
  const response = await fetchWithTimeout(PUSH_ENDPOINT, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  }, REQUEST_TIMEOUT_MS);

  const responseText = await response.text();
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}${responseText ? `: ${responseText.slice(0, 500)}` : ""}`);
  }

  let result: { task_id?: unknown };
  try {
    result = JSON.parse(responseText) as { task_id?: unknown };
  } catch {
    throw new Error("backend returned invalid JSON");
  }
  if (typeof result.task_id !== "string" || !result.task_id) {
    throw new Error("backend response does not contain task_id");
  }
  return result.task_id;
}

async function handoffToLocalAgent(task: TaskHandoff): Promise<void> {
  const response = await fetchWithTimeout(`${LOCAL_AGENT_URL}/task`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(task),
  }, LOCAL_TIMEOUT_MS);
  if (!response.ok) throw new Error(`local agent returned HTTP ${response.status}`);
}

function fallbackQueuePath(): string {
  const stateHome = process.env.XDG_STATE_HOME?.trim() || join(homedir(), ".local", "state");
  return join(stateHome, "tax", "tasks.jsonl");
}

async function appendFallback(task: TaskHandoff): Promise<void> {
  const path = fallbackQueuePath();
  await mkdir(dirname(path), { recursive: true });
  await appendFile(path, `${JSON.stringify(task)}\n`, { encoding: "utf8", mode: 0o600 });
}

function log(
  ctx: { hasUI?: boolean; ui?: { notify?: (message: string, level?: "info" | "warning" | "error") => void } },
  message: string,
  level: "info" | "warning" | "error" = "info",
) {
  console.log(`[${EXTENSION_NAME}] ${message}`);
  if (!ctx.hasUI) return;
  try {
    ctx.ui?.notify?.(message, level);
  } catch {
    // Ignore stale/no-op UI contexts.
  }
}

function logQuietly(message: string, level: "info" | "warning" = "info") {
  if (process.env.TAX_PUSH_DEBUG !== "1") return;
  const output = `[${EXTENSION_NAME}] ${message}`;
  if (level === "warning") console.warn(output);
  else console.log(output);
}

export default function (pi: ExtensionAPI) {
  let currentPrompt = "";
  let lastAssistantFromEvent: { id?: string; message: AnyMessage } | undefined;
  let lastSentKey: string | undefined;
  let inFlightKey: string | undefined;

  pi.on("before_agent_start", async (event) => {
    currentPrompt = typeof event.prompt === "string" ? event.prompt : contentToText(event.prompt);
    lastAssistantFromEvent = undefined;
  });

  pi.on("message_end", async (event) => {
    if (event.message?.role !== "assistant") return;
    lastAssistantFromEvent = { message: event.message };
  });

  pi.on("agent_settled", async (_event, ctx) => {
    try {
      const apiKey = process.env.TAX_API_KEY?.trim();
      if (!apiKey) {
        log(ctx, "TAX_API_KEY is not set; skip push notification", "warning");
        return;
      }

      const orcaTerminalHandle = process.env.ORCA_TERMINAL_HANDLE?.trim() || "";
      if (!orcaTerminalHandle) {
        log(ctx, "ORCA_TERMINAL_HANDLE is not set; skip replyable notification", "warning");
        return;
      }

      const entries = getContextEntries(ctx);
      const result = analyzeTurn(entries, lastAssistantFromEvent, currentPrompt);
      if (result.key === lastSentKey || result.key === inFlightKey) return;
      inFlightKey = result.key;

      const metadata = {
        source: "pi-extension",
        agent: "pi",
        app: "tax",
        orca_terminal_handle: orcaTerminalHandle,
        orca_worktree_id: process.env.ORCA_WORKTREE_ID?.trim() || process.env.ORCA_WORKSPACE_ID?.trim() || "",
        orca_tab_id: process.env.ORCA_TAB_ID?.trim() || "",
        orca_pane_key: process.env.ORCA_PANE_KEY?.trim() || "",
      };
      const sessionFile = ctx.sessionManager?.getSessionFile?.() || process.env.PI_SESSION_FILE?.trim() || "";
      const context = [
        `Command: pi -p ${result.prompt}`,
        `Outcome: ${result.outcome}`,
        `Attempts: ${result.attempts}`,
        result.category ? `Category: ${result.category}` : "",
        result.suggestion ? `Suggested action: ${result.suggestion}` : "",
        `Directory: ${ctx.cwd}`,
        sessionFile ? `Session: ${sessionFile}` : "",
      ].filter(Boolean).join("\n");
      let taskID: string;
      try {
        taskID = await postPush({
          title: result.title,
          body: result.body,
          context,
          logs: result.logs,
          ...metadata,
        }, apiKey);
        lastSentKey = result.key;
      } finally {
        if (inFlightKey === result.key) inFlightKey = undefined;
      }

      const handoff: TaskHandoff = {
        task_id: taskID,
        ...metadata,
      };
      try {
        await handoffToLocalAgent(handoff);
        logQuietly(`Push sent; watching task ${taskID.slice(0, 8)}`);
      } catch (localError) {
        await appendFallback(handoff);
        const reason = localError instanceof Error ? localError.message : String(localError);
        logQuietly(`Push sent; local agent unavailable (${reason}), task queued`, "warning");
      }
    } catch (error) {
      inFlightKey = undefined;
      const message = error instanceof Error ? error.message : String(error);
      log(ctx, `Failed to send push notification: ${message}`, "warning");
    }
  });
}
