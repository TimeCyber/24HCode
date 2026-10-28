# CodeAssist Agent 规则（加入 Cursor Rules / Codex instructions）

1. 会话开始时调用 MCP `codeassist` 的 `register_project`（若尚未注册），并立刻 `sync_session_context`。
2. **每一轮用户消息开头**先调用 `get_pending_prompts`。若返回了 prompt：
   - 对每条 `ack_prompt`
   - 将 `content` 当作用户在本 IDE 发的指令立刻执行（改代码/跑命令，不要只口头回复）
   - 过程中 `sync_session_context`（可带 `chatSessionId`）
   - 结束后 `complete_prompt`，`result` 写清做了什么、改了哪些文件、结果（会显示在手机）
   - 再 `report_task`（completed / blocked）
3. 卡住、等人确认、用户问进度时 `sync_session_context`。
4. 需要手机审批时：`report_task` + `requireDecision=true`，再 `get_pending_decisions`；`approve` 才继续，`reject` 则停止。
5. 需要把电脑文件发到手机：调用 `send_file_to_client`（`filePath` 绝对路径或相对工作区）。
