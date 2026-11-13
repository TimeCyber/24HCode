import 'dart:typed_data';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'remote_request.dart';

/// Android 10+ 的高重要性任务提醒。完成与待确认使用独立通知渠道。
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  // Android 8+ 的渠道行为由系统保存；更新提醒策略时使用新的渠道 id。
  static const _completionChannelId = 'codeassist_task_done_v7';
  static const _completionChannelName = '任务完成提醒';
  static const _completionChannelDesc = '任务完成或失败时弹出提醒并播放提示音';
  static const _approvalChannelId = 'codeassist_task_approval_v7';
  static const _approvalChannelName = '待确认提醒';
  static const _approvalChannelDesc = '需要你确认操作时弹出提醒并播放提示音';
  static const _sound = RawResourceAndroidNotificationSound('task_done');

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _seq = 0;

  Future<void> init() async {
    if (_ready) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _plugin.initialize(settings: initSettings);

    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _completionChannelId,
        _completionChannelName,
        description: _completionChannelDesc,
        importance: Importance.max,
        playSound: true,
        sound: _sound,
        enableVibration: true,
        enableLights: true,
        showBadge: true,
        audioAttributesUsage: AudioAttributesUsage.notification,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _approvalChannelId,
        _approvalChannelName,
        description: _approvalChannelDesc,
        importance: Importance.max,
        playSound: true,
        sound: _sound,
        enableVibration: true,
        enableLights: true,
        showBadge: true,
        audioAttributesUsage: AudioAttributesUsage.notification,
      ),
    );
    try {
      await android?.requestNotificationsPermission();
    } catch (_) {}
    _ready = true;
  }

  AndroidNotificationDetails _details({
    required String channelId,
    required String channelName,
    required String channelDescription,
    required String title,
    required String body,
    bool onlyAlertOnce = false,
  }) {
    return AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
      sound: _sound,
      enableVibration: true,
      vibrationPattern: Int64List.fromList(const [0, 400, 160, 400, 160, 400]),
      enableLights: true,
      category: AndroidNotificationCategory.message,
      visibility: NotificationVisibility.public,
      ticker: title,
      autoCancel: true,
      channelShowBadge: true,
      onlyAlertOnce: onlyAlertOnce,
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: title,
        summaryText: 'CodeAssist',
      ),
      audioAttributesUsage: AudioAttributesUsage.notification,
    );
  }

  Future<void> _ensureNotificationsEnabled() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (await android?.areNotificationsEnabled() == false) {
      throw StateError('系统已关闭 CodeAssist 通知，请在 Android 设置中重新启用');
    }
  }

  Future<void> showPendingApproval(TaskEvent task, String scope) async {
    if (!isPendingApproval(task)) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final key = 'approval_notified_v2_$scope';
    final receipts = prefs.getStringList(key) ?? <String>[];
    if (receipts.contains(task.id) ||
        (prefs.getStringList('task_notified_v2_$scope')?.contains(task.id) ??
            false)) {
      return;
    }
    await init();
    if (!isPendingApproval(task)) return;
    await _ensureNotificationsEnabled();
    final id =
        0x40000000 +
        task.id.codeUnits.fold<int>(
          0,
          (hash, unit) => (hash * 31 + unit) & 0x1fffffff,
        );
    const title = 'CodeAssist 待确认';
    final request = RemoteRequest.parse(task.detail);
    final reason = request?.reason.trim() ?? '';
    final detail = reason.isEmpty ? task.title : '${task.title}：$reason';
    final preview = detail.length > 180
        ? '${detail.substring(0, 180)}…'
        : detail;
    final body = '$preview\n打开 CodeAssist 查看并处理';
    // Replace a same-id notification created by an older, potentially silent channel.
    await _plugin.cancel(id: id);
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: _details(
          channelId: _approvalChannelId,
          channelName: _approvalChannelName,
          channelDescription: _approvalChannelDesc,
          title: title,
          body: body,
          onlyAlertOnce: true,
        ),
      ),
    );
    await prefs.reload();
    final updated = {...?prefs.getStringList(key), task.id}.toList();
    await prefs.setStringList(
      key,
      updated.length <= 200 ? updated : updated.sublist(updated.length - 200),
    );
  }

  Future<void> showTaskCompleted({
    required String title,
    required String body,
  }) async {
    await init();
    await _ensureNotificationsEnabled();
    _seq = (_seq + 1) % 100000;
    final id = 920000 + _seq;
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: _details(
          channelId: _completionChannelId,
          channelName: _completionChannelName,
          channelDescription: _completionChannelDesc,
          title: title,
          body: body,
        ),
      ),
    );
  }
}
