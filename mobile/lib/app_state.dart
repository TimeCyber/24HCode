import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_client.dart';
import 'background_watch_service.dart';
import 'models.dart';
import 'notification_service.dart';

const _kBgNotifiedIds = 'bg_notified_prompt_ids';

class AppState extends ChangeNotifier {
  static const _kUrl = 'server_url';
  static const _kToken = 'access_token';
  static const _kActiveProject = 'active_project_id';
  static const _kActiveChat = 'active_chat_session_id';

  String serverUrl = 'http://10.0.2.2:8787';
  String token = 'codeassist-dev-token';
  bool configured = false;
  bool connecting = false;
  String? error;

  List<Project> projects = [];
  List<TaskEvent> tasks = [];
  List<PromptJob> prompts = [];
  List<PromptJob> chatMessages = [];
  List<ChatSession> chatSessions = [];
  List<SessionContext> sessions = [];

  String? activeProjectId;
  String? activeChatSessionId;

  ApiClient? _api;
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  Timer? _reconnectTimer;
  Timer? _progressPollTimer;
  bool _disposed = false;
  final Set<String> _completionSoundPlayed = {};
  final Set<String> _taskNotifyPlayed = {};

  Project? get activeProject {
    final id = activeProjectId;
    if (id == null) return null;
    try {
      return projects.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Windows 路径大小写不同会产生重复「离线项目」，按规范化路径去重。
  static String _normPath(String p) =>
      p.trim().replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '').toLowerCase();

  static List<Project> _dedupeProjects(List<Project> input) {
    final seen = <String>{};
    final out = <Project>[];
    // 已按 lastSeen 倒序时，先到的优先（在线/更新的在前）
    for (final p in input) {
      final key = '${p.ide}::${_normPath(p.workspacePath)}';
      if (seen.contains(key)) continue;
      seen.add(key);
      out.add(p);
    }
    return out;
  }

  ChatSession? get activeChatSession {
    final id = activeChatSessionId;
    if (id == null) return null;
    try {
      return chatSessions.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<void> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    serverUrl = prefs.getString(_kUrl) ?? serverUrl;
    token = prefs.getString(_kToken) ?? token;
    activeProjectId = prefs.getString(_kActiveProject);
    activeChatSessionId = prefs.getString(_kActiveChat);
    configured = prefs.getString(_kUrl) != null;
    notifyListeners();
    if (configured) {
      await connect();
    }
  }

  Future<void> saveConfig(String url, String accessToken) async {
    serverUrl = url.trim();
    token = accessToken.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUrl, serverUrl);
    await prefs.setString(_kToken, token);
    configured = true;
    notifyListeners();
    await connect();
  }

  Future<void> _persistSelection() async {
    final prefs = await SharedPreferences.getInstance();
    if (activeProjectId != null) {
      await prefs.setString(_kActiveProject, activeProjectId!);
    } else {
      await prefs.remove(_kActiveProject);
    }
    if (activeChatSessionId != null) {
      await prefs.setString(_kActiveChat, activeChatSessionId!);
    } else {
      await prefs.remove(_kActiveChat);
    }
  }

  Future<void> connect() async {
    connecting = true;
    error = null;
    notifyListeners();
    _api = ApiClient(baseUrl: serverUrl, token: token);
    try {
      await refreshAll();
      _connectWs();
      connecting = false;
      notifyListeners();
    } catch (e) {
      connecting = false;
      error = e.toString();
      notifyListeners();
      _scheduleReconnect();
    }
  }

  Future<void> refreshAll() async {
    final api = _api;
    if (api == null) return;
    projects = _dedupeProjects(await api.listProjects());
    tasks = await api.listTasks();
    sessions = await api.listSessionContexts();

    if (activeProjectId == null ||
        !projects.any((p) => p.id == activeProjectId)) {
      final online = projects.where((p) => p.online).toList();
      activeProjectId = online.isNotEmpty
          ? online.first.id
          : (projects.isNotEmpty ? projects.first.id : null);
    }

    await _loadChatSessionsForActiveProject();
    await _loadMessagesForActiveChat();
    await _persistSelection();
    notifyListeners();
  }

  static List<ChatSession> _dedupeSessions(List<ChatSession> input) {
    final seen = <String>{};
    final out = <ChatSession>[];
    for (final s in input) {
      if (seen.contains(s.id)) continue;
      seen.add(s.id);
      out.add(s);
    }
    return out;
  }

  bool _loadingSessions = false;

  Future<void> _loadChatSessionsForActiveProject() async {
    final api = _api;
    final projectId = activeProjectId;
    if (api == null || projectId == null) {
      chatSessions = [];
      activeChatSessionId = null;
      return;
    }
    if (_loadingSessions) return;
    _loadingSessions = true;
    try {
      // 服务端会 prune 空的同名重复会话（项目合并后常见）
      chatSessions =
          _dedupeSessions(await api.listChatSessions(projectId: projectId));
      if (chatSessions.isEmpty) {
        final created =
            await api.createChatSession(projectId, title: '默认会话');
        chatSessions = [created];
        activeChatSessionId = created.id;
        return;
      }
      if (activeChatSessionId == null ||
          !chatSessions.any((s) => s.id == activeChatSessionId)) {
        activeChatSessionId = chatSessions.first.id;
      }
    } finally {
      _loadingSessions = false;
    }
  }

  Future<void> deleteChatSession(String sessionId) async {
    final api = _api;
    final projectId = activeProjectId;
    if (api == null || projectId == null) {
      throw Exception('请先选择 Cursor 项目');
    }
    await api.deleteChatSession(sessionId);
    chatSessions = _dedupeSessions(
      await api.listChatSessions(projectId: projectId),
    );
    if (chatSessions.isEmpty) {
      final created = await api.createChatSession(projectId, title: '默认会话');
      chatSessions = [created];
      activeChatSessionId = created.id;
      chatMessages = [];
    } else if (activeChatSessionId == sessionId ||
        activeChatSessionId == null ||
        !chatSessions.any((s) => s.id == activeChatSessionId)) {
      activeChatSessionId = chatSessions.first.id;
      await _loadMessagesForActiveChat();
    }
    await _persistSelection();
    notifyListeners();
  }

  Future<void> _loadMessagesForActiveChat() async {
    final api = _api;
    final sid = activeChatSessionId;
    if (api == null || sid == null) {
      chatMessages = [];
      return;
    }
    final previous = chatMessages;
    final loaded = await api.listSessionMessages(sid);
    _notifyPromptCompletions(previous, loaded);
    chatMessages = loaded;
    _ensureProgressPolling();
  }

  bool _isTerminalPromptStatus(String status) =>
      status == 'done' || status == 'failed';

  void _playCompletionSound() {
    SystemSound.play(SystemSoundType.alert);
  }

  Future<void> _rememberNotifiedPrompt(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_kBgNotifiedIds) ?? [];
    if (list.contains(id)) return;
    list.add(id);
    final trimmed =
        list.length > 200 ? list.sublist(list.length - 200) : list;
    await prefs.setStringList(_kBgNotifiedIds, trimmed);
  }

  bool _looksCompleted(PromptJob m) =>
      _isTerminalPromptStatus(m.status) ||
      (m.result != null && m.result!.trim().isNotEmpty);

  void _maybeNotifyPromptCompletion(PromptJob? old, PromptJob next) {
    if (!_looksCompleted(next)) return;
    // 初次加载 / 切会话时已是终态，不提醒
    if (old == null) return;
    if (_looksCompleted(old)) return;
    if (_completionSoundPlayed.contains(next.id)) return;
    // 后台交给前台服务推送，避免主线程抢先标记 notified / 停服务导致无推送
    unawaited(() async {
      final inFg = await BackgroundWatchService.isAppForeground();
      if (!inFg) return;
      if (_completionSoundPlayed.contains(next.id)) return;
      _completionSoundPlayed.add(next.id);
      await _rememberNotifiedPrompt(next.id);
      _playCompletionSound();
      final ok = next.status != 'failed';
      final preview = (next.result ?? next.content).trim();
      final body = preview.isEmpty
          ? (ok ? '指令已完成' : '指令执行失败')
          : (preview.length > 120 ? '${preview.substring(0, 120)}…' : preview);
      await NotificationService.instance.showTaskCompleted(
        title: ok ? 'Cursor 任务完成' : 'Cursor 任务失败',
        body: body,
      );
      await BackgroundWatchService.ensureWatching(
        hasInFlight: _hasInFlightMessages,
      );
    }());
  }

  void _maybeNotifyTaskEvent(TaskEvent? old, TaskEvent next) {
    final completed = next.type == 'completed' || next.status == 'completed';
    if (!completed) return;
    if (old != null &&
        (old.type == 'completed' || old.status == 'completed')) {
      return;
    }
    if (_taskNotifyPlayed.contains(next.id)) return;
    _taskNotifyPlayed.add(next.id);
    _playCompletionSound();
    final detail = next.detail.trim();
    final body = detail.isEmpty
        ? next.title
        : '${next.title}\n${detail.length > 100 ? '${detail.substring(0, 100)}…' : detail}';
    unawaited(
      NotificationService.instance.showTaskCompleted(
        title: 'Cursor 任务完成',
        body: body,
      ),
    );
  }

  void _notifyPromptCompletions(
    List<PromptJob> previous,
    List<PromptJob> next,
  ) {
    final prevMap = {for (final m in previous) m.id: m};
    for (final m in next) {
      _maybeNotifyPromptCompletion(prevMap[m.id], m);
    }
  }

  Future<void> selectProject(String projectId) async {
    if (activeProjectId == projectId) return;
    activeProjectId = projectId;
    activeChatSessionId = null;
    await _loadChatSessionsForActiveProject();
    await _loadMessagesForActiveChat();
    await _persistSelection();
    _sendSubscribe();
    notifyListeners();
  }

  Future<void> selectChatSession(String sessionId) async {
    if (activeChatSessionId == sessionId) return;
    activeChatSessionId = sessionId;
    await _loadMessagesForActiveChat();
    await _persistSelection();
    notifyListeners();
  }

  void _upsertChatSession(ChatSession session) {
    final idx = chatSessions.indexWhere((e) => e.id == session.id);
    if (idx >= 0) {
      final next = [...chatSessions];
      next[idx] = session;
      chatSessions = next;
    } else {
      chatSessions = [session, ...chatSessions];
    }
  }

  Future<ChatSession> addChatSession({String? title}) async {
    final api = _api;
    final projectId = activeProjectId;
    if (api == null || projectId == null) {
      throw Exception('请先选择 Cursor 项目');
    }
    final session = await api.createChatSession(
      projectId,
      title: title ?? '新会话',
    );
    // 以服务端列表为准，避免 WS 推送与本地插入重复
    chatSessions = _dedupeSessions(
      await api.listChatSessions(projectId: projectId),
    );
    if (!chatSessions.any((s) => s.id == session.id)) {
      _upsertChatSession(session);
    }
    activeChatSessionId = session.id;
    chatMessages = [];
    await _persistSelection();
    notifyListeners();
    return session;
  }

  Future<void> approveTask(String taskId, {String? comment}) async {
    await _api?.submitDecision(taskId, 'approve', comment: comment);
    await refreshAll();
  }

  Future<void> rejectTask(String taskId, {String? comment}) async {
    await _api?.submitDecision(taskId, 'reject', comment: comment);
    await refreshAll();
  }

  Future<void> sendPrompt(String content) async {
    final projectId = activeProjectId;
    var chatSessionId = activeChatSessionId;
    if (projectId == null) {
      throw Exception('请先在右上角选择 Cursor 项目');
    }
    if (chatSessionId == null) {
      await addChatSession(title: '默认会话');
      chatSessionId = activeChatSessionId;
    }
    await _api?.createPrompt(
      content: content,
      chatSessionId: chatSessionId,
      projectId: projectId,
    );
    await _loadMessagesForActiveChat();
    _ensureProgressPolling();
    notifyListeners();
  }

  Future<List<int>> downloadAttachmentBytes(String fileId) async {
    final api = _api;
    if (api == null) throw Exception('未连接服务器');
    return api.downloadFileBytes(fileId);
  }

  Future<void> sendImageToAgent({
    required String fileName,
    required List<int> bytes,
    String? mimeType,
    String? message,
  }) async {
    final api = _api;
    final projectId = activeProjectId;
    var chatSessionId = activeChatSessionId;
    if (api == null) throw Exception('未连接服务器');
    if (projectId == null) throw Exception('请先在右上角选择 Cursor 项目');
    if (chatSessionId == null) {
      await addChatSession(title: '默认会话');
      chatSessionId = activeChatSessionId;
    }
    if (chatSessionId == null) throw Exception('无法创建会话');
    if (bytes.isEmpty) throw Exception('图片为空');
    if (bytes.length > 100 * 1024 * 1024) {
      throw Exception('文件过大（最大 100MB）');
    }
    final b64 = base64Encode(bytes);
    await api.uploadFileToAgent(
      projectId: projectId,
      chatSessionId: chatSessionId,
      fileName: fileName,
      contentBase64: b64,
      mimeType: mimeType,
      message: message,
    );
    await _loadMessagesForActiveChat();
    _ensureProgressPolling();
    notifyListeners();
  }

  void _connectWs() {
    _wsSub?.cancel();
    _ws?.sink.close();
    final httpUrl = serverUrl.replaceAll(RegExp(r'/+$'), '');
    final wsUrl = httpUrl
        .replaceFirst(RegExp(r'^http'), 'ws')
        .replaceFirst(RegExp(r'^https'), 'wss');
    final uri = Uri.parse('$wsUrl/ws?token=${Uri.encodeComponent(token)}');
    _ws = WebSocketChannel.connect(uri);
    _wsSub = _ws!.stream.listen(
      _onWsMessage,
      onError: (_) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
    );
    _sendSubscribe();
  }

  void _sendSubscribe() {
    final ids = activeProjectId == null ? null : [activeProjectId!];
    _ws?.sink.add(jsonEncode({
      'type': 'subscribe',
      if (ids != null) 'projectIds': ids,
    }));
  }

  void _onWsMessage(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = msg['type'] as String?;
      final payload = msg['payload'];
      if (type == null || payload is! Map<String, dynamic>) return;

      switch (type) {
        case 'project.online':
        case 'project.offline':
          final p = Project.fromJson(payload);
          final idx = projects.indexWhere((e) => e.id == p.id);
          if (idx >= 0) {
            projects[idx] = p;
          } else {
            // 同路径已有条目则更新，避免路径大小写再插一条
            final pathIdx = projects.indexWhere(
              (e) =>
                  e.ide == p.ide &&
                  _normPath(e.workspacePath) == _normPath(p.workspacePath),
            );
            if (pathIdx >= 0) {
              final next = [...projects];
              next[pathIdx] = p;
              projects = next;
            } else {
              projects = [p, ...projects];
            }
          }
          projects = _dedupeProjects(projects);
          notifyListeners();
          break;
        case 'task.created':
        case 'task.updated':
          final t = TaskEvent.fromJson(payload);
          final idx = tasks.indexWhere((e) => e.id == t.id);
          final old = idx >= 0 ? tasks[idx] : null;
          if (idx >= 0) {
            tasks[idx] = t;
          } else {
            tasks = [t, ...tasks];
          }
          _maybeNotifyTaskEvent(old, t);
          notifyListeners();
          break;
        case 'prompt.updated':
          _applyPromptDeliveryPayload(payload);
          unawaited(_onPromptUpdated());
          break;
        case 'chat.session.updated':
          final s = ChatSession.fromJson(payload);
          if (s.projectId == activeProjectId) {
            _upsertChatSession(s);
            chatSessions = _dedupeSessions(chatSessions);
            notifyListeners();
          }
          break;
        case 'chat.session.deleted':
          final deletedId = payload['id'] as String?;
          final deletedProjectId = payload['projectId'] as String?;
          if (deletedId != null &&
              (deletedProjectId == null ||
                  deletedProjectId == activeProjectId)) {
            chatSessions =
                chatSessions.where((s) => s.id != deletedId).toList();
            if (activeChatSessionId == deletedId) {
              activeChatSessionId =
                  chatSessions.isNotEmpty ? chatSessions.first.id : null;
              unawaited(_loadMessagesForActiveChat());
            }
            notifyListeners();
          }
          break;
        case 'session.updated':
          final s = SessionContext.fromJson(payload);
          final idx = sessions.indexWhere((e) => e.projectId == s.projectId);
          if (idx >= 0) {
            sessions[idx] = s;
          } else {
            sessions = [s, ...sessions];
          }
          notifyListeners();
          break;
        default:
          break;
      }
    } catch (_) {
      // ignore malformed
    }
  }

  void _applyPromptDeliveryPayload(Map<String, dynamic> payload) {
    final promptId = payload['promptId'] as String?;
    final chatSessionId = payload['chatSessionId'] as String?;
    final status = payload['status'] as String?;
    final result = payload['result'] as String?;
    final content = payload['content'] as String?;
    final updatedAt = payload['updatedAt'] as String?;
    if (promptId == null || status == null) return;
    if (chatSessionId != null &&
        activeChatSessionId != null &&
        chatSessionId != activeChatSessionId) {
      return;
    }
    final idx = chatMessages.indexWhere((m) => m.id == promptId);
    if (idx >= 0) {
      final old = chatMessages[idx];
      final updated = PromptJob(
        id: old.id,
        projectIds: old.projectIds,
        chatSessionId: old.chatSessionId ?? chatSessionId,
        content: content ?? old.content,
        status: status,
        createdAt: old.createdAt,
        updatedAt: updatedAt ?? old.updatedAt,
        result: result ?? old.result,
        attachment: old.attachment,
      );
      _maybeNotifyPromptCompletion(old, updated);
      final next = [...chatMessages];
      next[idx] = updated;
      chatMessages = next;
      notifyListeners();
    }
    _ensureProgressPolling();
  }

  Future<void> _onPromptUpdated() async {
    final projectId = activeProjectId;
    if (projectId != null && _api != null) {
      chatSessions = await _api!.listChatSessions(projectId: projectId);
    }
    await _loadMessagesForActiveChat();
    _ensureProgressPolling();
    notifyListeners();
  }

  bool get _hasInFlightMessages => chatMessages.any((m) {
        if (m.status == 'done' || m.status == 'failed') return false;
        // 已有结果则视为完成，避免前台服务一直「监听中」
        if (m.result != null && m.result!.trim().isNotEmpty) return false;
        return m.status == 'queued' ||
            m.status == 'delivered' ||
            m.status == 'running';
      });

  void _ensureProgressPolling() {
    unawaited(() async {
      if (_hasInFlightMessages) {
        await BackgroundWatchService.seedWatchingIds(
          chatMessages
              .where((m) =>
                  m.status == 'queued' ||
                  m.status == 'delivered' ||
                  m.status == 'running')
              .where((m) =>
                  m.result == null || m.result!.trim().isEmpty)
              .map((m) => m.id),
        );
      }
      await BackgroundWatchService.ensureWatching(
        hasInFlight: _hasInFlightMessages,
      );
    }());
    if (_disposed || !_hasInFlightMessages) {
      _progressPollTimer?.cancel();
      _progressPollTimer = null;
      return;
    }
    if (_progressPollTimer != null) return;
    _progressPollTimer =
        Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_disposed || !_hasInFlightMessages) {
        _progressPollTimer?.cancel();
        _progressPollTimer = null;
        unawaited(BackgroundWatchService.ensureWatching(hasInFlight: false));
        return;
      }
      try {
        await _loadMessagesForActiveChat();
        if (activeProjectId != null && _api != null) {
          chatSessions =
              await _api!.listChatSessions(projectId: activeProjectId);
        }
        notifyListeners();
        if (!_hasInFlightMessages) {
          _progressPollTimer?.cancel();
          _progressPollTimer = null;
          unawaited(BackgroundWatchService.ensureWatching(hasInFlight: false));
        }
      } catch (_) {
        // ignore transient
      }
    });
  }

  void _scheduleReconnect() {
    if (_disposed || !configured) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!_disposed) connect();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _progressPollTimer?.cancel();
    _wsSub?.cancel();
    _ws?.sink.close();
    super.dispose();
  }
}
