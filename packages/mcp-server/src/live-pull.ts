import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { WebSocket } from "ws";
import type { PromptDelivery } from "@codeassist/shared";
import type { ApiClient } from "./api-client.js";

type Options = {
  serverUrl: string;
  token: string;
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
      const projectId = opts.getProjectId();
      ws?.send(
        JSON.stringify({
          type: "subscribe",
          ...(projectId ? { projectIds: [projectId] } : {}),
        }),
      );
      // 重连后把积压的 queued 排空
      void drainQueue();
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

    ws.on("error", () => {
      /* close retries */
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
        };
      };
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
        console.error(
          `[codeassist-mcp] 串行执行手机指令 (${prompts.length}) → 完成后自动接下一条`,
        );
        notifyToast(`CodeAssist：正在 Cursor 执行手机指令`);
        focusCursorWorkspace(opts.getWorkspace());

        for (const p of prompts) {
          try {
            await api.ackPrompt(p.id);
          } catch {
            /* may already be running */
          }
        }

        const chatSessionId = prompts.find((p) => p.chatSessionId)?.chatSessionId;

        await api
          .syncSessionContext({
            projectId,
            chatSessionId,
            summary: `正在执行手机指令：${prompts.map((p) => p.content).join(" | ").slice(0, 200)}`,
            currentStep: "Cursor Agent 执行中",
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

        const agentResult = await runCursorAgent(
          opts.getWorkspace(),
          enrichedContents,
          prompts.map((p) => p.id),
          resumeChatId,
        );

        if (chatSessionId && agentResult.cursorChatId) {
          await api
            .updateChatSession(chatSessionId, {
              cursorChatId: agentResult.cursorChatId,
            })
            .catch(() => undefined);
        }

        const resultText = agentResult.text;
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
  return () => {
    closed = true;
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
    for (const key of ["session_id", "chatId", "chat_id", "conversation_id"]) {
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

    const timeoutMs = Number(
      process.env.CODEASSIST_AGENT_TIMEOUT_MS || 15 * 60 * 1000,
    );

    console.error(
      `[codeassist-mcp] Cursor Agent 执行中(无黑框): ${launch.label}`,
    );
    let out = "";
    let err = "";
    let settled = false;
    const finish = (text: string, cursorChatId?: string) => {
      if (settled) return;
      settled = true;
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

    const timer = setTimeout(() => {
      try {
        child.kill();
      } catch {
        /* ignore */
      }
      const partial = [out, err].filter(Boolean).join("\n").trim();
      finish(
        `[agent-error] 执行超时(${Math.round(timeoutMs / 1000)}s)\n${partial || "(无输出)"}`,
        extractCursorChatId(partial),
      );
    }, timeoutMs);

    child.stdout?.on("data", (d: Buffer) => {
      out += d.toString("utf8");
    });
    child.stderr?.on("data", (d: Buffer) => {
      err += d.toString("utf8");
    });
    child.on("error", (e) => {
      clearTimeout(timer);
      finish(`[agent-error] ${e.message}`);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
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
