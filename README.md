# CodeAssist

[English](README.en.md) | 中文

## 这是什么

> **打通 AI 工具的最后一公里（PC → 手机）**

**CodeAssist 是一款辅助 App：让你随时随地连接家里 / 公司电脑上的 Cursor 或 Codex，继续写代码、下指令、看结果。**

不用守在电脑前——手机打开 App，选中在线的 Cursor/Codex 项目，像平时在 IDE 里发 Prompt 一样远程编程；PC 侧真实执行，结果同步回手机。

技术组成（内网）：**Flutter 客户端** + **中继服务** + **MCP（挂在 Cursor / Codex）**。

```
手机 App  ←→  中继 :8787  ←→  MCP（IDE 内）  ←→  Cursor / Codex Agent
```

---

## 给新用户 / 给 AI 的一句话 Prompt

把下面整段复制到 **Cursor** 或 **Codex** 对话里，让 AI 按文档自动部署：

```text
请完整阅读本仓库 docs/INSTALL.md 与 README.md，并按文档逐步完成本机 CodeAssist 部署：
1) 安装依赖并 build；2) 在本机内网启动中继服务（HOST=0.0.0.0, PORT=8787）；
3) 按我正在用的 IDE（Cursor 或 Codex）写好/合并 MCP 配置并说明如何重载；
4) 安装 Cursor Agent CLI（若本机是 Cursor）并 agent login；5) 写入/确认 Agent 规则；
6) 用 flutter 打 Android release APK，并告诉我 APK 路径、本机局域网 IP、手机里要填的 Server URL 与 Token；
7) 用中文给出「怎么用手机远程发指令」的简短说明。
不要跳过步骤；遇到路径/环境差异先探测本机再改配置。改完后告诉我需要手动点哪些按钮（如重载 MCP）。
```

**逐步安装、排障、验收 → [`docs/INSTALL.md`](docs/INSTALL.md)**  
**English README → [`README.en.md`](README.en.md)**

---

## 功能一览

| 能力 | 说明 |
|------|------|
| 远程 Prompt | 手机按「项目 + Session」发指令，PC Agent 执行并回传结果 |
| 多项目 | 多个 Cursor/Codex 工作区同时在线，手机切换选择 |
| 多 Session | 每项目多个对话；新建 Session 对应 Cursor 侧新上下文 |
| 会话上下文 | 对话内展示当前执行状态 / 摘要 |
| 文件互通 | PC→手机：`send_file_to_client`；手机→PC：对话附件 |
| 任务上报 | Agent `report_task`，可选手机审批（approve/reject） |

---

## 仓库结构

```
packages/shared         共享协议（Zod）
packages/server         中继：REST + WebSocket + SQLite
packages/mcp-server     Cursor / Codex MCP Server
mobile/                 Flutter 客户端
configs/                MCP / Agent 规则示例
docs/INSTALL.md         完整安装说明（推荐 AI 阅读）
docs/harmonyos.md       鸿蒙构建说明
.cursor/rules/          本仓库 Cursor Agent 规则
```

---

## 环境要求

| 项目 | 要求 |
|------|------|
| Node.js | ≥ 18 |
| 打包 Android | Flutter + Android SDK |
| Cursor | 建议安装 [Cursor Agent CLI](https://cursor.com/install) 并 `agent login` |
| 网络 | 手机与 PC 同一局域网；防火墙放行 TCP **8787** |

---

## 1. 安装依赖并编译

```powershell
cd <REPO>   # 例如 D:\androidproject\CodeAssit
npm install
npm run build
```

---

## 2. 启动内网中继

```powershell
cd <REPO>
$env:ACCESS_TOKEN="codeassist-dev-token"   # 可改成自己的口令
$env:HOST="0.0.0.0"                        # 必须，否则真机连不上
$env:PORT="8787"
npm run start:server
```

- 健康检查：`http://127.0.0.1:8787/health` → `{ "ok": true }`
- 查局域网 IP（给手机填）：

```powershell
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike '127.*' } |
  Select-Object IPAddress, InterfaceAlias
```

手机 Server URL：`http://192.168.x.x:8787`  
Token：与 `ACCESS_TOKEN` 相同（默认 `codeassist-dev-token`）。

### 中继环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `PORT` | `8787` | HTTP/WS 端口 |
| `HOST` | `0.0.0.0` | 内网访问务必全网卡 |
| `ACCESS_TOKEN` | `codeassist-dev-token` | Bearer Token |
| `DATA_DIR` | `./data` | SQLite 目录 |
| `OFFLINE_MS` | `120000` | 项目离线判定 |

---

## 3. 配置 Cursor MCP

1. 参考 [`configs/cursor-mcp.example.json`](configs/cursor-mcp.example.json)  
2. 合并到项目 `.cursor/mcp.json` 或用户 `%USERPROFILE%\.cursor\mcp.json`  
3. 把 `args` 改成你本机 `packages/mcp-server/run.mjs` 的**绝对路径**  
4. `CODEASSIST_TOKEN` 与中继一致；`CODEASSIST_IDE=cursor`  
5. 使用 `CODEASSIST_WORKSPACE=${workspaceFolder}`；**不要**写死未展开的 `${workspaceFolderBasename}` 作为项目名  
6. 改配置后将 `CODEASSIST_MCP_BUILD` 数字 +1，在 Cursor 里 **Reload** MCP  

可选 Agent CLI 路径：

```json
"CODEASSIST_AGENT_CMD": "C:\\Users\\<你>\\AppData\\Local\\cursor-agent\\agent.cmd"
```

安装 CLI：

```powershell
irm https://cursor.com/install?win32=true | iex
agent login
```

启用规则：[`configs/agent-rule.example.md`](configs/agent-rule.example.md) 或 `.cursor/rules/codeassist.mdc`。

---

## 4. 配置 Codex MCP

参考 [`configs/codex-mcp.example.toml`](configs/codex-mcp.example.toml)：

- `CODEASSIST_IDE=codex`
- Token / Server URL 与中继一致
- 工作区建议填绝对路径
- 同样写入 Agent 规则并重载 MCP

---

## 5. MCP 工具

| Tool | 作用 |
|------|------|
| `register_project` | 注册/刷新当前工作区到中继 |
| `get_pending_prompts` | 拉取手机指令并执行 |
| `ack_prompt` / `complete_prompt` | 回写执行中 / 完成结果 |
| `sync_session_context` | 同步会话摘要到手机对话 |
| `report_task` | 上报任务（可要求手机审批） |
| `get_pending_decisions` | 拉取 approve/reject |
| `send_file_to_client` | 把本机文件发到手机对话 |

手机一点发送时，MCP（live-pull）也会自动拉取并拉起 Agent；规则里仍要求每轮主动 `get_pending_prompts`。

---

## 6. Flutter 客户端

```powershell
cd <REPO>\mobile
flutter pub get
flutter run
# 或打正式包：
flutter build apk --release
```

产物：`mobile\build\app\outputs\flutter-apk\app-release.apk`

| 场景 | Server URL |
|------|------------|
| 真机（同一局域网） | `http://<电脑局域网IP>:8787` |
| Android 模拟器 | `http://10.0.2.2:8787` |
| iOS 模拟器 | `http://127.0.0.1:8787` |

鸿蒙：见 [`docs/harmonyos.md`](docs/harmonyos.md)。

### 客户端怎么用

1. 设置里填 Server URL + Token 并连接  
2. 首页对话：右上角选 **在线项目**  
3. 顶部切换 / **新建 Session**  
4. 输入指令发送 → 等 PC 执行 → 气泡里看结果  
5. 可下载 PC 发来的附件  

---

## 7. 验收清单

- [ ] `health` 正常，中继 `HOST=0.0.0.0`  
- [ ] 手机能访问 `http://<局域网IP>:8787`  
- [ ] MCP 已 Reload，工具列表含 `send_file_to_client` 等  
- [ ] 手机项目在线，名称是文件夹名（不是 `${...}`）  
- [ ] 手机发一条指令 → PC 执行 → 手机看到结果  

---

## 8. 常见问题

| 现象 | 处理 |
|------|------|
| 手机连不上 | 检查 HOST、防火墙 8787、IP、Token |
| 项目离线 | IDE/MCP 是否开启、中继是否在跑 |
| 项目名是 `${workspaceFolderBasename}` | 去掉该 env，Reload，再 `register_project` |
| 指令无结果 | `agent login`；确认未禁用 Agent 拉起 |
| 新工具不出现 | `CODEASSIST_MCP_BUILD`+1 → Reload；或重启 IDE |
| 改 TS 不生效 | `npm run build`（运行的是 `dist/`） |

更全说明：[`docs/INSTALL.md`](docs/INSTALL.md)。

---

## 许可与贡献

本项目采用 [Apache License 2.0](LICENSE) 开源协议。  
Copyright 2026 TimeCyber  

问题与改进欢迎提 Issue / PR：<https://github.com/TimeCyber/24HCode>
