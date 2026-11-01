import 'package:cross_file/cross_file.dart';

export 'package:cross_file/cross_file.dart' show XFile;

enum ImageSource { camera, gallery }

class ImagePicker {
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
  }) async =>
      null;

  Future<List<XFile>> pickMultiImage({
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
  }) async =>
      const [];
}
