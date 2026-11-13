import 'models.dart';

// The local relay expires deliveries after 50 minutes without an update.
// Older cloud relays leave the same records active until a result arrives.
const promptStatusExpiry = Duration(minutes: 50);

bool isActivePromptStatus(String status) =>
    status == 'queued' || status == 'delivered' || status == 'running';

bool isTerminalPromptStatus(String status) =>
    status == 'done' || status == 'failed';

String reportedPromptStatus(String status, String? result) {
  if (isTerminalPromptStatus(status)) return status;
  final text = result?.trim();
  if (text == null || text.isEmpty) return status;
  return text.startsWith('[agent-error]') ? 'failed' : 'done';
}

String displayPromptStatus(
  String status,
  String? result,
  String updatedAt,
  DateTime now,
) {
  final reported = reportedPromptStatus(status, result);
  if (reported != 'running' && reported != 'delivered') return reported;
  final updated = DateTime.tryParse(updatedAt);
  if (updated == null || now.difference(updated) >= promptStatusExpiry) {
    return 'stale';
  }
  return reported;
}

bool acceptsPromptUpdate({
  required String previousStatus,
  required int previousUpdatedMillis,
  String? previousResult,
  required String incomingStatus,
  required int incomingUpdatedMillis,
  String? incomingResult,
}) {
  if (isTerminalPromptStatus(previousStatus) !=
      isTerminalPromptStatus(incomingStatus)) {
    return isTerminalPromptStatus(incomingStatus);
  }
  final wasTerminal = isTerminalPromptStatus(
    reportedPromptStatus(previousStatus, previousResult),
  );
  final isTerminal = isTerminalPromptStatus(
    reportedPromptStatus(incomingStatus, incomingResult),
  );
  if (wasTerminal != isTerminal) return isTerminal;
  return incomingUpdatedMillis >= previousUpdatedMillis;
}

/// Runtime polling fetches pending requests only, rather than the entire task history.
List<TaskEvent> mergePendingTasks(
  List<TaskEvent> current,
  List<TaskEvent> pending,
  DateTime requestedAt,
) {
  final result = <String, TaskEvent>{};
  for (final task in current) {
    final created = DateTime.tryParse(task.createdAt);
    if (task.status != 'awaiting_decision' ||
        (created != null && !created.isBefore(requestedAt))) {
      result[task.id] = task;
    }
  }
  for (final task in pending.reversed) {
    final existing = current.where((t) => t.id == task.id).firstOrNull;
    // A task id cannot be reopened; don't regress a decision received mid-poll.
    if (existing != null && existing.status != 'awaiting_decision') continue;
    result[task.id] = task;
  }
  return result.values.toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
}

String projectOrderKey(Project project) =>
    '${project.ide}::${project.workspacePath.trim().replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '').toLowerCase()}';

/// Recent sends take priority over the stable order used for the other projects.
class StableProjectOrder {
  StableProjectOrder([
    Iterable<String> saved = const [],
    Map<String, int> savedSends = const {},
  ]) : keys = saved.toSet().toList(),
       lastSentAt = Map.of(savedSends);

  final List<String> keys;
  final Map<String, int> lastSentAt;

  bool recordSend(Project project, int sentAt) {
    final key = projectOrderKey(project);
    if (sentAt <= (lastSentAt[key] ?? 0)) return false;
    lastSentAt[key] = sentAt;
    return true;
  }

  List<Project> merge(List<Project> input) {
    final byKey = <String, Project>{};
    for (final project in input) {
      final key = projectOrderKey(project);
      final old = byKey[key];
      if (old == null ||
          project.lastSeenAt.compareTo(old.lastSeenAt) > 0 ||
          (project.lastSeenAt == old.lastSeenAt &&
              project.id.compareTo(old.id) < 0)) {
        byKey[key] = project;
      }
    }
    final additions = byKey.keys.where((key) => !keys.contains(key)).toList()
      ..sort((a, b) {
        final name = byKey[a]!.displayName.toLowerCase().compareTo(
          byKey[b]!.displayName.toLowerCase(),
        );
        return name != 0 ? name : a.compareTo(b);
      });
    keys.addAll(additions);
    final slots = {for (var i = 0; i < keys.length; i++) keys[i]: i};
    final orderedKeys = keys.where(byKey.containsKey).toList()
      ..sort((a, b) {
        final recent = (lastSentAt[b] ?? 0).compareTo(lastSentAt[a] ?? 0);
        return recent == 0 ? slots[a]!.compareTo(slots[b]!) : recent;
      });
    return [for (final key in orderedKeys) byKey[key]!];
  }
}

bool shouldNotifyTask(TaskEvent? old, TaskEvent next, DateTime connectedAt) {
  if (next.requireDecision && next.status == 'awaiting_decision') {
    if (old != null) return false;
    final timestamp = DateTime.tryParse(next.createdAt);
    return timestamp != null &&
        !timestamp.toUtc().isBefore(connectedAt.toUtc());
  }
  if (next.type != 'completed' && next.status != 'completed') return false;
  if (old != null) return old.type != 'completed' && old.status != 'completed';
  // Replay of an already completed task is history, not a new transition.
  final timestamp = DateTime.tryParse(next.updatedAt);
  return timestamp != null && !timestamp.toUtc().isBefore(connectedAt.toUtc());
}
