#!/usr/bin/env node
/**
 * After an Agent turn ends, peek queued prompts and auto-continue the chat.
 */
import { createHash } from "node:crypto";
import path from "node:path";
import { createInterface } from "node:readline";

const SERVER_URL = (
  process.env.CODEASSIST_SERVER_URL ?? "http://127.0.0.1:8787"
).replace(/\/$/, "");
const TOKEN = process.env.CODEASSIST_TOKEN ?? "codeassist-dev-token";
const IDE = process.env.CODEASSIST_IDE ?? "cursor";

function readStdin() {
  return new Promise((resolve) => {
    const chunks = [];
    const rl = createInterface({ input: process.stdin });
    rl.on("line", (line) => chunks.push(line));
    rl.on("close", () => resolve(chunks.join("\n")));
    setTimeout(() => {
      try {
        rl.close();
      } catch {
        /* ignore */
      }
    }, 2000);
  });
}

function projectIdFor(workspacePath) {
  const hash = createHash("sha1")
    .update(`${IDE}:${workspacePath}`)
    .digest("hex")
    .slice(0, 16);
  return `${IDE}-${hash}`;
}

function resolveWorkspace(input) {
  const fromEnv =
    process.env.CODEASSIST_WORKSPACE ||
    (process.env.WORKSPACE_FOLDER_PATHS || "").split(/[;,]/)[0] ||
    "";
  if (fromEnv.trim()) return path.resolve(fromEnv.trim());
  const roots = input.workspace_roots ?? [];
  if (roots[0]) {
    let p = String(roots[0]);
    if (p.startsWith("/") && /^\/[a-zA-Z]:/.test(p)) p = p.slice(1);
    return path.resolve(p);
  }
  return path.resolve(process.cwd());
}

function out(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

async function main() {
  let input = {};
  try {
    const raw = await readStdin();
    if (raw.trim()) input = JSON.parse(raw);
  } catch {
    out({});
    return;
  }

  if (input.status && input.status !== "completed") {
    out({});
    return;
  }

  const workspace = resolveWorkspace(input);
  const projectId = projectIdFor(workspace);

  let prompts = [];
  try {
    const res = await fetch(`${SERVER_URL}/api/prompts`, {
      headers: { Authorization: `Bearer ${TOKEN}` },
    });
    if (!res.ok) {
      out({});
      return;
    }
    const all = await res.json();
    prompts = all.filter(
      (p) =>
        p.status === "queued" &&
        Array.isArray(p.projectIds) &&
        p.projectIds.includes(projectId),
    );
  } catch {
    out({});
    return;
  }

  if (prompts.length === 0) {
    out({});
    return;
  }

  const preview = prompts.map((p, i) => `${i + 1}. ${p.content}`).join("\n\n");
  out({
    followup_message:
      `【CodeAssist 手机新 Prompt × ${prompts.length}】请立即 get_pending_prompts，对每条 ack_prompt 后执行 content，再 complete_prompt。\n\n预览：\n${preview}`,
  });
}

main().catch(() => out({}));
