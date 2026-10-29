import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 收集 Flutter / Zone 异常与业务面包屑，供「闪退日志」按钮查看。
/// 原生层直接 SIGSEGV 时，至少能看到崩溃前最后几条面包屑。
class CrashLogService {
  CrashLogService._();
  static final CrashLogService instance = CrashLogService._();

  static const _fileName = 'crash_log.txt';
  static const _maxBytes = 256 * 1024;
  final _lock = Object();
  File? _file;
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/$_fileName');
      if (!await _file!.exists()) {
        await _file!.writeAsString('=== CodeAssist crash log ===\n');
      }
      await log('app_start', 'CrashLogService ready');
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  Future<File> _ensureFile() async {
    if (_file != null) return _file!;
    await init();
    return _file!;
  }

  Future<void> log(String tag, String message) async {
    try {
      final f = await _ensureFile();
      final line =
          '${DateTime.now().toIso8601String()} [$tag] $message\n';
      await f.writeAsString(line, mode: FileMode.append, flush: true);
      await _trimIfNeeded(f);
    } catch (_) {}
  }

  Future<void> logError(
    String tag,
    Object error,
    StackTrace? stack,
  ) async {
    final buf = StringBuffer()
      ..writeln('----- ERROR -----')
      ..writeln(error.toString());
    if (stack != null) {
      buf.writeln(stack.toString());
    }
    buf.writeln('----- END -----');
    await log(tag, buf.toString());
  }

  Future<void> _trimIfNeeded(File f) async {
    try {
      final len = await f.length();
      if (len <= _maxBytes) return;
      final text = await f.readAsString();
      final keep = text.substring(text.length ~/ 2);
      await f.writeAsString(
        '=== CodeAssist crash log (trimmed) ===\n$keep',
        flush: true,
      );
    } catch (_) {}
  }

  Future<String> readAll() async {
    try {
      final f = await _ensureFile();
      if (!await f.exists()) return '（暂无日志）';
      final text = await f.readAsString();
      return text.isEmpty ? '（暂无日志）' : text;
    } catch (e) {
      return '读取失败：$e';
    }
  }

  Future<void> clear() async {
    try {
      final f = await _ensureFile();
      await f.writeAsString(
        '=== CodeAssist crash log (cleared ${DateTime.now().toIso8601String()}) ===\n',
        flush: true,
      );
    } catch (_) {}
  }

  /// 尽量抓取本机 logcat（多数正式包无权限，失败则忽略）
  Future<String> tryReadLogcat() async {
    if (!Platform.isAndroid) return '';
    try {
      final r = await Process.run(
        'logcat',
        ['-d', '-t', '120', '*:W'],
        runInShell: false,
      ).timeout(const Duration(seconds: 3));
      final out = (r.stdout as String? ?? '').trim();
      if (out.isEmpty) return '';
      return '\n\n===== logcat (may be empty without permission) =====\n$out\n';
    } catch (e) {
      return '\n\n===== logcat unavailable: $e =====\n';
    }
  }

  void installHooks() {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      unawaited(
        logError(
          'FlutterError',
          details.exceptionAsString(),
          details.stack,
        ),
      );
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(logError('PlatformDispatcher', error, stack));
      return true;
    };
  }
}
