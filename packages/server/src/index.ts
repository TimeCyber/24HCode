import fs from "node:fs";
import path from "node:path";
import Fastify from "fastify";
import cors from "@fastify/cors";
import {
  CompletePromptRequestSchema,
  CreateChatSessionRequestSchema,
  CreateFileTransferRequestSchema,
  CreatePromptRequestSchema,
  CreateTaskRequestSchema,
  OpenWorkspaceRequestSchema,
  RegisterProjectRequestSchema,
  SubmitDecisionRequestSchema,
  SyncSessionContextRequestSchema,
  UpdateChatSessionRequestSchema,
} from "@codeassist/shared";
import { createAuth } from "./auth.js";
import { openDb } from "./db.js";
import { loadEnvFile } from "./load-env.js";
import { Store } from "./store.js";
import { WsHub } from "./ws-hub.js";

loadEnvFile();

const PORT = Number(process.env.PORT ?? 8787);
const HOST = process.env.HOST ?? "0.0.0.0";
const ACCESS_TOKEN = process.env.ACCESS_TOKEN ?? "codeassist-dev-token";
const DATA_DIR = process.env.DATA_DIR ?? path.join(process.cwd(), "data");
const DB_PATH = process.env.DB_PATH ?? path.join(DATA_DIR, "codeassist.db");
const FILES_DIR = process.env.FILES_DIR ?? path.join(DATA_DIR, "files");
/** 无心跳超过此时长才标离线（默认 10 分钟；过短会导致手机经常闪离线） */
const OFFLINE_MS = Number(process.env.OFFLINE_MS ?? 10 * 60 * 1000);
/**
 * 指令卡在 running/delivered 且长时间无心跳则自动失败。
 * 默认 50 分钟：对齐 Agent 绝对上限，避免正常长任务被服务端误杀。
 */
const PROMPT_STALE_MS = Number(
  process.env.PROMPT_STALE_MS ?? 50 * 60 * 1000,
);
fs.mkdirSync(FILES_DIR, { recursive: true });

const auth = createAuth(ACCESS_TOKEN);
const db = openDb(DB_PATH);
const store = new Store(db);
const hub = new WsHub();
const mergedDupes = store.dedupeProjectsByWorkspace();
if (mergedDupes > 0) {
  console.log(
    `[codeassist-server] merged ${mergedDupes} duplicate project(s) (path case variants)`,
  );
}

// 文件以 Base64 JSON 上传，100MB 原文约 133MB，body 放宽到 150MB
const app = Fastify({
  logger: true,
  bodyLimit: 150 * 1024 * 1024,
});
await app.register(cors, { origin: true });

// DELETE/GET/心跳 POST 若带了 Content-Type 但无 body，或缺少 Content-Type，放宽解析，避免 400/415
const parseLooseBody = (
  body: string | Buffer,
  done: (err: Error | null, body?: unknown) => void,
) => {
  try {
    const raw = typeof body === "string" ? body : body.toString("utf8");
    if (!raw || !raw.trim()) {
      done(null, {});
      return;
    }
    const t = raw.trim();
    if (t.startsWith("{") || t.startsWith("[")) {
      done(null, JSON.parse(t));
      return;
    }
    done(null, {});
  } catch (err) {
    done(err as Error, undefined);
  }
};
app.addContentTypeParser(
  "application/json",
  { parseAs: "string" },
  (_req, body, done) => parseLooseBody(body, done),
);
app.addContentTypeParser(
  "*",
  { parseAs: "string" },
  (_req, body, done) => parseLooseBody(body, done),
);

app.addHook("onRequest", async (req, reply) => {
  if (req.url.startsWith("/health")) return;
  const token = auth.extractToken(
    req.headers.authorization,
    (req.query as { token?: string }).token,
  );
  if (!auth.isValid(token)) {
    return reply.code(401).send({ error: "unauthorized" });
  }
});

app.get("/health", async () => ({ ok: true }));

app.post("/api/projects/register", async (req, reply) => {
  const parsed = RegisterProjectRequestSchema.safeParse(req.body);
  if (!parsed.success) {
    return reply.code(400).send({ error: parsed.error.flatten() });
  }
  const project = store.registerProject(parsed.data);
  hub.broadcast("project.online", project, project.id);
  return project;
});

app.post("/api/projects/:id/heartbeat", async (req, reply) => {
  const { id } = req.params as { id: string };
  const before = store.getProject(id);
  const project = store.heartbeat(id);
  if (!project) return reply.code(404).send({ error: "project not found" });
  // 仅在「离线→在线」时广播，避免每几秒刷一次导致客户端抖动
  if (!before?.online) {
    hub.broadcast("project.online", project, project.id);
  }
  return project;
});

app.get("/api/projects", async () => store.listProjects());

/** 手机：请求 PC 端打开指定工作区（由在线 MCP/桥接认领执行） */
app.post("/api/projects/open", async (req, reply) => {
  const parsed = OpenWorkspaceRequestSchema.safeParse(req.body);
  if (!parsed.success) {
    return reply.code(400).send({ error: parsed.error.flatten() });
  }
  const data = { ...parsed.data };
  if (!data.viaProjectId) {
    const via = store.findOnlineProjectForIde(data.ide);
    if (via) data.viaProjectId = via.id;
  }
  if (data.viaProjectId && !store.getProject(data.viaProjectId)) {
    return reply.code(404).send({ error: "via project not found" });
  }
  const onlineAny = store.listProjects().some((p) => p.online);
  if (!onlineAny) {
    return reply
      .code(409)
      .send({ error: "no online PC project; open Cursor/Codex MCP or bridge first" });
  }
  const cmd = store.enqueueOpenWorkspace(data);
  // 推给指定项目；无 via 时广播给全部在线 MCP
  hub.broadcast("project.open", cmd, cmd.viaProjectId);
  return cmd;
});

app.get("/api/projects/open/:id", async (req, reply) => {
  const { id } = req.params as { id: string };
  const cmd = store.getOpenWorkspace(id);
  if (!cmd) return reply.code(404).send({ error: "open command not found" });
  return cmd;
});

app.get("/api/mcp/open-workspace", async (req, reply) => {
  const projectId = String(
    (req.query as { projectId?: string }).projectId ?? "",
  ).trim();
  if (!projectId) {
    return reply.code(400).send({ error: "projectId required" });
  }
  const cmd = store.claimOpenWorkspace(projectId);
  return cmd ? [cmd] : [];
});

app.post("/api/mcp/open-workspace/:id/complete", async (req, reply) => {
  const { id } = req.params as { id: string };
  const body = (req.body ?? {}) as { status?: string; error?: string };
  const status = body.status === "failed" ? "failed" : "done";
  const cmd = store.completeOpenWorkspace(id, status, body.error);
  if (!cmd) return reply.code(404).send({ error: "open command not found" });
  hub.broadcast("project.open", cmd, cmd.viaProjectId ?? cmd.claimedBy);
  return cmd;
});

app.post("/api/tasks", async (req, reply) => {
  const parsed = CreateTaskRequestSchema.safeParse(req.body);
  if (!parsed.success) {
    return reply.code(400).send({ error: parsed.error.flatten() });
  }
  if (!store.getProject(parsed.data.projectId)) {
    return reply.code(404).send({ error: "project not found" });
  }
  const task = store.createTask(parsed.data);
  hub.broadcast("task.created", task, task.projectId);
  return task;
});

app.get("/api/tasks", async (req) => {
  const status = (req.query as { status?: string }).status;
  return store.listTasks(status);
});

app.post("/api/tasks/:id/decision", async (req, reply) => {
  const { id } = req.params as { id: string };
  const parsed = SubmitDecisionRequestSchema.safeParse(req.body);
  if (!parsed.success) {
    return reply.code(400).send({ error: parsed.error.flatten() });
  }
  try {
    const result = store.submitDecision(
      id,
      parsed.data.action,
      parsed.data.comment,
    );
    if (!result) return reply.code(404).send({ error: "task not found" });
    hub.broadcast("task.updated", result.task, result.task.projectId);
    hub.broadcast("decision.created", result.decision, result.decision.projectId);
    return result;
  } catch (err) {
    return reply.code(400).send({
      error: err instanceof Error ? err.message : "bad request",
    });
  }
});

app.get("/api/mcp/decisions", async (req, reply) => {
  const projectId = (req.query as { projectId?: string }).projectId;
  if (!projectId) return reply.code(400).send({ error: "projectId required" });
  store.heartbeat(projectId);
  return store.pullDecisions(projectId);
});

app.get("/api/chat-sessions", async (req) => {
  const projectId = (req.query as { projectId?: string }).projectId;
  if (projectId) {
    store.pruneRedundantChatSessions(projectId);
  }
  return store.listChatSessions(projectId);
});

app.post("/api/chat-sessions", async (req, reply) => {
  const parsed = CreateChatSessionRequestSchema.safeParse(req.body);
  if (!parsed.success) {
    return reply.code(400).send({ error: parsed.error.flatten() });
  }
  if (!store.getProject(parsed.data.projectId)) {
    return reply.code(404).send({ error: "project not found" });
  }
  const session = store.createChatSession(parsed.data);
  hub.broadcast("chat.session.updated", session, session.projectId);
  return session;
});

app.patch("/api/chat-sessions/:id", async (req, reply) => {
  const { id } = req.params as { id: string };
  const parsed = UpdateChatSessionRequestSchema.safeParse(req.body ?? {});
  if (!parsed.success) {
    return reply.code(400).send({ error: parsed.error.flatten() });
  }
  const session = store.updateChatSession(id, parsed.data);
  if (!session) return reply.code(404).send({ error: "chat session not found" });
  hub.broadcast("chat.session.updated", session, session.projectId);
  return session;
});

app.delete("/api/chat-sessions/:id", async (req, reply) => {
  const { id } = req.params as { id: string };
  const existing = store.getChatSession(id);
  if (!existing) return reply.code(404).send({ error: "chat session not found" });
  const projectId = existing.projectId;
  const ok = store.deleteChatSession(id);
  if (!ok) return reply.code(404).send({ error: "chat session not found" });
  hub.broadcast(
    "chat.session.deleted",
    { id, projectId },
    projectId,
  );
  // 删光后保证仍有默认会话
  const left = store.listChatSessions(projectId);
  if (left.length === 0) {
    const created = store.createChatSession({ projectId, title: "默认会话" });
    hub.broadcast("chat.session.updated", created, projectId);
    return { ok: true, created };
  }
  return { ok: true };
});

app.post("/api/chat-sessions/prune", async (req, reply) => {
  const projectId = (req.body as { projectId?: string } | null)?.projectId;
  if (!projectId) return reply.code(400).send({ error: "projectId required" });
  const removed = store.pruneRedundantChatSessions(projectId);
  return { ok: true, removed, sessions: store.listChatSessions(projectId) };
});

app.get("/api/chat-sessions/:id", async (req, reply) => {
  const { id } = req.params as { id: string };
  const session = store.getChatSession(id);
  if (!session) return reply.code(404).send({ error: "chat session not found" });
  return session;
});

app.get("/api/chat-sessions/:id/messages", async (req, reply) => {
  const { id } = req.params as { id: string };
  const session = store.getChatSession(id);
  if (!session) return reply.code(404).send({ error: "chat session not found" });
  return store.listPrompts({ chatSessionId: id });
});

app.post("/api/prompts", async (req, reply) => {
  const parsed = CreatePromptRequestSchema.safeParse(req.body);
  if (!parsed.success) {
    return reply.code(400).send({ error: parsed.error.flatten() });
  }
  try {
    const { prompt, deliveries } = store.createPrompt(parsed.data);
    for (const d of deliveries) {
      hub.broadcast("prompt.updated", d, d.projectId);
    }
    if (prompt.chatSessionId) {
      const session = store.getChatSession(prompt.chatSessionId);
      if (session) {
        hub.broadcast("chat.session.updated", session, session.projectId);
      }
    }
    return { prompt, deliveries };
  } catch (err) {
    return reply.code(400).send({
      error: err instanceof Error ? err.message : "bad request",
    });
  }
});

app.get("/api/prompts", async (req) => {
  const q = req.query as { projectId?: string; chatSessionId?: string };
  return store.listPrompts({
    projectId: q.projectId,
    chatSessionId: q.chatSessionId,
  });
});

app.get("/api/mcp/prompts", async (req, reply) => {
  const projectId = (req.query as { projectId?: string }).projectId;
  if (!projectId) return reply.code(400).send({ error: "projectId required" });
  store.heartbeat(projectId);
  const deliveries = store.pullPrompts(projectId);
  for (const d of deliveries) {
    hub.broadcast("prompt.updated", d, d.projectId);
  }
  return deliveries;
});

app.post("/api/mcp/prompts/:id/ack", async (req, reply) => {
  const { id } = req.params as { id: string };
  const delivery = store.ackPrompt(id);
  if (!delivery) return reply.code(404).send({ error: "prompt not found" });
  hub.broadcast("prompt.updated", delivery, delivery.projectId);
  return delivery;
});

app.post("/api/mcp/prompts/:id/complete", async (req, reply) => {
  const { id } = req.params as { id: string };
  const parsed = CompletePromptRequestSchema.safeParse(req.body ?? {});
  if (!parsed.success) {
    return reply.code(400).send({ error: parsed.error.flatten() });
  }
  const delivery = store.completePrompt(
    id,
    parsed.data.status,
    parsed.data.result,
  );
  if (!delivery) return reply.code(404).send({ error: "prompt not found" });
  hub.broadcast("prompt.updated", delivery, delivery.projectId);
  return delivery;
});

app.post("/api/mcp/session-context", async (req, reply) => {
  const parsed = SyncSessionContextRequestSchema.safeParse(req.body);
  if (!parsed.success) {
    return reply.code(400).send({ error: parsed.error.flatten() });
  }
  if (!store.getProject(parsed.data.projectId)) {
    return reply.code(404).send({ error: "project not found" });
  }
  const ctx = store.upsertSessionContext(parsed.data);
  hub.broadcast("session.updated", ctx, ctx.projectId);
  if (parsed.data.chatSessionId) {
    const chat = store.getChatSession(parsed.data.chatSessionId);
    if (chat) {
      hub.broadcast("chat.session.updated", chat, chat.projectId);
    }
  }
  return ctx;
});

app.post("/api/files", async (req, reply) => {
  const parsed = CreateFileTransferRequestSchema.safeParse(req.body);
  if (!parsed.success) {
    return reply.code(400).send({ error: parsed.error.flatten() });
  }
  try {
    const created = store.createFileTransfer(parsed.data, FILES_DIR);
    hub.broadcast("file.created", created.file, created.file.projectId);
    hub.broadcast("prompt.updated", created.delivery, created.delivery.projectId);
    if (created.file.chatSessionId) {
      const session = store.getChatSession(created.file.chatSessionId);
      if (session) {
        hub.broadcast("chat.session.updated", session, session.projectId);
      }
    }
    return created;
  } catch (err) {
    return reply.code(400).send({
      error: err instanceof Error ? err.message : "bad request",
    });
  }
});

app.get("/api/files/:id", async (req, reply) => {
  const { id } = req.params as { id: string };
  const file = store.getFileTransfer(id);
  if (!file) return reply.code(404).send({ error: "file not found" });
  return file;
});

app.get("/api/files/:id/download", async (req, reply) => {
  const { id } = req.params as { id: string };
  const stored = store.getFileStoragePath(id, FILES_DIR);
  if (!stored) return reply.code(404).send({ error: "file not found" });
  const data = fs.readFileSync(stored.absolutePath);
  const encodedName = encodeURIComponent(stored.file.fileName);
  return reply
    .header(
      "Content-Type",
      stored.file.mimeType || "application/octet-stream",
    )
    .header(
      "Content-Disposition",
      `attachment; filename*=UTF-8''${encodedName}`,
    )
    .header("Content-Length", String(data.length))
    .send(data);
});

app.get("/api/session-contexts", async () => store.listSessionContexts());

app.get("/api/session-contexts/:projectId", async (req, reply) => {
  const { projectId } = req.params as { projectId: string };
  const ctx = store.getSessionContext(projectId);
  if (!ctx) return reply.code(404).send({ error: "session context not found" });
  return ctx;
});

await app.listen({ port: PORT, host: HOST });
const server = app.server;
hub.attach(server, (token) => auth.isValid(token));

setInterval(() => {
  const offline = store.markOfflineStale(OFFLINE_MS);
  for (const p of offline) {
    hub.broadcast("project.offline", { ...p, online: false }, p.id);
  }
}, Math.min(OFFLINE_MS, 10_000));

setInterval(() => {
  const stale = store.failStalePromptDeliveries(
    PROMPT_STALE_MS,
    `执行超时（超过 ${Math.round(PROMPT_STALE_MS / 1000)} 秒仍无结果），已自动失败。请重新发送指令。`,
  );
  for (const d of stale) {
    hub.broadcast("prompt.updated", d, d.projectId);
    app.log.warn(
      { deliveryId: d.id, projectId: d.projectId },
      "stale prompt auto-failed",
    );
  }
}, 30_000);

app.log.info(
  `CodeAssist server listening on http://${HOST}:${PORT} (token configured, promptStaleMs=${PROMPT_STALE_MS})`,
);
