import { spawn, type ChildProcess } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { WebSocket } from "ws";
import type { PromptDelivery } from "@codeassist/shared";
import type { ApiClient } from "./api-client.js";
import {
  openIdeWorkspace,
  startBridgeForWorkspace,
} from "./open-workspace.js";

/**
 * 空闲超时：stdout/stderr 持续无输出才视为卡住（默认 5 分钟）。
 * 正常长时间执行会不断有输出，定时器会被刷新，不会误杀。
 */
const DEFAULT_IDLE_TIMEOUT_MS = 5 * 60 * 1000;
/** 绝对上限：再活跃也最多跑这么久（默认 45 分钟），防真正失控 */
const DEFAULT_MAX_TIMEOUT_MS = 45 * 60 * 1000;

function envMs(name: string, fallback: number, minMs: number): number {
  const n = Number(process.env[name] || fallback);
  return Number.isFinite(n) && n >= minMs ? n : fallback;
}

function agentIdleTimeoutMs(): number {
  return envMs("CODEASSIST_AGENT_IDLE_TIMEOUT_MS", DEFAULT_IDLE_TIMEOUT_MS, 30_000);
}

function agentMaxTimeoutMs(): number {
  // 兼容旧变量名 CODEASSIST_AGENT_TIMEOUT_MS 作为绝对上限
  return envMs("CODEASSIST_AGENT_TIMEOUT_MS", DEFAULT_MAX_TIMEOUT_MS, 60_000);
}

type AgentSessionLock = {
  setAgentPid: (pid: number | undefined) => void;
  release: () => void;
};

type AgentSessionLockOwner = {
  token: string;
  pid: number;
  agentPid?: number;
  host: string;
  heartbeatAt: number;
};

function processIsAlive(pid: number | undefined): boolean {
  if (!pid || !Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === "EPERM";
  }
}

/**
 * Serialize writes to a Cursor/Codex conversation across duplicate bridge/MCP
 * processes. The in-memory drain guard only protects one process; a lock in the
 * OS temp directory is shared by all consumers on this machine.
 */
async function acquireAgentSessionLock(
  projectId: string,
  chatSessionId?: string,
): Promise<AgentSessionLock> {
  const key = `${projectId}:${chatSessionId || "default"}`;
  const name = createHash("sha256").update(key).digest("hex");
  const dir = path.join(os.tmpdir(), "codeassist-agent-locks");
  fs.mkdirSync(dir, { recursive: true });
  const lockPath = path.join(dir, `${name}.lock`);
  const token = randomUUID();
  const owner: AgentSessionLockOwner = {
    token,
    pid: process.pid,
    host: os.hostname(),
    heartbeatAt: Date.now(),
  };
  const writeOwner = () => {
    try {
      const current = JSON.parse(fs.readFileSync(lockPath, "utf8")) as AgentSessionLockOwner;
      if (current.token === token) {
        owner.heartbeatAt = Date.now();
        fs.writeFileSync(lockPath, JSON.stringify(owner), "utf8");
      }
    } catch {
      /* the lock may be removed while this process is shutting down */
    }
  };

  while (true) {
    try {
      const fd = fs.openSync(lockPath, "wx");
      fs.writeFileSync(fd, JSON.stringify(owner), "utf8");
      fs.closeSync(fd);
      break;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "EEXIST") throw err;
      let existing: AgentSessionLockOwner | undefined;
      let stale = false;
      try {
        existing = JSON.parse(fs.readFileSync(lockPath, "utf8")) as AgentSessionLockOwner;
        const ageMs = Date.now() - (existing.heartbeatAt || 0);
        const sameHost = existing.host === os.hostname();
        stale = sameHost
          ? !processIsAlive(existing.pid) && !processIsAlive(existing.agentPid)
          : ageMs > 2 * 60 * 60 * 1000;
      } catch {
        try {
          stale = Date.now() - fs.statSync(lockPath).mtimeMs > 30_000;
        } catch {
          stale = true;
        }
      }
      if (stale) {
        // Re-read the owner immediately before removing a stale lock so a
        // heartbeat or a concurrent recovery cannot delete a new owner's lock.
        try {
          const latest = JSON.parse(fs.readFileSync(lockPath, "utf8")) as AgentSessionLockOwner;
          if (!existing || latest.token === existing.token) fs.unlinkSync(lockPath);
        } catch {
          /* another process already reclaimed it */
        }
        continue;
      }
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }

  const heartbeatTimer = setInterval(writeOwner, 15_000);
  heartbeatTimer.unref();
  return {
    setAgentPid(pid) {
      owner.agentPid = pid;
      writeOwner();
    },
    release() {
      clearInterval(heartbeatTimer);
      try {
        const current = JSON.parse(fs.readFileSync(lockPath, "utf8")) as AgentSessionLockOwner;
        if (current.token === token) fs.unlinkSync(lockPath);
      } catch {
        /* already released or reclaimed */
      }
    },
  };
}

/** 可自动重试/切备用引擎的失败（绝对上限超时不重试，避免拖死队列） */
function isRetryableAgentFailure(text: string): boolean {
  if (!text.startsWith("[agent-error]")) return false;
  if (text.includes("绝对上限")) return false;
  if (/未找到 Cursor Agent CLI|未找到 Codex CLI/i.test(text)) return false;
  return (
    /agent exited \d+/i.test(text) ||
    /codex exited \d+/i.test(text) ||
    /exit=\d+/i.test(text) ||
    /ownership is currently changing/i.test(text) ||
    /ENOTFOUND|ECONNRESET|ETIMEDOUT|ECONNREFUSED|unavailable/i.test(text) ||
    /空闲超时/i.test(text)
  );
}

function killProcessTree(child: ChildProcess) {
  const pid = child.pid;
  if (!pid) return;
  try {
    if (process.platform === "win32") {
      spawn("taskkill", ["/pid", String(pid), "/T", "/F"], {
        windowsHide: true,
        stdio: "ignore",
        detached: true,
      }).unref();
    } else {
      child.kill("SIGKILL");
    }
  } catch {
    try {
      child.kill("SIGKILL");
    } catch {
      /* ignore */
    }
  }
}

type Options = {
  serverUrl: string;
  token: string;
  /** cursor | codex — 决定拉起哪套 Agent CLI */
  ide?: "cursor" | "codex";
  getProjectId: () => string | null;
  getWorkspace: () => string;
  onPrompts: (prompts: PromptDelivery[]) => void;
};

/**
 * Phone creates prompt → relay WS → MCP pulls and runs Cursor Agent,
 * then pushes execution result back to the phone (complete_prompt + session + task).
 */
export function startLivePull(api: ApiClient, opts: Options): () => void {
  let closed = false;
  let ws: WebSocket | null = null;
  let retryTimer: ReturnType<typeof setTimeout> | null = null;
  let draining = false;
  let wakeAgain = false;
  const seen = new Set<string>();

  const connect = () => {
    if (closed) return;
    const http = opts.serverUrl.replace(/\/$/, "");
    const wsUrl = http.replace(/^http:/, "ws:").replace(/^https:/, "wss:");
    const url = `${wsUrl}/ws?token=${encodeURIComponent(opts.token)}`;
    ws = new WebSocket(url);

    ws.on("open", () => {
      console.error("[codeassist-mcp] live-pull connected (phone→PC→结果回传)");
      // 订阅全部事件：除本项目 prompt 外，还需收到 project.open
      ws?.send(JSON.stringify({ type: "subscribe" }));
      // 重连后把积压的 queued 排空
      void drainQueue();
      void drainOpenWorkspace();
    });

    ws.on("message", (raw) => {
      void onMessage(String(raw));
    });

    ws.on("close", () => {
      ws = null;
      if (!closed) {
        retryTimer = setTimeout(() => {
          retryTimer = null;
          connect();
        }, 3000);
      }
    });

    ws.on("error", (err) => {
      // 云端 nginx 常丢 Upgrade → WS 失败；靠下方 HTTP 轮询兜底，勿静默吞掉
      console.error(
        "[codeassist-mcp] live-pull ws error (will retry; HTTP poll still active):",
        err instanceof Error ? err.message : err,
      );
    });
  };

  async function onMessage(raw: string) {
    try {
      const msg = JSON.parse(raw) as {
        type?: string;
        payload?: {
          id?: string;
          projectId?: string;
          status?: string;
          content?: string;
          workspacePath?: string;
          viaProjectId?: string;
          claimedBy?: string;
        };
      };
      if (msg.type === "project.open" && msg.payload) {
        const st = msg.payload.status;
        if (!st || st === "queued") {
          await drainOpenWorkspace();
        }
        return;
      }
      if (msg.type !== "prompt.updated" || !msg.payload) return;
      const projectId = opts.getProjectId();
      if (!projectId || msg.payload.projectId !== projectId) return;
      if (msg.payload.status && msg.payload.status !== "queued") return;

      // 执行中又来新指令：不要写入 seen（否则完成后永远不会再跑），只唤醒排空
      if (draining) {
        wakeAgain = true;
        return;
      }
      await drainQueue();
    } catch (err) {
      console.error("[codeassist-mcp] live-pull error:", err);
    }
  }

  async function drainOpenWorkspace() {
    if (closed) return;
    const projectId = opts.getProjectId();
    if (!projectId) return;
    try {
      const cmds = await api.claimOpenWorkspace(projectId);
      for (const cmd of cmds) {
        console.error(
          `[codeassist-mcp] open workspace claim=${cmd.id} path=${cmd.workspacePath} ide=${cmd.ide}`,
        );
        const opened = openIdeWorkspace(cmd.ide, cmd.workspacePath);
        const bridged = startBridgeForWorkspace({
          ide: cmd.ide,
          workspace: cmd.workspacePath,
          serverUrl: opts.serverUrl,
          token: opts.token,
        });
        const ok = opened.ok || bridged.ok;
        const detail = [opened.detail, bridged.detail]
          .filter(Boolean)
          .join("；");
        await api
          .completeOpenWorkspace(
            cmd.id,
            ok ? "done" : "failed",
            ok ? undefined : detail,
          )
          .catch(() => undefined);
        console.error(
          `[codeassist-mcp] open workspace ${ok ? "done" : "failed"}: ${detail}`,
        );
        notifyToast(
          ok
            ? `CodeAssist：已在 PC 打开 ${path.basename(cmd.workspacePath)}`
            : `CodeAssist：打开项目失败`,
        );
      }
    } catch (err) {
      console.error("[codeassist-mcp] open-workspace drain error:", err);
    }
  }

  async function drainQueue() {
    if (closed) return;
    if (draining) {
      wakeAgain = true;
      return;
    }
    draining = true;
    try {
      do {
        wakeAgain = false;
        const projectId = opts.getProjectId();
        if (!projectId) break;

        // 一次一条，前一条完成后再拉下一条
        const prompts = await api.pullPrompts(projectId);
        if (prompts.length === 0) continue;

        for (const p of prompts) seen.add(p.id);
        opts.onPrompts(prompts);
        const chatSessionId = prompts.find((p) => p.chatSessionId)?.chatSessionId;
        const sessionLock = await acquireAgentSessionLock(projectId, chatSessionId);
        try {
            console.error(
              `[codeassist-mcp] 串行执行手机指令 (${prompts.length}) → 完成后自动接下一条`,
            );
            const ide = opts.ide === "codex" ? "codex" : "cursor";
            const ideLabel = ide === "codex" ? "Codex" : "Cursor";
            notifyToast(`CodeAssist：正在 ${ideLabel} 执行手机指令`);
            if (ide === "cursor") {
              focusCursorWorkspace(opts.getWorkspace());
            }

            for (const p of prompts) {
              try {
                await api.ackPrompt(p.id);
              } catch {
                /* may already be running */
              }
            }

            await api
              .syncSessionContext({
                projectId,
                chatSessionId,
                summary: `正在执行手机指令：${prompts.map((p) => p.content).join(" | ").slice(0, 200)}`,
                currentStep: `${ideLabel} Agent 执行中`,
                openFiles: [],
                status: "coding",
              })
              .catch(() => undefined);

            let resumeChatId: string | undefined;
            if (chatSessionId) {
              try {
                const chat = await api.getChatSession(chatSessionId);
                resumeChatId = chat.cursorChatId;
              } catch {
                /* ignore */
              }
            }

            const enrichedContents: string[] = [];
            for (const p of prompts) {
              enrichedContents.push(
                await materializePromptAttachment(
                  api,
                  opts.getWorkspace(),
                  p,
                ),
              );
            }

            // 空闲超时 + 绝对上限；有输出会续命。硬兜底防止 Windows 杀不干净导致队列永久卡住
            const idleMs = agentIdleTimeoutMs();
            const maxMs = agentMaxTimeoutMs();
            let agentResult: AgentRunResult;
            let hardTimer: ReturnType<typeof setTimeout> | undefined;
            let lastHeartbeatAt = 0;
            const heartbeat = () => {
              const now = Date.now();
              if (now - lastHeartbeatAt < 60_000) return;
              lastHeartbeatAt = now;
              for (const p of prompts) {
                void api.ackPrompt(p.id).catch(() => undefined);
              }
              void api
                .syncSessionContext({
                  projectId,
                  chatSessionId,
                  summary: `手机指令执行中（仍有进度）：${prompts.map((p) => p.content).join(" | ").slice(0, 160)}`,
                  currentStep: `${ideLabel} Agent 执行中（活跃）`,
                  openFiles: [],
                  status: "coding",
                })
                .catch(() => undefined);
            };
            try {
              const raceAgent = (
                run: () => Promise<AgentRunResult>,
              ): Promise<AgentRunResult> => {
                if (hardTimer) clearTimeout(hardTimer);
                return Promise.race([
                  run().finally(() => {
                    if (hardTimer) clearTimeout(hardTimer);
                  }),
                  new Promise<AgentRunResult>((resolve) => {
                    hardTimer = setTimeout(() => {
                      resolve({
                        text: `[agent-error] 执行超过绝对上限(${Math.round(maxMs / 1000)}s)，已中止以免阻塞后续手机指令`,
                      });
                    }, maxMs + 20_000);
                  }),
                ]);
              };

              const runPrimary = (resume?: string) =>
                ide === "codex"
                  ? () =>
                      runCodexAgent(
                        opts.getWorkspace(),
                        enrichedContents,
                        prompts.map((p) => p.id),
                        resume,
                        idleMs,
                        maxMs,
                        heartbeat,
                        (pid) => sessionLock.setAgentPid(pid),
                      )
                  : () =>
                      runCursorAgent(
                        opts.getWorkspace(),
                        enrichedContents,
                        prompts.map((p) => p.id),
                        resume,
                        idleMs,
                        maxMs,
                        heartbeat,
                        (pid) => sessionLock.setAgentPid(pid),
                      );

              agentResult = await raceAgent(runPrimary(resumeChatId));

              // 瞬时失败时重试一次；Codex 续聊保留原 ID，避免静默切成新会话。
              if (isRetryableAgentFailure(agentResult.text)) {
                console.error(
                  `[codeassist-mcp] ${ideLabel} 首次失败，自动重试一次：${agentResult.text.slice(0, 160)}`,
                );
                notifyToast(`CodeAssist：${ideLabel} 失败，自动重试…`);
                const retryResumeId = ide === "codex" ? resumeChatId : undefined;
                if (chatSessionId && !retryResumeId) {
                  await api
                    .updateChatSession(chatSessionId, { cursorChatId: "" })
                    .catch(() => undefined);
                }
                agentResult = await raceAgent(runPrimary(retryResumeId));
              }

              // 备用2：Cursor 仍失败时，若本机有 Codex CLI 则切换 Codex 再跑
              const allowCodexFallback =
                process.env.CODEASSIST_FALLBACK_CODEX !== "0";
              if (
                ide === "cursor" &&
                allowCodexFallback &&
                isRetryableAgentFailure(agentResult.text) &&
                findCodexCmd()
              ) {
                console.error(
                  `[codeassist-mcp] Cursor 仍失败，备用切换 Codex：${agentResult.text.slice(0, 160)}`,
                );
                notifyToast("CodeAssist：Cursor 失败，改用 Codex 执行…");
                agentResult = await raceAgent(() =>
                  runCodexAgent(
                    opts.getWorkspace(),
                    enrichedContents,
                    prompts.map((p) => p.id),
                    undefined,
                    idleMs,
                    maxMs,
                    heartbeat,
                    (pid) => sessionLock.setAgentPid(pid),
                  ),
                );
              }
            } catch (err) {
              if (hardTimer) clearTimeout(hardTimer);
              agentResult = {
                text: `[agent-error] ${err instanceof Error ? err.message : String(err)}`,
              };
            }

            if (chatSessionId && agentResult.cursorChatId) {
              await api
                .updateChatSession(chatSessionId, {
                  cursorChatId: agentResult.cursorChatId,
                })
                .catch(() => undefined);
            }

            let resultText = agentResult.text;
            if (resultText === "[agent-error] agent exited 1") {
              resultText =
                "[agent-error] agent exited 1（Cursor Agent 无输出退出）。常见原因：会话 resume 损坏、Cursor API 瞬时失败、Agent 进程崩溃。已尝试自动重试/备用引擎；仍失败请保持 Cursor 打开本项目（走 MCP 人工回合），或重登 agent status。";
            }
            const ok = !resultText.startsWith("[agent-error]");
            const summary = truncate(resultText, 3500);

            for (const p of prompts) {
              try {
                await api.completePrompt(
                  p.id,
                  ok ? "done" : "failed",
                  summary || (ok ? "执行完成" : "执行失败"),
                );
              } catch (err) {
                console.error("[codeassist-mcp] complete_prompt failed:", err);
              }
            }

            await api
              .syncSessionContext({
                projectId,
                chatSessionId,
                summary: ok
                  ? `手机指令已完成：${prompts.map((p) => p.content).join(" | ").slice(0, 120)}`
                  : `手机指令失败：${prompts.map((p) => p.content).join(" | ").slice(0, 120)}`,
                currentStep: ok ? "已回传结果到手机" : "执行失败，已回传错误",
                openFiles: [],
                status: ok ? "done" : "blocked",
                extra: summary,
              })
              .catch(() => undefined);

            await api
              .createTask({
                projectId,
                type: ok ? "completed" : "blocked",
                title: ok ? "手机指令执行完成" : "手机指令执行失败",
                detail: `指令：\n${prompts.map((p) => p.content).join("\n")}\n\n结果：\n${summary}`,
                requireDecision: false,
              })
              .catch(() => undefined);

            notifyToast(
              ok
                ? "CodeAssist：结果已同步到手机"
                : "CodeAssist：执行失败，错误已同步到手机",
            );
        } finally {
          sessionLock.release();
        }
        // 继续 while：再 pull 下一条 queued
        wakeAgain = true;
      } while (!closed && wakeAgain);
    } catch (err) {
      console.error("[codeassist-mcp] live-pull drain error:", err);
    } finally {
      draining = false;
      if (!closed && wakeAgain) {
        wakeAgain = false;
        void drainQueue();
      }
    }
  }

  connect();

  // HTTP 轮询兜底：WS 在部分网关（如未配置 Upgrade 的 nginx）会一直连不上，
  // 仅靠 WS open/message 时永远不会 drainQueue，手机端就会一直「排队等待」。
  const pollMs = Number(process.env.CODEASSIST_POLL_MS ?? 3000);
  const pollEvery = Number.isFinite(pollMs) && pollMs >= 1000 ? pollMs : 3000;
  console.error(
    `[codeassist-mcp] live-pull HTTP poll every ${pollEvery}ms (WS + poll)`,
  );
  const pollTimer = setInterval(() => {
    if (closed || draining) return;
    void drainQueue();
    void drainOpenWorkspace();
  }, pollEvery);

  return () => {
    closed = true;
    clearInterval(pollTimer);
    if (retryTimer) clearTimeout(retryTimer);
    ws?.close();
  };
}

function truncate(s: string, n: number): string {
  const t = s.trim();
  if (t.length <= n) return t;
  return `${t.slice(0, n)}\n…(已截断)`;
}

type AgentLaunch = { exe: string; prefixArgs: string[]; label: string };

/** Prefer node.exe + index.js so Windows 不会弹出黑框，且中文/换行参数不被 cmd 弄坏。 */
function resolveAgentLaunch(): AgentLaunch | null {
  if (process.env.CODEASSIST_DISABLE_AGENT_SPAWN === "1") return null;

  const override = process.env.CODEASSIST_AGENT_CMD?.trim();
  if (override) {
    if (override.toLowerCase().endsWith(".js") && fs.existsSync(override)) {
      const node =
        process.env.CODEASSIST_AGENT_NODE?.trim() ||
        path.join(path.dirname(override), "node.exe");
      if (fs.existsSync(node)) {
        return { exe: node, prefixArgs: [override], label: override };
      }
    }
    if (override.toLowerCase().endsWith("node.exe") || override === "node") {
      return { exe: override, prefixArgs: [], label: override };
    }
  }

  const local = process.env.LOCALAPPDATA || "";
  const root = path.join(local, "cursor-agent");
  const versionsRoot = path.join(root, "versions");
  if (fs.existsSync(versionsRoot)) {
    const dirs = fs
      .readdirSync(versionsRoot, { withFileTypes: true })
      .filter((d) => d.isDirectory())
      .map((d) => d.name)
      .filter((name) =>
        /^\d{4}\.\d{1,2}\.\d{1,2}(-\d{2}-\d{2}-\d{2})?-[a-f0-9]+$/i.test(name),
      )
      .sort()
      .reverse();
    for (const name of dirs) {
      const dir = path.join(versionsRoot, name);
      const node = path.join(dir, "node.exe");
      const indexJs = path.join(dir, "index.js");
      if (fs.existsSync(node) && fs.existsSync(indexJs)) {
        return {
          exe: node,
          prefixArgs: [indexJs],
          label: `cursor-agent/${name}`,
        };
      }
    }
  }

  // .cmd/.ps1 必须走 cmd/powershell，黑框+参数易坏；发现不到 node 时再报错
  if (
    override &&
    fs.existsSync(override) &&
    !/\.(cmd|bat|ps1)$/i.test(override)
  ) {
    return { exe: override, prefixArgs: [], label: override };
  }
  return null;
}

function findCursorCmd(): string | null {
  const candidates = [
    process.env.CURSOR_CMD,
    "D:\\cursor\\resources\\app\\bin\\cursor.cmd",
    path.join(process.env.LOCALAPPDATA ?? "", "Programs", "cursor", "resources", "app", "bin", "cursor.cmd"),
    "cursor.cmd",
    "cursor",
  ].filter(Boolean) as string[];
  for (const c of candidates) {
    if (c === "cursor" || c === "cursor.cmd") return c;
    if (fs.existsSync(c)) return c;
  }
  return null;
}

function focusCursorWorkspace(workspace: string) {
  const cursor = findCursorCmd();
  if (!cursor) return;
  try {
    spawn(cursor, ["-r", workspace], {
      detached: true,
      stdio: "ignore",
      shell: true,
      windowsHide: true,
    }).unref();
  } catch {
    /* ignore */
  }
}

type AgentRunResult = { text: string; cursorChatId?: string };

function extractCursorChatId(raw: string): string | undefined {
  const patterns = [
    /"thread_id"\s*:\s*"([^"]+)"/i,
    /"threadId"\s*:\s*"([^"]+)"/i,
    /"session_id"\s*:\s*"([^"]+)"/i,
    /"chatId"\s*:\s*"([^"]+)"/i,
    /"chat_id"\s*:\s*"([^"]+)"/i,
    /"conversation_id"\s*:\s*"([^"]+)"/i,
  ];
  for (const re of patterns) {
    const m = raw.match(re);
    if (m?.[1]) return m[1];
  }
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    for (const key of [
      "thread_id",
      "threadId",
      "session_id",
      "chatId",
      "chat_id",
      "conversation_id",
    ]) {
      const v = parsed[key];
      if (typeof v === "string" && v) return v;
    }
  } catch {
    /* not pure json */
  }
  return undefined;
}

function extractResultText(raw: string): string {
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    if (typeof parsed.result === "string" && parsed.result.trim()) {
      return parsed.result;
    }
    if (typeof parsed.text === "string" && parsed.text.trim()) {
      return parsed.text;
    }
  } catch {
    /* keep raw */
  }
  return raw;
}

async function materializePromptAttachment(
  api: ApiClient,
  workspace: string,
  prompt: PromptDelivery,
): Promise<string> {
  const attachment = prompt.attachment;
  if (!attachment) return prompt.content;
  try {
    const bytes = await api.downloadFileBytes(attachment.id);
    const inboxDir = path.join(workspace, ".codeassist", "inbox");
    fs.mkdirSync(inboxDir, { recursive: true });
    const safeName = attachment.fileName.replace(/[\\/:*?"<>|]/g, "_");
    const localName = `${attachment.id.slice(0, 8)}_${safeName}`;
    const localPath = path.join(inboxDir, localName);
    fs.writeFileSync(localPath, bytes);
    const rel = path.relative(workspace, localPath).replace(/\\/g, "/");
    const isImage = (attachment.mimeType ?? "").startsWith("image/")
      || /\.(png|jpe?g|gif|webp|bmp|heic)$/i.test(attachment.fileName);
    return (
      `${prompt.content}\n\n` +
      `【手机附件已保存到工作区】\n` +
      `- 本地路径：${rel}\n` +
      `- 文件名：${attachment.fileName}\n` +
      (isImage
        ? `- 这是图片，请用 Read 工具打开该路径查看图片内容，再按用户说明处理。\n`
        : `- 请读取该文件并根据用户说明处理。\n`)
    );
  } catch (err) {
    console.error("[codeassist-mcp] materialize attachment failed:", err);
    return (
      `${prompt.content}\n\n` +
      `【注意】手机附件「${attachment.fileName}」下载到工作区失败：${
        err instanceof Error ? err.message : String(err)
      }`
    );
  }
}

function runCursorAgent(
  workspace: string,
  contents: string[],
  deliveryIds: string[],
  resumeChatId?: string,
  idleTimeoutMs: number = agentIdleTimeoutMs(),
  maxTimeoutMs: number = agentMaxTimeoutMs(),
  onActivity?: () => void,
  onSpawn?: (pid: number | undefined) => void,
): Promise<AgentRunResult> {
  return new Promise((resolve) => {
    const launch = resolveAgentLaunch();
    if (!launch) {
      resolve({
        text: "[agent-error] 未找到 Cursor Agent CLI。请执行: irm https://cursor.com/install?win32=true | iex",
      });
      return;
    }

    const prompt =
      `你正在 Cursor 中执行【手机客户端发来的指令】，必须像本地用户在 IDE 发 Prompt 一样认真改代码、跑命令。\n` +
      `要求：\n` +
      `1. 直接执行下列指令（不要只口头说明）\n` +
      `2. 过程中可用 MCP codeassist：ack_prompt / sync_session_context\n` +
      `3. 结束后用中文写清：做了什么、改了哪些文件、结果如何（这段会同步给手机）\n\n` +
      contents.map((c, i) => `### 指令 ${i + 1}\n${c}`).join("\n\n") +
      (deliveryIds.length ? `\n\nDeliveryIds: ${deliveryIds.join(", ")}` : "");

    let promptArg = prompt;
    let promptFile: string | null = null;
    if (Buffer.byteLength(prompt, "utf8") > 6000) {
      promptFile = path.join(
        workspace,
        `.codeassist-prompt-${Date.now()}.txt`,
      );
      try {
        fs.writeFileSync(promptFile, prompt, "utf8");
        promptArg = `请读取并严格执行文件中的指令：${promptFile}`;
      } catch {
        promptFile = null;
      }
    }

    const args = [
      ...launch.prefixArgs,
      "-p",
      "--force",
      "--approve-mcps",
      "--trust",
      "--workspace",
      workspace,
      "--output-format",
      "json",
    ];
    if (resumeChatId) {
      args.push("--resume", resumeChatId);
      console.error(`[codeassist-mcp] 续跑 Cursor session: ${resumeChatId}`);
    }
    args.push(promptArg);

    console.error(
      `[codeassist-mcp] Cursor Agent 执行中(无黑框, idle=${Math.round(idleTimeoutMs / 1000)}s, max=${Math.round(maxTimeoutMs / 1000)}s): ${launch.label}`,
    );
    let out = "";
    let err = "";
    let settled = false;
    let idleTimer: ReturnType<typeof setTimeout> | undefined;
    let maxTimer: ReturnType<typeof setTimeout> | undefined;
    let killWaitTimer: ReturnType<typeof setTimeout> | undefined;

    const clearTimers = () => {
      if (idleTimer) clearTimeout(idleTimer);
      if (maxTimer) clearTimeout(maxTimer);
      if (killWaitTimer) clearTimeout(killWaitTimer);
      idleTimer = undefined;
      maxTimer = undefined;
      killWaitTimer = undefined;
    };

    const finish = (text: string, cursorChatId?: string) => {
      if (settled) return;
      settled = true;
      clearTimers();
      if (promptFile) {
        try {
          fs.unlinkSync(promptFile);
        } catch {
          /* ignore */
        }
      }
      resolve({ text, cursorChatId });
    };

    const child = spawn(launch.exe, args, {
      cwd: workspace,
      shell: false,
      windowsHide: true,
      env: {
        ...process.env,
        CI: process.env.CI || "1",
        NO_OPEN_BROWSER: "1",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    onSpawn?.(child.pid);

    const abortForTimeout = (reason: string) => {
      if (settled) return;
      console.error(`[codeassist-mcp] Agent ${reason}，taskkill 进程树`);
      killProcessTree(child);
      killWaitTimer = setTimeout(() => {
        if (settled) return;
        killProcessTree(child);
        const partial = [out, err].filter(Boolean).join("\n").trim();
        finish(
          `[agent-error] ${reason}，已中止以免阻塞后续手机指令\n${partial || "(无输出)"}`,
          extractCursorChatId(partial),
        );
      }, 8_000);
    };

    const armIdleTimer = () => {
      if (idleTimer) clearTimeout(idleTimer);
      idleTimer = setTimeout(() => {
        abortForTimeout(
          `空闲超时(${Math.round(idleTimeoutMs / 1000)}s无输出)`,
        );
      }, idleTimeoutMs);
    };

    armIdleTimer();
    maxTimer = setTimeout(() => {
      abortForTimeout(`绝对上限(${Math.round(maxTimeoutMs / 1000)}s)`);
    }, maxTimeoutMs);

    const noteActivity = () => {
      if (settled) return;
      armIdleTimer();
      try {
        onActivity?.();
      } catch {
        /* ignore */
      }
    };

    child.stdout?.on("data", (d: Buffer) => {
      out += d.toString("utf8");
      noteActivity();
    });
    child.stderr?.on("data", (d: Buffer) => {
      err += d.toString("utf8");
      noteActivity();
    });
    child.on("error", (e) => {
      finish(`[agent-error] ${e.message}`);
    });
    child.on("close", (code) => {
      const raw = [out, err].filter(Boolean).join("\n").trim();
      const cursorChatId = extractCursorChatId(raw) ?? resumeChatId;
      if (code !== 0 && !raw) {
        finish(`[agent-error] agent exited ${code}`, cursorChatId);
        return;
      }
      if (code !== 0) {
        finish(`[agent-error] exit=${code}\n${extractResultText(raw)}`, cursorChatId);
        return;
      }
      finish(
        extractResultText(raw) || "Agent 已执行完成（无文本输出）",
        cursorChatId,
      );
    });
  });
}

function findCodexCmd(): string | null {
  const override = process.env.CODEASSIST_CODEX_CMD?.trim();
  if (override && fs.existsSync(override)) return override;
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
  for (const c of fallbacks) {
    if (c === "codex" || c === "codex.exe") return c;
    if (fs.existsSync(c)) return c;
  }
  return null;
}

function extractCodexLastMessage(raw: string, outFile?: string): string {
  if (outFile) {
    try {
      if (fs.existsSync(outFile)) {
        const t = fs.readFileSync(outFile, "utf8").trim();
        if (t) return t;
      }
    } catch {
      /* ignore */
    }
  }
  // --json 输出 JSONL：取最后一条带 message/text/content 的
  const lines = raw.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      const obj = JSON.parse(lines[i]!) as Record<string, unknown>;
      for (const key of ["last_agent_message", "message", "text", "content", "result"]) {
        const v = obj[key];
        if (typeof v === "string" && v.trim()) return v.trim();
      }
      const item = obj.item as Record<string, unknown> | undefined;
      if (item && typeof item.text === "string" && item.text.trim()) {
        return item.text.trim();
      }
    } catch {
      /* continue */
    }
  }
  return extractResultText(raw);
}

function runCodexAgent(
  workspace: string,
  contents: string[],
  deliveryIds: string[],
  resumeChatId?: string,
  idleTimeoutMs: number = agentIdleTimeoutMs(),
  maxTimeoutMs: number = agentMaxTimeoutMs(),
  onActivity?: () => void,
  onSpawn?: (pid: number | undefined) => void,
): Promise<AgentRunResult> {
  return new Promise((resolve) => {
    const codex = findCodexCmd();
    if (!codex) {
      resolve({
        text: "[agent-error] 未找到 Codex CLI。请确认已安装 OpenAI Codex 桌面版，或设置 CODEASSIST_CODEX_CMD。",
      });
      return;
    }

    const prompt =
      `你正在 Codex 中执行【手机客户端发来的指令】，必须像本地用户在 IDE 发 Prompt 一样认真改代码、跑命令。\n` +
      `要求：\n` +
      `1. 直接执行下列指令（不要只口头说明）\n` +
      `2. 过程中可用 MCP codeassist：ack_prompt / sync_session_context\n` +
      `3. 结束后用中文写清：做了什么、改了哪些文件、结果如何（这段会同步给手机）\n\n` +
      contents.map((c, i) => `### 指令 ${i + 1}\n${c}`).join("\n\n") +
      (deliveryIds.length ? `\n\nDeliveryIds: ${deliveryIds.join(", ")}` : "");

    let promptArg = prompt;
    let promptFile: string | null = null;
    if (Buffer.byteLength(prompt, "utf8") > 6000) {
      promptFile = path.join(
        workspace,
        `.codeassist-prompt-${Date.now()}.txt`,
      );
      try {
        fs.writeFileSync(promptFile, prompt, "utf8");
        promptArg = `请读取并严格执行文件中的指令：${promptFile}`;
      } catch {
        promptFile = null;
      }
    }

    const outFile = path.join(
      workspace,
      `.codeassist`,
      `codex-last-${Date.now()}.txt`,
    );
    try {
      fs.mkdirSync(path.dirname(outFile), { recursive: true });
    } catch {
      /* ignore */
    }

    // ChatGPT 登录账号不支持部分默认新模型（如 gpt-6.1-sol），显式指定可用模型。
    // 可用 CODEASSIST_CODEX_MODEL 覆盖，例如 gpt-5.6-luna / gpt-6-luna。
    const model =
      process.env.CODEASSIST_CODEX_MODEL?.trim() || "gpt-6-luna";

    // Mobile prompts run headlessly, so there is no terminal UI to answer
    // Codex's on-request approval prompts. Route eligible requests through
    // Codex automatic review; this uses the workspace-write sandbox and can
    // still deny risky actions. Keep the flag before `resume` so it applies
    // to both new and resumed sessions.
    const args = ["exec", "--approve-for-me", "-C", workspace];
    if (resumeChatId) {
      args.push("resume", resumeChatId);
      console.error(`[codeassist-mcp] 续跑 Codex session: ${resumeChatId}`);
    }
    args.push(
      "-m",
      model,
      "--json",
      "-o",
      outFile,
      "--skip-git-repo-check",
      promptArg,
    );

    console.error(
      `[codeassist-mcp] Codex 执行中(model=${model}, idle=${Math.round(idleTimeoutMs / 1000)}s, max=${Math.round(maxTimeoutMs / 1000)}s): ${codex}`,
    );

    let out = "";
    let err = "";
    let settled = false;
    let idleTimer: ReturnType<typeof setTimeout> | undefined;
    let maxTimer: ReturnType<typeof setTimeout> | undefined;
    let killWaitTimer: ReturnType<typeof setTimeout> | undefined;

    const clearTimers = () => {
      if (idleTimer) clearTimeout(idleTimer);
      if (maxTimer) clearTimeout(maxTimer);
      if (killWaitTimer) clearTimeout(killWaitTimer);
    };

    const finish = (text: string, cursorChatId?: string) => {
      if (settled) return;
      settled = true;
      clearTimers();
      for (const f of [promptFile, outFile]) {
        if (!f) continue;
        try {
          fs.unlinkSync(f);
        } catch {
          /* ignore */
        }
      }
      resolve({ text, cursorChatId });
    };

    // Resume must use the same Codex home as the desktop app that owns the thread.
    const userProfile = process.env.USERPROFILE?.trim() || os.homedir();
    const homeRoot = path.parse(userProfile).root;
    const codexHome =
      process.env.CODEX_HOME?.trim() || path.join(userProfile, ".codex");

    const child = spawn(codex, args, {
      cwd: workspace,
      shell: false,
      windowsHide: true,
      env: {
        ...process.env,
        HOME: userProfile,
        CODEX_HOME: codexHome,
        ...(process.platform === "win32"
          ? {
              USERPROFILE: userProfile,
              HOMEDRIVE:
                process.env.HOMEDRIVE || homeRoot.replace(/[\\/]+$/, ""),
              HOMEPATH:
                process.env.HOMEPATH ||
                userProfile.slice(homeRoot.length) ||
                path.sep,
            }
          : {}),
        CI: process.env.CI || "1",
        NO_COLOR: "1",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    onSpawn?.(child.pid);

    const abortForTimeout = (reason: string) => {
      if (settled) return;
      console.error(`[codeassist-mcp] Codex ${reason}，taskkill 进程树`);
      killProcessTree(child);
      killWaitTimer = setTimeout(() => {
        if (settled) return;
        killProcessTree(child);
        const partial = [out, err].filter(Boolean).join("\n").trim();
        finish(
          `[agent-error] ${reason}，已中止以免阻塞后续手机指令\n${
            extractCodexLastMessage(partial, outFile) || "(无输出)"
          }`,
          extractCursorChatId(partial) ?? resumeChatId,
        );
      }, 8_000);
    };

    const armIdleTimer = () => {
      if (idleTimer) clearTimeout(idleTimer);
      idleTimer = setTimeout(() => {
        abortForTimeout(
          `空闲超时(${Math.round(idleTimeoutMs / 1000)}s无输出)`,
        );
      }, idleTimeoutMs);
    };
    armIdleTimer();
    maxTimer = setTimeout(() => {
      abortForTimeout(`绝对上限(${Math.round(maxTimeoutMs / 1000)}s)`);
    }, maxTimeoutMs);

    const noteActivity = () => {
      if (settled) return;
      armIdleTimer();
      try {
        onActivity?.();
      } catch {
        /* ignore */
      }
    };

    child.stdout?.on("data", (d: Buffer) => {
      out += d.toString("utf8");
      noteActivity();
    });
    child.stderr?.on("data", (d: Buffer) => {
      err += d.toString("utf8");
      noteActivity();
    });
    child.on("error", (e) => {
      finish(`[agent-error] ${e.message}`);
    });
    child.on("close", (code) => {
      const raw = [out, err].filter(Boolean).join("\n").trim();
      const sessionId = extractCursorChatId(raw) ?? resumeChatId;
      const text = extractCodexLastMessage(raw, outFile);
      if (code !== 0 && !text) {
        finish(`[agent-error] codex exited ${code}`, sessionId);
        return;
      }
      if (code !== 0) {
        finish(`[agent-error] exit=${code}\n${text}`, sessionId);
        return;
      }
      finish(text || "Codex 已执行完成（无文本输出）", sessionId);
    });
  });
}

function notifyToast(message: string) {
  if (process.platform !== "win32") return;
  const safe = message.replace(/'/g, "''");
  const ps = `
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$n = New-Object System.Windows.Forms.NotifyIcon
$n.Icon = [System.Drawing.SystemIcons]::Information
$n.Visible = $true
$n.BalloonTipTitle = 'CodeAssist'
$n.BalloonTipText = '${safe}'
$n.ShowBalloonTip(5000)
Start-Sleep -Seconds 6
$n.Dispose()
`;
  try {
    spawn(
      "powershell.exe",
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps],
      { detached: true, stdio: "ignore", windowsHide: true },
    ).unref();
  } catch {
    /* ignore */
  }
}
