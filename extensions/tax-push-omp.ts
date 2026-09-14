import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

import { analyzeTurn, truncatePayloadText } from "./tax-push.ts";

const REQUEST_TIMEOUT_MS = 10_000;
const CONTEXT_MAX_LENGTH = 100_000;
const LOGS_MAX_LENGTH = 500_000;
const EXTENSION_NAME = "tax-push-omp";

async function fetchWithTimeout(url: string, init: RequestInit, timeoutMs: number): Promise<Response> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

async function postPush(endpoint: string, payload: Record<string, string>, apiKey: string): Promise<string> {
  const response = await fetchWithTimeout(endpoint, {
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

export default function (omp: ExtensionAPI) {
  let currentPrompt = "";
  let lastSentKey: string | undefined;
  let inFlightKey: string | undefined;

  omp.on("before_agent_start", async (event) => {
    if (typeof event.prompt === "string") currentPrompt = event.prompt;
  });

  omp.on("session_stop", async (event, ctx) => {
    try {
      const apiKey = process.env.TAX_API_KEY?.trim();
      if (!apiKey) {
        log(ctx, "TAX_API_KEY is not set; skip push notification", "warning");
        return;
      }

      const server = process.env.TAX_SERVER?.trim() || "";
      if (!server) {
        log(ctx, "TAX_SERVER is not set; skip push notification", "warning");
        return;
      }
      const endpoint = `${server.replace(/\/+$/, "")}/push`;

      const orcaTerminalHandle = process.env.ORCA_TERMINAL_HANDLE?.trim() || "";
      if (!orcaTerminalHandle) {
        log(ctx, "ORCA_TERMINAL_HANDLE is not set; skip push notification", "warning");
        return;
      }

      const entryPrefix = `${event.session_id}:${event.turn_id}`;
      const entries = event.messages.map((message, index) => ({
        type: "message",
        id: `${entryPrefix}:${index}`,
        message,
      }));
      const fallbackAssistant = event.last_assistant_message
        ? { id: `${entryPrefix}:last`, message: event.last_assistant_message }
        : undefined;
      const result = analyzeTurn(entries, fallbackAssistant, currentPrompt, "omp");
      if (result.key === lastSentKey || result.key === inFlightKey) return;
      inFlightKey = result.key;

      const metadata = {
        source: "omp-extension",
        agent: "omp",
        app: "tax",
        host_id: process.env.TAX_HOST_ID?.trim() || "mac-main",
        orca_terminal_handle: orcaTerminalHandle,
        orca_worktree_id: process.env.ORCA_WORKTREE_ID?.trim() || process.env.ORCA_WORKSPACE_ID?.trim() || "",
        orca_tab_id: process.env.ORCA_TAB_ID?.trim() || "",
        orca_pane_key: process.env.ORCA_PANE_KEY?.trim() || "",
      };
      const context = [
        `Command: omp -p ${result.prompt}`,
        `Outcome: ${result.outcome}`,
        `Attempts: ${result.attempts}`,
        result.category ? `Category: ${result.category}` : "",
        result.suggestion ? `Suggested action: ${result.suggestion}` : "",
        `Directory: ${ctx.cwd}`,
        event.session_file ? `Session: ${event.session_file}` : "",
      ].filter(Boolean).join("\n");

      try {
        await postPush(endpoint, {
          title: result.title,
          body: result.body,
          context: truncatePayloadText(context, CONTEXT_MAX_LENGTH),
          logs: truncatePayloadText(result.logs, LOGS_MAX_LENGTH),
          ...metadata,
        }, apiKey);
        lastSentKey = result.key;
      } finally {
        if (inFlightKey === result.key) inFlightKey = undefined;
      }
      logQuietly("Push sent");
    } catch (error) {
      inFlightKey = undefined;
      const message = error instanceof Error ? error.message : String(error);
      log(ctx, `Failed to send push notification: ${message}`, "warning");
    }
  });
}
