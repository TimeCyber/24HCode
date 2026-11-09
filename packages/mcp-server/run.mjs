#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
// Launcher: change this file path in mcp.json to force Cursor to respawn MCP.
const deviceEnv = path.join(path.dirname(fileURLToPath(import.meta.url)), ".codeassist-device.env");
// Explicit MCP relay settings are an intentional credential pair. Never mix
// one of them with the paired cloud device token from the local file.
const hasExplicitRelayConfig = Boolean(
  process.env.CODEASSIST_SERVER_URL?.trim() ||
  process.env.CODEASSIST_TOKEN?.trim(),
);
try {
  if (hasExplicitRelayConfig) {
    console.error(
      `[codeassist-mcp] using explicitly configured relay ${process.env.CODEASSIST_SERVER_URL || "http://127.0.0.1:8787"}; paired credentials ignored`,
    );
  } else {
    const contents = fs.readFileSync(deviceEnv, "utf8").replace(/^\uFEFF/, "");
    const pairedEnv = {};
    for (const row of contents.split(/\r?\n/)) {
      const line = row.trim();
      if (!line || line.startsWith("#")) continue;
      const split = line.indexOf("=");
      if (split > 0) pairedEnv[line.slice(0, split).trim()] = line.slice(split + 1).trim();
    }
    if (pairedEnv.CODEASSIST_SERVER_URL && pairedEnv.CODEASSIST_TOKEN) {
      process.env.CODEASSIST_SERVER_URL = pairedEnv.CODEASSIST_SERVER_URL;
      process.env.CODEASSIST_TOKEN = pairedEnv.CODEASSIST_TOKEN;
      console.error(`[codeassist-mcp] using paired relay ${process.env.CODEASSIST_SERVER_URL}`);
    }
  }
} catch (error) {
  if (error?.code !== "ENOENT") throw error;
}
console.error(
  `[codeassist-mcp] launcher v0.3.7 cwd=${process.cwd()} workspace=${process.env.CODEASSIST_WORKSPACE || ""}`,
);
await import("./dist/index.js");
