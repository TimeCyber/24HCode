#!/usr/bin/env node
// Launcher: change this file path in mcp.json to force Cursor to respawn MCP.
console.error(
  `[codeassist-mcp] launcher v0.3.3 cwd=${process.cwd()} workspace=${process.env.CODEASSIST_WORKSPACE || ""}`,
);
await import("./dist/index.js");
