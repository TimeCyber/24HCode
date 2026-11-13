import { spawn } from "node:child_process";
import type {
  CodexUsageWindow,
  SyncCodexUsageRequest,
} from "@codeassist/shared";
import type { ApiClient } from "./api-client.js";

const USAGE_POLL_MS = 2 * 60 * 1000;
const APP_SERVER_TIMEOUT_MS = 15_000;

function parseWindow(value: unknown): CodexUsageWindow | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as Record<string, unknown>;
  const usedPercent = Number(raw.usedPercent);
  const windowDurationMins = Number(raw.windowDurationMins);
  const resetsAt = Number(raw.resetsAt);
  if (
    !Number.isInteger(usedPercent) ||
    usedPercent < 0 ||
    usedPercent > 100 ||
    !Number.isInteger(windowDurationMins) ||
    windowDurationMins <= 0
  ) {
    return null;
  }
  return {
    usedPercent,
    windowDurationMins,
    ...(Number.isInteger(resetsAt) && resetsAt > 0 ? { resetsAt } : {}),
  };
}

/** Ask the installed Codex CLI for its own account rate-limit snapshot. */
export function readCodexUsage(): Promise<Omit<SyncCodexUsageRequest, "projectId"> | null> {
  return new Promise((resolve) => {
    let child: ReturnType<typeof spawn>;
    try {
      child = spawn("codex", ["app-server", "--listen", "stdio://"], {
        stdio: ["pipe", "pipe", "ignore"],
        windowsHide: true,
      });
    } catch {
      resolve(null);
      return;
    }
    const stdout = child.stdout;
    const stdin = child.stdin;
    if (!stdout || !stdin) {
      child.kill();
      resolve(null);
      return;
    }

    let buffer = "";
    let finished = false;
    let requestSent = false;
    const timeout = setTimeout(() => finish(null), APP_SERVER_TIMEOUT_MS);

    const finish = (
      snapshot: Omit<SyncCodexUsageRequest, "projectId"> | null,
    ) => {
      if (finished) return;
      finished = true;
      clearTimeout(timeout);
      child.kill();
      resolve(snapshot);
    };

    stdin.on("error", () => finish(null));
    child.on("error", () => finish(null));
    child.on("exit", () => finish(null));
    stdout.setEncoding("utf8");
    stdout.on("data", (chunk: string) => {
      if (finished) return;
      buffer += chunk;
      let newline = buffer.indexOf("\n");
      while (newline >= 0) {
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        newline = buffer.indexOf("\n");
        if (!line) continue;

        let message: Record<string, unknown>;
        try {
          message = JSON.parse(line) as Record<string, unknown>;
        } catch {
          continue;
        }

        if (message.id === 1) {
          if (message.error) {
            finish(null);
          } else if (!requestSent) {
            requestSent = true;
            stdin.write('{"method":"initialized","params":{}}\n');
            stdin.write(
              '{"method":"account/rateLimits/read","id":2,"params":{}}\n',
            );
          }
          continue;
        }

        if (message.id !== 2) continue;
        const result = message.result as
          | { rateLimits?: Record<string, unknown> }
          | undefined;
        const limits = result?.rateLimits;
        if (!limits || typeof limits !== "object") {
          finish(null);
          continue;
        }
        const planType =
          typeof limits.planType === "string"
            ? limits.planType.slice(0, 40)
            : undefined;
        const primary = parseWindow(limits.primary);
        const secondary = parseWindow(limits.secondary);
        if (!primary && !secondary) {
          finish(null);
          continue;
        }
        finish({ planType, primary, secondary });
      }
    });

    stdin.write(
      JSON.stringify({
        method: "initialize",
        id: 1,
        params: {
          clientInfo: {
            name: "codeassist",
            title: "CodeAssist",
            version: "0.1.0",
          },
        },
      }) + "\n",
    );
  });
}

/** Periodically publish quota data without forwarding account identifiers. */
export function startCodexUsageReporter(
  api: ApiClient,
  getProjectId: () => string | null,
  getPeerApis: () => ApiClient[] = () => [],
): () => void {
  let stopped = false;
  let inFlight = false;
  const poll = async () => {
    const projectId = getProjectId();
    if (stopped || inFlight || !projectId) return;
    inFlight = true;
    try {
      const usage = await readCodexUsage();
      if (!stopped && usage) {
        await Promise.allSettled(
          [api, ...getPeerApis()].map((target) =>
            target.updateCodexUsage(projectId, usage),
          ),
        );
      }
    } catch {
      // Codex may be signed out or unavailable; keep the last known snapshot.
    } finally {
      inFlight = false;
    }
  };

  void poll();
  const timer = setInterval(() => void poll(), USAGE_POLL_MS);
  return () => {
    stopped = true;
    clearInterval(timer);
  };
}
