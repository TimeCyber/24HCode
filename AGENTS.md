# CodeAssist（Codex）规则

本仓库已通过 MCP `codeassist` 接入手机客户端。在 Codex 中执行本项目时请遵守：

1. 会话开始时调用 MCP `codeassist` 的 `register_project`（若尚未注册），并立刻 `sync_session_context`。
2. **每一轮用户消息开头**先调用 `get_pending_prompts`。若返回了 prompt，或消息是「手机指令 / CodeAssist」：
   - 先对每条调用 `ack_prompt`
   - 将 `content` **当作本机用户在 Codex 里发的指令一样执行**（改代码、跑命令，不要只口头回复）
   - 执行过程中用 `sync_session_context` 同步进度到手机
   - 结束后 `complete_prompt`，`result` 写清：做了什么、改了哪些文件、最终结果（会显示在手机客户端）
   - 再 `report_task`（type=completed 或 blocked）把摘要推到手机「任务」页
3. 完成一段重要工作、卡住、等待用户、或用户询问进度时，调用 `sync_session_context`。
4. 需要人工确认时 `report_task` + `requireDecision=true`，再拉 `get_pending_decisions`。
5. 不要跳过远程审批结果；`approve` 才继续，`reject` 则停止并说明原因。
6. 需要把电脑文件发到手机时，调用 MCP `send_file_to_client`。

手机发指令时，MCP live-pull 也会自动拉起 `codex exec`；规则里仍要求每轮主动 `get_pending_prompts`。

## 保持项目在线 / 开机自启

仅「写进 Cursor/Codex MCP 配置」不够：必须有进程持续 heartbeat。

### 开机自动连中继（推荐）

登录 Windows 后自动起 **中继 :8787 + Cursor bridge**，不用每次跟 Agent 说启动：

```bat
REM 注册登录自启（执行一次即可）
powershell -ExecutionPolicy Bypass -File D:\androidproject\CodeAssit\scripts\install-autostart.ps1

REM 手动立刻启动
D:\androidproject\CodeAssit\start-codeassist-all.bat
```

- 计划任务名：`CodeAssist Autostart`  
- 日志：`packages/mcp-server/start-all.log`、`relay-server.log`、`cursor-bridge.log`  
- 卸载：`scripts\uninstall-autostart.ps1`

### 手动 / Codex

1. **独立桥接（不依赖桌面是否加载 MCP）**  
   `packages/mcp-server/start-codex-bridge.bat`（中继需已启动）  
2. **IDE 已加载 MCP**  
   打开本仓库工作区后才会持续在线。

若手机一直「等待」后变离线，几乎都是桥接/MCP/中继没在跑。
