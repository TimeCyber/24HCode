import 'package:cross_file/cross_file.dart';

class ShareResult {
  const ShareResult(this.status, [this.raw = '']);
  final ShareResultStatus status;
  final String raw;
}

enum ShareResultStatus { success, dismissed, unavailable }

class ShareParams {
  ShareParams({
    this.text,
    this.subject,
    this.files,
  });

  final String? text;
  final String? subject;
  final List<XFile>? files;
}

class SharePlus {
  SharePlus._();
  static final instance = SharePlus._();

  Future<ShareResult> share(ShareParams params) async {
    return const ShareResult(ShareResultStatus.unavailable);
  }
}

class Share {
  static Future<ShareResult> share(String text, {String? subject}) async {
    return SharePlus.instance.share(ShareParams(text: text, subject: subject));
  }

  static Future<ShareResult> shareXFiles(
    List<XFile> files, {
    String? subject,
    String? text,
  }) async {
    return SharePlus.instance.share(
      ShareParams(files: files, subject: subject, text: text),
    );
  }
}
