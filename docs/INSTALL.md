# CodeAssist 完整安装与使用说明（给 AI / 给用户）

> 本文档供 **Cursor** 或 **Codex** 中的 AI **直接阅读并逐步执行**。  
> 目标：在内网 PC 上启动中继 → 配置 MCP →（可选）打包 Android → 手机可远程操控 Cursor/Codex。  
> 仓库说明：[中文 README](../README.md) · [English README](../README.en.md)

---

## 给用户的一句话 Prompt（复制发给 AI）

把下面整段复制到 Cursor 或 Codex 对话里即可：

```text
请完整阅读本仓库 docs/INSTALL.md，并按文档逐步完成本机 CodeAssist 部署：
1) 安装依赖并 build；2) 在本机内网启动中继服务（0.0.0.0:8787）；
3) 按我正在用的 IDE（Cursor 或 Codex）写好/合并 MCP 配置并说明如何重载；
4) 安装 Cursor Agent CLI（若本机是 Cursor）；5) 写入/确认 Agent 规则；
6) 用 flutter 打 Android release APK，并告诉我 APK 路径、本机局域网 IP、手机里要填的 Server URL 与 Token；
7) 用中文给出「怎么用手机远程发指令」的简短说明。
不要跳过步骤；遇到路径/环境差异先探测本机再改配置。改完相关配置后告诉我需要我手动点哪些按钮（如重载 MCP）。
```

---

## 0. 系统是什么

| 组件 | 作用 |
|------|------|
| **中继服务** `packages/server` | 内网 HTTP + WebSocket + SQLite，手机与 IDE 都连它 |
| **MCP Server** `packages/mcp-server` | 挂在 Cursor / Codex 里，注册项目、拉手机指令、回传结果、发文件到手机 |
| **Flutter 客户端** `mobile` | Android（及 iOS/鸿蒙）App，选项目、按 Session 对话、收结果/文件 |

架构：`手机 App` ↔ `中继(8787)` ↔ `MCP(在 IDE 进程内)` ↔ `Cursor/Codex Agent`

---

## 1. 环境要求（AI 先检查）

在仓库根目录执行探测（Windows PowerShell 示例）：

```powershell
node -v          # 需要 >= 18
npm -v
flutter --version  # 若要打包安卓则需要
```

- **必装**：Node.js 18+、npm  
- **打包安卓**：Flutter SDK + Android SDK  
- **Cursor 用户**：建议安装 Cursor Agent CLI（手机发指令时由 MCP 拉起真实执行）  
- **网络**：手机与 PC 同一局域网；防火墙放行 TCP `8787`

仓库根目录（请按本机实际路径替换，下文用 `<REPO>` 表示）：

- 示例：`D:\androidproject\CodeAssit`

---

## 2. 安装依赖并编译

```powershell
cd <REPO>
npm install
npm run build
```

成功应生成：

- `packages/server/dist/`
- `packages/mcp-server/dist/`
- `packages/mcp-server/run.mjs`（Cursor 推荐用这个启动器）

---

## 3. 启动内网中继服务

### 3.1 启动命令

```powershell
cd <REPO>
$env:ACCESS_TOKEN="codeassist-dev-token"   # 可改成自己的强口令
$env:HOST="0.0.0.0"                        # 必须监听全网卡，手机才能连
$env:PORT="8787"
npm run start:server
```

健康检查：

```powershell
Invoke-RestMethod http://127.0.0.1:8787/health
# 期望：{ ok: true }
```

### 3.2 查本机局域网 IP（给手机填）

```powershell
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
  Select-Object IPAddress, InterfaceAlias
```

记下形如 `192.168.x.x` 的地址。手机 Server URL 填：

```text
http://192.168.x.x:8787
```

Token 与 `ACCESS_TOKEN` 一致（默认 `codeassist-dev-token`）。

### 3.3 防火墙（若手机连不上）

Windows 放行入站 TCP 8787（管理员 PowerShell）：

```powershell
New-NetFirewallRule -DisplayName "CodeAssist Relay 8787" -Direction Inbound -Protocol TCP -LocalPort 8787 -Action Allow
```

### 3.4 环境变量（中继）

| 变量 | 默认 | 说明 |
|------|------|------|
| `PORT` | `8787` | 端口 |
| `HOST` | `0.0.0.0` | 内网访问务必 `0.0.0.0` |
| `ACCESS_TOKEN` | `codeassist-dev-token` | Bearer Token |
| `DATA_DIR` | `./data` | SQLite 数据目录 |
| `OFFLINE_MS` | `120000` | 超时判离线 |

---

## 4. 配置 Cursor MCP

### 4.1 写入 MCP 配置

参考：`configs/cursor-mcp.example.json`  

合并到以下之一（以你本机 Cursor 实际配置为准）：

- 项目：`<REPO>/.cursor/mcp.json`
- 或用户全局：`%USERPROFILE%\.cursor\mcp.json`

**推荐配置模板**（把路径改成绝对路径；Node 也可用绝对路径）：

```json
{
  "mcpServers": {
    "codeassist": {
      "command": "node",
      "args": ["D:/androidproject/CodeAssit/packages/mcp-server/run.mjs"],
      "env": {
        "CODEASSIST_SERVER_URL": "http://127.0.0.1:8787",
        "CODEASSIST_TOKEN": "codeassist-dev-token",
        "CODEASSIST_IDE": "cursor",
        "CODEASSIST_WORKSPACE": "${workspaceFolder}",
        "CODEASSIST_MCP_BUILD": "0.3.3"
      }
    }
  }
}
```

说明：

- `CODEASSIST_TOKEN` 必须与中继 `ACCESS_TOKEN` 相同  
- `CODEASSIST_WORKSPACE` 用 `${workspaceFolder}`；若 Cursor **未展开**该变量，MCP 会回退用真实工作区路径，**不要**再写死 `CODEASSIST_PROJECT_NAME=${workspaceFolderBasename}`（未展开会变成字面量项目名）  
- 改完后把 `CODEASSIST_MCP_BUILD` 数字 +1，有助于 Cursor 强制重启 MCP 进程  

### 4.2 安装 Cursor Agent CLI（强烈推荐）

手机发指令时，MCP 会拉起 Agent 真实改代码：

```powershell
irm https://cursor.com/install?win32=true | iex
agent login
agent status
```

可选：在 mcp.json 的 `env` 增加：

```json
"CODEASSIST_AGENT_CMD": "C:\\Users\\<你>\\AppData\\Local\\cursor-agent\\agent.cmd"
```

### 4.3 写入 Agent 规则

把 `configs/agent-rule.example.md` 或本仓库 `.cursor/rules/codeassist.mdc` 作为项目规则启用（Always Apply），保证 Agent：

1. 开头 `get_pending_prompts`  
2. `ack` → 执行 → `complete_prompt` / `sync_session_context`  
3. 需要时 `send_file_to_client` 把文件发到手机  

### 4.4 重载 MCP

1. Cursor Settings → MCP → `codeassist` → **Reload**  
2. 仍无新工具：先 Disable 再 Enable，或重启 Cursor  
3. 打开本仓库工作区后，应能看到工具例如：  
   `register_project`、`get_pending_prompts`、`ack_prompt`、`complete_prompt`、`sync_session_context`、`report_task`、`send_file_to_client`  

让 AI 在对话里调用一次 `register_project`，手机端应出现该项目且为 **在线**。

---

## 5. 配置 Codex MCP

参考：`configs/codex-mcp.example.toml`  

按本机 Codex 配置文件格式合并，例如：

```toml
[mcp_servers.codeassist]
command = "node"
args = ["D:/androidproject/CodeAssit/packages/mcp-server/run.mjs"]

[mcp_servers.codeassist.env]
CODEASSIST_SERVER_URL = "http://127.0.0.1:8787"
CODEASSIST_TOKEN = "codeassist-dev-token"
CODEASSIST_IDE = "codex"
CODEASSIST_WORKSPACE = "."
```

- `CODEASSIST_IDE` 必须为 `codex`  
- 工作区路径用 Codex 当前项目根目录（绝对路径更稳）  
- 同样需要中继已启动、Token 一致  
- 将 `configs/agent-rule.example.md` 并入 Codex instructions  

重启 / 重载 Codex MCP 后调用 `register_project` 验收。

---

## 6. 打包 Android APK

```powershell
cd <REPO>\mobile
flutter pub get
flutter build apk --release
```

产物：

```text
<REPO>\mobile\build\app\outputs\flutter-apk\app-release.apk
```

安装到手机后：

1. 打开 App → 设置  
2. **Server URL**：`http://<PC局域网IP>:8787`  
3. **Token**：与中继相同  
4. 保存并连接  

模拟器可用 `http://10.0.2.2:8787`。

---

## 7. 怎么用（用户操作手册）

### 7.1 每次开工顺序

1. PC 启动中继（第 3 节）  
2. 打开 Cursor/Codex，确认 MCP `codeassist` 已连接，项目在手机显示 **在线**  
3. 手机连上同一内网中继  

### 7.2 手机远程发指令（主流程）

1. 打开 App 首页（Prompt 对话）  
2. 右上角选择要操控的 **Cursor/Codex 项目**  
3. 顶部可切换 / **新建 Session**（新 Session ≈ Cursor 侧新会话上下文）  
4. 输入指令发送  
5. PC 侧 MCP 自动拉取并用 Agent 执行  
6. 结果回传到同一会话气泡；上下文条会显示执行状态  

### 7.3 常见能力

| 能力 | 说明 |
|------|------|
| 多项目 | 多个 IDE 窗口各自注册；手机切换项目 |
| 多 Session | 每项目多个对话，互不串上下文 |
| 电脑→手机文件 | IDE 里让 AI 调 `send_file_to_client` |
| 手机→电脑图文 | 客户端发送附件后，Agent 按规则处理 |

### 7.4 验收清单

- [ ] `http://127.0.0.1:8787/health` 正常  
- [ ] 手机能连 `http://<局域网IP>:8787`  
- [ ] MCP 工具列表含 `send_file_to_client` 等  
- [ ] 手机项目显示在线且名称是文件夹名（不是 `${workspaceFolderBasename}`）  
- [ ] 手机发「你好」→ PC 执行 → 手机看到结果  

---

## 8. 故障排查

| 现象 | 处理 |
|------|------|
| 手机连不上 | 检查 HOST=0.0.0.0、防火墙、IP、Token |
| 项目离线 | IDE 是否打开、MCP 是否 Reload、中继是否在跑 |
| 项目名是 `${...}` | 去掉 mcp.json 里的 `CODEASSIST_PROJECT_NAME` 占位符，Reload，再 `register_project` |
| 发了指令无结果 | `agent login`；看 MCP 日志；确认未设 `CODEASSIST_DISABLE_AGENT_SPAWN=1` |
| 新 MCP 工具不出现 | `CODEASSIST_MCP_BUILD` +1 → Reload；或禁用再启用；或重启 IDE |
| 改了 TS 不生效 | 必须 `npm run build -w @codeassist/mcp-server`（跑的是 `dist/`） |

---

## 9. AI 执行时的硬性要求

1. **先探测**本机仓库绝对路径、Node、Flutter、局域网 IP，再改配置，禁止写死别人的盘符不核对。  
2. 中继必须 `HOST=0.0.0.0`，否则真机无法访问。  
3. MCP 的 Token 与中继必须一致。  
4. 编译 MCP/中继后若用户说「工具没有」，指导其 **Reload MCP** 并 bump `CODEASSIST_MCP_BUILD`。  
5. 打完 APK 明确回复：**路径、局域网 IP、URL、Token、下一步点哪里**。  
6. 全程用**中文**向用户汇报。  

---

## 10. 相关文件索引

| 路径 | 用途 |
|------|------|
| `docs/INSTALL.md` | 本文 |
| `README.md` | 总览 |
| `configs/cursor-mcp.example.json` | Cursor MCP 示例 |
| `configs/codex-mcp.example.toml` | Codex MCP 示例 |
| `configs/agent-rule.example.md` | Agent 规则示例 |
| `.cursor/rules/codeassist.mdc` | 本仓库 Cursor 规则 |
| `packages/mcp-server/run.mjs` | MCP 启动器 |
| `mobile/` | Flutter 客户端 |
