import 'dart:io';

import 'package:flutter/services.dart';

/// 安卓安全语音：走系统 RecognizerIntent，避免华为 FakeRecognitionService 闪退。
class SafeSpeech {
  SafeSpeech._();

  static const _channel = MethodChannel('codeassist/safe_speech');

  /// 弹出系统语音界面，返回识别文字；取消或失败返回空串 / 抛错。
  static Future<String> recognize({
    String locale = 'zh-CN',
    String prompt = '请说话',
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('SafeSpeech is Android-only');
    }
    final raw = await _channel.invokeMethod<String>('recognize', {
      'locale': locale,
      'prompt': prompt,
    });
    return (raw ?? '').trim();
  }
}
