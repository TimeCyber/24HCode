import 'dart:convert';

class ChatActivity {
  static int _sequence = 0;
  ChatActivity({
    String? id,
    required this.projectId,
    this.chatId,
    required this.timestamp,
    required this.status,
    required this.step,
    required this.summary,
    this.extra = '',
  }) : id = id ?? '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
  final String id;
  final String projectId;
  final String? chatId;
  final String timestamp;
  final String status;
  final String step;
  final String summary;
  final String extra;
  Map<String, dynamic> toJson() => {
    'id': id,
    'projectId': projectId,
    'chatId': chatId,
    'timestamp': timestamp,
    'status': status,
    'step': step,
    'summary': summary,
    'extra': extra,
  };
  factory ChatActivity.fromJson(Map<String, dynamic> j) => ChatActivity(
    id: j['id'] as String?,
    projectId: j['projectId'] as String,
    chatId: j['chatId'] as String?,
    timestamp: j['timestamp'] as String,
    status: j['status'] as String,
    step: j['step'] as String,
    summary: j['summary'] as String,
    extra: j['extra'] as String? ?? '',
  );
}

/// Keep observed progress in the conversation, coalescing updates to the same step.
class ChatActivityLog {
  final List<ChatActivity> items = [];

  Iterable<ChatActivity> forConversation(String projectId, String? chatId) {
    final projectItems = items.where((item) => item.projectId == projectId);
    int second(ChatActivity item) =>
        (DateTime.tryParse(item.timestamp)?.millisecondsSinceEpoch ?? 0) ~/
        1000;
    final scoped = {
      for (final item in projectItems)
        if (item.chatId != null)
          (item.status, item.step, item.summary, second(item)),
    };
    return projectItems.where((item) {
      if (item.chatId != null) return item.chatId == chatId;
      // The relay can send a project snapshot and a conversation snapshot together.
      final time = second(item);
      return ![-1, 0, 1].any(
        (offset) => scoped.contains((
          item.status,
          item.step,
          item.summary,
          time + offset,
        )),
      );
    });
  }

  bool add(ChatActivity next) {
    if (next.status == 'idle' || (next.step.isEmpty && next.summary.isEmpty)) {
      return false;
    }
    final index = items.lastIndexWhere(
      (e) => e.projectId == next.projectId && e.chatId == next.chatId,
    );
    if (index >= 0) {
      final last = items[index];
      final oldTime = DateTime.tryParse(last.timestamp);
      final newTime = DateTime.tryParse(next.timestamp);
      if (oldTime != null && newTime != null && newTime.isBefore(oldTime)) {
        return false;
      }
      if (last.status == next.status &&
          last.step == next.step &&
          last.summary == next.summary) {
        if (last.extra == next.extra) return false;
        items[index] = ChatActivity(
          id: last.id,
          projectId: last.projectId,
          chatId: last.chatId,
          timestamp: last.timestamp,
          status: last.status,
          step: last.step,
          summary: last.summary,
          extra: next.extra,
        );
        return true;
      }
    }
    items.add(next);
    if (items.length > 500) items.removeRange(0, items.length - 500);
    return true;
  }

  String encode() => jsonEncode(items.map((e) => e.toJson()).toList());
  void restore(String? value) {
    items.clear();
    if (value == null) return;
    try {
      for (final row in (jsonDecode(value) as List).take(500)) {
        items.add(ChatActivity.fromJson(Map<String, dynamic>.from(row as Map)));
      }
    } catch (_) {
      items.clear();
    }
  }
}
