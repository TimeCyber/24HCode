import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_service.dart';

const kAppForegroundPref = 'app_in_foreground';
const _kUrl = 'server_url';
const _kToken = 'access_token';
const _kActiveChat = 'active_chat_session_id';
const _kNotifiedIds = 'bg_notified_prompt_ids';
const _kWatchingIds = 'bg_watching_prompt_ids';

@pragma('vm:entry-point')
void codeAssistStartCallback() {
  FlutterForegroundTask.setTaskHandler(CodeAssistWatchHandler());
}

/// 有进行中指令时启动前台服务，后台继续轮询并弹本地通知。
class BackgroundWatchService {
  BackgroundWatchService._();

  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'codeassist_watch',
        channelName: '任务监听',
        channelDescription: '应用在后台时监听 AI 任务完成',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(2500),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialized = true;
  }

  static Future<bool> isAppForeground() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getBool(kAppForegroundPref) ?? true;
  }

  static Future<void> setAppForeground(bool foreground) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kAppForegroundPref, foreground);
    await FlutterForegroundTask.saveData(
      key: kAppForegroundPref,
      value: foreground,
    );
  }

  /// 主线程在发现进行中任务时写入，服务重启后仍能识别「该推送」。
  static Future<void> seedWatchingIds(Iterable<String> ids) async {
    final list = ids.where((e) => e.isNotEmpty).toList();
    if (list.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final watching = (prefs.getStringList(_kWatchingIds) ?? []).toSet()
      ..addAll(list);
    await prefs.setStringList(_kWatchingIds, watching.toList());
  }

  /// [hasInFlight] 为 false 时：仅在前台才允许主线程停服务；
  /// 后台由 TaskHandler 推送完成后再自行 stop，避免主线程抢停导致不推送。
  static Future<void> ensureWatching({required bool hasInFlight}) async {
    await init();
    if (!hasInFlight) {
      final fg = await isAppForeground();
      if (!fg) {
        // 后台：保留监听服务，让 isolate 负责推送
        return;
      }
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
      return;
    }

    final notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'CodeAssist 正在等待任务完成',
        notificationText: '可切到后台，完成后会推送通知',
      );
      return;
    }

    // 安卓 10 只声明 dataSync；remoteMessaging 为 API34+，部分机型组合声明会起服失败
    await FlutterForegroundTask.startService(
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: 'CodeAssist 正在等待任务完成',
      notificationText: '可切到后台，完成后会推送通知',
      callback: codeAssistStartCallback,
    );
  }
}

class CodeAssistWatchHandler extends TaskHandler {
  final Map<String, String> _lastStatus = {};
  bool _pluginsReady = false;
  bool _polling = false;

  Future<void> _ensurePlugins() async {
    if (_pluginsReady) return;
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    await NotificationService.instance.init();
    _pluginsReady = true;
  }

  bool _isInFlight(String status, String? result) {
    if (status == 'done' || status == 'failed') return false;
    if (result != null && result.trim().isNotEmpty) return false;
    return status == 'queued' ||
        status == 'delivered' ||
        status == 'running';
  }

  bool _isTerminal(String status, String? result) {
    if (status == 'done' || status == 'failed') return true;
    return result != null && result.trim().isNotEmpty;
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _ensurePlugins();
    await _pollOnce();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_pollOnce());
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  Future<void> _pollOnce() async {
    if (_polling) return;
    _polling = true;
    try {
      await _ensurePlugins();
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      final url = prefs.getString(_kUrl);
      final token = prefs.getString(_kToken);
      final chatId = prefs.getString(_kActiveChat);
      if (url == null ||
          token == null ||
          chatId == null ||
          url.isEmpty ||
          token.isEmpty ||
          chatId.isEmpty) {
        return;
      }

      final base = url.replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse('$base/api/chat-sessions/$chatId/messages');
      final res = await http
          .get(uri, headers: {'Authorization': 'Bearer $token'})
          .timeout(const Duration(seconds: 12));
      if (res.statusCode < 200 || res.statusCode >= 300) return;

      final list = jsonDecode(res.body) as List<dynamic>;
      var hasInFlight = false;
      final notified = (prefs.getStringList(_kNotifiedIds) ?? []).toSet();
      final watching = (prefs.getStringList(_kWatchingIds) ?? []).toSet();
      var didNotify = false;
      var watchingChanged = false;

      for (final raw in list) {
        if (raw is! Map<String, dynamic>) continue;
        final id = raw['id'] as String?;
        final status = raw['status'] as String?;
        if (id == null || status == null) continue;
        final result = (raw['result'] as String?)?.trim();

        final prev = _lastStatus[id];
        final effectiveStatus = _isTerminal(status, result) &&
                status != 'done' &&
                status != 'failed'
            ? 'done'
            : status;

        if (_isInFlight(status, result)) {
          hasInFlight = true;
          if (watching.add(id)) watchingChanged = true;
        }

        final wasWatching = watching.contains(id);
        final becameTerminal = _isTerminal(status, result) &&
            (prev == 'queued' ||
                prev == 'delivered' ||
                prev == 'running' ||
                // 服务重启丢了内存态时：只要曾在 watching 列表里，终态也要推
                (prev == null && wasWatching));

        _lastStatus[id] = effectiveStatus;

        if (!becameTerminal) continue;
        if (notified.contains(id)) {
          if (watching.remove(id)) watchingChanged = true;
          continue;
        }

        final ok = status != 'failed';
        final content = (raw['content'] as String?)?.trim() ?? '';
        final preview = (result != null && result.isNotEmpty)
            ? result
            : (content.isNotEmpty ? content : (ok ? '指令已完成' : '指令执行失败'));
        final body = preview.length > 120
            ? '${preview.substring(0, 120)}…'
            : preview;

        try {
          await NotificationService.instance.showTaskCompleted(
            title: ok ? '任务完成' : '任务失败',
            body: body,
          );
          // 成功后才写入 notified，失败下一轮还能重试
          notified.add(id);
          if (watching.remove(id)) watchingChanged = true;
          await FlutterForegroundTask.updateService(
            notificationTitle: ok ? '任务完成' : '任务失败',
            notificationText:
                body.length > 60 ? '${body.substring(0, 60)}…' : body,
          );
          didNotify = true;
        } catch (e) {
          await FlutterForegroundTask.updateService(
            notificationTitle: '任务完成但通知失败',
            notificationText: e.toString().length > 80
                ? '${e.toString().substring(0, 80)}…'
                : e.toString(),
          );
        }
      }

      final trimmedNotified = notified.toList();
      await prefs.setStringList(
        _kNotifiedIds,
        trimmedNotified.length > 200
            ? trimmedNotified.sublist(trimmedNotified.length - 200)
            : trimmedNotified,
      );
      if (watchingChanged || !hasInFlight) {
        await prefs.setStringList(_kWatchingIds, watching.toList());
      }

      if (!hasInFlight) {
        if (didNotify || watching.isEmpty) {
          if (didNotify) {
            await Future<void>.delayed(const Duration(milliseconds: 1200));
          }
          FlutterForegroundTask.sendDataToMain({'action': 'stop_watch'});
          await FlutterForegroundTask.stopService();
        } else {
          // 已终态但弹通知失败：保留服务下一轮重试（安卓 10 常见）
          await FlutterForegroundTask.updateService(
            notificationTitle: '任务已完成，正在重试通知',
            notificationText: '若一直无横幅，请检查系统通知权限',
          );
        }
      } else {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'CodeAssist 正在等待任务完成',
          notificationText: '后台监听中…完成后会推送',
        );
      }
    } catch (e) {
      try {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'CodeAssist 监听异常，重试中',
          notificationText: e.toString().length > 80
              ? '${e.toString().substring(0, 80)}…'
              : e.toString(),
        );
      } catch (_) {}
    } finally {
      _polling = false;
    }
  }
}
