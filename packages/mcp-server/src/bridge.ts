#!/usr/bin/env node
/**
 * 独立桥接进程：不依赖 Codex/Cursor 桌面是否已加载 MCP。
 * 负责：register + heartbeat + live-pull（手机指令 → codex/cursor exec）。
 *
 * 用法：
 *   CODEASSIST_IDE=codex CODEASSIST_WORKSPACE=D:/path node dist/bridge.js
 */
import path from "node:path";
import { ApiClient } from "./api-client.js";
import { startLivePull } from "./live-pull.js";

const SERVER_URL = (
  process.env.CODEASSIST_SERVER_URL ?? "http://127.0.0.1:8787"
).replace(/\/$/, "");
const TOKEN = process.env.CODEASSIST_TOKEN ?? "codeassist-dev-token";
const IDE = (process.env.CODEASSIST_IDE ?? "codex") as "cursor" | "codex";
const WORKSPACE = path.resolve(
  process.env.CODEASSIST_WORKSPACE ?? process.cwd(),
);
const NAME =
  process.env.CODEASSIST_PROJECT_NAME?.trim() ||
  path.basename(WORKSPACE) ||
  "project";
const POLL_MS = Number(process.env.CODEASSIST_POLL_MS ?? 3000);

const api = new ApiClient(SERVER_URL, TOKEN);
let projectId: string | null = null;

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

async function main() {
  console.error(
    `[codeassist-bridge] start ide=${IDE} workspace=${WORKSPACE} server=${SERVER_URL}`,
  );
  await ensureRegistered();

  startLivePull(api, {
    serverUrl: SERVER_URL,
    token: TOKEN,
    ide: IDE,
    getProjectId: () => projectId,
    getWorkspace: () => WORKSPACE,
    onPrompts: () => undefined,
  });

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
