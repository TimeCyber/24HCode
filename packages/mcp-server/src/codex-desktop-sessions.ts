import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { CodexDesktopSession } from "@codeassist/shared";
import type { ApiClient } from "./api-client.js";

const APP_SERVER_TIMEOUT_MS = 20_000;
const SESSION_PAGE_SIZE = 100;
const MAX_SESSIONS = 500;
const SESSION_POLL_MS = 60_000;

type RpcMessage = {
  id?: number;
  result?: {
    data?: unknown[];
    nextCursor?: string | null;
  };
  error?: unknown;
};

function findCodexCmd(): string | null {
  const override = process.env.CODEASSIST_CODEX_CMD?.trim();
  if (override && fs.existsSync(override)) return override;
  const runtime = process.env.CODEX_APP_RUNTIME_CLI_PATH?.trim();
  if (runtime && fs.existsSync(runtime)) return runtime;
  const local = process.env.LOCALAPPDATA ?? "";
  const binRoot = path.join(local, "OpenAI", "Codex", "bin");
  if (fs.existsSync(binRoot)) {
    try {
      const dirs = fs
        .readdirSync(binRoot, { withFileTypes: true })
        .filter((d) => d.isDirectory())
        .map((d) => d.name)
        .sort()
        .reverse();
      for (const name of dirs) {
        const exe = path.join(binRoot, name, "codex.exe");
        if (fs.existsSync(exe)) return exe;
      }
    } catch {
      /* ignore */
    }
  }
  const fallbacks = [
    path.join(local, "OpenAI", "Codex", "codex.exe"),
    "codex.exe",
    "codex",
  ];
  for (const candidate of fallbacks) {
    if (candidate === "codex" || candidate === "codex.exe") return candidate;
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

function codexEnvironment(): NodeJS.ProcessEnv {
  const profile = process.env.USERPROFILE?.trim() || os.homedir();
  const root = path.parse(profile).root;
  return {
    ...process.env,
    HOME: profile,
    USERPROFILE: profile,
    CODEX_HOME: process.env.CODEX_HOME?.trim() || path.join(profile, ".codex"),
    ...(process.platform === "win32"
      ? {
          HOMEDRIVE: process.env.HOMEDRIVE || root.replace(/[\\/]+$/, ""),
          HOMEPATH:
            process.env.HOMEPATH || profile.slice(root.length) || path.sep,
        }
      : {}),
  };
}

function normalizeWorkspace(value: string): string {
  let filePath = value;
  if (filePath.startsWith("file:")) {
    try {
      filePath = fileURLToPath(filePath);
    } catch {
      return "";
    }
  }
  const normalized = path.resolve(filePath).replace(/[\\/]+$/, "");
  return process.platform === "win32" ? normalized.toLowerCase() : normalized;
}

function cleanText(value: unknown, maxLength: number): string {
  return typeof value === "string"
    ? value.replace(/\s+/g, " ").trim().slice(0, maxLength)
    : "";
}

function mapSession(value: unknown): CodexDesktopSession | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as Record<string, unknown>;
  const id = cleanText(raw.id, 160);
  if (!id) return null;
  const preview = cleanText(raw.preview, 240);
  const name = cleanText(raw.name, 100);
  const title = name || preview.slice(0, 80) || `Codex 会话 ${id.slice(0, 8)}`;
  const updatedAt = Number(raw.updatedAt);
  return {
    id,
    title,
    ...(preview ? { preview } : {}),
    source: cleanText(raw.source, 40) || "unknown",
    updatedAt: Number.isFinite(updatedAt) && updatedAt > 0 ? updatedAt : 0,
  };
}

/** Read locally stored Codex threads through the supported app-server protocol. */
export function readCodexDesktopSessions(
  workspace: string,
): Promise<CodexDesktopSession[] | null> {
  return new Promise((resolve) => {
    const codex = findCodexCmd();
    if (!codex) {
      resolve(null);
      return;
    }

    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(codex, ["app-server", "--listen", "stdio://"], {
        stdio: ["pipe", "pipe", "ignore"],
        windowsHide: true,
        env: codexEnvironment(),
      });
    } catch {
      resolve(null);
      return;
    }

    const stdin = child.stdin;
    const stdout = child.stdout;
    if (!stdin || !stdout) {
      child.kill();
      resolve(null);
      return;
    }

    const targetWorkspace = normalizeWorkspace(workspace);
    const all: unknown[] = [];
    let buffer = "";
    let requestId = 1;
    let expectedListId = 0;
    let initialized = false;
    let finished = false;
    const timeout = setTimeout(() => finish(null), APP_SERVER_TIMEOUT_MS);

    const finish = (result: CodexDesktopSession[] | null) => {
      if (finished) return;
      finished = true;
      clearTimeout(timeout);
      child.kill();
      resolve(result);
    };

    const send = (message: Record<string, unknown>) => {
      if (!finished && stdin.writable) stdin.write(`${JSON.stringify(message)}\n`);
    };

    const requestPage = (cursor: string | null) => {
      const id = ++requestId;
      expectedListId = id;
      send({
        method: "thread/list",
        id,
        params: {
          cursor,
          limit: SESSION_PAGE_SIZE,
          sortKey: "updated_at",
          sourceKinds: ["cli", "vscode", "appServer", "exec"],
          useStateDbOnly: true,
        },
      });
    };

    stdin.on("error", () => finish(null));
    child.on("error", () => finish(null));
    child.on("exit", () => {
      if (!finished) finish(null);
    });
    stdout.setEncoding("utf8");
    stdout.on("data", (chunk: string) => {
      buffer += chunk;
      let newline = buffer.indexOf("\n");
      while (newline >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        newline = buffer.indexOf("\n");
        if (!line) continue;

        let message: RpcMessage;
        try {
          message = JSON.parse(line) as RpcMessage;
        } catch {
          continue;
        }

        if (message.id === 1 && !initialized) {
          if (message.error) {
            finish(null);
            return;
          }
          initialized = true;
          send({ method: "initialized", params: {} });
          requestPage(null);
          continue;
        }
        if (message.id !== expectedListId || expectedListId === 0) continue;
        if (message.error || !message.result) {
          finish(null);
          return;
        }

        all.push(...(message.result.data ?? []));
        const cursor = message.result.nextCursor ?? null;
        if (cursor && all.length < MAX_SESSIONS) {
          requestPage(cursor);
          continue;
        }

        const sessions: CodexDesktopSession[] = [];
        for (const item of all) {
          if (!item || typeof item !== "object") continue;
          const raw = item as Record<string, unknown>;
          if (
            typeof raw.cwd !== "string" ||
            normalizeWorkspace(raw.cwd) !== targetWorkspace
          ) {
            continue;
          }
          const session = mapSession(item);
          if (session) sessions.push(session);
        }
        finish(sessions);
      }
    });

    send({
      method: "initialize",
      id: 1,
      params: {
        clientInfo: {
          name: "codeassist",
          title: "CodeAssist",
          version: "0.1.0",
        },
        capabilities: { experimentalApi: true },
      },
    });
  });
}

/** Periodically sync thread metadata so the phone can select a PC conversation. */
export function startCodexDesktopSessionReporter(
  api: ApiClient,
  getProjectId: () => string | null,
  getWorkspace: () => string,
  getPeerApis: () => ApiClient[] = () => [],
): () => void {
  let stopped = false;
  let inFlight = false;
  const poll = async () => {
    const projectId = getProjectId();
    if (stopped || inFlight || !projectId) return;
    inFlight = true;
    try {
      const sessions = await readCodexDesktopSessions(getWorkspace());
      if (!stopped && sessions) {
        await Promise.allSettled(
          [api, ...getPeerApis()].map((target) =>
            target.updateCodexDesktopSessions(projectId, { sessions }),
          ),
        );
      }
    } catch (err) {
      console.error("[codeassist-mcp] Codex session sync failed:", err);
    } finally {
      inFlight = false;
    }
  };

  void poll();
  const timer = setInterval(() => void poll(), SESSION_POLL_MS);
  return () => {
    stopped = true;
    clearInterval(timer);
  };
}
