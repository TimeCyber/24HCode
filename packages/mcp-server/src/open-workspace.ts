import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { Ide } from "@codeassist/shared";

function findCursorCmd(): string | null {
  const candidates = [
    process.env.CURSOR_CMD,
    "D:\\cursor\\resources\\app\\bin\\cursor.cmd",
    path.join(
      process.env.LOCALAPPDATA ?? "",
      "Programs",
      "cursor",
      "resources",
      "app",
      "bin",
      "cursor.cmd",
    ),
    "cursor.cmd",
    "cursor",
  ].filter(Boolean) as string[];
  for (const c of candidates) {
    if (c === "cursor" || c === "cursor.cmd") return c;
    if (fs.existsSync(c)) return c;
  }
  return null;
}

function findCodexCmd(): string | null {
  const candidates = [
    process.env.CODEX_CMD,
    "codex.cmd",
    "codex",
  ].filter(Boolean) as string[];
  for (const c of candidates) {
    if (c === "codex" || c === "codex.cmd") return c;
    if (fs.existsSync(c)) return c;
  }
  return null;
}

/** 在 PC 打开 IDE 工作区（新窗口，不强制复用当前窗口） */
export function openIdeWorkspace(
  ide: Ide | string,
  workspace: string,
): { ok: boolean; detail: string } {
  const target = path.resolve(workspace.trim());
  if (!fs.existsSync(target)) {
    return { ok: false, detail: `路径不存在: ${target}` };
  }

  const kind = String(ide).toLowerCase();
  try {
    if (kind === "codex") {
      const codex = findCodexCmd();
      if (codex) {
        spawn(codex, [target], {
          detached: true,
          stdio: "ignore",
          shell: true,
          windowsHide: true,
          cwd: target,
        }).unref();
        return { ok: true, detail: `已启动 Codex: ${target}` };
      }
      return {
        ok: true,
        detail: `未找到 Codex CLI，将仅启动桥接注册: ${target}`,
      };
    }

    // cursor / 其他：优先用 Cursor 打开目录
    const cursor = findCursorCmd();
    if (!cursor) {
      return { ok: false, detail: "未找到 Cursor 可执行文件" };
    }
    spawn(cursor, [target], {
      detached: true,
      stdio: "ignore",
      shell: true,
      windowsHide: true,
    }).unref();
    return { ok: true, detail: `已用 Cursor 打开: ${target}` };
  } catch (err) {
    return {
      ok: false,
      detail: err instanceof Error ? err.message : String(err),
    };
  }
}

/**
 * 为新工作区拉起独立 bridge，使手机立刻能刷到该项目在线
 *（不依赖 Cursor 桌面是否已加载 MCP）
 */
export function startBridgeForWorkspace(opts: {
  ide: Ide | string;
  workspace: string;
  serverUrl: string;
  token: string;
}): { ok: boolean; detail: string } {
  const workspace = path.resolve(opts.workspace.trim());
  const here = path.dirname(fileURLToPath(import.meta.url));
  const bridgeJs = path.join(here, "bridge.js");
  if (!fs.existsSync(bridgeJs)) {
    return { ok: false, detail: `bridge.js 不存在: ${bridgeJs}` };
  }
  const ide =
    String(opts.ide).toLowerCase() === "codex" ? "codex" : "cursor";
  try {
    spawn(process.execPath, [bridgeJs], {
      detached: true,
      stdio: "ignore",
      windowsHide: true,
      env: {
        ...process.env,
        CODEASSIST_SERVER_URL: opts.serverUrl,
        CODEASSIST_TOKEN: opts.token,
        CODEASSIST_IDE: ide,
        CODEASSIST_WORKSPACE: workspace,
        CODEASSIST_PROJECT_NAME: path.basename(workspace) || "project",
      },
    }).unref();
    return { ok: true, detail: `已启动 ${ide} bridge: ${workspace}` };
  } catch (err) {
    return {
      ok: false,
      detail: err instanceof Error ? err.message : String(err),
    };
  }
}
