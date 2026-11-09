import type {
  ChatSession,
  CodexDesktopSession,
  CodexUsageSnapshot,
  CreateFileTransferRequest,
  CreateTaskRequest,
  Decision,
  FileTransfer,
  OpenWorkspaceCommand,
  Project,
  PromptDelivery,
  PromptJob,
  RegisterProjectRequest,
  SessionContext,
  SyncSessionContextRequest,
  SyncCodexDesktopSessionsRequest,
  SyncCodexUsageRequest,
  TaskEvent,
  UpdateChatSessionRequest,
} from "@codeassist/shared";

export class ApiClient {
  constructor(
    private readonly baseUrl: string,
    private readonly token: string,
  ) {}

  private async request<T>(
    method: string,
    path: string,
    body?: unknown,
  ): Promise<T> {
    const hasBody = body !== undefined || method === "POST" || method === "PUT" || method === "PATCH";
    const payload = body === undefined && hasBody ? {} : body;
    const headers: Record<string, string> = {
      Authorization: `Bearer ${this.token}`,
    };
    let serialized: string | undefined;
    if (payload !== undefined) {
      headers["Content-Type"] = "application/json";
      serialized = JSON.stringify(payload);
    }
    const res = await fetch(`${this.baseUrl}${path}`, {
      method,
      headers,
      body: serialized,
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error(`API ${method} ${path} failed: ${res.status} ${text}`);
    }
    return (await res.json()) as T;
  }

  registerProject(input: RegisterProjectRequest): Promise<Project> {
    return this.request("POST", "/api/projects/register", input);
  }

  listProjects(): Promise<Project[]> {
    return this.request("GET", "/api/projects");
  }

  heartbeat(projectId: string): Promise<Project> {
    return this.request("POST", `/api/projects/${projectId}/heartbeat`);
  }

  createTask(input: CreateTaskRequest): Promise<TaskEvent> {
    return this.request("POST", "/api/tasks", input);
  }

  pullDecisions(projectId: string): Promise<Decision[]> {
    return this.request(
      "GET",
      `/api/mcp/decisions?projectId=${encodeURIComponent(projectId)}`,
    );
  }

  pullPrompts(projectId: string): Promise<PromptDelivery[]> {
    return this.request(
      "GET",
      `/api/mcp/prompts?projectId=${encodeURIComponent(projectId)}`,
    );
  }

  ackPrompt(id: string): Promise<PromptDelivery> {
    return this.request("POST", `/api/mcp/prompts/${id}/ack`);
  }

  completePrompt(
    id: string,
    status: "done" | "failed" = "done",
    result?: string,
  ): Promise<PromptDelivery> {
    return this.request("POST", `/api/mcp/prompts/${id}/complete`, {
      status,
      result,
    });
  }

  syncSessionContext(
    input: SyncSessionContextRequest,
  ): Promise<SessionContext> {
    return this.request("POST", "/api/mcp/session-context", input);
  }

  updateCodexUsage(
    projectId: string,
    input: Omit<SyncCodexUsageRequest, "projectId">,
  ): Promise<CodexUsageSnapshot> {
    return this.request(
      "PUT",
      `/api/mcp/codex-usage/${encodeURIComponent(projectId)}`,
      input,
    );
  }

  updateCodexDesktopSessions(
    projectId: string,
    input: SyncCodexDesktopSessionsRequest,
  ): Promise<CodexDesktopSession[]> {
    return this.request(
      "PUT",
      `/api/mcp/codex-sessions/${encodeURIComponent(projectId)}`,
      input,
    );
  }

  getChatSession(id: string): Promise<ChatSession> {
    return this.request("GET", `/api/chat-sessions/${id}`);
  }

  updateChatSession(
    id: string,
    input: UpdateChatSessionRequest,
  ): Promise<ChatSession> {
    return this.request("PATCH", `/api/chat-sessions/${id}`, input);
  }

  createFileTransfer(input: CreateFileTransferRequest): Promise<{
    file: FileTransfer;
    prompt: PromptJob;
    delivery: PromptDelivery;
  }> {
    return this.request("POST", "/api/files", input);
  }

  async downloadFileBytes(fileId: string): Promise<Buffer> {
    const res = await fetch(`${this.baseUrl}/api/files/${fileId}/download`, {
      method: "GET",
      headers: { Authorization: `Bearer ${this.token}` },
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error(`download file failed: ${res.status} ${text}`);
    }
    const ab = await res.arrayBuffer();
    return Buffer.from(ab);
  }

  claimOpenWorkspace(projectId: string): Promise<OpenWorkspaceCommand[]> {
    return this.request<unknown>(
      "GET",
      `/api/mcp/open-workspace?projectId=${encodeURIComponent(projectId)}`,
    ).then(normalizeOpenWorkspaceCommands);
  }

  completeOpenWorkspace(
    id: string,
    status: "done" | "failed" = "done",
    error?: string,
  ): Promise<OpenWorkspaceCommand> {
    return this.request("POST", `/api/mcp/open-workspace/${id}/complete`, {
      status,
      error,
    });
  }
}

function normalizeOpenWorkspaceCommands(value: unknown): OpenWorkspaceCommand[] {
  if (value == null) return [];
  if (Array.isArray(value)) return value as OpenWorkspaceCommand[];
  if (typeof value !== "object") {
    throw new Error("Unexpected open-workspace response: expected an object or array");
  }

  const record = value as Record<string, unknown>;
  for (const key of ["commands", "items", "data"]) {
    const nested = record[key];
    if (Array.isArray(nested)) return nested as OpenWorkspaceCommand[];
    if (nested == null && key in record) return [];
    if (nested && typeof nested === "object") {
      const command = nested as Record<string, unknown>;
      if (typeof command.id === "string") {
        return [command as unknown as OpenWorkspaceCommand];
      }
    }
  }

  if (typeof record.id === "string") {
    return [record as unknown as OpenWorkspaceCommand];
  }
  throw new Error("Unexpected open-workspace response: command list is missing");
}
