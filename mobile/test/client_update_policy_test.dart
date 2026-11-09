import 'package:flutter_test/flutter_test.dart';
import 'package:codeassist_mobile/client_update_policy.dart';
import 'package:codeassist_mobile/models.dart';

Project project(
  String id,
  String name, {
  String? path,
  String seen = '2026-11-09T00:00:00Z',
  bool online = true,
}) => Project(
  id: id,
  name: name,
  workspacePath: path ?? 'D:/$id',
  ide: 'codex',
  lastSeenAt: seen,
  online: online,
);

TaskEvent task(String state, String time) => TaskEvent(
  id: 'task',
  projectId: 'project',
  type: state,
  title: '任务',
  detail: '',
  status: state,
  requireDecision: false,
  createdAt: time,
  updatedAt: time,
);

void main() {
  test('heartbeat refresh, online changes and rename preserve row slots', () {
    final order = StableProjectOrder();
    expect(
      order.merge([project('b', 'B'), project('a', 'A')]).map((p) => p.id),
      ['a', 'b'],
    );
    final refreshed = order.merge([
      project('b', 'B', seen: '2026-11-09T09:00:00Z'),
      project('a', 'Z', online: false),
    ]);
    expect(refreshed.map((p) => p.id), ['a', 'b']);
    expect(refreshed.first.online, false);
    expect(
      StableProjectOrder(
        order.keys,
      ).merge(refreshed.reversed.toList()).map((p) => p.id),
      ['a', 'b'],
    );
    expect(order.merge([project('c', '0'), ...refreshed]).map((p) => p.id), [
      'a',
      'b',
      'c',
    ]);
  });

  test(
    'path aliases dedupe to newest record without moving or losing missing slots',
    () {
      final order = StableProjectOrder();
      order.merge([
        project('one', 'A', path: r'D:\Code'),
        project('other', 'B'),
      ]);
      final rows = order.merge([
        project('old', 'Z', path: 'd:/code/'),
        project('new', 'Z', path: 'D:/CODE', seen: '2026-11-09T09:00:00Z'),
        project('other', 'B'),
      ]);
      expect(rows.map((p) => p.id), ['new', 'other']);
      order.merge([project('other', 'B')]);
      expect(order.merge(rows.reversed.toList()).map((p) => p.id), [
        'new',
        'other',
      ]);
    },
  );

  test('old completed replay is silent; fresh completions still notify', () {
    final now = DateTime.parse('2026-11-09T08:00:00Z');
    expect(
      shouldNotifyTask(null, task('completed', '2026-11-08T12:00:00Z'), now),
      false,
    );
    expect(
      shouldNotifyTask(null, task('completed', '2026-11-09T08:01:00Z'), now),
      true,
    );
    expect(
      shouldNotifyTask(
        task('pending', '2026-11-08T12:00:00Z'),
        task('completed', '2026-11-08T12:00:00Z'),
        now,
      ),
      true,
    );
    expect(
      shouldNotifyTask(
        task('completed', '2026-11-09T08:01:00Z'),
        task('completed', '2026-11-09T08:01:00Z'),
        now,
      ),
      false,
    );
    expect(shouldNotifyTask(null, task('completed', 'invalid'), now), false);
  });
}
