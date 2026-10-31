/**
 * 启动中继 + 独立 bridge（心跳保活，不依赖 Cursor/Codex 是否打开）。
 * 幂等：中继已在跑则跳过；bridge 每次确保拉起一条（同工作区会合并为同一项目）。
 *
 * 用法：
 *   node scripts/start-relay.mjs
 *   或双击 / 计划任务：start-codeassist-all.bat
 */
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const logDir = path.join(root, "packages", "mcp-server");
const serverLog = path.join(logDir, "relay-server.log");
const bridgeLog = path.join(logDir, "cursor-bridge.log");

const env = {
  ...process.env,
  ACCESS_TOKEN: process.env.ACCESS_TOKEN || "codeassist-dev-token",
  HOST: process.env.HOST || "0.0.0.0",
  PORT: process.env.PORT || "8787",
  OFFLINE_MS: process.env.OFFLINE_MS || String(10 * 60 * 1000),
  CODEASSIST_SERVER_URL:
    process.env.CODEASSIST_SERVER_URL || "http://127.0.0.1:8787",
  CODEASSIST_TOKEN: process.env.CODEASSIST_TOKEN || "codeassist-dev-token",
  CODEASSIST_IDE: process.env.CODEASSIST_IDE || "cursor",
  CODEASSIST_WORKSPACE: process.env.CODEASSIST_WORKSPACE || root,
  CODEASSIST_PROJECT_NAME: process.env.CODEASSIST_PROJECT_NAME || "CodeAssit",
  CODEASSIST_POLL_MS: process.env.CODEASSIST_POLL_MS || "5000",
};

const nodeExe = process.execPath;
const detachChildren = process.env.CODEASSIST_DETACH === "1";

function appendLog(file, line) {
  try {
    fs.appendFileSync(file, `[${new Date().toISOString()}] ${line}\n`);
  } catch {
    /* ignore */
  }
}

function log(msg) {
  console.error(`[start-relay] ${msg}`);
  appendLog(path.join(logDir, "start-relay.log"), msg);
}

async function healthOk() {
  const base = env.CODEASSIST_SERVER_URL.replace(/\/$/, "");
  try {
    const res = await fetch(`${base}/health`, {
      signal: AbortSignal.timeout(2000),
    });
    return res.ok;
  } catch {
    return false;
  }
}

function spawnLogged(name, command, args, cwd, logFile) {
  fs.mkdirSync(path.dirname(logFile), { recursive: true });
  const out = fs.openSync(logFile, "a");
  const child = spawn(command, args, {
    cwd,
    env,
    stdio: ["ignore", out, out],
    shell: process.platform === "win32",
    detached: detachChildren,
    windowsHide: true,
  });
  if (detachChildren) {
    child.unref();
  } else {
    child.on("exit", (code, signal) => {
      log(`${name} exited code=${code} signal=${signal}`);
    });
  }
  return child;
}

async function waitForServer(tries = 60) {
  for (let i = 0; i < tries; i++) {
    if (await healthOk()) return true;
    await new Promise((r) => setTimeout(r, 500));
  }
  return false;
}

async function main() {
  log(
    `start ide=${env.CODEASSIST_IDE} workspace=${env.CODEASSIST_WORKSPACE} server=${env.CODEASSIST_SERVER_URL}`,
  );

  let serverChild = null;
  if (await healthOk()) {
    log("relay already healthy, skip starting server");
  } else {
    log("starting relay server…");
    serverChild = spawnLogged(
      "server",
      "npm",
      ["run", "start", "-w", "@codeassist/server"],
      root,
      serverLog,
    );
    const ok = await waitForServer();
    if (!ok) {
      log("server not ready, abort bridge");
      process.exitCode = 1;
      return;
    }
    log("relay health ok");
  }

  const bridgeJs = path.join(root, "packages", "mcp-server", "dist", "bridge.js");
  if (!fs.existsSync(bridgeJs)) {
    log(`bridge missing: ${bridgeJs} (run npm run build)`);
    process.exitCode = 1;
    return;
  }

  log("starting bridge…");
  spawnLogged("bridge", nodeExe, [bridgeJs], root, bridgeLog);

  if (detachChildren) {
    log("detached mode: children unref'd, exiting launcher");
    return;
  }

  // 前台保活：任一子进程退出则结束（计划任务用 detached）
  process.on("SIGINT", () => {
    try {
      serverChild?.kill();
    } catch {
      /* ignore */
    }
    process.exit(0);
  });
  process.on("SIGTERM", () => {
    try {
      serverChild?.kill();
    } catch {
      /* ignore */
    }
    process.exit(0);
  });

  // 保持进程，便于手动调试；自启 bat 会设 CODEASSIST_DETACH=1
  if (!serverChild) {
    // 仅 bridge 时也挂住，避免立刻退出导致部分环境杀子进程
    setInterval(() => {}, 1 << 30);
  }
}

main().catch((err) => {
  log(String(err));
  process.exitCode = 1;
});
