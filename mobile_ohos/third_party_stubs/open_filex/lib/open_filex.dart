enum ResultType { done, error, noApp, fileNotFound, permissionDenied }

class OpenResult {
  OpenResult({this.type = ResultType.done, this.message = 'ok'});
  final ResultType type;
  final String message;
}

class OpenFilex {
  static Future<OpenResult> open(String filePath, {String? type, String? uti}) async {
    return OpenResult(message: '鸿蒙版暂不支持系统打开文件');
  }
}
