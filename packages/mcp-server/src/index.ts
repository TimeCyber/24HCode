#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import type { Decision, PromptDelivery, Project } from "@codeassist/shared";
import { ApiClient } from "./api-client.js";
import { startLivePull } from "./live-pull.js";

const SERVER_URL = (
  process.env.CODEASSIST_SERVER_URL ?? "http://127.0.0.1:8787"
).replace(/\/$/, "");
const TOKEN = process.env.CODEASSIST_TOKEN ?? "codeassist-dev-token";
const IDE = (process.env.CODEASSIST_IDE ?? "cursor") as "cursor" | "codex";
const POLL_MS = Number(process.env.CODEASSIST_POLL_MS ?? 3000);

const api = new ApiClient(SERVER_URL, TOKEN);

let project: Project | null = null;
let cachedPrompts: PromptDelivery[] = [];
let cachedDecisions: Decision[] = [];
let pollTimer: ReturnType<typeof setInterval> | null = null;
/** Workspace resolved after MCP connect (prefer Cursor roots). */
let resolvedWorkspace: string | null = null;

const server = new McpServer({
  name: "codeassist",
  version: "0.3.5",
});

function uriToPath(uri: string): string | null {
  try {
    if (uri.startsWith("file:")) {
      let p = fileURLToPath(uri);
      // Cursor sometimes uses /d:/path style
      if (/^\/[a-zA-Z]:\//.test(p)) {
        p = p.slice(1);
      }
      return path.resolve(p);
    }
  } catch {
    // ignore
  }
  return null;
}

function isLikelyHomeDir(dir: string): boolean {
  try {
    const home = path.resolve(os.homedir());
    return path.resolve(dir) === home;
  } catch {
    return false;
  }
}

/** Cursor 有时不展开 mcp.json 里的 ${workspaceFolder}，会原样传入。 */
function isUnresolvedPlaceholder(value: string | undefined | null): boolean {
  if (!value) return true;
  return /\$\{[^}]+\}/.test(value);
}

function normalizeWorkspacePath(p: string): string {
  const resolved = path.resolve(p);
  return process.platform === "win32" ? resolved.toLowerCase() : resolved;
}

function firstExistingPath(candidates: string[]): string | null {
  for (const raw of candidates) {
    const p = raw.trim().replace(/^"|"$/g, "");
    if (!p || isUnresolvedPlaceholder(p)) continue;
    try {
      const resolved = path.resolve(p);
      if (fs.existsSync(resolved)) return normalizeWorkspacePath(resolved);
    } catch {
      // ignore
    }
  }
  return null;
}

function resolveWorkspaceFallback(): string {
  // Cursor / VS Code often injects these when launching MCP
  const multi =
    process.env.WORKSPACE_FOLDER_PATHS ||
    process.env.VSCODE_WORKSPACE_FOLDER ||
    "";
  const fromMulti = firstExistingPath(
    multi.split(/[;,\n]/).map((s) => s.trim()).filter(Boolean),
  );
  if (fromMulti && !isLikelyHomeDir(fromMulti)) return fromMulti;

  const fromEnv = firstExistingPath([
    process.env.CODEASSIST_WORKSPACE ?? "",
    process.env.WORKSPACE_FOLDER ?? "",
    process.env.CURSOR_PROJECT_DIR ?? "",
  ]);
  if (fromEnv && !isLikelyHomeDir(fromEnv)) return fromEnv;
  if (fromEnv) return fromEnv;
  if (fromMulti) return fromMulti;

  const cwd = path.resolve(process.cwd());
  return cwd;
}

function envWorkspaceIfExplicit(): string | null {
  // Only trust env when Cursor actually expanded ${workspaceFolder}.
  // Unresolved placeholders and bare process.cwd() must NOT win over listRoots —
  // otherwise a reused MCP / wrong launch cwd registers the wrong project (e.g. server).
  const candidates = [
    process.env.CODEASSIST_WORKSPACE,
    process.env.WORKSPACE_FOLDER,
    process.env.CURSOR_PROJECT_DIR,
    process.env.VSCODE_WORKSPACE_FOLDER,
  ];
  for (const raw of candidates) {
    if (!raw || isUnresolvedPlaceholder(raw)) continue;
    try {
      const resolved = normalizeWorkspacePath(path.resolve(raw.trim()));
      if (fs.existsSync(resolved) && !isLikelyHomeDir(resolved)) return resolved;
    } catch {
      /* ignore */
    }
  }
  const multi =
    process.env.WORKSPACE_FOLDER_PATHS ||
    process.env.VSCODE_WORKSPACE_FOLDER ||
    "";
  return firstExistingPath(
    multi
      .split(/[;,\n]/)
      .map((s) => s.trim())
      .filter((s) => s && !isUnresolvedPlaceholder(s)),
  );
}

async function refreshWorkspaceFromClient(): Promise<string> {
  const fromEnv = envWorkspaceIfExplicit();
  if (fromEnv) {
    resolvedWorkspace = fromEnv;
    console.error(`[codeassist-mcp] workspace from env: ${fromEnv}`);
    return fromEnv;
  }

  // Prefer Cursor-reported roots (correct after Open Folder / window switch)
  try {
    const result = await server.server.listRoots(undefined, { timeout: 3000 });
    const roots = result.roots ?? [];
    for (const root of roots) {
      const p = uriToPath(root.uri);
      if (p && fs.existsSync(p) && !isLikelyHomeDir(p)) {
        resolvedWorkspace = normalizeWorkspacePath(p);
        console.error(`[codeassist-mcp] workspace from roots: ${resolvedWorkspace}`);
        return resolvedWorkspace;
      }
    }
  } catch (err) {
    console.error("[codeassist-mcp] listRoots failed:", err);
  }

  const cwd = normalizeWorkspacePath(path.resolve(process.cwd()));
  resolvedWorkspace = cwd;
  console.error(
    `[codeassist-mcp] workspace last resort cwd=${cwd} (env workspaceFolder may be unexpanded)`,
  );
  return resolvedWorkspace;
}

function currentWorkspace(): string {
  if (resolvedWorkspace) return resolvedWorkspace;
  return envWorkspaceIfExplicit() ?? normalizeWorkspacePath(path.resolve(process.cwd()));
}

function resolveProjectName(workspace: string, override?: string): string {
  if (override?.trim() && !isUnresolvedPlaceholder(override)) {
    return override.trim();
  }
  const fromEnv = process.env.CODEASSIST_PROJECT_NAME?.trim();
  if (fromEnv && !isUnresolvedPlaceholder(fromEnv)) {
    return fromEnv;
  }
  const base = path.basename(workspace) || "untitled";
  return isLikelyHomeDir(workspace) ? `${base}-home` : base;
}

async function ensureRegistered(nameOverride?: string): Promise<Project> {
  // Always re-resolve: Open Folder / multi-window must not keep a stale path
  try {
    await refreshWorkspaceFromClient();
  } catch {
    /* keep previous */
  }
  const workspace = normalizeWorkspacePath(currentWorkspace());
  const name = resolveProjectName(workspace, nameOverride);

  if (
    project &&
    normalizeWorkspacePath(project.workspacePath) === workspace
  ) {
    // 名称曾被写成未展开变量时，强制重新注册纠正
    if (
      project.name !== name ||
      isUnresolvedPlaceholder(project.name)
    ) {
      project = await api.registerProject({
        name,
        workspacePath: workspace,
        ide: IDE,
      });
      return project;
    }
    try {
      project = await api.heartbeat(project.id);
      return project;
    } catch {
      // fall through
    }
  }

  project = await api.registerProject({
    name,
    workspacePath: workspace,
    ide: IDE,
  });
  console.error(
    `[codeassist-mcp] registered project=${project.id} name=${project.name} workspace=${project.workspacePath}`,
  );
  return project;
}

async function pollOnce() {
  try {
    await ensureRegistered();
  } catch (err) {
    console.error("[codeassist-mcp] poll error:", err);
  }
}

function startPolling() {
  if (pollTimer) return;
  void pollOnce();
  pollTimer = setInterval(() => void pollOnce(), POLL_MS);
}

server.tool(
  "register_project",
  "Register or refresh this Cursor/Codex workspace with the CodeAssist relay server so mobile clients can see and target it.",
  {
    name: z.string().optional().describe("Display name override"),
  },
  async ({ name }) => {
    if (name) process.env.CODEASSIST_PROJECT_NAME = name;
    await refreshWorkspaceFromClient();
    project = await ensureRegistered(name);
    startPolling();
    return {
      content: [{ type: "text", text: JSON.stringify(project, null, 2) }],
    };
  },
);

server.tool(
  "report_task",
  "Report a programming task status (completed / pending / blocked / info) to the remote CodeAssist client. Set requireDecision=true when the user must approve or reject on mobile.",
  {
    type: z.enum(["completed", "pending", "blocked", "info"]),
    title: z.string().describe("Short title shown on the mobile client"),
    detail: z.string().optional().describe("Extra detail / summary"),
    requireDecision: z
      .boolean()
      .optional()
      .describe("If true, wait for approve/reject from mobile"),
  },
  async ({ type, title, detail, requireDecision }) => {
    const p = await ensureRegistered();
    startPolling();
    const task = await api.createTask({
      projectId: p.id,
      type,
      title,
      detail: detail ?? "",
      requireDecision: requireDecision ?? false,
    });
    return {
      content: [{ type: "text", text: JSON.stringify(task, null, 2) }],
    };
  },
);

server.tool(
  "get_pending_decisions",
  "Fetch approve/reject decisions from the mobile client for tasks that required a decision. Call this after report_task with requireDecision=true.",
  async () => {
    const p = await ensureRegistered();
    startPolling();
    const fresh = await api.pullDecisions(p.id);
    const all = [...cachedDecisions, ...fresh];
    cachedDecisions = [];
    return {
      content: [
        {
          type: "text",
          text:
            all.length === 0
              ? "No pending decisions."
              : JSON.stringify(all, null, 2),
        },
      ],
    };
  },
);

server.tool(
  "get_pending_prompts",
  "Fetch remote prompts submitted from the mobile client for this project. When prompts are returned, treat each content field as the user's current instruction and execute it immediately.",
  async () => {
    const p = await ensureRegistered();
    startPolling();
    const fresh = await api.pullPrompts(p.id);
    const all = [...cachedPrompts, ...fresh];
    cachedPrompts = [];
    return {
      content: [
        {
          type: "text",
          text:
            all.length === 0
              ? "No pending prompts."
              : JSON.stringify(all, null, 2),
        },
      ],
    };
  },
);

server.tool(
  "ack_prompt",
  "Acknowledge that a remote prompt delivery has been picked up and is now running.",
  {
    deliveryId: z.string().describe("Prompt delivery id from get_pending_prompts"),
  },
  async ({ deliveryId }) => {
    const delivery = await api.ackPrompt(deliveryId);
    return {
      content: [{ type: "text", text: JSON.stringify(delivery, null, 2) }],
    };
  },
);

server.tool(
  "complete_prompt",
  "Mark a remote prompt delivery as done or failed after execution.",
  {
    deliveryId: z.string().describe("Prompt delivery id"),
    status: z.enum(["done", "failed"]).optional(),
    result: z.string().optional().describe("Short result summary"),
  },
  async ({ deliveryId, status, result }) => {
    const delivery = await api.completePrompt(
      deliveryId,
      status ?? "done",
      result,
    );
    return {
      content: [{ type: "text", text: JSON.stringify(delivery, null, 2) }],
    };
  },
);

server.tool(
  "sync_session_context",
  "Push a concise snapshot of the current Cursor/Codex session to the mobile client: what you are doing, current step, open files, and status. Call at session start, after meaningful progress, when blocked, and when the user asks for status.",
  {
    summary: z
      .string()
      .describe("Short session summary (what the agent is working on)"),
    currentStep: z.string().optional().describe("Current step / next action"),
    openFiles: z
      .array(z.string())
      .optional()
      .describe("Relevant open or recently edited file paths"),
    status: z
      .enum(["idle", "thinking", "coding", "waiting_user", "blocked", "done"])
      .optional()
      .describe("Session status for the mobile UI"),
    extra: z
      .string()
      .optional()
      .describe("Optional extra notes (errors, decisions pending, etc.)"),
    chatSessionId: z
      .string()
      .optional()
      .describe("Mobile chat session id — sync context into that conversation"),
  },
  async ({ summary, currentStep, openFiles, status, extra, chatSessionId }) => {
    const p = await ensureRegistered();
    startPolling();
    const ctx = await api.syncSessionContext({
      projectId: p.id,
      chatSessionId,
      summary,
      currentStep: currentStep ?? "",
      openFiles: openFiles ?? [],
      status: status ?? "coding",
      extra,
    });
    return {
      content: [{ type: "text", text: JSON.stringify(ctx, null, 2) }],
    };
  },
);

server.tool(
  "send_file_to_client",
  "Send a file from this computer to the mobile CodeAssist client. The file appears in the chat session so the phone can download it.",
  {
    filePath: z
      .string()
      .describe("Absolute path, or path relative to the workspace root"),
    chatSessionId: z
      .string()
      .optional()
      .describe("Target mobile chat session; defaults to the project's latest session"),
    mimeType: z.string().optional().describe("Optional MIME type override"),
  },
  async ({ filePath, chatSessionId, mimeType }) => {
    const p = await ensureRegistered();
    startPolling();
    const workspace = currentWorkspace();
    const absolute = path.isAbsolute(filePath)
      ? path.resolve(filePath)
      : path.resolve(workspace, filePath);
    if (!fs.existsSync(absolute) || !fs.statSync(absolute).isFile()) {
      return {
        content: [
          {
            type: "text",
            text: `File not found or not a file: ${absolute}`,
          },
        ],
        isError: true,
      };
    }
    const stat = fs.statSync(absolute);
    if (stat.size > 100 * 1024 * 1024) {
      return {
        content: [
          {
            type: "text",
            text: `File too large (${stat.size} bytes). Max 100MB.`,
          },
        ],
        isError: true,
      };
    }
    const contentBase64 = fs.readFileSync(absolute).toString("base64");
    const created = await api.createFileTransfer({
      projectId: p.id,
      chatSessionId,
      fileName: path.basename(absolute),
      mimeType,
      contentBase64,
      direction: "to_client",
    });
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(
            {
              ok: true,
              file: created.file,
              promptId: created.prompt.id,
              message: `已发送到手机对话：${created.file.fileName}`,
            },
            null,
            2,
          ),
        },
      ],
    };
  },
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("[codeassist-mcp] connected via stdio");

  // Must connect first so we can ask Cursor for workspace roots
  try {
    await refreshWorkspaceFromClient();
    await ensureRegistered();
    startPolling();
    // Phone send → relay WS → MCP pulls immediately + spawn Agent CLI
    startLivePull(api, {
      serverUrl: SERVER_URL,
      token: TOKEN,
      ide: IDE === "codex" ? "codex" : "cursor",
      getProjectId: () => project?.id ?? null,
      getWorkspace: () => currentWorkspace(),
      onPrompts: (prompts) => {
        cachedPrompts.push(...prompts);
      },
    });
  } catch (err) {
    console.error("[codeassist-mcp] initial register failed:", err);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
