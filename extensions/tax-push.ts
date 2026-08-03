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
};

type SessionMessageEntry = {
  type?: string;
  id?: string;
  message?: AnyMessage;
};

type TaskHandoff = {
  task_id: string;
  agterm_session_id: string;
  agterm_socket: string;
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

function makeNotificationBody(text: string, maxLength = 180): string {
  const oneLine = text.replace(/\s+/g, " ").trim();
  if (!oneLine) return "pi completed";
  if (oneLine.length <= maxLength) return oneLine;
  return `${oneLine.slice(0, maxLength - 1).trimEnd()}…`;
}

function getContextEntries(ctx: { sessionManager?: { buildContextEntries?: () => unknown[]; getBranch?: () => unknown[] } }) {
  return ctx.sessionManager?.buildContextEntries?.() ?? ctx.sessionManager?.getBranch?.() ?? [];
}

function findLastAssistantMessage(entries: unknown[]) {
  for (let index = entries.length - 1; index >= 0; index--) {
    const entry = entries[index] as SessionMessageEntry;
    if (entry?.type === "message" && entry.message?.role === "assistant") {
      return { id: entry.id, message: entry.message, index };
    }
  }
  return undefined;
}

function findFirstUserPromptForTurn(entries: unknown[], assistantIndex: number): string | undefined {
  let prompt: string | undefined;
  for (let index = assistantIndex - 1; index >= 0; index--) {
    const entry = entries[index] as SessionMessageEntry;
    if (entry?.type !== "message" || !entry.message) continue;
    if (entry.message.role === "user") {
      const text = contentToText(entry.message.content).trim();
      if (text) prompt = text;
      continue;
    }
    if (prompt && entry.message.role === "assistant") break;
  }
  return prompt;
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

  pi.on("before_agent_start", async (event) => {
    currentPrompt = typeof event.prompt === "string" ? event.prompt : contentToText(event.prompt);
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

      const entries = getContextEntries(ctx);
      const assistantFromSession = findLastAssistantMessage(entries);
      const assistant = assistantFromSession ?? lastAssistantFromEvent;
      if (!assistant?.message || assistant.message.role !== "assistant") {
        log(ctx, "No assistant message found; skip push notification", "warning");
        return;
      }

      const logs = contentToText(assistant.message.content).trim();
      if (!logs) {
        log(ctx, "Assistant message is empty; skip push notification", "warning");
        return;
      }

      const prompt = (
        assistantFromSession ? findFirstUserPromptForTurn(entries, assistantFromSession.index) : undefined
      ) ?? currentPrompt.trim();
      const dedupeKey = `${assistant.id ?? "event"}:${prompt}:${logs.length}`;
      if (dedupeKey === lastSentKey) return;
      lastSentKey = dedupeKey;

      const metadata = {
        source: "pi-extension",
        agent: "pi",
        app: "tax",
        agterm_session_id: process.env.AGTERM_SESSION_ID?.trim() || "",
      };
      const sessionFile = ctx.sessionManager?.getSessionFile?.() || process.env.PI_SESSION_FILE?.trim() || "";
      const context = [
        `Command: pi -p ${prompt}`,
        `Directory: ${ctx.cwd}`,
        sessionFile ? `Session: ${sessionFile}` : "",
      ].filter(Boolean).join("\n");
      const taskID = await postPush({
        title: "pi completed",
        body: makeNotificationBody(logs),
        context,
        logs,
        ...metadata,
      }, apiKey);

      const handoff: TaskHandoff = {
        task_id: taskID,
        agterm_socket: process.env.AGTERM_SOCKET?.trim() || "",
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
      const message = error instanceof Error ? error.message : String(error);
      log(ctx, `Failed to send push notification: ${message}`, "warning");
    }
  });
}
