import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_client.dart';
import 'auth_api.dart';
import 'background_watch_service.dart';
import 'ide_labels.dart';
import 'models.dart';
import 'notification_service.dart';

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

class AppState extends ChangeNotifier {
  static const _kUrl = 'server_url';
  static const _kApiRoot = 'api_root';
  static const _kToken = 'access_token';
  static const _kUsername = 'username';
  static const _kNickName = 'nick_name';
  static const _kActiveProject = 'active_project_id';
  static const _kActiveChat = 'active_chat_session_id';
  static const _kConnMode = 'connection_mode';
  static const _kRecentWorkspaces = 'recent_workspace_paths';

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
  List<String> recentWorkspacePaths = [];
  /// 附件下载状态（按 fileId），不绑在聊天气泡 State 上，避免滑动回收取消 UI
  final Map<String, AttachmentDownloadState> attachmentDownloads = {};
  List<TaskEvent> tasks = [];
  List<PromptJob> prompts = [];
  List<PromptJob> chatMessages = [];
  List<ChatSession> chatSessions = [];
  List<SessionContext> sessions = [];

  String? activeProjectId;
  String? activeChatSessionId;

  ApiClient? _api;
  ApiClient? get apiOrNull => _api;
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
    apiRoot = prefs.getString(_kApiRoot) ?? apiRoot;
    token = prefs.getString(_kToken) ?? token;
    username = prefs.getString(_kUsername) ?? '';
    nickName = prefs.getString(_kNickName) ?? '';
    activeProjectId = prefs.getString(_kActiveProject);
    activeChatSessionId = prefs.getString(_kActiveChat);
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
      final looksLan = u.isNotEmpty &&
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
    _wsSub?.cancel();
    _wsSub = null;
    await _ws?.sink.close();
    _ws = null;
    _reconnectTimer?.cancel();
    _progressPollTimer?.cancel();
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
    connecting = true;
    error = null;
    notifyListeners();
    _api = ApiClient(baseUrl: serverUrl, token: token);
    try {
      await refreshAll();
      _connectWs();
      _ensureProgressPolling();
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
      final online = projects.where((p) => p.isEffectivelyOnline()).toList();
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
      throw Exception('请先选择 AI 项目');
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
      final ok = next.status != 'failed';
      final preview = (next.result ?? next.content).trim();
      final body = preview.isEmpty
          ? (ok ? '指令已完成' : '指令执行失败')
          : (preview.length > 120 ? '${preview.substring(0, 120)}…' : preview);
      try {
        _playCompletionSound();
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

  String _activeIdeLabel() =>
      activeProject?.ideLabel ?? kGenericIdeLabel;

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
        title: '${_activeIdeLabel()} 任务完成',
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
      final anyOnline =
          projects.where((p) => p.isEffectivelyOnline()).toList();
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

    // 等待 PC 认领执行（最多约 20s），期间多次刷新项目列表
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      await refreshAll();
      if (id != null) {
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
    await refreshAll();

    if (status == 'failed') {
      throw Exception(err?.isNotEmpty == true ? err! : 'PC 打开项目失败');
    }
    if (status == 'queued' || status == 'claimed') {
      return '已下发打开指令，请稍后点刷新查看新项目（状态：$status）';
    }
    return 'PC 已打开，项目列表已刷新';
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
      throw Exception('请先在右上角选择 AI 项目');
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
    var chatSessionId = activeChatSessionId;
    if (api == null) throw Exception('未连接服务器');
    if (projectId == null) throw Exception('请先在右上角选择 AI 项目');
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
    // 云端：.../codeassist/ws ；本地 Node：.../ws
    final wsUrl = '$httpUrl/ws'
        .replaceFirst(RegExp(r'^http'), 'ws')
        .replaceFirst(RegExp(r'^https'), 'wss');
    final uri = Uri.parse('$wsUrl?token=${Uri.encodeComponent(token)}');
    try {
      _ws = WebSocketChannel.connect(uri);
      _wsSub = _ws!.stream.listen(
        _onWsMessage,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
      );
      _sendSubscribe();
    } catch (_) {
      // WS 失败时仍靠轮询
      _ensureProgressPolling();
    }
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
