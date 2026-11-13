import { spawn, type ChildProcess } from "node:child_process";
import os from "node:os";
import path from "node:path";
import type { MobileConfirmations, MobileQuestion } from "./mobile-confirmation.js";
import { parseMobileAnswers } from "./mobile-confirmation.js";

type Json = Record<string, any>;
export type ExecutionProgress = {
  status: "thinking" | "coding" | "waiting_user" | "blocked" | "done";
  currentStep: string;
  extra?: string;
  openFiles?: string[];
};
type Options = {
  codex: string;
  /** Alternate process entry point for protocol integration tests. */
  appServerArgs?: string[];
  workspace: string;
  prompt: string;
  resumeChatId?: string;
  chatSessionId?: string;
  model?: string;
  idleTimeoutMs: number;
  maxTimeoutMs: number;
  confirmations: MobileConfirmations;
  signal?: AbortSignal;
  onProgress: (progress: ExecutionProgress) => void;
  onActivity?: () => void;
  onSpawn?: (pid: number | undefined) => void;
  kill: (child: ChildProcess) => void;
};

/** Own one app-server transport: replies can only resolve requests from this run. */
export async function runCodexAppServer(opts: Options): Promise<{ text: string; cursorChatId?: string }> {
  const profile = process.env.USERPROFILE?.trim() || os.homedir();
  const root = path.parse(profile).root;
  const child = spawn(opts.codex, opts.appServerArgs ?? ["app-server", "--listen", "stdio://"], {
    cwd: opts.workspace, windowsHide: true, stdio: ["pipe", "pipe", "pipe"],
    env: {
      ...process.env, HOME: profile, USERPROFILE: profile,
      CODEX_HOME: process.env.CODEX_HOME?.trim() || path.join(profile, ".codex"),
      HOMEDRIVE: process.env.HOMEDRIVE || root.replace(/[\\/]+$/, ""),
      HOMEPATH: process.env.HOMEPATH || profile.slice(root.length) || path.sep,
      CODEASSIST_AGENT_CHILD: "1", NO_COLOR: "1",
    },
  });
  opts.onSpawn?.(child.pid);
  let sequence = 0;
  let threadId = opts.resumeChatId;
  let turnId: string | undefined;
  let completed = false;
  let stderr = "";
  let buffer = "";
  let lastMessage = "";
  const messages = new Map<string, string>();
  const itemDetails = new Map<string, Json>();
  const requests = new Map<number | string, AbortController>();
  const calls = new Map<number, { resolve: (v: Json) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> }>();
  let idleTimer: ReturnType<typeof setTimeout> | undefined;
  let maxTimer: ReturnType<typeof setTimeout> | undefined;
  let resolveDone!: (result: { text: string; cursorChatId?: string }) => void;
  const done = new Promise<{ text: string; cursorChatId?: string }>((resolve) => { resolveDone = resolve; });
  const send = (message: Json) => {
    if (!completed && child.stdin.writable) child.stdin.write(JSON.stringify(message) + "\n");
  };
  const finish = (text: string) => {
    if (completed) return;
    completed = true;
    clearTimeout(idleTimer); clearTimeout(maxTimer);
    opts.signal?.removeEventListener("abort", onAbort);
    for (const controller of requests.values()) controller.abort();
    requests.clear();
    for (const call of calls.values()) { clearTimeout(call.timer); call.reject(new Error("Codex 连接已结束")); }
    calls.clear();
    opts.kill(child);
    resolveDone({ text, cursorChatId: threadId });
  };
  const onAbort = () => finish("[agent-error] 任务已取消，待确认请求已关闭");
  const request = (method: string, params: Json): Promise<Json> => new Promise((resolve, reject) => {
    if (completed) { reject(new Error("Codex 连接已结束")); return; }
    const id = ++sequence;
    const timer = setTimeout(() => { calls.delete(id); reject(new Error(`${method} 响应超时`)); }, 60_000);
    calls.set(id, { resolve, reject, timer });
    send({ id, method, params });
  });
  const progress = (value: ExecutionProgress) => {
    if (!completed) opts.onProgress(value);
  };
  const armIdle = () => {
    clearTimeout(idleTimer);
    // Human thinking time must not be mistaken for an unresponsive agent.
    if (!completed && requests.size === 0) {
      idleTimer = setTimeout(() => finish("[agent-error] Codex 空闲超时，任务已停止"), opts.idleTimeoutMs);
    }
  };
  const activity = () => { armIdle(); opts.onActivity?.(); };

  const handleServerRequest = async (message: Json) => {
    const p = message.params ?? {};
    if (p.threadId !== threadId || (turnId && p.turnId && p.turnId !== turnId)) {
      send({ id: message.id, error: { code: -32602, message: "Request does not belong to the active task" } });
      return;
    }
    const method = String(message.method);
    const isQuestion = method === "item/tool/requestUserInput" || method === "tool/requestUserInput";
    const command = method === "item/commandExecution/requestApproval";
    const files = method === "item/fileChange/requestApproval";
    const permissions = method === "item/permissions/requestApproval";
    if (!isQuestion && !command && !files && !permissions) {
      // Never manufacture a grant for a new/unknown permission request shape.
      send({ id: message.id, error: { code: -32601, message: "This confirmation type is not supported by CodeAssist" } });
      progress({ status: "blocked", currentStep: "遇到暂不支持的确认类型", extra: method });
      return;
    }
    const questions: MobileQuestion[] = Array.isArray(p.questions) ? p.questions : [];
    if (isQuestion && (!questions.length || p.questions.some((q: Json) => q.isSecret))) {
      send({ id: message.id, result: { answers: {} } });
      void request("turn/interrupt", { threadId, turnId: p.turnId }).catch(() => undefined);
      progress({ status: "blocked", currentStep: "需要在电脑端处理敏感输入" });
      return;
    }
    const controller = new AbortController();
    requests.set(message.id, controller);
    armIdle();
    const cached = itemDetails.get(p.itemId) ?? {};
    const paths = (cached.changes ?? []).map((c: Json) => c.path).filter((s: unknown) => typeof s === "string");
    const title = isQuestion ? "Codex 需要你回答问题" : command ? "Codex 请求执行命令" : permissions ? "Codex 请求临时权限" : "Codex 请求修改文件";
    progress({ status: "waiting_user", currentStep: title, extra: p.reason || p.command || "请在手机查看并确认" });
    try {
      const answer = await opts.confirmations.request(title, {
        kind: isQuestion ? "question" : command ? "command" : permissions ? "permissions" : "fileChange",
        threadId, turnId: p.turnId, chatSessionId: opts.chatSessionId,
        reason: [p.reason || "Codex 正在等待你的确认", p.networkApprovalContext ? JSON.stringify(p.networkApprovalContext) : ""].filter(Boolean).join("\n"), command: p.command ?? cached.command,
        cwd: p.cwd ?? opts.workspace, paths: files ? [...paths, ...(p.grantRoot ? [p.grantRoot] : [])] : undefined,
        questions: isQuestion ? questions : undefined,
        permissions: permissions ? p.permissions : p.additionalPermissions,
      }, controller.signal);
      if (completed || controller.signal.aborted) return;
      if (isQuestion) {
        const answers = answer.approved ? parseMobileAnswers(answer.comment, questions) : {};
        send({ id: message.id, result: { answers } });
        if (!answer.approved) void request("turn/interrupt", { threadId, turnId: p.turnId }).catch(() => undefined);
      } else if (permissions) {
        const granted = Object.fromEntries(Object.entries(p.permissions ?? {}).filter(([key, value]) =>
          (key === "network" || key === "fileSystem") && value != null));
        send({ id: message.id, result: { permissions: answer.approved ? granted : {}, scope: "turn" } });
      } else {
        // Only a one-time grant. Never create permanent command/network allow rules.
        send({ id: message.id, result: { decision: answer.approved ? "accept" : "decline" } });
      }
      progress({ status: "coding", currentStep: answer.approved ? "已收到手机确认，继续执行" : "已拒绝当前请求", extra: answer.reason });
    } catch (error) {
      if (!completed && !controller.signal.aborted) {
        send({ id: message.id, result: isQuestion ? { answers: {} } : permissions ? { permissions: {}, scope: "turn" } : { decision: "decline" } });
        if (isQuestion) void request("turn/interrupt", { threadId, turnId: p.turnId }).catch(() => undefined);
        progress({ status: "blocked", currentStep: "确认未成功，已停止该操作", extra: String(error) });
      }
    } finally { requests.delete(message.id); armIdle(); }
  };

  const handle = (message: Json) => {
    if (message.id !== undefined && message.method) {
      void handleServerRequest(message);
      return;
    }
    if (message.id !== undefined) {
      const call = calls.get(message.id);
      if (call) {
        calls.delete(message.id); clearTimeout(call.timer);
        if (message.error) call.reject(new Error(message.error.message || JSON.stringify(message.error)));
        else call.resolve(message.result ?? {});
      }
      return;
    }
    const p = message.params ?? {};
    if (!threadId || p.threadId !== threadId) return;
    if (turnId && p.turnId && p.turnId !== turnId) return;
    if (message.method === "serverRequest/resolved") {
      requests.get(p.requestId)?.abort();
      requests.delete(p.requestId); armIdle();
    } else if (message.method === "turn/started") {
      turnId = p.turn?.id;
      progress({ status: "thinking", currentStep: "Codex 正在分析任务" });
    } else if (message.method === "item/agentMessage/delta" && !requests.size) {
      const text = (messages.get(p.itemId) ?? "") + (p.delta ?? "");
      messages.set(p.itemId, text.slice(-16000));
      progress({ status: "thinking", currentStep: "Codex 正在回复", extra: text.slice(-1200) });
    } else if (message.method === "item/started" || message.method === "item/completed") {
      const item = p.item ?? {};
      itemDetails.set(item.id, item);
      const started = message.method === "item/started";
      if (item.type === "agentMessage" && !started) lastMessage = item.text || lastMessage;
      if (requests.size) return; // Do not overwrite an outstanding approval with activity.
      if (item.type === "commandExecution") {
        progress({ status: "coding", currentStep: started ? "正在执行命令" : `命令${item.status === "failed" ? "失败" : item.status === "declined" ? "已拒绝" : "结束"}`, extra: [item.command, item.aggregatedOutput?.slice(-1600)].filter(Boolean).join("\n") });
      } else if (item.type === "fileChange") {
        const paths = (item.changes ?? []).map((c: Json) => c.path);
        progress({ status: "coding", currentStep: started ? "正在修改文件" : "文件修改已结束", openFiles: paths, extra: paths.join("\n") });
      } else if (item.type === "mcpToolCall" && !/codeassist/.test(item.server)) {
        progress({ status: "coding", currentStep: `${started ? "正在调用" : "已结束"} ${item.server}/${item.tool}` });
      }
    } else if (message.method === "turn/plan/updated" && !requests.size) {
      progress({ status: "thinking", currentStep: "执行计划已更新", extra: (p.plan ?? []).map((s: Json) => `${s.status}: ${s.step}`).join("\n") });
    } else if (message.method === "error") {
      progress({ status: "blocked", currentStep: p.willRetry ? "Codex 连接异常，正在重试" : "Codex 执行失败", extra: p.error?.message });
      if (!p.willRetry) finish(`[agent-error] ${p.error?.message || "Codex 执行失败"}`);
    } else if (message.method === "turn/completed") {
      const turn = p.turn ?? {};
      const text = lastMessage || [...messages.values()].at(-1) || "Codex 执行完成";
      finish(turn.status === "completed" ? text : `[agent-error] ${turn.error?.message || (turn.status === "interrupted" ? "任务已中断" : "执行失败")}\n${text}`);
    }
  };
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk: string) => {
    activity(); buffer += chunk;
    let newline: number;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
      try { handle(JSON.parse(line)); } catch { /* Only protocol messages are processed. */ }
    }
  });
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk: string) => { stderr = (stderr + chunk).slice(-5000); });
  child.stdin.on("error", (e) => finish(`[agent-error] Codex 通道断开：${e.message}`));
  child.on("error", (e) => finish(`[agent-error] ${e.message}`));
  child.on("close", (code) => finish(`[agent-error] Codex 连接提前结束 (${code})\n${stderr}`));
  opts.signal?.addEventListener("abort", onAbort, { once: true });
  if (opts.signal?.aborted) onAbort();
  armIdle();
  if (!completed) maxTimer = setTimeout(() => finish("[agent-error] 执行超过绝对上限，任务已中止"), opts.maxTimeoutMs);
  void (async () => {
    try {
      await request("initialize", { clientInfo: { name: "codeassist", title: "CodeAssist mobile bridge", version: "0.2.0" }, capabilities: { experimentalApi: true } });
      send({ method: "initialized", params: {} });
      const params = { cwd: opts.workspace, model: opts.model, approvalPolicy: "on-request", approvalsReviewer: "user", sandbox: "workspace-write" };
      const result = opts.resumeChatId
        ? await request("thread/resume", { ...params, threadId: opts.resumeChatId, excludeTurns: true })
        : await request("thread/start", params);
      threadId = result.thread?.id;
      if (!threadId) throw new Error("Codex 未返回 threadId");
      // Never inject a second task into an already active desktop conversation.
      if (result.thread?.status?.type === "active") throw new Error("该PC会话正在执行任务，请等待完成后再发送");
      const started = await request("turn/start", { threadId, input: [{ type: "text", text: opts.prompt, text_elements: [] }] });
      turnId = started.turn?.id ?? turnId;
    } catch (error) { finish(`[agent-error] ${error instanceof Error ? error.message : String(error)}`); }
  })();
  return done;
}
