import 'dart:convert';

import 'models.dart';

bool isPendingApproval(TaskEvent task) =>
    task.status == 'awaiting_decision' &&
    !(RemoteRequest.parse(task.detail)?.expired ?? false);

bool didApprovalTimeOut(TaskEvent task) =>
    task.status == 'rejected' &&
    task.decisionComment?.startsWith('手机确认已超时') == true;

/// Travels in the existing task detail field, so deployed relays need no migration.
class RemoteRequest {
  static const prefix = 'CODEASSIST_REMOTE_REQUEST_V1\n';
  RemoteRequest(this.data);
  final Map<String, dynamic> data;

  String get kind => data['kind'] as String? ?? 'confirmation';
  String get reason => data['reason'] as String? ?? '';
  String? get command => data['command'] as String?;
  String? get cwd => data['cwd'] as String?;
  String? get chatSessionId => data['chatSessionId'] as String?;
  String? get threadId => data['threadId'] as String?;
  String? get turnId => data['turnId'] as String?;
  String? get permissionsText => data['permissions'] == null
      ? null
      : const JsonEncoder.withIndent('  ').convert(data['permissions']);
  List<String> get paths =>
      (data['paths'] as List? ?? []).whereType<String>().toList();
  List<Map<String, dynamic>> get questions => (data['questions'] as List? ?? [])
      .whereType<Map<String, dynamic>>()
      .toList();
  DateTime get expiresAt => DateTime.parse(data['expiresAt'] as String);
  bool get expired => !DateTime.now().isBefore(expiresAt);

  static RemoteRequest? parse(String detail) {
    if (!detail.startsWith(prefix)) return null;
    try {
      final data = jsonDecode(detail.substring(prefix.length));
      if (data is! Map<String, dynamic> ||
          data['version'] != 1 ||
          data['requestId'] is! String ||
          data['kind'] is! String ||
          DateTime.tryParse(data['expiresAt'] as String? ?? '') == null) {
        return null;
      }
      return RemoteRequest(data);
    } catch (_) {
      return null;
    }
  }
}
