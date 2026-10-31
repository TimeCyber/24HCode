import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiClient {
  ApiClient({required this.baseUrl, required this.token});

  String baseUrl;
  String token;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  /// GET/DELETE 勿带 Content-Type: application/json（无 body 时 Fastify 会 400）
  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer $token',
      };

  Uri _uri(String path, [Map<String, String>? query]) {
    final normalized = baseUrl.replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$normalized$path').replace(queryParameters: query);
  }

  Future<List<Project>> listProjects() async {
    final res = await http.get(_uri('/api/projects'), headers: _headers);
    _ensureOk(res);
    final list = jsonDecode(res.body) as List<dynamic>;
    return list
        .map((e) => Project.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 请求 PC 端打开工作区（在线 MCP/桥接执行）
  Future<Map<String, dynamic>> openWorkspace({
    required String workspacePath,
    String ide = 'cursor',
    String? viaProjectId,
  }) async {
    final res = await http.post(
      _uri('/api/projects/open'),
      headers: _headers,
      body: jsonEncode({
        'workspacePath': workspacePath.trim(),
        'ide': ide,
        if (viaProjectId != null && viaProjectId.isNotEmpty)
          'viaProjectId': viaProjectId,
      }),
    );
    _ensureOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getOpenWorkspaceStatus(String id) async {
    final res = await http.get(
      _uri('/api/projects/open/$id'),
      headers: _authHeaders,
    );
    _ensureOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<List<TaskEvent>> listTasks({String? status}) async {
    final res = await http.get(
      _uri('/api/tasks', status == null ? null : {'status': status}),
      headers: _headers,
    );
    _ensureOk(res);
    final list = jsonDecode(res.body) as List<dynamic>;
    return list
        .map((e) => TaskEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> submitDecision(
    String taskId,
    String action, {
    String? comment,
  }) async {
    final res = await http.post(
      _uri('/api/tasks/$taskId/decision'),
      headers: _headers,
      body: jsonEncode({
        'action': action,
        if (comment != null && comment.isNotEmpty) 'comment': comment,
      }),
    );
    _ensureOk(res);
  }

  Future<List<ChatSession>> listChatSessions({String? projectId}) async {
    final res = await http.get(
      _uri(
        '/api/chat-sessions',
        projectId == null ? null : {'projectId': projectId},
      ),
      headers: _headers,
    );
    _ensureOk(res);
    final list = jsonDecode(res.body) as List<dynamic>;
    return list
        .map((e) => ChatSession.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ChatSession> createChatSession(String projectId, {String? title}) async {
    final res = await http.post(
      _uri('/api/chat-sessions'),
      headers: _headers,
      body: jsonEncode({
        'projectId': projectId,
        if (title != null && title.isNotEmpty) 'title': title,
      }),
    );
    _ensureOk(res);
    return ChatSession.fromJson(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
  }

  Future<void> deleteChatSession(String sessionId) async {
    final res = await http.delete(
      _uri('/api/chat-sessions/$sessionId'),
      headers: _authHeaders,
    );
    _ensureOk(res);
  }

  Future<List<ChatSession>> pruneChatSessions(String projectId) async {
    final res = await http.post(
      _uri('/api/chat-sessions/prune'),
      headers: _headers,
      body: jsonEncode({'projectId': projectId}),
    );
    _ensureOk(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final list = body['sessions'] as List<dynamic>? ?? [];
    return list
        .map((e) => ChatSession.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PromptJob>> listPrompts({
    String? projectId,
    String? chatSessionId,
  }) async {
    final query = <String, String>{};
    if (projectId != null) query['projectId'] = projectId;
    if (chatSessionId != null) query['chatSessionId'] = chatSessionId;
    final res = await http.get(
      _uri('/api/prompts', query.isEmpty ? null : query),
      headers: _headers,
    );
    _ensureOk(res);
    final list = jsonDecode(res.body) as List<dynamic>;
    return list
        .map((e) => PromptJob.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<PromptJob>> listSessionMessages(String chatSessionId) async {
    final res = await http.get(
      _uri('/api/chat-sessions/$chatSessionId/messages'),
      headers: _headers,
    );
    _ensureOk(res);
    final list = jsonDecode(res.body) as List<dynamic>;
    return list
        .map((e) => PromptJob.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> createPrompt({
    required String content,
    String? chatSessionId,
    String? projectId,
    List<String>? projectIds,
  }) async {
    final res = await http.post(
      _uri('/api/prompts'),
      headers: _headers,
      body: jsonEncode({
        'content': content,
        if (chatSessionId != null) 'chatSessionId': chatSessionId,
        if (projectId != null) 'projectId': projectId,
        if (projectIds != null) 'projectIds': projectIds,
      }),
    );
    _ensureOk(res);
  }

  Future<List<SessionContext>> listSessionContexts() async {
    final res =
        await http.get(_uri('/api/session-contexts'), headers: _headers);
    _ensureOk(res);
    final list = jsonDecode(res.body) as List<dynamic>;
    return list
        .map((e) => SessionContext.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<int>> downloadFileBytes(String fileId) async {
    final res = await http.get(
      _uri('/api/files/$fileId/download'),
      headers: {'Authorization': 'Bearer $token'},
    );
    _ensureOk(res);
    return res.bodyBytes;
  }

  Future<void> uploadFileToAgent({
    required String projectId,
    required String chatSessionId,
    required String fileName,
    required String contentBase64,
    String? mimeType,
    String? message,
  }) async {
    final res = await http.post(
      _uri('/api/files'),
      headers: _headers,
      body: jsonEncode({
        'projectId': projectId,
        'chatSessionId': chatSessionId,
        'fileName': fileName,
        'contentBase64': contentBase64,
        'direction': 'to_agent',
        if (mimeType != null && mimeType.isNotEmpty) 'mimeType': mimeType,
        if (message != null && message.trim().isNotEmpty)
          'message': message.trim(),
      }),
    );
    _ensureOk(res);
  }

  /// 生成配对码（手机端）
  Future<Map<String, dynamic>> createPairCode() async {
    final res = await http.post(_uri('/pair/code'), headers: _headers);
    _ensureOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> listPairedDevices() async {
    final res = await http.get(_uri('/pair/devices'), headers: _authHeaders);
    _ensureOk(res);
    final list = jsonDecode(res.body) as List<dynamic>;
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> revokePairedDevice(String deviceId) async {
    final res = await http.delete(
      _uri('/pair/devices/$deviceId'),
      headers: _authHeaders,
    );
    _ensureOk(res);
  }

  void _ensureOk(http.Response res) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
  }
}
