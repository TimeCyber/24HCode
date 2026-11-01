/**
 * 启动本地中继 :8787 + bridge；若存在云端 pair 配置则再起一条 cloud bridge。
 * 客户端可在「内网 / 云端」间切换，两边都能收到同一工作区心跳与指令。
 *
 * 说明：单个 MCP/bridge 进程只连一个 SERVER_URL；双通道 = 起两个 bridge 进程。
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
const bridgeLogLocal = path.join(logDir, "cursor-bridge.log");
const bridgeLogCloud = path.join(logDir, "cursor-bridge-cloud.log");
const deviceEnvFile = path.join(logDir, ".codeassist-device.env");

function loadDeviceEnvFile(filePath) {
  const out = {};
  if (!fs.existsSync(filePath)) return out;
  try {
    const text = fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/, "");
    for (const raw of text.split(/\r?\n/)) {
      const line = raw.trim();
      if (!line || line.startsWith("#")) continue;
      const i = line.indexOf("=");
      if (i <= 0) continue;
      const key = line.slice(0, i).trim();
      const val = line.slice(i + 1).trim();
      if (key) out[key] = val;
    }
  } catch (e) {
    console.error(`[start-relay] load device env failed: ${e}`);
  }
  return out;
}

function isLocalUrl(url) {
  const u = String(url || "").replace(/\/$/, "");
  return (
    /^(https?:\/\/)?(127\.0\.0\.1|localhost)(:\d+)?(\/|$)/i.test(u) ||
    /^https?:\/\/192\.168\.\d+\.\d+/i.test(u) ||
    /^https?:\/\/10\.\d+\.\d+\.\d+/i.test(u)
  );
}

const deviceEnv = loadDeviceEnvFile(deviceEnvFile);

const LOCAL_URL = (
  process.env.CODEASSIST_LOCAL_SERVER_URL ||
  "http://127.0.0.1:8787"
).replace(/\/$/, "");
const LOCAL_TOKEN =
  process.env.CODEASSIST_LOCAL_TOKEN ||
  process.env.ACCESS_TOKEN ||
  "codeassist-dev-token";

const cloudUrl = String(deviceEnv.CODEASSIST_SERVER_URL || "")
  .trim()
  .replace(/\/$/, "");
const cloudToken = String(deviceEnv.CODEASSIST_TOKEN || "").trim();
const hasCloud =
  Boolean(cloudUrl && cloudToken) && !isLocalUrl(cloudUrl);

const baseEnv = {
  ...process.env,
  ACCESS_TOKEN: LOCAL_TOKEN,
  HOST: process.env.HOST || "0.0.0.0",
  PORT: process.env.PORT || "8787",
  OFFLINE_MS: process.env.OFFLINE_MS || String(10 * 60 * 1000),
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

async function healthOk(baseUrl) {
  const base = String(baseUrl || "").replace(/\/$/, "");
  try {
    const res = await fetch(`${base}/health`, {
      signal: AbortSignal.timeout(2500),
    });
    return res.ok;
  } catch {
    return false;
  }
}

function spawnLogged(name, command, args, cwd, logFile, childEnv) {
  fs.mkdirSync(path.dirname(logFile), { recursive: true });
  const out = fs.openSync(logFile, "a");
  const child = spawn(command, args, {
    cwd,
    env: childEnv,
    stdio: ["ignore", out, out],
    shell: false,
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

async function waitForLocal(tries = 60) {
  for (let i = 0; i < tries; i++) {
    if (await healthOk(LOCAL_URL)) return true;
    await new Promise((r) => setTimeout(r, 500));
  }
  return false;
}

async function main() {
  log(
    `start ide=${baseEnv.CODEASSIST_IDE} workspace=${baseEnv.CODEASSIST_WORKSPACE} local=${LOCAL_URL} cloud=${hasCloud ? cloudUrl : "(none)"}`,
  );

  let serverChild = null;
  if (await healthOk(LOCAL_URL)) {
    log(`local relay healthy at ${LOCAL_URL}, skip starting server`);
  } else {
    const serverJs = path.join(root, "packages", "server", "dist", "index.js");
    if (!fs.existsSync(serverJs)) {
      log(`server missing: ${serverJs} (run npm run build)`);
      process.exitCode = 1;
      return;
    }
    log("starting local relay server…");
    serverChild = spawnLogged(
      "server",
      nodeExe,
      [serverJs],
      path.join(root, "packages", "server"),
      serverLog,
      {
        ...baseEnv,
        CODEASSIST_SERVER_URL: LOCAL_URL,
        CODEASSIST_TOKEN: LOCAL_TOKEN,
      },
    );
    const ok = await waitForLocal();
    if (!ok) {
      log("local server not ready, abort");
      process.exitCode = 1;
      return;
    }
    log("local relay health ok");
  }

  const bridgeJs = path.join(root, "packages", "mcp-server", "dist", "bridge.js");
  if (!fs.existsSync(bridgeJs)) {
    log(`bridge missing: ${bridgeJs} (run npm run build)`);
    process.exitCode = 1;
    return;
  }

  log(`starting local bridge → ${LOCAL_URL}`);
  spawnLogged("bridge-local", nodeExe, [bridgeJs], root, bridgeLogLocal, {
    ...baseEnv,
    CODEASSIST_SERVER_URL: LOCAL_URL,
    CODEASSIST_TOKEN: LOCAL_TOKEN,
  });

  if (hasCloud) {
    if (await healthOk(cloudUrl)) {
      log(`starting cloud bridge → ${cloudUrl}`);
      spawnLogged("bridge-cloud", nodeExe, [bridgeJs], root, bridgeLogCloud, {
        ...baseEnv,
        CODEASSIST_SERVER_URL: cloudUrl,
        CODEASSIST_TOKEN: cloudToken,
      });
    } else {
      log(`cloud relay not reachable (${cloudUrl}), skip cloud bridge`);
    }
  } else {
    log("no cloud device env, local-only mode");
  }

  if (detachChildren) {
    log("detached mode: children unref'd, exiting launcher");
    return;
  }

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

  if (!serverChild) {
    setInterval(() => {}, 1 << 30);
  }
}

main().catch((err) => {
  log(String(err));
  process.exitCode = 1;
});
