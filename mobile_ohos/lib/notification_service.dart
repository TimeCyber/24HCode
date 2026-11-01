/// 鸿蒙版：本地通知暂用控制台占位（后续可接 NotificationKit）
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  Future<void> init() async {}

  Future<void> showTaskCompleted({
    required String title,
    required String body,
    String? payload,
  }) async {
    // ignore: avoid_print
    print('[ohos-notify] $title | $body');
  }
}
