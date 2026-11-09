#!/usr/bin/env node
/**
 * 独立桥接进程：不依赖 Codex/Cursor 桌面是否已加载 MCP。
 * 负责：register + heartbeat + live-pull（手机指令 → codex/cursor exec）。
 *
 * 用法：
 *   CODEASSIST_IDE=codex CODEASSIST_WORKSPACE=D:/path node dist/bridge.js
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ApiClient } from "./api-client.js";
import { startLivePull } from "./live-pull.js";
import { startCodexUsageReporter } from "./codex-usage.js";
import { startCodexDesktopSessionReporter } from "./codex-desktop-sessions.js";
import type { Project } from "@codeassist/shared";

const SERVER_URL = (
  process.env.CODEASSIST_SERVER_URL ?? "http://127.0.0.1:8787"
).replace(/\/$/, "");
// CODEASSIST_TOKEN authenticates this relay connection; it is separate from
// the mobile user's mcp-x login token.
const RELAY_TOKEN = process.env.CODEASSIST_TOKEN ?? "codeassist-dev-token";
const IDE = (process.env.CODEASSIST_IDE ?? "codex") as "cursor" | "codex";
const WORKSPACE = path.resolve(
  process.env.CODEASSIST_WORKSPACE ?? process.cwd(),
);
const NAME =
  process.env.CODEASSIST_PROJECT_NAME?.trim() ||
  path.basename(WORKSPACE) ||
  "project";
const POLL_MS = Number(process.env.CODEASSIST_POLL_MS ?? 3000);
const PROJECT_WORKER_ONLY = process.env.CODEASSIST_PROJECT_WORKER_ONLY === "1";
const DEVICE_ENV_FILE = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  ".codeassist-device.env",
);

const api = new ApiClient(SERVER_URL, RELAY_TOKEN);
let projectId: string | null = null;
const projectWorkers = new Map<
  string,
  { workspacePath: string; stop: () => void; stopSessions?: () => void }
>();
let syncingProjectWorkers = false;

function cloudPeerApi(): ApiClient | null {
  try {
    const contents = fs
      .readFileSync(DEVICE_ENV_FILE, "utf8")
      .replace(/^\uFEFF/, "");
    const env = new Map<string, string>();
    for (const raw of contents.split(/\r?\n/)) {
      const line = raw.trim();
      if (!line || line.startsWith("#")) continue;
      const i = line.indexOf("=");
      if (i <= 0) continue;
      env.set(line.slice(0, i).trim(), line.slice(i + 1).trim());
    }
    const url = (env.get("CODEASSIST_SERVER_URL") ?? "")
      .trim()
      .replace(/\/$/, "");
    const token = (env.get("CODEASSIST_TOKEN") ?? "").trim();
    const local =
      /^(https?:\/\/)?(127\.0\.0\.1|localhost)(:\d+)?(\/|$)/i.test(url) ||
      /^https?:\/\/192\.168\.\d+\.\d+/i.test(url) ||
      /^https?:\/\/10\.\d+\.\d+\.\d+/i.test(url);
    if (!url || !token || local || (url === SERVER_URL && token === RELAY_TOKEN)) {
      return null;
    }
    return new ApiClient(url, token);
  } catch {
    return null;
  }
}

async function ensureRegistered() {
  const project = await api.registerProject({
    name: NAME,
    workspacePath: WORKSPACE,
    ide: IDE,
  });
  projectId = project.id;
  console.error(
    `[codeassist-bridge] online project=${project.id} ide=${project.ide} name=${project.name} workspace=${project.workspacePath}`,
  );
  return project;
}

function normalizeWorkspace(workspace: string): string {
  const resolved = path.resolve(workspace);
  return process.platform === "win32" ? resolved.toLowerCase() : resolved;
}

function isLocalWorkspace(project: Project): boolean {
  try {
    return fs.statSync(project.workspacePath).isDirectory();
  } catch {
    return false;
  }
}

/**
 * 每个本机在线项目各有一个队列消费者。这样某个 Codex 项目的长任务
 * 不会占住其他项目的消费循环；服务端保证同一项目仍只运行一条指令。
 */
async function syncProjectWorkers() {
  if (syncingProjectWorkers) return;
  syncingProjectWorkers = true;
  try {
    const projects = await api.listProjects();
    const wanted = projects.filter(
      (project) =>
        project.online &&
        project.ide === IDE &&
        isLocalWorkspace(project) &&
        (!PROJECT_WORKER_ONLY || project.id === projectId),
    );
    const wantedIds = new Set(wanted.map((project) => project.id));

    for (const [id, worker] of projectWorkers) {
      if (!wantedIds.has(id)) {
        worker.stop();
        worker.stopSessions?.();
        projectWorkers.delete(id);
      }
    }

    for (const project of wanted) {
      const workspacePath = path.resolve(project.workspacePath);
      const existing = projectWorkers.get(project.id);
      if (
        existing &&
        normalizeWorkspace(existing.workspacePath) ===
          normalizeWorkspace(workspacePath)
      ) {
        continue;
      }
      existing?.stop();
      existing?.stopSessions?.();
      const stopSessions =
        IDE === "codex"
          ? startCodexDesktopSessionReporter(
              api,
              () => project.id,
              () => workspacePath,
              () => {
                const peer = cloudPeerApi();
                return peer ? [peer] : [];
              },
            )
          : undefined;
      projectWorkers.set(project.id, {
        workspacePath,
        stopSessions,
        stop: startLivePull(api, {
          serverUrl: SERVER_URL,
          token: RELAY_TOKEN,
          ide: IDE,
          getProjectId: () => project.id,
          getWorkspace: () => workspacePath,
          onPrompts: () => undefined,
        }),
      });
      console.error(
        `[codeassist-bridge] project worker started project=${project.id} ide=${project.ide} workspace=${workspacePath}`,
      );
    }
  } catch (err) {
    console.error("[codeassist-bridge] project worker sync failed:", err);
  } finally {
    syncingProjectWorkers = false;
  }
}

async function main() {
  console.error(
    `[codeassist-bridge] start ide=${IDE} workspace=${WORKSPACE} server=${SERVER_URL}`,
  );
  await ensureRegistered();
  if (IDE === "codex") {
    startCodexUsageReporter(api, () => projectId, () => {
      const peer = cloudPeerApi();
      return peer ? [peer] : [];
    });
  }

  await syncProjectWorkers();
  setInterval(() => void syncProjectWorkers(), Math.max(POLL_MS * 4, 10_000));

  setInterval(() => {
    void (async () => {
      try {
        if (!projectId) {
          await ensureRegistered();
          return;
        }
        await api.heartbeat(projectId);
      } catch (err) {
        console.error("[codeassist-bridge] heartbeat failed, re-register:", err);
        projectId = null;
        try {
          await ensureRegistered();
        } catch (e2) {
          console.error("[codeassist-bridge] re-register failed:", e2);
        }
      }
    })();
  }, POLL_MS);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
