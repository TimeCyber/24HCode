# CodeAssist

English | [中文](README.md)

## What it is

**CodeAssist is a companion app that lets you connect to Cursor or Codex on your PC anytime, anywhere—and keep coding.**

You don’t have to sit at the desk. Open the app on your phone, pick an online Cursor/Codex project, and send prompts just like in the IDE. The PC agent actually runs the work; results sync back to your phone.

Under the hood (LAN): **Flutter client** + **relay server** + **MCP (inside Cursor / Codex)**.

```
Phone App  ←→  Relay :8787  ←→  MCP (inside IDE)  ←→  Cursor / Codex Agent
```

---

## One-shot prompt for new users / AI

Paste this into a **Cursor** or **Codex** chat so the agent can deploy for you:

```text
Please read docs/INSTALL.md and README.en.md in this repo, then complete CodeAssist setup on this machine step by step:
1) Install dependencies and build; 2) Start the relay on the LAN (HOST=0.0.0.0, PORT=8787);
3) Write/merge MCP config for the IDE I am using (Cursor or Codex) and tell me how to reload;
4) Install Cursor Agent CLI (if using Cursor) and run agent login; 5) Add/confirm Agent rules;
6) Build a Flutter Android release APK and tell me the APK path, this PC's LAN IP, and the Server URL + Token for the phone;
7) Briefly explain in English how to send remote prompts from the phone.
Do not skip steps; probe local paths/environment before editing configs. After changes, tell me which buttons I must click manually (e.g. Reload MCP).
```

**Full install / troubleshooting / checklist → [`docs/INSTALL.md`](docs/INSTALL.md)** (Chinese; same steps)  
**Chinese README → [`README.md`](README.md)**

---

## Features

| Feature | Description |
|---------|-------------|
| Remote prompts | Phone chats per **project + session**; PC agent runs and returns results |
| Multi-project | Multiple Cursor/Codex workspaces online; switch on the phone |
| Multi-session | Several chats per project; “new session” ≈ new Cursor chat context |
| Session context | Live status / summary shown inside the conversation |
| File transfer | PC→phone: `send_file_to_client`; phone→PC: chat attachments |
| Task reports | Agent `report_task`, optional phone approve/reject |

---

## Repository layout

```
packages/shared         Shared protocol (Zod)
packages/server         Relay: REST + WebSocket + SQLite
packages/mcp-server     Cursor / Codex MCP server
mobile/                 Flutter client
configs/                MCP / agent rule examples
docs/INSTALL.md         Full install guide (recommended for AI)
docs/harmonyos.md       HarmonyOS build notes
.cursor/rules/          Cursor agent rules for this repo
```

---

## Requirements

| Item | Requirement |
|------|-------------|
| Node.js | ≥ 18 |
| Android build | Flutter + Android SDK |
| Cursor | Install [Cursor Agent CLI](https://cursor.com/install) and `agent login` (recommended) |
| Network | Phone and PC on the same LAN; allow TCP **8787** |

---

## 1. Install and build

```powershell
cd <REPO>   # e.g. D:\androidproject\CodeAssit
npm install
npm run build
```

---

## 2. Start the LAN relay

```powershell
cd <REPO>
$env:ACCESS_TOKEN="codeassist-dev-token"   # change for production
$env:HOST="0.0.0.0"                        # required for real devices
$env:PORT="8787"
npm run start:server
```

- Health: `http://127.0.0.1:8787/health` → `{ "ok": true }`
- Find LAN IP (for the phone):

```powershell
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike '127.*' } |
  Select-Object IPAddress, InterfaceAlias
```

Phone Server URL: `http://192.168.x.x:8787`  
Token: same as `ACCESS_TOKEN` (default `codeassist-dev-token`).

### Relay environment variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `PORT` | `8787` | HTTP/WS port |
| `HOST` | `0.0.0.0` | Bind all interfaces for LAN |
| `ACCESS_TOKEN` | `codeassist-dev-token` | Bearer token |
| `DATA_DIR` | `./data` | SQLite directory |
| `OFFLINE_MS` | `120000` | Offline threshold |

---

## 3. Configure Cursor MCP

1. See [`configs/cursor-mcp.example.json`](configs/cursor-mcp.example.json)  
2. Merge into project `.cursor/mcp.json` or user `%USERPROFILE%\.cursor\mcp.json`  
3. Set `args` to the **absolute path** of `packages/mcp-server/run.mjs`  
4. `CODEASSIST_TOKEN` must match the relay; `CODEASSIST_IDE=cursor`  
5. Use `CODEASSIST_WORKSPACE=${workspaceFolder}`; **do not** set project name to an unresolved `${workspaceFolderBasename}`  
6. Bump `CODEASSIST_MCP_BUILD` after edits, then **Reload** MCP in Cursor  

Optional:

```json
"CODEASSIST_AGENT_CMD": "C:\\Users\\<you>\\AppData\\Local\\cursor-agent\\agent.cmd"
```

Install CLI:

```powershell
irm https://cursor.com/install?win32=true | iex
agent login
```

Enable rules: [`configs/agent-rule.example.md`](configs/agent-rule.example.md) or `.cursor/rules/codeassist.mdc`.

---

## 4. Configure Codex MCP

See [`configs/codex-mcp.example.toml`](configs/codex-mcp.example.toml):

- `CODEASSIST_IDE=codex`
- Token / server URL must match the relay
- Prefer an absolute workspace path
- Add the same agent rules and reload MCP

---

## 5. MCP tools

| Tool | Purpose |
|------|---------|
| `register_project` | Register / refresh workspace on the relay |
| `get_pending_prompts` | Pull phone prompts and execute them |
| `ack_prompt` / `complete_prompt` | Mark running / done with result text |
| `sync_session_context` | Push session summary into the phone chat |
| `report_task` | Report a task (optional phone decision) |
| `get_pending_decisions` | Pull approve/reject |
| `send_file_to_client` | Send a local file into the phone chat |

On phone send, MCP live-pull also auto-fetches and spawns the Agent; rules still require calling `get_pending_prompts` each turn.

---

## 6. Flutter client

```powershell
cd <REPO>\mobile
flutter pub get
flutter run
# release APK:
flutter build apk --release
```

Output: `mobile\build\app\outputs\flutter-apk\app-release.apk`

| Scenario | Server URL |
|----------|------------|
| Real device (same LAN) | `http://<PC-LAN-IP>:8787` |
| Android emulator | `http://10.0.2.2:8787` |
| iOS simulator | `http://127.0.0.1:8787` |

HarmonyOS: [`docs/harmonyos.md`](docs/harmonyos.md).

### How to use the app

1. Enter Server URL + Token in settings and connect  
2. Home chat: pick an **online project** (top-right)  
3. Switch or **create a Session**  
4. Send a prompt → wait for PC → read the result bubble  
5. Download attachments sent from the PC when needed  

---

## 7. Acceptance checklist

- [ ] `health` OK and relay uses `HOST=0.0.0.0`  
- [ ] Phone can open `http://<LAN-IP>:8787`  
- [ ] MCP reloaded; tools include `send_file_to_client`  
- [ ] Project shows online with a real folder name (not `${...}`)  
- [ ] Phone prompt → PC runs → phone shows the result  

---

## 8. Troubleshooting

| Symptom | Fix |
|---------|-----|
| Phone cannot connect | Check `HOST`, firewall 8787, IP, Token |
| Project offline | IDE/MCP running? Relay up? |
| Name is `${workspaceFolderBasename}` | Remove that env, Reload, `register_project` |
| No execution result | `agent login`; ensure agent spawn is not disabled |
| New tools missing | Bump `CODEASSIST_MCP_BUILD` → Reload; or restart IDE |
| TS changes ignored | Run `npm run build` (runtime uses `dist/`) |

More detail: [`docs/INSTALL.md`](docs/INSTALL.md).

---

## License & contributing

Licensed under the [Apache License 2.0](LICENSE).  
Copyright 2026 TimeCyber  

Issues and PRs welcome: <https://github.com/TimeCyber/24HCode>
