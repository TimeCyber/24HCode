import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 本地推送：任务完成时通知栏 + 横幅 + 声音。
/// 安卓 10 上避免 MessagingStyle / 强依赖全屏意图导致整条通知被 OEM 丢掉。
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  // Android 8+ 渠道创建后声音/重要性不可改；换 id 强制重建
  static const _channelId = 'codeassist_alert_heads_up_v6';
  static const _channelName = '任务完成提醒';
  static const _channelDesc = '任务完成时通知栏提醒并响铃震动';
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
    try {
      await android?.requestNotificationsPermission();
    } catch (_) {}
    try {
      await android?.requestFullScreenIntentPermission();
    } catch (_) {}
    _ready = true;
  }

  AndroidNotificationDetails _details({
    required String title,
    required String body,
    required bool fullScreen,
  }) {
    return AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
      sound: _sound,
      enableVibration: true,
      vibrationPattern: Int64List.fromList(
        const [0, 400, 160, 400, 160, 400],
      ),
      enableLights: true,
      category: AndroidNotificationCategory.message,
      visibility: NotificationVisibility.public,
      ticker: title,
      autoCancel: true,
      channelShowBadge: true,
      onlyAlertOnce: false,
      fullScreenIntent: fullScreen,
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: title,
        summaryText: 'CodeAssist',
      ),
      audioAttributesUsage: AudioAttributesUsage.notification,
    );
  }

  Future<void> showTaskCompleted({
    required String title,
    required String body,
  }) async {
    await init();
    _seq = (_seq + 1) % 100000;
    final id = 910000 + _seq;

    // 先走安卓 10 更稳的 BigText；失败再降级无自定义音 / 无全屏意图
    Object? lastError;
    for (final fullScreen in const [true, false]) {
      try {
        await _plugin.show(
          id: id,
          title: title,
          body: body,
          notificationDetails: NotificationDetails(
            android: _details(title: title, body: body, fullScreen: fullScreen),
          ),
        );
        lastError = null;
        break;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError != null) {
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
            enableVibration: true,
            category: AndroidNotificationCategory.alarm,
            visibility: NotificationVisibility.public,
            ticker: title,
            autoCancel: true,
            styleInformation: BigTextStyleInformation(
              body,
              contentTitle: title,
            ),
          ),
        ),
      );
    }

    try {
      await SystemSound.play(SystemSoundType.alert);
      await HapticFeedback.heavyImpact();
    } catch (_) {}
  }
}
