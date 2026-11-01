import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class CrashLogService {
  CrashLogService._();
  static final CrashLogService instance = CrashLogService._();

  File? _file;

  void installHooks() {
    FlutterError.onError = (details) {
      unawaited(logError('FlutterError', details.exception, details.stack));
      FlutterError.presentError(details);
    };
  }

  Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/crash_log.txt');
      if (!await _file!.exists()) {
        await _file!.writeAsString('');
      }
    } catch (_) {}
  }

  Future<void> log(String tag, String message) async {
    final line = '[${DateTime.now().toIso8601String()}] $tag: $message\n';
    try {
      await _file?.writeAsString(line, mode: FileMode.append);
    } catch (_) {}
  }

  Future<void> logError(String tag, Object error, [StackTrace? stack]) async {
    final line =
        '[${DateTime.now().toIso8601String()}] $tag: $error\n${stack ?? ''}\n---\n';
    try {
      await _file?.writeAsString(line, mode: FileMode.append);
    } catch (_) {}
  }

  Future<String> readAll() async {
    try {
      return await _file?.readAsString() ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> clear() async {
    try {
      await _file?.writeAsString('');
    } catch (_) {}
  }

  Future<String> exportPath() async => _file?.path ?? '';

  Future<String> tryReadLogcat() async => '';
}
