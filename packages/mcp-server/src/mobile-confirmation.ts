import { randomUUID } from "node:crypto";
import type { TaskEvent } from "@codeassist/shared";
import type { ApiClient } from "./api-client.js";

export const REMOTE_REQUEST_PREFIX = "CODEASSIST_REMOTE_REQUEST_V1\n";
export type MobileQuestion = {
  id: string;
  question: string;
  options?: { label: string; description?: string }[] | null;
};
export type RemoteRequest = {
  version: 1;
  requestId: string;
  kind: "command" | "fileChange" | "question" | "confirmation" | "permissions";
  threadId?: string;
  turnId?: string;
  chatSessionId?: string;
  reason: string;
  command?: string;
  cwd?: string;
  paths?: string[];
  permissions?: unknown;
  questions?: MobileQuestion[];
  expiresAt: string;
};
export type MobileAnswer = { approved: boolean; comment?: string; reason?: string };
type ConfirmationApi = Pick<ApiClient, "createTask" | "listTasks" | "submitDecision">;

/** Reads task state without consuming the project's Agent/MCP decision queue. */
export class MobileConfirmations {
  private active = new Map<string, (task: TaskEvent) => void>();
  constructor(private api: ConfirmationApi, private projectId: string, private pollMs = 5000) {}

  observe(task: TaskEvent): void {
    if (task.projectId === this.projectId) this.active.get(task.id)?.(task);
  }

  async request(
    title: string,
    request: Omit<RemoteRequest, "version" | "requestId" | "expiresAt">,
    signal: AbortSignal,
    timeoutMs = 10 * 60_000,
  ): Promise<MobileAnswer> {
    if (signal.aborted) return { approved: false, reason: "请求已取消" };
    const expiresAt = new Date(Date.now() + timeoutMs).toISOString();
    const detail: RemoteRequest = { ...request, version: 1, requestId: randomUUID(), expiresAt };
    const task = await this.api.createTask({
      projectId: this.projectId, type: "pending", title, requireDecision: true,
      detail: REMOTE_REQUEST_PREFIX + JSON.stringify(detail),
    });
    if (!task.id || task.projectId !== this.projectId) throw new Error("中继未成功创建确认请求");
    return new Promise((resolve) => {
      let finished = false;
      let polling = false;
      const finish = (answer: MobileAnswer, dismiss = false) => {
        if (finished) return;
        finished = true;
        clearInterval(poll);
        clearTimeout(timeout);
        signal.removeEventListener("abort", onAbort);
        this.active.delete(task.id);
        if (dismiss) {
          void this.api.submitDecision(task.id, "reject", answer.reason).catch(() => undefined);
        }
        resolve(answer);
      };
      const onAbort = () => finish({ approved: false, reason: "请求已取消或已在电脑端处理" }, true);
      const observe = (updated: TaskEvent) => {
        if (Date.now() >= Date.parse(expiresAt) || signal.aborted) return;
        if (updated.status === "approved" || updated.status === "rejected") {
          finish({ approved: updated.status === "approved", comment: updated.decisionComment });
        }
      };
      const check = async () => {
        if (finished || polling) return;
        polling = true;
        try {
          // A persisted task status survives WebSocket loss and competing MCP pulls.
          const pending = await this.api.listTasks("awaiting_decision");
          if (finished || pending.some((t) => t.id === task.id)) return;
          for (const status of ["approved", "rejected"]) {
            const rows = await this.api.listTasks(status);
            const updated = rows.find((t) => t.id === task.id && t.projectId === this.projectId);
            if (updated && !finished) { observe(updated); break; }
          }
        } catch { /* A network error is never approval. Retry until expiry. */ }
        finally { polling = false; }
      };
      const poll = setInterval(() => void check(), this.pollMs);
      const timeout = setTimeout(() => finish({ approved: false, reason: "手机确认已超时，请重新发起" }, true), Math.max(0, Date.parse(expiresAt) - Date.now()));
      this.active.set(task.id, observe);
      signal.addEventListener("abort", onAbort, { once: true });
      if (signal.aborted) onAbort();
      else void check();
    });
  }
}

export function parseMobileAnswers(comment: string | undefined, questions: MobileQuestion[]): Record<string, { answers: string[] }> {
  let parsed: unknown;
  try { parsed = JSON.parse(comment ?? ""); } catch { throw new Error("手机回复缺少问题答案"); }
  const answers = (parsed as { answers?: Record<string, unknown> } | null)?.answers;
  const result: Record<string, { answers: string[] }> = {};
  for (const question of questions) {
    const answer = answers?.[question.id] as { answers?: unknown } | undefined;
    if (!Array.isArray(answer?.answers) || !answer.answers.length ||
        !answer.answers.every((s: unknown) => typeof s === "string" && s.trim().length > 0 && s.length <= 12000)) {
      throw new Error(`手机回复缺少有效答案：${question.question}`);
    }
    Object.defineProperty(result, question.id, { value: { answers: answer.answers as string[] }, enumerable: true });
  }
  return result;
}
