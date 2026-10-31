import { z } from "zod";

export const IdeSchema = z.enum([
  "cursor",
  "codex",
  "trae",
  "trea",
  "workbuddy",
  "claude",
  "claude-code",
]);
export type Ide = z.infer<typeof IdeSchema>;

export const ProjectSchema = z.object({
  id: z.string(),
  name: z.string(),
  workspacePath: z.string(),
  ide: IdeSchema,
  lastSeenAt: z.string(),
  online: z.boolean(),
});
export type Project = z.infer<typeof ProjectSchema>;

export const RegisterProjectRequestSchema = z.object({
  id: z.string().optional(),
  name: z.string().min(1),
  workspacePath: z.string().min(1),
  ide: IdeSchema.default("cursor"),
});
export type RegisterProjectRequest = z.infer<typeof RegisterProjectRequestSchema>;

export const TaskTypeSchema = z.enum(["completed", "pending", "blocked", "info"]);
export type TaskType = z.infer<typeof TaskTypeSchema>;

export const TaskStatusSchema = z.enum([
  "awaiting_decision",
  "approved",
  "rejected",
  "acked",
]);
export type TaskStatus = z.infer<typeof TaskStatusSchema>;

export const TaskEventSchema = z.object({
  id: z.string(),
  projectId: z.string(),
  type: TaskTypeSchema,
  title: z.string(),
  detail: z.string().default(""),
  status: TaskStatusSchema,
  requireDecision: z.boolean().default(false),
  decisionComment: z.string().optional(),
  createdAt: z.string(),
  updatedAt: z.string(),
});
export type TaskEvent = z.infer<typeof TaskEventSchema>;

export const CreateTaskRequestSchema = z.object({
  projectId: z.string().min(1),
  type: TaskTypeSchema,
  title: z.string().min(1),
  detail: z.string().optional().default(""),
  requireDecision: z.boolean().optional().default(false),
});
export type CreateTaskRequest = z.infer<typeof CreateTaskRequestSchema>;

export const DecisionActionSchema = z.enum(["approve", "reject"]);
export type DecisionAction = z.infer<typeof DecisionActionSchema>;

export const DecisionSchema = z.object({
  taskId: z.string(),
  projectId: z.string(),
  action: DecisionActionSchema,
  comment: z.string().optional(),
  createdAt: z.string(),
  consumed: z.boolean().default(false),
});
export type Decision = z.infer<typeof DecisionSchema>;

export const SubmitDecisionRequestSchema = z.object({
  action: DecisionActionSchema,
  comment: z.string().optional(),
});
export type SubmitDecisionRequest = z.infer<typeof SubmitDecisionRequestSchema>;

export const PromptStatusSchema = z.enum([
  "queued",
  "delivered",
  "running",
  "done",
  "failed",
]);
export type PromptStatus = z.infer<typeof PromptStatusSchema>;

export const ChatSessionSchema = z.object({
  id: z.string(),
  projectId: z.string(),
  title: z.string(),
  cursorChatId: z.string().optional(),
  contextSummary: z.string().optional(),
  contextStep: z.string().optional(),
  contextStatus: z.string().optional(),
  contextExtra: z.string().optional(),
  createdAt: z.string(),
  updatedAt: z.string(),
});
export type ChatSession = z.infer<typeof ChatSessionSchema>;

export const CreateChatSessionRequestSchema = z.object({
  projectId: z.string().min(1),
  title: z.string().min(1).optional(),
});
export type CreateChatSessionRequest = z.infer<
  typeof CreateChatSessionRequestSchema
>;

export const UpdateChatSessionRequestSchema = z.object({
  title: z.string().min(1).optional(),
  cursorChatId: z.string().min(1).optional(),
  contextSummary: z.string().optional(),
  contextStep: z.string().optional(),
  contextStatus: z.string().optional(),
  contextExtra: z.string().optional(),
});
export type UpdateChatSessionRequest = z.infer<
  typeof UpdateChatSessionRequestSchema
>;

export const FileDirectionSchema = z.enum(["to_client", "to_agent"]);
export type FileDirection = z.infer<typeof FileDirectionSchema>;

export const FileAttachmentSchema = z.object({
  id: z.string(),
  fileName: z.string(),
  mimeType: z.string().optional(),
  size: z.number().int().nonnegative(),
  direction: FileDirectionSchema.optional(),
});
export type FileAttachment = z.infer<typeof FileAttachmentSchema>;

export const PromptJobSchema = z.object({
  id: z.string(),
  projectIds: z.array(z.string()).min(1),
  chatSessionId: z.string().optional(),
  content: z.string().min(1),
  status: PromptStatusSchema,
  createdAt: z.string(),
  updatedAt: z.string(),
  result: z.string().optional(),
  attachment: FileAttachmentSchema.optional(),
});
export type PromptJob = z.infer<typeof PromptJobSchema>;

export const CreateFileTransferRequestSchema = z.object({
  projectId: z.string().min(1),
  chatSessionId: z.string().min(1).optional(),
  fileName: z.string().min(1),
  mimeType: z.string().optional(),
  contentBase64: z.string().min(1),
  /** to_client=PC→手机；to_agent=手机→PC AI（默认 to_client） */
  direction: FileDirectionSchema.optional(),
  /** 发给 AI 时的附加说明（可选） */
  message: z.string().optional(),
});
export type CreateFileTransferRequest = z.infer<
  typeof CreateFileTransferRequestSchema
>;

export const FileTransferSchema = z.object({
  id: z.string(),
  projectId: z.string(),
  chatSessionId: z.string().optional(),
  fileName: z.string(),
  mimeType: z.string().optional(),
  size: z.number().int().nonnegative(),
  createdAt: z.string(),
  promptId: z.string().optional(),
  direction: FileDirectionSchema.optional(),
});
export type FileTransfer = z.infer<typeof FileTransferSchema>;

/** Per-project delivery row for a prompt job */
export const PromptDeliverySchema = z.object({
  id: z.string(),
  promptId: z.string(),
  projectId: z.string(),
  chatSessionId: z.string().optional(),
  content: z.string(),
  status: PromptStatusSchema,
  createdAt: z.string(),
  updatedAt: z.string(),
  result: z.string().optional(),
  attachment: FileAttachmentSchema.optional(),
});
export type PromptDelivery = z.infer<typeof PromptDeliverySchema>;

export const CreatePromptRequestSchema = z
  .object({
    content: z.string().min(1),
    chatSessionId: z.string().min(1).optional(),
    projectId: z.string().min(1).optional(),
    projectIds: z.array(z.string()).min(1).optional(),
  })
  .refine(
    (v) => Boolean(v.chatSessionId) || (v.projectIds && v.projectIds.length > 0) || Boolean(v.projectId),
    { message: "chatSessionId or projectId(s) required" },
  );
export type CreatePromptRequest = z.infer<typeof CreatePromptRequestSchema>;

export const CompletePromptRequestSchema = z.object({
  status: z.enum(["done", "failed"]).default("done"),
  result: z.string().optional(),
});
export type CompletePromptRequest = z.infer<typeof CompletePromptRequestSchema>;

export const SessionStatusSchema = z.enum([
  "idle",
  "thinking",
  "coding",
  "waiting_user",
  "blocked",
  "done",
]);
export type SessionStatus = z.infer<typeof SessionStatusSchema>;

export const SessionContextSchema = z.object({
  id: z.string(),
  projectId: z.string(),
  summary: z.string(),
  currentStep: z.string().default(""),
  openFiles: z.array(z.string()).default([]),
  status: SessionStatusSchema.default("idle"),
  extra: z.string().optional(),
  createdAt: z.string(),
  updatedAt: z.string(),
});
export type SessionContext = z.infer<typeof SessionContextSchema>;

export const SyncSessionContextRequestSchema = z.object({
  projectId: z.string().min(1),
  chatSessionId: z.string().min(1).optional(),
  summary: z.string().min(1),
  currentStep: z.string().optional().default(""),
  openFiles: z.array(z.string()).optional().default([]),
  status: SessionStatusSchema.optional().default("idle"),
  extra: z.string().optional(),
});
export type SyncSessionContextRequest = z.infer<
  typeof SyncSessionContextRequestSchema
>;

export const OpenWorkspaceRequestSchema = z.object({
  workspacePath: z.string().min(1),
  ide: IdeSchema.default("cursor"),
  /** 指定由哪个已在线项目的 MCP/桥接执行；不传则任意匹配 IDE 的在线节点可认领 */
  viaProjectId: z.string().min(1).optional(),
});
export type OpenWorkspaceRequest = z.infer<typeof OpenWorkspaceRequestSchema>;

export const OpenWorkspaceCommandSchema = z.object({
  id: z.string(),
  workspacePath: z.string(),
  ide: IdeSchema,
  viaProjectId: z.string().optional(),
  status: z.enum(["queued", "claimed", "done", "failed"]),
  claimedBy: z.string().optional(),
  error: z.string().optional(),
  createdAt: z.string(),
  updatedAt: z.string(),
});
export type OpenWorkspaceCommand = z.infer<typeof OpenWorkspaceCommandSchema>;

export const WsEventTypeSchema = z.enum([
  "task.created",
  "task.updated",
  "prompt.updated",
  "project.online",
  "project.offline",
  "project.open",
  "decision.created",
  "session.updated",
  "chat.session.updated",
  "chat.session.deleted",
  "file.created",
]);
export type WsEventType = z.infer<typeof WsEventTypeSchema>;

export const WsEventSchema = z.object({
  type: WsEventTypeSchema,
  payload: z.unknown(),
  at: z.string(),
});
export type WsEvent = z.infer<typeof WsEventSchema>;

export function nowIso(): string {
  return new Date().toISOString();
}
