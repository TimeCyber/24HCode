import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { nanoid } from "nanoid";
import {
  type ChatSession,
  type CreateChatSessionRequest,
  type CreateFileTransferRequest,
  type CreatePromptRequest,
  type CreateTaskRequest,
  type Decision,
  type DecisionAction,
  type FileTransfer,
  type Ide,
  type OpenWorkspaceCommand,
  type OpenWorkspaceRequest,
  type Project,
  type PromptDelivery,
  type PromptJob,
  type RegisterProjectRequest,
  type SessionContext,
  type SyncSessionContextRequest,
  type TaskEvent,
  type TaskStatus,
  type UpdateChatSessionRequest,
  nowIso,
} from "@codeassist/shared";
import type { Db } from "./db.js";

const MAX_FILE_BYTES = 100 * 1024 * 1024;

function normalizeWorkspacePath(workspacePath: string): string {
  // Windows 路径大小写 / 斜杠不同会产生重复项目，统一成小写 + /
  const normalized = workspacePath
    .trim()
    .replace(/\\/g, "/")
    .replace(/\/+$/, "");
  return process.platform === "win32" ? normalized.toLowerCase() : normalized;
}

/** 入库展示路径：Windows 用反斜杠小写，保证列表一致 */
function canonicalStoredPath(workspacePath: string): string {
  const key = normalizeWorkspacePath(workspacePath);
  return process.platform === "win32" ? key.replace(/\//g, "\\") : key;
}

function projectIdFrom(workspacePath: string, ide: Ide, explicitId?: string): string {
  if (explicitId) return explicitId;
  const key = normalizeWorkspacePath(workspacePath);
  const hash = createHash("sha1")
    .update(`${ide}:${key}`)
    .digest("hex")
    .slice(0, 16);
  return `${ide}-${hash}`;
}

export class Store {
  /** 手机 → PC 打开工作区：内存队列（认领后由 MCP/桥接执行） */
  private openWorkspaceCommands: OpenWorkspaceCommand[] = [];

  constructor(private readonly db: Db) {}

  enqueueOpenWorkspace(input: OpenWorkspaceRequest): OpenWorkspaceCommand {
    const now = nowIso();
    const cmd: OpenWorkspaceCommand = {
      id: nanoid(),
      workspacePath: input.workspacePath.trim(),
      ide: input.ide,
      viaProjectId: input.viaProjectId,
      status: "queued",
      createdAt: now,
      updatedAt: now,
    };
    this.openWorkspaceCommands.unshift(cmd);
    // 只保留最近 50 条
    if (this.openWorkspaceCommands.length > 50) {
      this.openWorkspaceCommands.length = 50;
    }
    return cmd;
  }

  /**
   * 在线 MCP/桥接认领打开任务。
   * 匹配：queued，且 viaProjectId 为空或等于本 projectId；ide 与本项目一致（若能查到项目）。
   */
  claimOpenWorkspace(projectId: string): OpenWorkspaceCommand | null {
    const project = this.getProject(projectId);
    const now = nowIso();
    for (const cmd of this.openWorkspaceCommands) {
      if (cmd.status !== "queued") continue;
      if (cmd.viaProjectId && cmd.viaProjectId !== projectId) continue;
      if (project && cmd.ide !== project.ide) continue;
      cmd.status = "claimed";
      cmd.claimedBy = projectId;
      cmd.updatedAt = now;
      return { ...cmd };
    }
    return null;
  }

  completeOpenWorkspace(
    id: string,
    status: "done" | "failed",
    error?: string,
  ): OpenWorkspaceCommand | null {
    const cmd = this.openWorkspaceCommands.find((c) => c.id === id);
    if (!cmd) return null;
    cmd.status = status;
    cmd.error = error;
    cmd.updatedAt = nowIso();
    return { ...cmd };
  }

  getOpenWorkspace(id: string): OpenWorkspaceCommand | null {
    const cmd = this.openWorkspaceCommands.find((c) => c.id === id);
    return cmd ? { ...cmd } : null;
  }

  registerProject(input: RegisterProjectRequest): Project {
    const id = projectIdFrom(input.workspacePath, input.ide, input.id);
    const storedPath = canonicalStoredPath(input.workspacePath);
    const now = nowIso();

    // 合并历史因路径大小写/盘符大小写产生的重复项目
    this.mergeWorkspaceDuplicates(input.ide, storedPath, id);

    const existing = this.db
      .prepare("SELECT id FROM projects WHERE id = ?")
      .get(id) as { id: string } | undefined;

    if (existing) {
      this.db
        .prepare(
          `UPDATE projects SET name = ?, workspace_path = ?, ide = ?, last_seen_at = ?, online = 1 WHERE id = ?`,
        )
        .run(input.name, storedPath, input.ide, now, id);
    } else {
      this.db
        .prepare(
          `INSERT INTO projects (id, name, workspace_path, ide, last_seen_at, online)
           VALUES (?, ?, ?, ?, ?, 1)`,
        )
        .run(id, input.name, storedPath, input.ide, now);
    }
    return this.getProject(id)!;
  }

  /** 启动时清理：同一 IDE+规范化路径只保留一个项目 */
  dedupeProjectsByWorkspace(): number {
    const rows = this.db
      .prepare(
        `SELECT id, name, workspace_path, ide, last_seen_at, online
         FROM projects`,
      )
      .all() as Array<Record<string, unknown>>;

    const groups = new Map<string, Array<Record<string, unknown>>>();
    for (const row of rows) {
      const ide = String(row.ide);
      const key = `${ide}::${normalizeWorkspacePath(String(row.workspace_path))}`;
      const list = groups.get(key) ?? [];
      list.push(row);
      groups.set(key, list);
    }

    let removed = 0;
    for (const [, list] of groups) {
      if (list.length < 2) continue;
      const ide = String(list[0].ide) as Ide;
      const pathSample = String(list[0].workspace_path);
      const canonicalId = projectIdFrom(pathSample, ide);
      const keep =
        list.find((r) => String(r.id) === canonicalId) ??
        [...list].sort((a, b) =>
          String(b.last_seen_at).localeCompare(String(a.last_seen_at)),
        )[0];
      const keepId = String(keep.id);
      const dupIds = list
        .map((r) => String(r.id))
        .filter((id) => id !== keepId);
      this.mergeProjectIdsInto(keepId, dupIds);
      // 统一路径写法
      this.db
        .prepare(`UPDATE projects SET workspace_path = ? WHERE id = ?`)
        .run(canonicalStoredPath(pathSample), keepId);
      removed += dupIds.length;
    }
    return removed;
  }

  private mergeWorkspaceDuplicates(
    ide: Ide,
    workspacePath: string,
    canonicalId: string,
  ): void {
    const key = normalizeWorkspacePath(workspacePath);
    const rows = this.db
      .prepare(
        `SELECT id, workspace_path FROM projects WHERE ide = ?`,
      )
      .all(ide) as Array<{ id: string; workspace_path: string }>;
    const dupIds = rows
      .filter(
        (r) =>
          r.id !== canonicalId &&
          normalizeWorkspacePath(r.workspace_path) === key,
      )
      .map((r) => r.id);
    if (dupIds.length) this.mergeProjectIdsInto(canonicalId, dupIds);
  }

  private mergeProjectIdsInto(canonicalId: string, duplicateIds: string[]): void {
    for (const oldId of duplicateIds) {
      if (oldId === canonicalId) continue;
      this.db
        .prepare(`UPDATE tasks SET project_id = ? WHERE project_id = ?`)
        .run(canonicalId, oldId);
      this.db
        .prepare(`UPDATE decisions SET project_id = ? WHERE project_id = ?`)
        .run(canonicalId, oldId);
      this.db
        .prepare(
          `UPDATE prompt_deliveries SET project_id = ? WHERE project_id = ?`,
        )
        .run(canonicalId, oldId);
      this.db
        .prepare(`UPDATE chat_sessions SET project_id = ? WHERE project_id = ?`)
        .run(canonicalId, oldId);
      this.db
        .prepare(`UPDATE file_transfers SET project_id = ? WHERE project_id = ?`)
        .run(canonicalId, oldId);

      const hasCanonicalCtx = this.db
        .prepare(`SELECT id FROM session_contexts WHERE project_id = ?`)
        .get(canonicalId) as { id: string } | undefined;
      if (hasCanonicalCtx) {
        this.db
          .prepare(`DELETE FROM session_contexts WHERE project_id = ?`)
          .run(oldId);
      } else {
        this.db
          .prepare(
            `UPDATE session_contexts SET project_id = ? WHERE project_id = ?`,
          )
          .run(canonicalId, oldId);
      }

      this.db.prepare(`DELETE FROM projects WHERE id = ?`).run(oldId);
    }
    // 合并项目后，多个「默认会话」会挤到同一项目，清理空的重复会话
    this.pruneRedundantChatSessions(canonicalId);
  }

  /** 删除空的同名重复会话（保留最近更新的一条）。有消息的会话一律保留。 */
  pruneRedundantChatSessions(projectId: string): number {
    const sessions = this.listChatSessions(projectId);
    if (sessions.length <= 1) return 0;
    const byTitle = new Map<string, ChatSession[]>();
    for (const s of sessions) {
      const key = s.title.trim() || "(untitled)";
      const arr = byTitle.get(key) ?? [];
      arr.push(s);
      byTitle.set(key, arr);
    }
    let removed = 0;
    for (const group of byTitle.values()) {
      if (group.length <= 1) continue;
      const empty: ChatSession[] = [];
      const nonempty: ChatSession[] = [];
      for (const s of group) {
        const row = this.db
          .prepare(
            `SELECT COUNT(1) AS c FROM prompts WHERE chat_session_id = ?`,
          )
          .get(s.id) as { c: number };
        if (Number(row.c) > 0) nonempty.push(s);
        else empty.push(s);
      }
      // 同名且都无消息：只留最新一条
      if (empty.length > 1 && nonempty.length === 0) {
        empty.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
        for (const s of empty.slice(1)) {
          if (this.deleteChatSession(s.id)) removed += 1;
        }
      } else if (empty.length > 0 && nonempty.length > 0) {
        // 已有带消息的同名会话时，删掉空壳
        for (const s of empty) {
          if (this.deleteChatSession(s.id)) removed += 1;
        }
      } else if (empty.length > 1) {
        empty.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
        for (const s of empty.slice(1)) {
          if (this.deleteChatSession(s.id)) removed += 1;
        }
      }
    }
    return removed;
  }

  deleteChatSession(id: string): boolean {
    const existing = this.getChatSession(id);
    if (!existing) return false;
    this.db
      .prepare(`DELETE FROM prompt_deliveries WHERE chat_session_id = ?`)
      .run(id);
    this.db
      .prepare(
        `DELETE FROM prompt_deliveries WHERE prompt_id IN
         (SELECT id FROM prompts WHERE chat_session_id = ?)`,
      )
      .run(id);
    this.db.prepare(`DELETE FROM prompts WHERE chat_session_id = ?`).run(id);
    this.db
      .prepare(
        `UPDATE file_transfers SET chat_session_id = NULL WHERE chat_session_id = ?`,
      )
      .run(id);
    this.db.prepare(`DELETE FROM chat_sessions WHERE id = ?`).run(id);
    return true;
  }

  heartbeat(projectId: string): Project | null {
    const now = nowIso();
    const result = this.db
      .prepare(
        `UPDATE projects SET last_seen_at = ?, online = 1 WHERE id = ?`,
      )
      .run(now, projectId);
    if (result.changes === 0) return null;
    return this.getProject(projectId);
  }

  markOfflineStale(maxAgeMs: number): Project[] {
    const cutoff = new Date(Date.now() - maxAgeMs).toISOString();
    const stale = this.db
      .prepare(
        `SELECT id, name, workspace_path, ide, last_seen_at, online
         FROM projects WHERE online = 1 AND last_seen_at < ?`,
      )
      .all(cutoff) as Array<Record<string, unknown>>;

    if (stale.length === 0) return [];
    this.db
      .prepare(`UPDATE projects SET online = 0 WHERE online = 1 AND last_seen_at < ?`)
      .run(cutoff);
    return stale.map(mapProject);
  }

  listProjects(): Project[] {
    const rows = this.db
      .prepare(
        `SELECT id, name, workspace_path, ide, last_seen_at, online
         FROM projects ORDER BY last_seen_at DESC`,
      )
      .all() as Array<Record<string, unknown>>;
    // 防御：即使库里仍有历史重复，列表也按规范化路径去重
    const seen = new Set<string>();
    const out: Project[] = [];
    for (const row of rows) {
      const p = mapProject(row);
      const key = `${p.ide}::${normalizeWorkspacePath(p.workspacePath)}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push(p);
    }
    return out;
  }

  getProject(id: string): Project | null {
    const row = this.db
      .prepare(
        `SELECT id, name, workspace_path, ide, last_seen_at, online
         FROM projects WHERE id = ?`,
      )
      .get(id) as Record<string, unknown> | undefined;
    return row ? mapProject(row) : null;
  }

  createTask(input: CreateTaskRequest): TaskEvent {
    const now = nowIso();
    const id = nanoid();
    const status: TaskStatus = input.requireDecision
      ? "awaiting_decision"
      : "acked";
    this.db
      .prepare(
        `INSERT INTO tasks
         (id, project_id, type, title, detail, status, require_decision, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        id,
        input.projectId,
        input.type,
        input.title,
        input.detail ?? "",
        status,
        input.requireDecision ? 1 : 0,
        now,
        now,
      );
    return this.getTask(id)!;
  }

  getTask(id: string): TaskEvent | null {
    const row = this.db
      .prepare(
        `SELECT id, project_id, type, title, detail, status, require_decision,
                decision_comment, created_at, updated_at
         FROM tasks WHERE id = ?`,
      )
      .get(id) as Record<string, unknown> | undefined;
    return row ? mapTask(row) : null;
  }

  listTasks(status?: string): TaskEvent[] {
    const rows = status
      ? (this.db
          .prepare(
            `SELECT id, project_id, type, title, detail, status, require_decision,
                    decision_comment, created_at, updated_at
             FROM tasks WHERE status = ? ORDER BY created_at DESC`,
          )
          .all(status) as Array<Record<string, unknown>>)
      : (this.db
          .prepare(
            `SELECT id, project_id, type, title, detail, status, require_decision,
                    decision_comment, created_at, updated_at
             FROM tasks ORDER BY created_at DESC LIMIT 200`,
          )
          .all() as Array<Record<string, unknown>>);
    return rows.map(mapTask);
  }

  submitDecision(
    taskId: string,
    action: DecisionAction,
    comment?: string,
  ): { task: TaskEvent; decision: Decision } | null {
    const task = this.getTask(taskId);
    if (!task) return null;
    if (task.status !== "awaiting_decision") {
      throw new Error("Task is not awaiting decision");
    }
    const now = nowIso();
    const status: TaskStatus = action === "approve" ? "approved" : "rejected";
    this.db
      .prepare(
        `UPDATE tasks SET status = ?, decision_comment = ?, updated_at = ? WHERE id = ?`,
      )
      .run(status, comment ?? null, now, taskId);

    const decisionId = nanoid();
    this.db
      .prepare(
        `INSERT INTO decisions (id, task_id, project_id, action, comment, created_at, consumed)
         VALUES (?, ?, ?, ?, ?, ?, 0)`,
      )
      .run(decisionId, taskId, task.projectId, action, comment ?? null, now);

    const decision: Decision = {
      taskId,
      projectId: task.projectId,
      action,
      comment,
      createdAt: now,
      consumed: false,
    };
    return { task: this.getTask(taskId)!, decision };
  }

  pullDecisions(projectId: string): Decision[] {
    const rows = this.db
      .prepare(
        `SELECT task_id, project_id, action, comment, created_at, consumed
         FROM decisions WHERE project_id = ? AND consumed = 0
         ORDER BY created_at ASC`,
      )
      .all(projectId) as Array<Record<string, unknown>>;

    this.db
      .prepare(
        `UPDATE decisions SET consumed = 1 WHERE project_id = ? AND consumed = 0`,
      )
      .run(projectId);

    return rows.map((row) => ({
      taskId: String(row.task_id),
      projectId: String(row.project_id),
      action: row.action as DecisionAction,
      comment: row.comment ? String(row.comment) : undefined,
      createdAt: String(row.created_at),
      consumed: false,
    }));
  }

  createChatSession(input: CreateChatSessionRequest): ChatSession {
    const now = nowIso();
    const id = nanoid();
    const title =
      input.title?.trim() ||
      `会话 ${new Date().toLocaleString("zh-CN", { hour12: false })}`;
    this.db
      .prepare(
        `INSERT INTO chat_sessions
         (id, project_id, title, cursor_chat_id, created_at, updated_at)
         VALUES (?, ?, ?, NULL, ?, ?)`,
      )
      .run(id, input.projectId, title, now, now);
    return this.getChatSession(id)!;
  }

  updateChatSession(
    id: string,
    input: UpdateChatSessionRequest,
  ): ChatSession | null {
    const existing = this.getChatSession(id);
    if (!existing) return null;
    const now = nowIso();
    const title = input.title?.trim() || existing.title;
    const cursorChatId =
      input.cursorChatId?.trim() || existing.cursorChatId || null;
    const contextSummary =
      input.contextSummary !== undefined
        ? input.contextSummary
        : existing.contextSummary ?? null;
    const contextStep =
      input.contextStep !== undefined
        ? input.contextStep
        : existing.contextStep ?? null;
    const contextStatus =
      input.contextStatus !== undefined
        ? input.contextStatus
        : existing.contextStatus ?? null;
    const contextExtra =
      input.contextExtra !== undefined
        ? input.contextExtra
        : existing.contextExtra ?? null;
    this.db
      .prepare(
        `UPDATE chat_sessions
         SET title = ?, cursor_chat_id = ?,
             context_summary = ?, context_step = ?, context_status = ?,
             context_extra = ?, updated_at = ?
         WHERE id = ?`,
      )
      .run(
        title,
        cursorChatId,
        contextSummary,
        contextStep,
        contextStatus,
        contextExtra,
        now,
        id,
      );
    return this.getChatSession(id);
  }

  touchChatSession(id: string): void {
    this.db
      .prepare(`UPDATE chat_sessions SET updated_at = ? WHERE id = ?`)
      .run(nowIso(), id);
  }

  getChatSession(id: string): ChatSession | null {
    const row = this.db
      .prepare(
        `SELECT id, project_id, title, cursor_chat_id,
                context_summary, context_step, context_status, context_extra,
                created_at, updated_at
         FROM chat_sessions WHERE id = ?`,
      )
      .get(id) as Record<string, unknown> | undefined;
    return row ? mapChatSession(row) : null;
  }

  listChatSessions(projectId?: string): ChatSession[] {
    const rows = (
      projectId
        ? this.db
            .prepare(
              `SELECT id, project_id, title, cursor_chat_id,
                      context_summary, context_step, context_status, context_extra,
                      created_at, updated_at
               FROM chat_sessions WHERE project_id = ?
               ORDER BY updated_at DESC`,
            )
            .all(projectId)
        : this.db
            .prepare(
              `SELECT id, project_id, title, cursor_chat_id,
                      context_summary, context_step, context_status, context_extra,
                      created_at, updated_at
               FROM chat_sessions ORDER BY updated_at DESC`,
            )
            .all()
    ) as Array<Record<string, unknown>>;
    // 按 id 去重（防御脏数据）
    const seen = new Set<string>();
    const out: ChatSession[] = [];
    for (const row of rows) {
      const s = mapChatSession(row);
      if (seen.has(s.id)) continue;
      seen.add(s.id);
      out.push(s);
    }
    return out;
  }

  ensureChatSession(projectId: string): ChatSession {
    const existing = this.listChatSessions(projectId);
    if (existing.length > 0) return existing[0]!;
    return this.createChatSession({ projectId, title: "默认会话" });
  }

  createPrompt(input: CreatePromptRequest): {
    prompt: PromptJob;
    deliveries: PromptDelivery[];
  } {
    const now = nowIso();
    const promptId = nanoid();

    let chatSessionId = input.chatSessionId;
    let projectIds = input.projectIds ? [...input.projectIds] : [];

    if (chatSessionId) {
      const session = this.getChatSession(chatSessionId);
      if (!session) {
        throw new Error("chat session not found");
      }
      projectIds = [session.projectId];
      this.touchChatSession(chatSessionId);
    } else if (input.projectId) {
      const session = this.ensureChatSession(input.projectId);
      chatSessionId = session.id;
      projectIds = [input.projectId];
    }

    if (projectIds.length === 0) {
      throw new Error("projectId(s) required");
    }

    this.db
      .prepare(
        `INSERT INTO prompts (id, content, status, created_at, updated_at, chat_session_id)
         VALUES (?, ?, 'queued', ?, ?, ?)`,
      )
      .run(promptId, input.content, now, now, chatSessionId ?? null);

    const deliveries: PromptDelivery[] = [];
    for (const projectId of projectIds) {
      const deliveryId = nanoid();
      const sid =
        chatSessionId ??
        this.ensureChatSession(projectId).id;
      this.db
        .prepare(
          `INSERT INTO prompt_deliveries
           (id, prompt_id, project_id, content, status, created_at, updated_at, chat_session_id)
           VALUES (?, ?, ?, ?, 'queued', ?, ?, ?)`,
        )
        .run(
          deliveryId,
          promptId,
          projectId,
          input.content,
          now,
          now,
          sid,
        );
      deliveries.push({
        id: deliveryId,
        promptId,
        projectId,
        chatSessionId: sid,
        content: input.content,
        status: "queued",
        createdAt: now,
        updatedAt: now,
      });
    }

    return {
      prompt: {
        id: promptId,
        projectIds,
        chatSessionId,
        content: input.content,
        status: "queued",
        createdAt: now,
        updatedAt: now,
      },
      deliveries,
    };
  }

  /** 默认一次只取 1 条，保证 Cursor 串行；取完后调用方可再拉下一条。 */
  pullPrompts(projectId: string, limit = 1): PromptDelivery[] {
    const safeLimit = Math.max(1, Math.min(50, Math.floor(limit) || 1));
    const rows = this.db
      .prepare(
        `SELECT id, prompt_id, project_id, content, status, created_at, updated_at, result, chat_session_id
         FROM prompt_deliveries
         WHERE project_id = ? AND status = 'queued'
         ORDER BY created_at ASC
         LIMIT ?`,
      )
      .all(projectId, safeLimit) as Array<Record<string, unknown>>;

    const now = nowIso();
    const deliveries = rows.map((row) => this.enrichDelivery(mapDelivery(row)));
    for (const d of deliveries) {
      this.db
        .prepare(
          `UPDATE prompt_deliveries SET status = 'delivered', updated_at = ? WHERE id = ?`,
        )
        .run(now, d.id);
      this.db
        .prepare(`UPDATE prompts SET status = 'delivered', updated_at = ? WHERE id = ?`)
        .run(now, d.promptId);
      d.status = "delivered";
      d.updatedAt = now;
    }
    return deliveries;
  }

  ackPrompt(deliveryId: string): PromptDelivery | null {
    const now = nowIso();
    const existing = this.getDelivery(deliveryId);
    if (!existing) return null;
    this.db
      .prepare(
        `UPDATE prompt_deliveries SET status = 'running', updated_at = ? WHERE id = ?`,
      )
      .run(now, deliveryId);
    this.db
      .prepare(`UPDATE prompts SET status = 'running', updated_at = ? WHERE id = ?`)
      .run(now, existing.promptId);
    return this.getDelivery(deliveryId);
  }

  completePrompt(
    deliveryId: string,
    status: "done" | "failed",
    result?: string,
  ): PromptDelivery | null {
    const now = nowIso();
    const existing = this.getDelivery(deliveryId);
    if (!existing) return null;
    this.db
      .prepare(
        `UPDATE prompt_deliveries SET status = ?, result = ?, updated_at = ? WHERE id = ?`,
      )
      .run(status, result ?? null, now, deliveryId);
    this.db
      .prepare(
        `UPDATE prompts SET status = ?, result = ?, updated_at = ? WHERE id = ?`,
      )
      .run(status, result ?? null, now, existing.promptId);
    return this.getDelivery(deliveryId);
  }

  /** 清理长时间卡在 running/delivered 的指令，避免手机一直转圈且后续指令排不上 */
  failStalePromptDeliveries(
    maxAgeMs: number,
    resultMessage: string,
  ): PromptDelivery[] {
    const cutoff = new Date(Date.now() - maxAgeMs).toISOString();
    const rows = this.db
      .prepare(
        `SELECT id FROM prompt_deliveries
         WHERE status IN ('running', 'delivered') AND updated_at < ?
         ORDER BY updated_at ASC
         LIMIT 50`,
      )
      .all(cutoff) as Array<{ id: string }>;
    const out: PromptDelivery[] = [];
    for (const row of rows) {
      const d = this.completePrompt(row.id, "failed", resultMessage);
      if (d) out.push(d);
    }
    return out;
  }

  getDelivery(id: string): PromptDelivery | null {
    const row = this.db
      .prepare(
        `SELECT id, prompt_id, project_id, content, status, created_at, updated_at, result, chat_session_id
         FROM prompt_deliveries WHERE id = ?`,
      )
      .get(id) as Record<string, unknown> | undefined;
    return row ? this.enrichDelivery(mapDelivery(row)) : null;
  }

  private enrichDelivery(delivery: PromptDelivery): PromptDelivery {
    const promptRow = this.db
      .prepare(`SELECT attachment_id FROM prompts WHERE id = ?`)
      .get(delivery.promptId) as { attachment_id?: string } | undefined;
    const attachmentId = promptRow?.attachment_id
      ? String(promptRow.attachment_id)
      : null;
    if (!attachmentId) return delivery;
    const file = this.getFileTransfer(attachmentId);
    if (!file) return delivery;
    return {
      ...delivery,
      attachment: {
        id: file.id,
        fileName: file.fileName,
        mimeType: file.mimeType,
        size: file.size,
        direction: file.direction,
      },
    };
  }

  listPrompts(opts?: {
    projectId?: string;
    chatSessionId?: string;
  }): PromptJob[] {
    let prompts: Array<Record<string, unknown>>;
    if (opts?.chatSessionId) {
      prompts = this.db
        .prepare(
          `SELECT id, content, status, created_at, updated_at, result, chat_session_id, attachment_id
           FROM prompts WHERE chat_session_id = ?
           ORDER BY created_at ASC LIMIT 500`,
        )
        .all(opts.chatSessionId) as Array<Record<string, unknown>>;
    } else if (opts?.projectId) {
      prompts = this.db
        .prepare(
          `SELECT DISTINCT p.id, p.content, p.status, p.created_at, p.updated_at, p.result, p.chat_session_id, p.attachment_id
           FROM prompts p
           JOIN prompt_deliveries d ON d.prompt_id = p.id
           WHERE d.project_id = ?
           ORDER BY p.created_at DESC LIMIT 200`,
        )
        .all(opts.projectId) as Array<Record<string, unknown>>;
    } else {
      prompts = this.db
        .prepare(
          `SELECT id, content, status, created_at, updated_at, result, chat_session_id, attachment_id FROM prompts
           ORDER BY created_at DESC LIMIT 100`,
        )
        .all() as Array<Record<string, unknown>>;
    }

    return prompts.map((p) => this.mapPromptJob(p));
  }

  private mapPromptJob(p: Record<string, unknown>): PromptJob {
    const projectIds = (
      this.db
        .prepare(`SELECT project_id FROM prompt_deliveries WHERE prompt_id = ?`)
        .all(String(p.id)) as Array<{ project_id: string }>
    ).map((r) => r.project_id);
    const attachmentId = p.attachment_id ? String(p.attachment_id) : null;
    let attachment: PromptJob["attachment"];
    if (attachmentId) {
      const file = this.getFileTransfer(attachmentId);
      if (file) {
        attachment = {
          id: file.id,
          fileName: file.fileName,
          mimeType: file.mimeType,
          size: file.size,
          direction: file.direction,
        };
      }
    }
    return {
      id: String(p.id),
      projectIds,
      chatSessionId: p.chat_session_id
        ? String(p.chat_session_id)
        : undefined,
      content: String(p.content),
      status: p.status as PromptJob["status"],
      createdAt: String(p.created_at),
      updatedAt: String(p.updated_at),
      result: p.result ? String(p.result) : undefined,
      attachment,
    };
  }

  createFileTransfer(
    input: CreateFileTransferRequest,
    filesDir: string,
  ): { file: FileTransfer; prompt: PromptJob; delivery: PromptDelivery } {
    if (!this.getProject(input.projectId)) {
      throw new Error("project not found");
    }
    let chatSessionId = input.chatSessionId;
    if (chatSessionId) {
      const session = this.getChatSession(chatSessionId);
      if (!session) throw new Error("chat session not found");
      if (session.projectId !== input.projectId) {
        throw new Error("chat session project mismatch");
      }
    } else {
      chatSessionId = this.ensureChatSession(input.projectId).id;
    }

    let buffer: Buffer;
    try {
      buffer = Buffer.from(input.contentBase64, "base64");
    } catch {
      throw new Error("invalid base64 content");
    }
    if (!buffer.length) throw new Error("empty file");
    if (buffer.length > MAX_FILE_BYTES) {
      throw new Error(`file too large (max ${MAX_FILE_BYTES} bytes)`);
    }

    const direction = input.direction ?? "to_client";
    const fileName = path.basename(input.fileName.trim()) || "file.bin";
    const fileId = nanoid();
    const storageName = `${fileId}.bin`;
    fs.mkdirSync(filesDir, { recursive: true });
    fs.writeFileSync(path.join(filesDir, storageName), buffer);

    const now = nowIso();
    const promptId = nanoid();
    const deliveryId = nanoid();
    const sizeLabel =
      buffer.length >= 1024 * 1024
        ? `${(buffer.length / (1024 * 1024)).toFixed(1)} MB`
        : `${Math.max(1, Math.round(buffer.length / 1024))} KB`;

    const toAgent = direction === "to_agent";
    const caption = input.message?.trim();
    const content = toAgent
      ? caption && caption.length > 0
        ? caption
        : `用户从手机发送了图片「${fileName}」，请查看图片并根据内容协助处理。`
      : `[附件] ${fileName}`;
    const promptStatus = toAgent ? "queued" : "done";
    const result = toAgent
      ? null
      : `已推送文件到手机：${fileName}（${sizeLabel}）`;

    this.db
      .prepare(
        `INSERT INTO file_transfers
         (id, project_id, chat_session_id, file_name, mime_type, size, storage_name, prompt_id, created_at, direction)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        fileId,
        input.projectId,
        chatSessionId,
        fileName,
        input.mimeType ?? null,
        buffer.length,
        storageName,
        promptId,
        now,
        direction,
      );

    this.db
      .prepare(
        `INSERT INTO prompts
         (id, content, status, created_at, updated_at, result, chat_session_id, attachment_id)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        promptId,
        content,
        promptStatus,
        now,
        now,
        result,
        chatSessionId,
        fileId,
      );

    this.db
      .prepare(
        `INSERT INTO prompt_deliveries
         (id, prompt_id, project_id, content, status, created_at, updated_at, result, chat_session_id)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        deliveryId,
        promptId,
        input.projectId,
        content,
        promptStatus,
        now,
        now,
        result,
        chatSessionId,
      );

    this.touchChatSession(chatSessionId);

    const file = this.getFileTransfer(fileId)!;
    const prompt = this.mapPromptJob(
      this.db
        .prepare(
          `SELECT id, content, status, created_at, updated_at, result, chat_session_id, attachment_id
           FROM prompts WHERE id = ?`,
        )
        .get(promptId) as Record<string, unknown>,
    );
    const delivery = this.getDelivery(deliveryId)!;
    return { file, prompt, delivery };
  }

  getFileTransfer(id: string): FileTransfer | null {
    const row = this.db
      .prepare(
        `SELECT id, project_id, chat_session_id, file_name, mime_type, size, prompt_id, created_at, direction
         FROM file_transfers WHERE id = ?`,
      )
      .get(id) as Record<string, unknown> | undefined;
    if (!row) return null;
    return mapFileTransfer(row);
  }

  getFileStoragePath(id: string, filesDir: string): {
    file: FileTransfer;
    absolutePath: string;
  } | null {
    const row = this.db
      .prepare(
        `SELECT id, project_id, chat_session_id, file_name, mime_type, size, prompt_id, created_at, storage_name, direction
         FROM file_transfers WHERE id = ?`,
      )
      .get(id) as Record<string, unknown> | undefined;
    if (!row) return null;
    const absolutePath = path.join(filesDir, String(row.storage_name));
    if (!fs.existsSync(absolutePath)) return null;
    return {
      file: mapFileTransfer(row),
      absolutePath,
    };
  }

  upsertSessionContext(input: SyncSessionContextRequest): SessionContext {
    const now = nowIso();
    const existing = this.getSessionContext(input.projectId);
    const openFilesJson = JSON.stringify(input.openFiles ?? []);
    if (existing) {
      this.db
        .prepare(
          `UPDATE session_contexts
           SET summary = ?, current_step = ?, open_files = ?, status = ?,
               extra = ?, updated_at = ?
           WHERE project_id = ?`,
        )
        .run(
          input.summary,
          input.currentStep ?? "",
          openFilesJson,
          input.status ?? "idle",
          input.extra ?? null,
          now,
          input.projectId,
        );
    } else {
      const id = nanoid();
      this.db
        .prepare(
          `INSERT INTO session_contexts
           (id, project_id, summary, current_step, open_files, status, extra, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(
          id,
          input.projectId,
          input.summary,
          input.currentStep ?? "",
          openFilesJson,
          input.status ?? "idle",
          input.extra ?? null,
          now,
          now,
        );
    }

    // 同步写入当前对话 Session，客户端在对话内展示
    if (input.chatSessionId) {
      this.updateChatSession(input.chatSessionId, {
        contextSummary: input.summary,
        contextStep: input.currentStep ?? "",
        contextStatus: input.status ?? "idle",
        contextExtra: input.extra,
      });
    }

    return this.getSessionContext(input.projectId)!;
  }

  getSessionContext(projectId: string): SessionContext | null {
    const row = this.db
      .prepare(
        `SELECT id, project_id, summary, current_step, open_files, status, extra,
                created_at, updated_at
         FROM session_contexts WHERE project_id = ?`,
      )
      .get(projectId) as Record<string, unknown> | undefined;
    return row ? mapSession(row) : null;
  }

  listSessionContexts(): SessionContext[] {
    const rows = this.db
      .prepare(
        `SELECT id, project_id, summary, current_step, open_files, status, extra,
                created_at, updated_at
         FROM session_contexts ORDER BY updated_at DESC`,
      )
      .all() as Array<Record<string, unknown>>;
    return rows.map(mapSession);
  }

  /** 找一个指定 IDE 的在线项目，供打开工作区时默认经由 */
  findOnlineProjectForIde(ide: Ide): Project | null {
    const list = this.listProjects().filter(
      (p) => p.ide === ide && p.online,
    );
    return list[0] ?? null;
  }
}

function mapProject(row: Record<string, unknown>): Project {
  return {
    id: String(row.id),
    name: String(row.name),
    workspacePath: String(row.workspace_path),
    ide: row.ide as Ide,
    lastSeenAt: String(row.last_seen_at),
    online: Number(row.online) === 1 || row.online === true,
  };
}

function mapTask(row: Record<string, unknown>): TaskEvent {
  return {
    id: String(row.id),
    projectId: String(row.project_id),
    type: row.type as TaskEvent["type"],
    title: String(row.title),
    detail: String(row.detail ?? ""),
    status: row.status as TaskStatus,
    requireDecision: Boolean(row.require_decision),
    decisionComment: row.decision_comment
      ? String(row.decision_comment)
      : undefined,
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

function mapFileTransfer(row: Record<string, unknown>): FileTransfer {
  const directionRaw = row.direction ? String(row.direction) : undefined;
  const direction =
    directionRaw === "to_agent" || directionRaw === "to_client"
      ? directionRaw
      : undefined;
  return {
    id: String(row.id),
    projectId: String(row.project_id),
    chatSessionId: row.chat_session_id
      ? String(row.chat_session_id)
      : undefined,
    fileName: String(row.file_name),
    mimeType: row.mime_type ? String(row.mime_type) : undefined,
    size: Number(row.size),
    createdAt: String(row.created_at),
    promptId: row.prompt_id ? String(row.prompt_id) : undefined,
    direction,
  };
}

function mapDelivery(row: Record<string, unknown>): PromptDelivery {
  return {
    id: String(row.id),
    promptId: String(row.prompt_id),
    projectId: String(row.project_id),
    chatSessionId: row.chat_session_id
      ? String(row.chat_session_id)
      : undefined,
    content: String(row.content),
    status: row.status as PromptDelivery["status"],
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
    result: row.result ? String(row.result) : undefined,
  };
}

function mapChatSession(row: Record<string, unknown>): ChatSession {
  return {
    id: String(row.id),
    projectId: String(row.project_id),
    title: String(row.title),
    cursorChatId: row.cursor_chat_id
      ? String(row.cursor_chat_id)
      : undefined,
    contextSummary: row.context_summary
      ? String(row.context_summary)
      : undefined,
    contextStep: row.context_step ? String(row.context_step) : undefined,
    contextStatus: row.context_status
      ? String(row.context_status)
      : undefined,
    contextExtra: row.context_extra ? String(row.context_extra) : undefined,
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}

function mapSession(row: Record<string, unknown>): SessionContext {
  let openFiles: string[] = [];
  try {
    openFiles = JSON.parse(String(row.open_files ?? "[]")) as string[];
  } catch {
    openFiles = [];
  }
  return {
    id: String(row.id),
    projectId: String(row.project_id),
    summary: String(row.summary),
    currentStep: String(row.current_step ?? ""),
    openFiles,
    status: row.status as SessionContext["status"],
    extra: row.extra ? String(row.extra) : undefined,
    createdAt: String(row.created_at),
    updatedAt: String(row.updated_at),
  };
}
