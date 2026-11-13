import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_client.dart';
import 'auth_api.dart';
import 'background_watch_service.dart';
import 'ide_labels.dart';
import 'models.dart';
import 'notification_service.dart';
import 'client_update_policy.dart';
import 'remote_request.dart';
import 'chat_activity.dart';

const _kBgNotifiedIds = 'bg_notified_prompt_ids';

enum AttachmentDownloadStatus { idle, downloading, done, failed }

class AttachmentDownloadState {
  AttachmentDownloadState({
    required this.fileId,
    required this.status,
    this.savedPath,
    this.error,
  });

  final String fileId;
  final AttachmentDownloadStatus status;
  final String? savedPath;
  final String? error;

  bool get isBusy => status == AttachmentDownloadStatus.downloading;
}

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  static const _kUrl = 'server_url';
  static const _kApiRoot = 'api_root';
  static const _kToken = 'access_token';
  static const _kUsername = 'username';
  static const _kNickName = 'nick_name';
  static const _kActiveProject = 'active_project_id';
  static const _kActiveChat = 'active_chat_session_id';
  static const _kConnMode = 'connection_mode';
  static const _kRecentWorkspaces = 'recent_workspace_paths';
  static const _kScheduledPrompts = 'scheduled_prompts';
  static const _kHiddenProjectIds = 'hidden_project_ids';
  static const _kProjectSnapshotSyncEpochPrefix =
      'project_snapshot_sync_epoch_';
  // Bump when connected cloud projects have changed; existing clients then
  // fetch the full list once and keep using the local snapshot afterward.
  static const _projectSnapshotSyncEpoch = 2;
  static const _kProjectSnapshotPrefix = 'project_snapshot_v1_';

  /// `cloud` = mcp-x 账号登录；`lan` = 内网中继地址 + Token
  String connectionMode = 'cloud';

  /// CodeAssist 中继地址（云端 = apiRoot+/codeassist；内网 = 直接填 http://ip:8787）
  String serverUrl = '';

  /// RuoYi / mcp-x API 根，如 https://mcp-x.com/prod-api（仅云端模式）
  String apiRoot = 'https://mcp-x.com/prod-api';
  String token = '';
  String username = '';
  String nickName = '';
  bool configured = false;
  bool get isLanMode => connectionMode == 'lan';
  bool get isCloudMode => connectionMode != 'lan';
  bool connecting = false;
  String? error;

  List<Project> projects = [];
  final Set<String> hiddenProjectIds = <String>{};
  List<String> recentWorkspacePaths = [];

  List<Project> get visibleProjects => projects
      .where((project) => !hiddenProjectIds.contains(project.id))
      .toList();

  List<Project> get hiddenProjects => projects
      .where((project) => hiddenProjectIds.contains(project.id))
      .toList();

  bool isProjectHidden(String projectId) =>
      hiddenProjectIds.contains(projectId);

  /// 附件下载状态（按 fileId），不绑在聊天气泡 State 上，避免滑动回收取消 UI
  final Map<String, AttachmentDownloadState> attachmentDownloads = {};
  List<TaskEvent> tasks = [];
  List<PromptJob> prompts = [];
  List<PromptJob> chatMessages = [];
  List<ProjectActivity> projectActivities = [];
  final projectActivityLoaded = <String>{};
  DateTime? _lastActivityRefresh;
  ApiClient? _activityRefreshApi;
  List<ChatSession> chatSessions = [];
  List<SessionContext> sessions = [];
  final chatActivityLog = ChatActivityLog();
  Timer? _activitySaveTimer;
  Future<void> _activitySave = Future.value();

  @override
  void notifyListeners() {
    if (!connecting && configured && _api != null && _clientScope.isNotEmpty) {
      var changed = false;
      for (final chat in chatSessions) {
        if (!chat.hasContext) continue;
        changed =
            chatActivityLog.add(
              ChatActivity(
                projectId: chat.projectId,
                chatId: chat.id,
                timestamp: chat.updatedAt,
                status: chat.contextStatus ?? 'idle',
                step: chat.contextStep ?? '',
                summary: chat.contextSummary ?? '',
                extra: chat.contextExtra ?? '',
              ),
            ) ||
            changed;
      }
      for (final session in sessions) {
        changed =
            chatActivityLog.add(
              ChatActivity(
                projectId: session.projectId,
                timestamp: session.updatedAt,
                status: session.status,
                step: session.currentStep,
                summary: session.summary,
                extra: session.extra ?? '',
              ),
            ) ||
            changed;
      }
      if (changed) {
        _activitySaveTimer?.cancel();
        final key = 'chat_activity_v1_$_clientScope';
        final snapshot = chatActivityLog.encode();
        _activitySaveTimer = Timer(const Duration(milliseconds: 500), () {
          _activitySave = _activitySave.catchError((Object _) {}).then((
            _,
          ) async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(key, snapshot);
          });
        });
      }
    }
    super.notifyListeners();
  }

  final Map<String, CodexUsageSnapshot> codexUsageByProject = {};

  /// 云端已配对的家里电脑；内网模式不使用
  List<Map<String, dynamic>> pairedDevices = [];

  /// 是否已成功拉取过配对列表（避免加载中误提示）
  bool pairedDevicesLoaded = false;

  String? activeProjectId;
  String? activeChatSessionId;
  List<ScheduledPrompt> scheduledPrompts = [];

  ApiClient? _api;
  ApiClient? get apiOrNull => _api;
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  Timer? _reconnectTimer;
  Timer? _progressPollTimer;
  Timer? _scheduledPromptTimer;
  Timer? _runtimePollTimer;
  bool _runtimeRefreshing = false;
  ApiClient? _approvalRefreshApi;
  int _wsReconnectAttempt = 0;
  bool _wsConnected = false;
  bool _scheduledPromptsLoaded = false;
  bool _scheduledPromptDispatching = false;
  bool _appForeground = true;
  bool _disposed = false;
  final Set<String> _completionSoundPlayed = {};
  final Set<String> _taskNotifyPlayed = {};
  StableProjectOrder _projectOrder = StableProjectOrder();
  DateTime _taskConnectedAt = DateTime.now().toUtc();
  String _clientScope = '';
  Future<void> _persistOrder = Future<void>.value();
  Future<void> _taskNotificationQueue = Future<void>.value();

  void _setProjects(List<Project> input) {
    projects = _projectOrder.merge(input);
    final key = 'project_order_v1_$_clientScope';
    final snapshotKey = '$_kProjectSnapshotPrefix$_clientScope';
    final order = List<String>.of(_projectOrder.keys);
    final sendsKey = 'project_sends_v1_$_clientScope';
    final sends = jsonEncode(_projectOrder.lastSentAt);
    final snapshot = jsonEncode(
      projects.map((project) => project.toJson()).toList(),
    );
    _persistOrder = _persistOrder
        .catchError((Object _) {})
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setStringList(key, order);
          await prefs.setString(sendsKey, sends);
          await prefs.setString(snapshotKey, snapshot);
        })
        .catchError((Object _) {});
  }

  Future<bool> _restoreProjectSnapshot(String scope) async {
    final prefs = await SharedPreferences.getInstance();
    final snapshot = prefs.getString('$_kProjectSnapshotPrefix$scope');
    if (snapshot == null || snapshot.isEmpty) return false;
    try {
      final decoded = jsonDecode(snapshot);
      if (decoded is! List) return false;
      _setProjects(
        decoded
            .whereType<Map>()
            .map((item) => Project.fromJson(Map<String, dynamic>.from(item)))
            .toList(),
      );
      return true;
    } catch (_) {
      // 损坏的本地快照不影响后续从服务端重新同步。
      return false;
    }
  }

  Future<void> _loadCachedSession() async {
    if (activeProjectId == null ||
        !visibleProjects.any((project) => project.id == activeProjectId)) {
      final candidates = visibleProjects;
      final online = candidates.where(
        (project) => project.isEffectivelyOnline(),
      );
      activeProjectId = online.isNotEmpty
          ? online.first.id
          : (candidates.isNotEmpty ? candidates.first.id : null);
    }
    await refreshCodexUsage();
    await _loadChatSessionsForActiveProject();
    await _loadMessagesForActiveChat();
    await _persistSelection();
    notifyListeners();
  }

  AppState() {
    WidgetsBinding.instance.addObserver(this);
    _appForeground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  Project? get activeProject {
    final id = activeProjectId;
    if (id == null) return null;
    try {
      return projects.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  CodexUsageSnapshot? get activeCodexUsage {
    final id = activeProjectId;
    return id == null ? null : codexUsageByProject[id];
  }

  /// 云端已登录但尚未绑定电脑：首页应引导去「设备配对」
  bool get needsDevicePairing =>
      isCloudMode && pairedDevicesLoaded && pairedDevices.isEmpty;

  /// Windows 路径大小写不同会产生重复「离线项目」，按规范化路径去重。
  static String _normPath(String p) => p
      .trim()
      .replaceAll('\\', '/')
      .replaceAll(RegExp(r'/+$'), '')
      .toLowerCase();

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
    await _loadScheduledPrompts();
    final prefs = await SharedPreferences.getInstance();
    apiRoot = prefs.getString(_kApiRoot) ?? apiRoot;
    token = prefs.getString(_kToken) ?? token;
    username = prefs.getString(_kUsername) ?? '';
    nickName = prefs.getString(_kNickName) ?? '';
    activeProjectId = prefs.getString(_kActiveProject);
    activeChatSessionId = prefs.getString(_kActiveChat);
    hiddenProjectIds
      ..clear()
      ..addAll(prefs.getStringList(_kHiddenProjectIds) ?? const <String>[]);
    recentWorkspacePaths = prefs.getStringList(_kRecentWorkspaces) ?? [];

    final savedUrl = prefs.getString(_kUrl);
    if (savedUrl != null && savedUrl.isNotEmpty) {
      serverUrl = savedUrl;
    } else if (apiRoot.isNotEmpty) {
      serverUrl = AuthApi.relayBaseFromRoot(apiRoot);
    }

    final savedMode = prefs.getString(_kConnMode);
    if (savedMode == 'lan' || savedMode == 'cloud') {
      connectionMode = savedMode!;
    } else {
      // 兼容旧配置：无 /codeassist 且像 host:port → 内网
      final u = serverUrl.toLowerCase();
      final looksLan =
          u.isNotEmpty &&
          !u.contains('/codeassist') &&
          (u.contains('192.168.') ||
              u.contains('10.') ||
              u.contains('127.0.0.1') ||
              u.contains('localhost') ||
              RegExp(r':\d+$').hasMatch(u.replaceAll(RegExp(r'/+$'), '')));
      connectionMode = looksLan ? 'lan' : 'cloud';
    }

    configured = token.isNotEmpty && serverUrl.isNotEmpty;
    notifyListeners();
    if (configured) {
      await connect();
    }
  }

  /// 云端短信登录 mcp-x（与 Web /web/auth/sms/* 一致），成功后自动连中继 /codeassist
  Future<void> login({
    required String root,
    required String phoneNumber,
    required String smsCode,
  }) async {
    connecting = true;
    error = null;
    notifyListeners();
    try {
      final result = await AuthApi.smsLogin(
        apiRoot: root,
        phoneNumber: phoneNumber,
        smsCode: smsCode,
      );
      connectionMode = 'cloud';
      apiRoot = AuthApi.normalizeRoot(root);
      serverUrl = AuthApi.relayBaseFromRoot(apiRoot);
      token = result.token;
      username = result.username ?? phoneNumber.trim();
      nickName = result.nickName ?? '';

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kConnMode, connectionMode);
      await prefs.setString(_kApiRoot, apiRoot);
      await prefs.setString(_kUrl, serverUrl);
      await prefs.setString(_kToken, token);
      await prefs.setString(_kUsername, username);
      await prefs.setString(_kNickName, nickName);
      configured = true;
      notifyListeners();
      await connect();
    } catch (e) {
      connecting = false;
      error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> sendSmsCode({
    required String root,
    required String phoneNumber,
  }) async {
    await AuthApi.sendSmsCode(apiRoot: root, phoneNumber: phoneNumber);
  }

  Future<void> logout() async {
    _activitySaveTimer?.cancel();
    chatActivityLog.items.clear();
    _clientScope = '';
    _runtimePollTimer?.cancel();
    _runtimePollTimer = null;
    _wsSub?.cancel();
    _wsSub = null;
    await _ws?.sink.close();
    _ws = null;
    _wsConnected = false;
    _reconnectTimer?.cancel();
    _progressPollTimer?.cancel();
    _scheduledPromptTimer?.cancel();
    _scheduledPromptTimer = null;
    _api = null;

    token = '';
    username = '';
    nickName = '';
    configured = false;
    projects = [];
    attachmentDownloads.clear();
    tasks = [];
    prompts = [];
    chatMessages = [];
    chatSessions = [];
    sessions = [];
    codexUsageByProject.clear();
    projectActivities = [];
    projectActivityLoaded.clear();
    _lastActivityRefresh = null;
    pairedDevices = [];
    pairedDevicesLoaded = false;
    activeProjectId = null;
    activeChatSessionId = null;
    error = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    await prefs.remove(_kUsername);
    await prefs.remove(_kNickName);
    await prefs.remove(_kActiveProject);
    await prefs.remove(_kActiveChat);
    notifyListeners();
  }

  /// 内网直连：填本地/局域网中继地址 + ACCESS_TOKEN（不会自动拼 /codeassist）
  Future<void> saveLanConfig({
    required String relayUrl,
    required String accessToken,
  }) async {
    connecting = true;
    error = null;
    notifyListeners();
    try {
      var url = relayUrl.trim().replaceAll(RegExp(r'/+$'), '');
      if (url.endsWith('/codeassist')) {
        url = url.substring(0, url.length - '/codeassist'.length);
      }
      if (url.endsWith('/api')) {
        url = url.substring(0, url.length - '/api'.length);
      }
      connectionMode = 'lan';
      serverUrl = url;
      token = accessToken.trim();
      username = '';
      nickName = '';

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kConnMode, connectionMode);
      await prefs.setString(_kUrl, serverUrl);
      await prefs.setString(_kToken, token);
      await prefs.remove(_kUsername);
      await prefs.remove(_kNickName);
      configured = true;
      notifyListeners();
      await connect();
    } catch (e) {
      connecting = false;
      error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  /// 兼容旧入口：带 /codeassist 当云端中继；否则当内网直连
  Future<void> saveConfig(String url, String accessToken) async {
    final trimmed = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.contains('/codeassist') ||
        trimmed.contains('mcp-x.com') ||
        trimmed.contains('prod-api')) {
      connectionMode = 'cloud';
      if (trimmed.endsWith('/codeassist')) {
        serverUrl = trimmed;
        apiRoot = AuthApi.normalizeRoot(trimmed);
      } else {
        apiRoot = AuthApi.normalizeRoot(trimmed);
        serverUrl = AuthApi.relayBaseFromRoot(apiRoot);
      }
      token = accessToken.trim();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kConnMode, connectionMode);
      await prefs.setString(_kApiRoot, apiRoot);
      await prefs.setString(_kUrl, serverUrl);
      await prefs.setString(_kToken, token);
      configured = true;
      notifyListeners();
      await connect();
      return;
    }
    await saveLanConfig(relayUrl: trimmed, accessToken: accessToken);
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
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    connecting = true;
    error = null;
    notifyListeners();
    _api = ApiClient(baseUrl: serverUrl, token: token);
    try {
      final scope = Uri.encodeComponent('$serverUrl|$username');
      final prefs = await SharedPreferences.getInstance();
      if (_clientScope != scope) {
        _clientScope = scope;
        projectActivities = [];
        projectActivityLoaded.clear();
        _lastActivityRefresh = null;
        _activitySaveTimer?.cancel();
        chatActivityLog.restore(prefs.getString('chat_activity_v1_$scope'));
        final savedSends = <String, int>{};
        try {
          final raw = prefs.getString('project_sends_v1_$scope');
          if (raw != null) {
            savedSends.addAll(Map<String, int>.from(jsonDecode(raw) as Map));
          }
        } catch (_) {
          // A damaged sort cache can be rebuilt from the relay's send history.
        }
        _projectOrder = StableProjectOrder(
          prefs.getStringList('project_order_v1_$scope') ?? const [],
          savedSends,
        );
        _taskNotifyPlayed.clear();
      }
      final hasProjectSnapshot = await _restoreProjectSnapshot(scope);
      _taskConnectedAt = DateTime.now().toUtc();
      if (hasProjectSnapshot) {
        final syncEpochKey = '$_kProjectSnapshotSyncEpochPrefix$scope';
        if ((prefs.getInt(syncEpochKey) ?? 0) < _projectSnapshotSyncEpoch) {
          try {
            _setProjects(await _api!.listProjects());
            await _persistOrder;
            await prefs.setInt(syncEpochKey, _projectSnapshotSyncEpoch);
          } catch (e) {
            error = '项目同步失败: $e';
          }
        }
        await _loadCachedSession();
      } else {
        // 首次安装或切换账号时只做一次初始同步；之后使用本地项目清单。
        await refreshAll();
      }
      _wsReconnectAttempt = 0;
      _connectWs();
      _startRuntimePolling();
      _ensureProgressPolling();
      _syncScheduledPromptTimer();
      connecting = false;
      notifyListeners();
    } catch (e) {
      connecting = false;
      error = e.toString();
      notifyListeners();
      _scheduleReconnect(refreshData: true);
    }
  }

  Future<void> refreshPairedDevices() async {
    final api = _api;
    if (api == null || isLanMode) {
      pairedDevices = [];
      pairedDevicesLoaded = isLanMode;
      notifyListeners();
      return;
    }
    try {
      pairedDevices = await api.listPairedDevices();
      pairedDevicesLoaded = true;
    } catch (_) {
      // 拉取失败不误判为「未配对」，保持上次结果；首次失败则仍视为未确认
    }
    notifyListeners();
  }

  Future<void> refreshAll() async {
    final api = _api;
    if (api == null) return;
    final errors = <String>[];
    try {
      _setProjects(await api.listProjects());
      await _persistOrder;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        '$_kProjectSnapshotSyncEpochPrefix$_clientScope',
        _projectSnapshotSyncEpoch,
      );
    } catch (e) {
      // Preserve rows during transient refresh failures.
      errors.add('项目: $e');
    }
    unawaited(refreshProjectActivity(force: true));
    try {
      tasks = await api.listTasks();
    } catch (e) {
      tasks = [];
      errors.add('任务: $e');
    }
    try {
      sessions = await api.listSessionContexts();
    } catch (e) {
      sessions = [];
      // 会话上下文失败不阻断首页（云端缺表时曾整页崩溃）
      errors.add('会话上下文: $e');
    }
    if (isCloudMode) {
      try {
        pairedDevices = await api.listPairedDevices();
        pairedDevicesLoaded = true;
      } catch (e) {
        errors.add('配对设备: $e');
      }
    } else {
      pairedDevices = [];
      pairedDevicesLoaded = true;
    }

    if (activeProjectId == null ||
        !visibleProjects.any((p) => p.id == activeProjectId)) {
      final candidates = visibleProjects;
      final online = candidates.where((p) => p.isEffectivelyOnline()).toList();
      activeProjectId = online.isNotEmpty
          ? online.first.id
          : (candidates.isNotEmpty ? candidates.first.id : null);
    }

    codexUsageByProject.removeWhere(
      (projectId, _) => !projects.any((project) => project.id == projectId),
    );
    await refreshCodexUsage();

    await _loadChatSessionsForActiveProject();
    await _loadMessagesForActiveChat();
    await _persistSelection();
    // 仅当项目都拉失败时把错误顶到首页；上下文缺表只记日志不挡操作
    error = errors.isNotEmpty && projects.isEmpty ? errors.join('\n') : null;
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

  Future<void> _loadChatSessionsForActiveProject() async {
    final api = _api;
    final projectId = activeProjectId;
    if (api == null || projectId == null) {
      chatSessions = [];
      activeChatSessionId = null;
      return;
    }
    final loaded = await api.listChatSessions(projectId: projectId);
    if (!identical(api, _api) || projectId != activeProjectId) return;
    chatSessions = _dedupeSessions(loaded);
    if (!chatSessions.any((s) => s.id == activeChatSessionId)) {
      activeChatSessionId = chatSessions.firstOrNull?.id;
    }
  }

  Future<void> deleteChatSession(String sessionId) async {
    final api = _api;
    final projectId = activeProjectId;
    if (api == null || projectId == null) {
      throw Exception('请先选择 AI 项目');
    }
    await api.deleteChatSession(sessionId);
    chatSessions = _dedupeSessions(
      await api.listChatSessions(projectId: projectId),
    );
    if (chatSessions.isEmpty) {
      activeChatSessionId = null;
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
    final fetched = await api.listSessionMessages(sid);
    if (!identical(api, _api) || sid != activeChatSessionId) return;
    final currentById = {
      for (final message in chatMessages) message.id: message,
    };
    final loaded = fetched.map((message) {
      final old = currentById[message.id];
      if (old != null &&
          !acceptsPromptUpdate(
            previousStatus: old.status,
            previousResult: old.result,
            previousUpdatedMillis:
                DateTime.tryParse(old.updatedAt)?.millisecondsSinceEpoch ?? 0,
            incomingStatus: message.status,
            incomingResult: message.result,
            incomingUpdatedMillis:
                DateTime.tryParse(message.updatedAt)?.millisecondsSinceEpoch ??
                0,
          )) {
        return old;
      }
      return message;
    }).toList();
    _notifyPromptCompletions(previous, loaded);
    chatMessages = loaded;
    final projectId = activeProjectId;
    if (projectId != null) {
      final byId = {
        for (final row in projectActivities) (row.projectId, row.promptId): row,
      };
      for (final message in loaded) {
        if (message.attachment != null && !message.attachment!.isToAgent) {
          continue;
        }
        final key = (projectId, message.id);
        final previous = byId[key];
        final updatedMillis =
            DateTime.tryParse(message.updatedAt)?.millisecondsSinceEpoch ?? 0;
        if (previous != null &&
            !acceptsPromptUpdate(
              previousStatus: previous.status,
              previousResult: previous.result,
              previousUpdatedMillis: previous.updatedMillis,
              incomingStatus: message.status,
              incomingResult: message.result,
              incomingUpdatedMillis: updatedMillis,
            )) {
          continue;
        }
        byId[key] = ProjectActivity(
          id: previous?.id ?? message.id,
          promptId: message.id,
          projectId: projectId,
          chatSessionId: sid,
          content: message.content,
          status: message.status,
          createdAt: message.createdAt,
          updatedAt: message.updatedAt,
          result: message.result,
        );
      }
      final sorted = byId.values.toList()
        ..sort((a, b) => b.updatedMillis.compareTo(a.updatedMillis));
      _setProjectActivities(sorted);
    }
    _ensureProgressPolling();
  }

  Future<void> _rememberNotifiedPrompt(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_kBgNotifiedIds) ?? [];
    if (list.contains(id)) return;
    list.add(id);
    final trimmed = list.length > 200 ? list.sublist(list.length - 200) : list;
    await prefs.setStringList(_kBgNotifiedIds, trimmed);
  }

  bool _looksCompleted(PromptJob m) =>
      isTerminalPromptStatus(m.status) ||
      (m.result != null && m.result!.trim().isNotEmpty);

  void _maybeNotifyPromptCompletion(PromptJob? old, PromptJob next) {
    if (!_looksCompleted(next)) return;
    // 初次加载 / 切会话时已是终态，不提醒
    if (old == null) return;
    if (_looksCompleted(old)) return;
    if (_completionSoundPlayed.contains(next.id)) return;
    // 主线程也推：安卓 10 上进程还活着时比只靠 FGS 更稳；与 FGS 用同一 notified 列表去重
    unawaited(() async {
      if (_completionSoundPlayed.contains(next.id)) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final already = prefs.getStringList(_kBgNotifiedIds) ?? [];
      if (already.contains(next.id)) {
        _completionSoundPlayed.add(next.id);
        return;
      }

      _completionSoundPlayed.add(next.id);
      final ok = reportedPromptStatus(next.status, next.result) != 'failed';
      final preview = next.result?.trim() ?? '';
      final body = preview.isEmpty
          ? (ok ? '指令已完成' : '指令执行失败')
          : (preview.length > 120 ? '${preview.substring(0, 120)}…' : preview);
      try {
        await NotificationService.instance.showTaskCompleted(
          title: ok ? '${_activeIdeLabel()} 任务完成' : '${_activeIdeLabel()} 任务失败',
          body: body,
        );
        await _rememberNotifiedPrompt(next.id);
      } catch (_) {
        // 失败允许重试 / 交给前台服务再推
        _completionSoundPlayed.remove(next.id);
      }
      // 仅前台时停监听服务；后台留给 FGS 自己停，避免抢停导致漏推
      final inFg = await BackgroundWatchService.isAppForeground();
      if (inFg) {
        await BackgroundWatchService.ensureWatching(
          hasInFlight: _hasInFlightMessages,
        );
      }
    }());
  }

  String _activeIdeLabel() => activeProject?.ideLabel ?? kGenericIdeLabel;

  void _maybeNotifyTaskEvent(TaskEvent? old, TaskEvent next) {
    final awaiting = next.status == 'awaiting_decision';
    if (awaiting
        ? !isPendingApproval(next)
        : !shouldNotifyTask(old, next, _taskConnectedAt)) {
      return;
    }
    if (_taskNotifyPlayed.contains(next.id)) return;
    _taskNotifyPlayed.add(next.id);
    final remote = RemoteRequest.parse(next.detail);
    final detail = remote?.reason ?? next.detail.trim();
    final body = detail.isEmpty
        ? next.title
        : '${next.title}\n${detail.length > 100 ? '${detail.substring(0, 100)}…' : detail}';
    final scope = _clientScope;
    final receiptKey = 'task_notified_v2_$scope';
    final title = '${_activeIdeLabel()} 任务完成';
    _taskNotificationQueue = _taskNotificationQueue
        .catchError((Object _) {})
        .then((_) async {
          try {
            if (_disposed || scope != _clientScope) return;
            if (awaiting) {
              final current = tasks
                  .where((task) => task.id == next.id)
                  .firstOrNull;
              if (current != null && isPendingApproval(current)) {
                await NotificationService.instance.showPendingApproval(
                  current,
                  scope,
                );
              } else {
                _taskNotifyPlayed.remove(next.id);
              }
              return;
            }
            final prefs = await SharedPreferences.getInstance();
            await prefs.reload();
            final receipts = prefs.getStringList(receiptKey) ?? <String>[];
            if (receipts.contains(next.id)) return;
            await NotificationService.instance.showTaskCompleted(
              title: title,
              body: body,
            );
            // Only suppress future deliveries after the notification was accepted.
            await prefs.reload();
            final delivered = prefs.getStringList(receiptKey) ?? <String>[];
            if (!delivered.contains(next.id)) delivered.add(next.id);
            await prefs.setStringList(
              receiptKey,
              delivered.length > 1000
                  ? delivered.sublist(delivered.length - 1000)
                  : delivered,
            );
          } catch (_) {
            // A future live transition may retry if persistence failed.
            _taskNotifyPlayed.remove(next.id);
          }
        });
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
    chatSessions = [];
    chatMessages = [];
    await refreshCodexUsage(projectId);
    await _loadChatSessionsForActiveProject();
    await _loadMessagesForActiveChat();
    await _persistSelection();
    _sendSubscribe();
    notifyListeners();
  }

  Future<void> setProjectHidden(String projectId, bool hidden) async {
    if (!projects.any((project) => project.id == projectId)) return;
    final changed = hidden
        ? hiddenProjectIds.add(projectId)
        : hiddenProjectIds.remove(projectId);
    if (!changed) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _kHiddenProjectIds,
      hiddenProjectIds.toList()..sort(),
    );

    if (hidden && activeProjectId == projectId) {
      final candidates = visibleProjects;
      final online = candidates.where((p) => p.isEffectivelyOnline()).toList();
      activeProjectId = online.isNotEmpty
          ? online.first.id
          : (candidates.isNotEmpty ? candidates.first.id : null);
      activeChatSessionId = null;
      chatSessions = [];
      chatMessages = [];
      await refreshCodexUsage();
      await _loadChatSessionsForActiveProject();
      await _loadMessagesForActiveChat();
      await _persistSelection();
      _sendSubscribe();
    }
    notifyListeners();
  }

  Future<void> refreshCodexUsage([String? projectId]) async {
    final api = _api;
    final id = projectId ?? activeProjectId;
    if (id == null) return;
    final matching = projects.where((item) => item.id == id);
    final project = matching.isEmpty ? null : matching.first;
    if (project == null || project.ide != 'codex') {
      codexUsageByProject.remove(id);
      return;
    }
    if (api == null) return;
    try {
      final usage = await api.getCodexUsage(id);
      if (usage == null) {
        codexUsageByProject.remove(id);
      } else {
        codexUsageByProject[id] = usage;
      }
      notifyListeners();
    } catch (_) {
      // Older relays may not expose this optional endpoint; keep the last value.
    }
  }

  Future<void> _rememberWorkspacePath(String path) async {
    final p = path.trim();
    if (p.isEmpty) return;
    final next = [p, ...recentWorkspacePaths.where((e) => e != p)];
    if (next.length > 12) next.removeRange(12, next.length);
    recentWorkspacePaths = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kRecentWorkspaces, recentWorkspacePaths);
    notifyListeners();
  }

  /// 手机控制 PC：打开工作区 → 桥接注册 → 刷新项目列表
  Future<String> openWorkspaceOnPc({
    required String workspacePath,
    String ide = 'cursor',
  }) async {
    final api = _api;
    if (api == null) throw Exception('未连接中继');
    final path = workspacePath.trim();
    if (path.isEmpty) throw Exception('请填写 PC 上的项目路径');

    String? via;
    final matchIde = projects
        .where((p) => p.ide == ide && p.isEffectivelyOnline())
        .toList();
    if (matchIde.isNotEmpty) {
      via = matchIde.any((p) => p.id == activeProjectId)
          ? activeProjectId
          : matchIde.first.id;
    } else {
      final anyOnline = projects.where((p) => p.isEffectivelyOnline()).toList();
      if (anyOnline.isNotEmpty) via = anyOnline.first.id;
    }

    final created = await api.openWorkspace(
      workspacePath: path,
      ide: ide,
      viaProjectId: via,
    );
    await _rememberWorkspacePath(path);

    final id = created['id'] as String?;
    String status = (created['status'] as String?) ?? 'queued';
    String? err = created['error'] as String?;

    // 等待 PC 认领执行（最多约 20s），只查询该指令状态，不重复拉取整批数据。
    if (id != null && status != 'done' && status != 'failed') {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1800));
        try {
          final st = await api.getOpenWorkspaceStatus(id);
          status = (st['status'] as String?) ?? status;
          err = st['error'] as String?;
          if (status == 'done' || status == 'failed') break;
        } catch (_) {
          /* ignore poll errors */
        }
      }
    }
    if (status == 'failed') {
      throw Exception(err?.isNotEmpty == true ? err! : 'PC 打开项目失败');
    }
    if (status == 'queued' || status == 'claimed') {
      return '已下发打开指令，请稍后点刷新查看新项目（状态：$status）';
    }
    return 'PC 已打开；如项目列表未更新，请手动刷新。';
  }

  Future<void> selectChatSession(String sessionId) async {
    if (!chatSessions.any((session) => session.id == sessionId)) return;
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
      throw Exception('请先选择 AI 项目');
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

  Future<String> _chatForSending(String projectId, ApiClient api) async {
    var chat = activeChatSession;
    if (chat == null) {
      await _loadChatSessionsForActiveProject();
      if (activeProjectId != projectId || !identical(api, _api)) {
        throw Exception('项目已切换，请重新发送');
      }
      chat = activeChatSession;
      await _loadMessagesForActiveChat();
    }
    chat ??= await addChatSession(title: '默认会话');
    if (activeProjectId != projectId ||
        !identical(api, _api) ||
        chat.projectId != projectId) {
      throw Exception('项目已切换，请重新发送');
    }
    return chat.id;
  }

  Future<void> approveTask(String taskId, {String? comment}) async {
    await _submitTaskDecision(taskId, 'approve', comment);
  }

  Future<void> rejectTask(String taskId, {String? comment}) async {
    await _submitTaskDecision(taskId, 'reject', comment);
  }

  Future<void> _submitTaskDecision(
    String taskId,
    String action,
    String? comment,
  ) async {
    final api = _api;
    if (api == null) throw Exception('未连接服务器');
    final existing = tasks.where((t) => t.id == taskId).firstOrNull;
    if (existing != null &&
        (RemoteRequest.parse(existing.detail)?.expired ?? false)) {
      throw Exception('确认请求已过期');
    }
    final task = await api.submitDecision(taskId, action, comment: comment);
    if (!identical(api, _api)) return;
    tasks = [task, ...tasks.where((t) => t.id != task.id)];
    notifyListeners();
  }

  void _startRuntimePolling() {
    _runtimePollTimer?.cancel();
    if (!_appForeground || !configured || _disposed) return;
    unawaited(_refreshPendingApprovals());
    unawaited(_refreshRuntimeState());
    _runtimePollTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      unawaited(_refreshPendingApprovals());
      if (!_wsConnected) {
        unawaited(_refreshRuntimeState());
      } else {
        final now = DateTime.now();
        if (projectActivities.any(
          (row) =>
              row.isInFlight &&
              isActivePromptStatus(
                displayPromptStatus(row.status, row.result, row.updatedAt, now),
              ),
        )) {
          unawaited(refreshProjectActivity());
        }
      }
    });
  }

  Future<void> _refreshPendingApprovals() async {
    final api = _api;
    if (api == null ||
        identical(api, _approvalRefreshApi) ||
        !_appForeground ||
        _disposed) {
      return;
    }
    _approvalRefreshApi = api;
    final requestedAt = DateTime.now().toUtc();
    try {
      final pending = await api
          .listTasks(status: 'awaiting_decision')
          .timeout(const Duration(seconds: 12));
      if (_disposed || !identical(api, _api) || !_appForeground) return;
      if (pending.isEmpty &&
          !tasks.any((task) => task.status == 'awaiting_decision')) {
        return;
      }
      tasks = mergePendingTasks(tasks, pending, requestedAt);
      for (final task in tasks.where(isPendingApproval)) {
        _maybeNotifyTaskEvent(null, task);
      }
      notifyListeners();
    } catch (_) {
      /* Retry independently of the chat and session status queries. */
    } finally {
      if (identical(api, _approvalRefreshApi)) _approvalRefreshApi = null;
    }
  }

  Future<void> _refreshRuntimeState() async {
    final api = _api;
    if (api == null || _runtimeRefreshing || !_appForeground || _disposed) {
      return;
    }
    _runtimeRefreshing = true;
    unawaited(refreshProjectActivity());
    final projectId = activeProjectId;
    try {
      final result = await Future.wait([
        api.listSessionContexts(),
        if (projectId != null) api.listChatSessions(projectId: projectId),
      ]).timeout(const Duration(seconds: 15));
      if (_disposed || !identical(api, _api)) return;
      sessions = result[0] as List<SessionContext>;
      if (projectId == activeProjectId && projectId != null) {
        chatSessions = _dedupeSessions(result[1] as List<ChatSession>);
      }
      notifyListeners();
    } catch (_) {
      /* Keep the last snapshot on a transient connection failure. */
    } finally {
      _runtimeRefreshing = false;
    }
  }

  Future<void> sendPrompt(String content) async {
    final api = _api;
    final projectId = activeProjectId;
    if (api == null) throw Exception('未连接服务器');
    if (projectId == null) {
      throw Exception('请先在右上角选择 AI 项目');
    }
    final chatSessionId = await _chatForSending(projectId, api);
    final sentAt = DateTime.now();
    await api.createPrompt(
      content: content,
      chatSessionId: chatSessionId,
      projectId: projectId,
    );
    _recordAcceptedSend(api, projectId, sentAt);
    await _loadMessagesForActiveChat();
    _ensureProgressPolling();
    notifyListeners();
  }

  Future<void> _loadScheduledPrompts() async {
    if (_scheduledPromptsLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kScheduledPrompts);
    if (raw != null) {
      try {
        final values = jsonDecode(raw) as List<dynamic>;
        scheduledPrompts = values
            .map(
              (value) =>
                  ScheduledPrompt.fromJson(value as Map<String, dynamic>),
            )
            .toList();
      } catch (_) {
        scheduledPrompts = [];
      }
    }
    _scheduledPromptsLoaded = true;
    _syncScheduledPromptTimer();
  }

  Future<void> _persistScheduledPrompts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kScheduledPrompts,
      jsonEncode(scheduledPrompts.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> addScheduledPrompt({
    required String prompt,
    required String projectId,
    required int intervalMinutes,
  }) async {
    await _loadScheduledPrompts();
    final item = ScheduledPrompt(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      projectId: projectId,
      prompt: prompt.trim(),
      intervalMinutes: intervalMinutes,
      nextRunAt: DateTime.now().add(Duration(minutes: intervalMinutes)),
    );
    scheduledPrompts = [item, ...scheduledPrompts];
    await _persistScheduledPrompts();
    _syncScheduledPromptTimer();
    notifyListeners();
  }

  Future<void> setScheduledPromptEnabled(String id, bool enabled) async {
    final index = scheduledPrompts.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final item = scheduledPrompts[index];
    final updated = item.copyWith(
      enabled: enabled,
      nextRunAt: enabled
          ? DateTime.now().add(Duration(minutes: item.intervalMinutes))
          : item.nextRunAt,
      clearLastError: true,
    );
    scheduledPrompts = [...scheduledPrompts]..[index] = updated;
    await _persistScheduledPrompts();
    _syncScheduledPromptTimer();
    notifyListeners();
  }

  Future<void> removeScheduledPrompt(String id) async {
    scheduledPrompts = scheduledPrompts.where((item) => item.id != id).toList();
    await _persistScheduledPrompts();
    _syncScheduledPromptTimer();
    notifyListeners();
  }

  void _syncScheduledPromptTimer() {
    final shouldRun =
        !_disposed &&
        _scheduledPromptsLoaded &&
        _appForeground &&
        configured &&
        _api != null &&
        scheduledPrompts.any((item) => item.enabled);
    if (!shouldRun) {
      _scheduledPromptTimer?.cancel();
      _scheduledPromptTimer = null;
      return;
    }
    if (_scheduledPromptTimer != null) return;
    _scheduledPromptTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_dispatchDueScheduledPrompts());
    });
    unawaited(_dispatchDueScheduledPrompts());
  }

  Future<void> _dispatchDueScheduledPrompts() async {
    final api = _api;
    if (_scheduledPromptDispatching ||
        !_appForeground ||
        !configured ||
        api == null) {
      return;
    }
    final now = DateTime.now();
    final due = scheduledPrompts
        .where((item) => item.enabled && !item.nextRunAt.isAfter(now))
        .toList();
    if (due.isEmpty) return;

    _scheduledPromptDispatching = true;
    try {
      for (final item in due) {
        if (!_appForeground || _api != api) break;
        final index = scheduledPrompts.indexWhere(
          (current) =>
              current.id == item.id &&
              current.enabled &&
              !current.nextRunAt.isAfter(DateTime.now()),
        );
        if (index < 0) continue;

        final attemptedAt = DateTime.now();
        final updated = item.copyWith(
          nextRunAt: attemptedAt.add(Duration(minutes: item.intervalMinutes)),
          lastRunAt: attemptedAt,
          clearLastError: true,
        );
        scheduledPrompts = [...scheduledPrompts]..[index] = updated;
        await _persistScheduledPrompts();
        notifyListeners();

        try {
          await api.createPrompt(
            content: item.prompt,
            projectId: item.projectId,
          );
          _recordAcceptedSend(api, item.projectId, attemptedAt);
          if (activeProjectId == item.projectId) {
            unawaited(_onPromptUpdated());
          }
        } catch (error) {
          final currentIndex = scheduledPrompts.indexWhere(
            (current) => current.id == item.id,
          );
          if (currentIndex >= 0) {
            scheduledPrompts = [...scheduledPrompts]
              ..[currentIndex] = scheduledPrompts[currentIndex].copyWith(
                lastError: error.toString().replaceFirst('Exception: ', ''),
              );
            await _persistScheduledPrompts();
            notifyListeners();
          }
        }
      }
    } finally {
      _scheduledPromptDispatching = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appForeground = state == AppLifecycleState.resumed;
    if (_appForeground) {
      _ensureProgressPolling();
      _startRuntimePolling();
    } else {
      _runtimePollTimer?.cancel();
      _runtimePollTimer = null;
      _progressPollTimer?.cancel();
      _progressPollTimer = null;
    }
    _syncScheduledPromptTimer();
  }

  Future<List<int>> downloadAttachmentBytes(String fileId) async {
    final api = _api;
    if (api == null) throw Exception('未连接服务器');
    return api.downloadFileBytes(fileId);
  }

  AttachmentDownloadState? attachmentDownloadOf(String fileId) =>
      attachmentDownloads[fileId];

  Future<Directory> _resolveAttachmentSaveDir() async {
    if (!kIsWeb && Platform.isAndroid) {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final d = Directory('${ext.path}/CodeAssistDownloads');
        if (!await d.exists()) await d.create(recursive: true);
        return d;
      }
    }
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/CodeAssistDownloads');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 下载附件到本地；状态保存在 [attachmentDownloads]，滑动聊天不会中断/清空进度
  Future<AttachmentDownloadState> downloadAttachmentFile({
    required String fileId,
    required String fileName,
  }) async {
    final current = attachmentDownloads[fileId];
    if (current?.status == AttachmentDownloadStatus.downloading) {
      return current!;
    }

    attachmentDownloads[fileId] = AttachmentDownloadState(
      fileId: fileId,
      status: AttachmentDownloadStatus.downloading,
      savedPath: current?.savedPath,
    );
    notifyListeners();

    try {
      final bytes = await downloadAttachmentBytes(fileId);
      final saveDir = await _resolveAttachmentSaveDir();
      final safeName = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final file = File('${saveDir.path}/$safeName');
      await file.writeAsBytes(bytes, flush: true);
      final done = AttachmentDownloadState(
        fileId: fileId,
        status: AttachmentDownloadStatus.done,
        savedPath: file.path,
      );
      attachmentDownloads[fileId] = done;
      notifyListeners();
      return done;
    } catch (e) {
      final failed = AttachmentDownloadState(
        fileId: fileId,
        status: AttachmentDownloadStatus.failed,
        savedPath: current?.savedPath,
        error: e.toString(),
      );
      attachmentDownloads[fileId] = failed;
      notifyListeners();
      return failed;
    }
  }

  Future<void> sendImageToAgent({
    required String fileName,
    required List<int> bytes,
    String? mimeType,
    String? message,
  }) async {
    final api = _api;
    final projectId = activeProjectId;
    if (api == null) throw Exception('未连接服务器');
    if (projectId == null) throw Exception('请先在右上角选择 AI 项目');
    if (bytes.isEmpty) throw Exception('图片为空');
    if (bytes.length > 100 * 1024 * 1024) {
      throw Exception('文件过大（最大 100MB）');
    }
    final chatSessionId = await _chatForSending(projectId, api);
    final b64 = base64Encode(bytes);
    final sentAt = DateTime.now();
    await api.uploadFileToAgent(
      projectId: projectId,
      chatSessionId: chatSessionId,
      fileName: fileName,
      contentBase64: b64,
      mimeType: mimeType,
      message: message,
    );
    _recordAcceptedSend(api, projectId, sentAt);
    await _loadMessagesForActiveChat();
    _ensureProgressPolling();
    notifyListeners();
  }

  void _connectWs() {
    _wsSub?.cancel();
    _ws?.sink.close();
    _wsConnected = false;
    final httpUrl = serverUrl.replaceAll(RegExp(r'/+$'), '');
    // 云端：.../codeassist/ws ；本地 Node：.../ws
    final wsUrl = '$httpUrl/ws'
        .replaceFirst(RegExp(r'^http'), 'ws')
        .replaceFirst(RegExp(r'^https'), 'wss');
    final uri = Uri.parse('$wsUrl?token=${Uri.encodeComponent(token)}');
    try {
      _ws = WebSocketChannel.connect(uri);
      final channel = _ws!;
      channel.ready
          .then((_) {
            if (identical(_ws, channel)) {
              _wsConnected = true;
              _wsReconnectAttempt = 0;
              _ensureProgressPolling();
              unawaited(_refreshRuntimeState());
            }
          })
          .catchError((Object _) {
            _onWsDisconnected(channel);
          });
      _wsSub = channel.stream.listen(
        _onWsMessage,
        onError: (_) => _onWsDisconnected(channel),
        onDone: () => _onWsDisconnected(channel),
      );
      _sendSubscribe();
    } catch (_) {
      // WS 失败时仍靠轮询
      _ensureProgressPolling();
      _scheduleReconnect();
    }
  }

  void _onWsDisconnected(WebSocketChannel channel) {
    if (!identical(_ws, channel)) return;
    _wsConnected = false;
    _ensureProgressPolling();
    _scheduleReconnect();
  }

  void _sendSubscribe() {
    // 项目动态需要同时接收其他工作区的 prompt.updated 事件。
    _ws?.sink.add(jsonEncode({'type': 'subscribe'}));
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
              projects = [...projects, p];
            }
          }
          _setProjects(projects);
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
          _upsertProjectActivity(payload);
          if (payload['projectId'] == activeProjectId) {
            _applyPromptDeliveryPayload(payload);
            unawaited(_onPromptUpdated());
          } else {
            notifyListeners();
          }
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
            chatSessions = chatSessions
                .where((s) => s.id != deletedId)
                .toList();
            if (activeChatSessionId == deletedId) {
              activeChatSessionId = chatSessions.isNotEmpty
                  ? chatSessions.first.id
                  : null;
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
        case 'codex.usage.updated':
          final usage = CodexUsageSnapshot.fromJson(payload);
          codexUsageByProject[usage.projectId] = usage;
          notifyListeners();
          break;
        default:
          break;
      }
    } catch (_) {
      // ignore malformed
    }
  }

  void _upsertProjectActivity(Map<String, dynamic> payload) {
    final promptId = payload['promptId'] as String?;
    final projectId = payload['projectId'] as String?;
    final status = payload['status'] as String?;
    if (promptId == null || projectId == null || status == null) return;
    if (payload['attachment'] is Map &&
        (payload['attachment'] as Map)['direction'] != 'to_agent') {
      return;
    }

    final key = '$projectId:$promptId';
    final previousItems = projectActivities
        .where((item) => '${item.projectId}:${item.promptId}' == key)
        .toList();
    final previous = previousItems.isEmpty ? null : previousItems.first;
    final timestamp = payload['updatedAt'] as String?;
    final updatedMillis = DateTime.tryParse(
      timestamp ?? '',
    )?.millisecondsSinceEpoch;
    if (previous != null &&
        !acceptsPromptUpdate(
          previousStatus: previous.status,
          previousResult: previous.result,
          previousUpdatedMillis: previous.updatedMillis,
          incomingStatus: status,
          incomingResult: payload['result'] as String?,
          incomingUpdatedMillis: updatedMillis ?? previous.updatedMillis,
        )) {
      return;
    }
    final items = projectActivities
        .where((item) => '${item.projectId}:${item.promptId}' != key)
        .toList();
    items.insert(
      0,
      ProjectActivity(
        id: payload['id'] as String? ?? previous?.id ?? promptId,
        promptId: promptId,
        projectId: projectId,
        content: payload['content'] as String? ?? previous?.content ?? '',
        status: status,
        createdAt: payload['createdAt'] as String? ?? previous?.createdAt,
        updatedAt:
            payload['updatedAt'] as String? ??
            DateTime.now().toUtc().toIso8601String(),
        result: payload['result'] as String? ?? previous?.result,
        chatSessionId:
            payload['chatSessionId'] as String? ?? previous?.chatSessionId,
      ),
    );
    _setProjectActivities(items);
  }

  void _recordProjectSends(Map<String, int> timestamps) {
    var changed = false;
    for (final project in projects) {
      final sentAt = timestamps[project.id];
      if (sentAt != null && _projectOrder.recordSend(project, sentAt)) {
        changed = true;
      }
    }
    if (changed) _setProjects(projects);
  }

  void _recordAcceptedSend(ApiClient api, String projectId, DateTime sentAt) {
    if (!identical(api, _api) || _disposed) return;
    _recordProjectSends({projectId: sentAt.millisecondsSinceEpoch});
    notifyListeners();
  }

  void _setProjectActivities(List<ProjectActivity> items) {
    final terminalCounts = <String, int>{};
    final timestamps = <String, int>{};
    projectActivities = items.where((item) {
      if (item.isIncomingFile) return false;
      final sentAt = DateTime.tryParse(
        item.createdAt ?? '',
      )?.millisecondsSinceEpoch;
      if (sentAt != null && sentAt > (timestamps[item.projectId] ?? 0)) {
        timestamps[item.projectId] = sentAt;
      }
      if (item.isInFlight) return true;
      final count = terminalCounts.update(
        item.projectId,
        (n) => n + 1,
        ifAbsent: () => 1,
      );
      return count <= 100;
    }).toList();
    _recordProjectSends(timestamps);
  }

  Future<void> refreshProjectActivity({bool force = false}) async {
    final api = _api;
    if (api == null || identical(api, _activityRefreshApi) || _disposed) return;
    final projectIds = visibleProjects.map((project) => project.id).toList();
    if (projectIds.isEmpty) return;
    final now = DateTime.now();
    if (!force &&
        _lastActivityRefresh != null &&
        now.difference(_lastActivityRefresh!) < const Duration(seconds: 30)) {
      return;
    }
    _lastActivityRefresh = now;
    _activityRefreshApi = api;
    void merge(List<ProjectActivity> incoming, Iterable<String> loaded) {
      final ids = loaded.toSet();
      final byId = {
        for (final row in incoming) (row.projectId, row.promptId): row,
      };
      for (final row in projectActivities) {
        final key = (row.projectId, row.promptId);
        final fetched = byId[key];
        if (!ids.contains(row.projectId)) {
          byId[key] = row;
        } else if (fetched == null) {
          if (row.updatedMillis >= now.millisecondsSinceEpoch) byId[key] = row;
        } else if (!acceptsPromptUpdate(
          previousStatus: row.status,
          previousResult: row.result,
          previousUpdatedMillis: row.updatedMillis,
          incomingStatus: fetched.status,
          incomingResult: fetched.result,
          incomingUpdatedMillis: fetched.updatedMillis,
        )) {
          byId[key] = row;
        }
      }
      final sorted = byId.values.toList()
        ..sort((a, b) => b.updatedMillis.compareTo(a.updatedMillis));
      _setProjectActivities(sorted);
      projectActivityLoaded.addAll(ids);
      notifyListeners();
    }

    try {
      if (isLanMode) {
        try {
          final rows = await api.listRecentProjectActivity().timeout(
            const Duration(seconds: 12),
          );
          if (!_disposed && identical(api, _api)) merge(rows, projectIds);
          return;
        } catch (_) {
          /* Older relays support the per-project prompts endpoint. */
        }
      }
      for (var offset = 0; offset < projectIds.length; offset += 4) {
        final batch = projectIds.skip(offset).take(4);
        final snapshots = await Future.wait(
          batch.map((id) async {
            try {
              return (id: id, rows: await api.listProjectDeliveries(id));
            } catch (_) {
              return (id: id, rows: null);
            }
          }),
        );
        if (_disposed || !identical(api, _api)) return;
        final successful = snapshots.where((snapshot) => snapshot.rows != null);
        merge(
          successful.expand((snapshot) => snapshot.rows!).toList(),
          successful.map((snapshot) => snapshot.id),
        );
      }
    } finally {
      if (identical(_activityRefreshApi, api)) _activityRefreshApi = null;
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
      final oldTime =
          DateTime.tryParse(old.updatedAt)?.millisecondsSinceEpoch ?? 0;
      if (!acceptsPromptUpdate(
        previousStatus: old.status,
        previousResult: old.result,
        previousUpdatedMillis: oldTime,
        incomingStatus: status,
        incomingResult: result,
        incomingUpdatedMillis:
            DateTime.tryParse(updatedAt ?? '')?.millisecondsSinceEpoch ??
            oldTime,
      )) {
        return;
      }
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

  Iterable<PromptJob> get _inFlightMessages {
    final now = DateTime.now();
    return chatMessages.where(
      (message) => isActivePromptStatus(
        displayPromptStatus(
          message.status,
          message.result,
          message.updatedAt,
          now,
        ),
      ),
    );
  }

  bool get _hasInFlightMessages => _inFlightMessages.isNotEmpty;

  void _ensureProgressPolling() {
    unawaited(() async {
      if (_hasInFlightMessages) {
        await BackgroundWatchService.seedWatchingIds(
          _inFlightMessages.map((m) => m.id),
        );
      }
      await BackgroundWatchService.ensureWatching(
        hasInFlight: _hasInFlightMessages,
      );
    }());
    if (_disposed || !_hasInFlightMessages || _wsConnected || !_appForeground) {
      _progressPollTimer?.cancel();
      _progressPollTimer = null;
      return;
    }
    if (_progressPollTimer != null) return;
    _progressPollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_disposed || !_hasInFlightMessages) {
        _progressPollTimer?.cancel();
        _progressPollTimer = null;
        unawaited(BackgroundWatchService.ensureWatching(hasInFlight: false));
        return;
      }
      try {
        await _loadMessagesForActiveChat();
        if (activeProjectId != null && _api != null) {
          chatSessions = await _api!.listChatSessions(
            projectId: activeProjectId,
          );
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

  void _scheduleReconnect({bool refreshData = false}) {
    if (_disposed || !configured) return;
    if (_reconnectTimer != null) return;
    final delaySeconds = switch (_wsReconnectAttempt) {
      0 => 3,
      1 => 6,
      2 => 12,
      3 => 24,
      4 => 48,
      _ => 60,
    };
    if (_wsReconnectAttempt < 5) _wsReconnectAttempt++;
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      _reconnectTimer = null;
      if (_disposed) return;
      if (refreshData) {
        unawaited(connect());
      } else {
        _connectWs();
      }
    });
  }

  @override
  void dispose() {
    _activitySaveTimer?.cancel();
    _runtimePollTimer?.cancel();
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    _progressPollTimer?.cancel();
    _scheduledPromptTimer?.cancel();
    _wsSub?.cancel();
    _ws?.sink.close();
    super.dispose();
  }
}
