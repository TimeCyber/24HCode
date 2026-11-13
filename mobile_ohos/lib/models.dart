import 'ide_labels.dart';

class Project {
  Project({
    required this.id,
    required this.name,
    required this.workspacePath,
    required this.ide,
    required this.lastSeenAt,
    required this.online,
  });

  final String id;
  final String name;
  final String workspacePath;
  final String ide;
  final String lastSeenAt;
  final bool online;

  /// UI 展示用：Cursor / Codex / Trae / WorkBuddy …
  String get ideLabel => ideDisplayName(ide);

  /// 服务端 online 标志，或最近 [grace] 内有心跳，都视为在线（避免短暂断心跳闪离线）
  bool isEffectivelyOnline([Duration grace = const Duration(minutes: 10)]) {
    if (online) return true;
    try {
      final seen = DateTime.parse(lastSeenAt).toUtc();
      return DateTime.now().toUtc().difference(seen) <= grace;
    } catch (_) {
      return false;
    }
  }

  factory Project.fromJson(Map<String, dynamic> json) => Project(
    id: json['id'] as String,
    name: json['name'] as String,
    workspacePath: json['workspacePath'] as String,
    ide: json['ide'] as String,
    lastSeenAt: json['lastSeenAt'] as String,
    online: json['online'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'workspacePath': workspacePath,
    'ide': ide,
    'lastSeenAt': lastSeenAt,
    'online': online,
  };

  /// mcp.json 变量未展开时 name 会是 ${workspaceFolderBasename}
  String get displayName {
    if (name.contains(r'${') || name.trim().isEmpty) {
      final parts = workspacePath
          .replaceAll('\\', '/')
          .split('/')
          .where((e) => e.isNotEmpty)
          .toList();
      return parts.isNotEmpty ? parts.last : name;
    }
    return name;
  }

  Project copyWith({bool? online}) => Project(
    id: id,
    name: name,
    workspacePath: workspacePath,
    ide: ide,
    lastSeenAt: lastSeenAt,
    online: online ?? this.online,
  );
}

class CodexUsageWindow {
  const CodexUsageWindow({
    required this.usedPercent,
    required this.windowDurationMins,
    this.resetsAt,
  });

  final int usedPercent;
  final int windowDurationMins;
  final int? resetsAt;

  int get remainingPercent => 100 - usedPercent;

  factory CodexUsageWindow.fromJson(Map<String, dynamic> json) =>
      CodexUsageWindow(
        usedPercent: (json['usedPercent'] as num).toInt(),
        windowDurationMins: (json['windowDurationMins'] as num).toInt(),
        resetsAt: (json['resetsAt'] as num?)?.toInt(),
      );
}

class CodexUsageSnapshot {
  const CodexUsageSnapshot({
    required this.projectId,
    this.planType,
    this.primary,
    this.secondary,
    required this.updatedAt,
  });

  final String projectId;
  final String? planType;
  final CodexUsageWindow? primary;
  final CodexUsageWindow? secondary;
  final String updatedAt;

  factory CodexUsageSnapshot.fromJson(Map<String, dynamic> json) =>
      CodexUsageSnapshot(
        projectId: json['projectId'] as String,
        planType: json['planType'] as String?,
        primary: json['primary'] == null
            ? null
            : CodexUsageWindow.fromJson(
                Map<String, dynamic>.from(json['primary'] as Map),
              ),
        secondary: json['secondary'] == null
            ? null
            : CodexUsageWindow.fromJson(
                Map<String, dynamic>.from(json['secondary'] as Map),
              ),
        updatedAt: json['updatedAt'] as String,
      );
}

class CodexDesktopSession {
  const CodexDesktopSession({
    required this.id,
    required this.title,
    this.preview,
    required this.source,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String? preview;
  final String source;

  /// Unix timestamp in seconds from the local Codex app-server.
  final int updatedAt;

  factory CodexDesktopSession.fromJson(Map<String, dynamic> json) =>
      CodexDesktopSession(
        id: json['id'] as String,
        title: json['title'] as String,
        preview: json['preview'] as String?,
        source: json['source'] as String? ?? 'unknown',
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

class ChatSession {
  ChatSession({
    required this.id,
    required this.projectId,
    required this.title,
    this.cursorChatId,
    this.contextSummary,
    this.contextStep,
    this.contextStatus,
    this.contextExtra,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String projectId;
  final String title;
  final String? cursorChatId;
  final String? contextSummary;
  final String? contextStep;
  final String? contextStatus;
  final String? contextExtra;
  final String createdAt;
  final String updatedAt;

  bool get hasContext =>
      (contextSummary != null && contextSummary!.trim().isNotEmpty) ||
      (contextStep != null && contextStep!.trim().isNotEmpty);

  factory ChatSession.fromJson(Map<String, dynamic> json) => ChatSession(
    id: json['id'] as String,
    projectId: json['projectId'] as String,
    title: json['title'] as String,
    cursorChatId: json['cursorChatId'] as String?,
    contextSummary: json['contextSummary'] as String?,
    contextStep: json['contextStep'] as String?,
    contextStatus: json['contextStatus'] as String?,
    contextExtra: json['contextExtra'] as String?,
    createdAt: json['createdAt'] as String,
    updatedAt: json['updatedAt'] as String,
  );
}

class TaskEvent {
  TaskEvent({
    required this.id,
    required this.projectId,
    required this.type,
    required this.title,
    required this.detail,
    required this.status,
    required this.requireDecision,
    this.decisionComment,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String projectId;
  final String type;
  final String title;
  final String detail;
  final String status;
  final bool requireDecision;
  final String? decisionComment;
  final String createdAt;
  final String updatedAt;

  factory TaskEvent.fromJson(Map<String, dynamic> json) => TaskEvent(
    id: json['id'] as String,
    projectId: json['projectId'] as String,
    type: json['type'] as String,
    title: json['title'] as String,
    detail: (json['detail'] as String?) ?? '',
    status: json['status'] as String,
    requireDecision: json['requireDecision'] as bool? ?? false,
    decisionComment: json['decisionComment'] as String?,
    createdAt: json['createdAt'] as String,
    updatedAt: json['updatedAt'] as String,
  );
}

/// A locally saved prompt that is sent repeatedly while the app is foregrounded.
class ScheduledPrompt {
  ScheduledPrompt({
    required this.id,
    required this.projectId,
    required this.prompt,
    required this.intervalMinutes,
    required this.nextRunAt,
    this.enabled = true,
    this.lastRunAt,
    this.lastError,
  });

  final String id;
  final String projectId;
  final String prompt;
  final int intervalMinutes;
  final DateTime nextRunAt;
  final bool enabled;
  final DateTime? lastRunAt;
  final String? lastError;

  ScheduledPrompt copyWith({
    String? projectId,
    String? prompt,
    int? intervalMinutes,
    DateTime? nextRunAt,
    bool? enabled,
    DateTime? lastRunAt,
    String? lastError,
    bool clearLastError = false,
  }) => ScheduledPrompt(
    id: id,
    projectId: projectId ?? this.projectId,
    prompt: prompt ?? this.prompt,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
    nextRunAt: nextRunAt ?? this.nextRunAt,
    enabled: enabled ?? this.enabled,
    lastRunAt: lastRunAt ?? this.lastRunAt,
    lastError: clearLastError ? null : (lastError ?? this.lastError),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'projectId': projectId,
    'prompt': prompt,
    'intervalMinutes': intervalMinutes,
    'nextRunAt': nextRunAt.toIso8601String(),
    'enabled': enabled,
    if (lastRunAt != null) 'lastRunAt': lastRunAt!.toIso8601String(),
    if (lastError != null) 'lastError': lastError,
  };

  factory ScheduledPrompt.fromJson(Map<String, dynamic> json) =>
      ScheduledPrompt(
        id: json['id'] as String,
        projectId: json['projectId'] as String,
        prompt: json['prompt'] as String,
        intervalMinutes: (json['intervalMinutes'] as num).toInt(),
        nextRunAt: DateTime.parse(json['nextRunAt'] as String),
        enabled: json['enabled'] as bool? ?? true,
        lastRunAt: json['lastRunAt'] == null
            ? null
            : DateTime.parse(json['lastRunAt'] as String),
        lastError: json['lastError'] as String?,
      );
}

class FileAttachment {
  FileAttachment({
    required this.id,
    required this.fileName,
    this.mimeType,
    required this.size,
    this.direction,
  });

  final String id;
  final String fileName;
  final String? mimeType;
  final int size;

  /// to_client=PC→手机；to_agent=手机→PC AI
  final String? direction;

  bool get isToAgent => direction == 'to_agent';
  bool get isImage {
    final mime = (mimeType ?? '').toLowerCase();
    if (mime.startsWith('image/')) return true;
    final name = fileName.toLowerCase();
    return name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.gif') ||
        name.endsWith('.webp') ||
        name.endsWith('.bmp') ||
        name.endsWith('.heic');
  }

  factory FileAttachment.fromJson(Map<String, dynamic> json) => FileAttachment(
    id: json['id'] as String,
    fileName: json['fileName'] as String,
    mimeType: json['mimeType'] as String?,
    size: (json['size'] as num).toInt(),
    direction: json['direction'] as String?,
  );
}

class PromptJob {
  PromptJob({
    required this.id,
    required this.projectIds,
    this.chatSessionId,
    required this.content,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.result,
    this.attachment,
  });

  final String id;
  final List<String> projectIds;
  final String? chatSessionId;
  final String content;
  final String status;
  final String createdAt;
  final String updatedAt;
  final String? result;
  final FileAttachment? attachment;

  factory PromptJob.fromJson(Map<String, dynamic> json) => PromptJob(
    id: json['id'] as String,
    projectIds: (json['projectIds'] as List<dynamic>? ?? [])
        .map((e) => e as String)
        .toList(),
    chatSessionId: json['chatSessionId'] as String?,
    content: json['content'] as String,
    status: json['status'] as String,
    createdAt: json['createdAt'] as String,
    updatedAt: json['updatedAt'] as String,
    result: json['result'] as String?,
    attachment: json['attachment'] is Map<String, dynamic>
        ? FileAttachment.fromJson(json['attachment'] as Map<String, dynamic>)
        : null,
  );
}

class ProjectActivity {
  ProjectActivity({
    required this.id,
    required this.promptId,
    required this.projectId,
    required this.content,
    required this.status,
    required this.updatedAt,
    this.result,
  });

  final String id;
  final String promptId;
  final String projectId;
  final String content;
  final String status;
  final String updatedAt;
  final String? result;

  factory ProjectActivity.fromJson(Map<String, dynamic> json) =>
      ProjectActivity(
        id: json['id'] as String,
        promptId: json['promptId'] as String,
        projectId: json['projectId'] as String,
        content: json['content'] as String,
        status: json['status'] as String,
        updatedAt: json['updatedAt'] as String,
        result: json['result'] as String?,
      );
}

class SessionContext {
  SessionContext({
    required this.id,
    required this.projectId,
    required this.summary,
    required this.currentStep,
    required this.openFiles,
    required this.status,
    this.extra,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String projectId;
  final String summary;
  final String currentStep;
  final List<String> openFiles;
  final String status;
  final String? extra;
  final String createdAt;
  final String updatedAt;

  factory SessionContext.fromJson(Map<String, dynamic> json) => SessionContext(
    id: json['id'] as String,
    projectId: json['projectId'] as String,
    summary: json['summary'] as String,
    currentStep: (json['currentStep'] as String?) ?? '',
    openFiles: (json['openFiles'] as List<dynamic>? ?? [])
        .map((e) => e as String)
        .toList(),
    status: (json['status'] as String?) ?? 'idle',
    extra: json['extra'] as String?,
    createdAt: json['createdAt'] as String,
    updatedAt: json['updatedAt'] as String,
  );
}
