import 'models.dart';

String projectOrderKey(Project project) =>
    '${project.ide}::${project.workspacePath.trim().replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '').toLowerCase()}';

/// Persist identity-based slots; heartbeat, rename and online status never move rows.
class StableProjectOrder {
  StableProjectOrder([Iterable<String> saved = const []])
    : keys = saved.toSet().toList();

  final List<String> keys;

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
    return [
      for (final key in keys)
        if (byKey.containsKey(key)) byKey[key]!,
    ];
  }
}

bool shouldNotifyTask(TaskEvent? old, TaskEvent next, DateTime connectedAt) {
  if (next.type != 'completed' && next.status != 'completed') return false;
  if (old != null) return old.type != 'completed' && old.status != 'completed';
  // Replay of an already completed task is history, not a new transition.
  final timestamp = DateTime.tryParse(next.updatedAt);
  return timestamp != null && !timestamp.toUtc().isBefore(connectedAt.toUtc());
}
