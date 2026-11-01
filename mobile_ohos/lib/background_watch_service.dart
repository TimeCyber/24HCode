/// 鸿蒙版：无 Android 前台服务，降级为空实现（前台轮询仍由 AppState 负责）
class BackgroundWatchService {
  BackgroundWatchService._();

  static Future<void> init() async {}

  static Future<void> setAppForeground(bool fg) async {}

  static Future<bool> isAppForeground() async => true;

  static Future<void> ensureWatching({required bool hasInFlight}) async {}

  static Future<void> seedWatchingIds(Iterable<String> ids) async {}
}
