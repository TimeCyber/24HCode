import 'dart:typed_data';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 本地推送：Cursor 任务 / 指令完成后提醒（横幅 + 声音）。
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  // Android 8+ 渠道创建后声音/重要性不可改，必须换 id
  static const _channelId = 'codeassist_tasks_heads_up_v4';
  static const _channelName = '任务完成横幅';
  static const _channelDesc = '任务完成时弹出横幅并响铃';
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

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDesc,
        importance: Importance.max,
        playSound: true,
        sound: _sound,
        enableVibration: true,
        enableLights: true,
        showBadge: true,
        audioAttributesUsage: AudioAttributesUsage.notification,
      ),
    );
    await android?.requestNotificationsPermission();
    _ready = true;
  }

  Future<void> showTaskCompleted({
    required String title,
    required String body,
  }) async {
    await init();
    _seq = (_seq + 1) % 100000;
    final id = 900000 + _seq;

    // 先发可靠的基础通知（后台 isolate 更稳），失败再降级
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDesc,
            importance: Importance.max,
            priority: Priority.max,
            playSound: true,
            sound: _sound,
            enableVibration: true,
            vibrationPattern: Int64List.fromList(const [0, 280, 120, 280]),
            enableLights: true,
            category: AndroidNotificationCategory.message,
            visibility: NotificationVisibility.public,
            ticker: title,
            autoCancel: true,
            channelShowBadge: true,
            onlyAlertOnce: false,
            styleInformation: BigTextStyleInformation(
              body,
              contentTitle: title,
              summaryText: 'CodeAssist',
            ),
            audioAttributesUsage: AudioAttributesUsage.notification,
          ),
        ),
      );
      return;
    } catch (_) {
      // fall through
    }

    // 降级：无自定义铃声 / 无富文本
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.public,
          ticker: 'CodeAssist',
          autoCancel: true,
        ),
      ),
    );
  }
}
