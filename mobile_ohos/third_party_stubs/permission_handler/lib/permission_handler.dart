enum PermissionStatus {
  denied,
  granted,
  restricted,
  limited,
  permanentlyDenied,
  provisional,
}

extension PermissionStatusGetters on PermissionStatus {
  bool get isGranted => this == PermissionStatus.granted;
  bool get isDenied => this == PermissionStatus.denied;
  bool get isPermanentlyDenied => this == PermissionStatus.permanentlyDenied;
}

class Permission {
  const Permission._(this.value);
  final int value;

  static const microphone = Permission._(1);
  static const camera = Permission._(2);
  static const photos = Permission._(3);
  static const storage = Permission._(4);
  static const notification = Permission._(5);
  static const requestInstallPackages = Permission._(6);

  Future<PermissionStatus> get status async => PermissionStatus.granted;

  Future<PermissionStatus> request() async => PermissionStatus.granted;
}

Future<bool> openAppSettings() async => false;

extension PermissionListRequest on List<Permission> {
  Future<Map<Permission, PermissionStatus>> request() async {
    return {for (final p in this) p: PermissionStatus.granted};
  }
}
