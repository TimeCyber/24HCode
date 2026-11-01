/// 鸿蒙版：语音识别暂未接入
class SafeSpeech {
  SafeSpeech._();

  static Future<String> recognize({
    String locale = 'zh-CN',
    String prompt = '请说话',
  }) async {
    throw UnsupportedError('鸿蒙版暂未支持语音输入，请使用键盘输入');
  }
}
