# PC 执行状态与手机确认

CodeAssist 托管的 Codex 任务通过 `codex app-server --listen stdio://` 执行。该进程的 JSON-RPC 连接负责接收进度、确认请求并将手机答复发送回原请求。协议参考：[OpenAI App Server](https://learn.chatgpt.com/docs/app-server)。

## 使用

- 执行状态、当前步骤和待确认内容按时间插入聊天记录，不使用顶部状态条。同一步骤的连续输出更新原消息，新步骤新增消息；已接收的进度按账号和会话在本机保存。
- 需要确认时显示命令、目录、文件或申请权限；问题支持选项和文字回答。
- “更多 → 任务与确认”可以查看其他项目的确认请求和历史任务。
- 原生命令和文件确认只发送本次 `accept` / `decline`；临时权限仅限当前 turn，不写永久放行规则。
- 默认确认有效期 10 分钟。超时、任务取消或连接结束会关闭请求；未收到明确同意不会执行所申请的操作。
- WebSocket 不可用时，PC 通过非消费式任务状态查询读取答复，手机在前台通过 HTTP 获取状态。不会拉走 Agent 的其他待办确认。
- 前台定时查询只获取待确认任务和状态，不反复下载完整任务历史；任务页下拉刷新可加载历史。问题答复连同结构化字段合计最多 1000 个字符，兼容当前云端字段限制。
- 默认沿用当前 Codex 模型配置，可用 `CODEASSIST_CODEX_MODEL` 明确覆盖。CLI 优先选用桌面当前运行版本，独立桥接按安装文件时间选择，避免按哈希目录名误选旧版本。

## 桌面正在运行的会话

桌面会话可使用 `sync_session_context` 同步步骤，使用 `request_client_decision` 等待手机用户确认功能选择或操作意图。仓库 AGENTS.md 已加入使用要求。`request_client_decision` 不授予原生沙箱权限，也不能代答本地 IDE/Codex 宿主在 MCP 工具执行前弹出的审批。

CodeAssist 托管的 Codex App Server 任务会把 App Server 发出的命令、文件变更、临时权限和 `tool/requestUserInput` 确认转发到手机客户端，再将答复回复给原请求；MCP App 的副作用调用确认也通过 `tool/requestUserInput` 进入该流程。若本地宿主在启动 MCP 工具处理函数前拒绝调用（例如返回 `user rejected MCP tool call`），请求没有到达本桥接，无法再转交手机审批。

独立桌面实例已经弹出的原生审批框，尚不能由本桥接代答。会话列表同步也不代表已订阅该实例的执行事件。不要为观察正在运行的会话另起写入者；托管执行会拒绝向活动会话注入新任务。

## 启用更新

1. 仓库根目录执行 `npm run build`。
2. 执行 `powershell -ExecutionPolicy Bypass -File scripts/configure-codex-confirmation.ps1`，将 CodeAssist MCP 工具等待时间设为 1260 秒。脚本备份原配置，不输出凭据。
3. 重启使用旧代码的 CodeAssist bridge，并重载 MCP / 重启 Codex。当前已经启动的 MCP 进程不会自动替换内存中的代码。
4. 安装新版手机客户端。

云端无需增加字段或接口：结构化请求存放在原有任务 detail 中，带 `CODEASSIST_REMOTE_REQUEST_V1` 标记；原有同意/拒绝接口承载结果。旧客户端可看到原始详情，但新版客户端提供完整展示、回答和过期控制。云端任务状态只代表用户答复；请求是否仍有效、是否向 Codex 发回结果由持有原请求的 PC 进程判断。PC 崩溃期间的旧请求到期后不能恢复授权，需重新发起。

敏感输入不会经手机表单转发。未支持的 MCP URL/form elicitation 等请求会返回错误并停止相应操作，不能默认为同意。

## 验证

`npm run test -w @codeassist/mcp-server` 覆盖真实子进程 JSON-RPC 的同意、拒绝、文件确认、问题回答、连接中断、活动会话保护，以及确认超时、取消和非消费式查询。

`flutter test --no-pub test/remote_request_test.dart test/client_update_policy_test.dart` 验证请求解析、过期禁用、问题必填与结构化答案，以及历史通知去重和项目排序。
