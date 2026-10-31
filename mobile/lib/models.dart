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
            ? FileAttachment.fromJson(
                json['attachment'] as Map<String, dynamic>,
              )
            : null,
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
