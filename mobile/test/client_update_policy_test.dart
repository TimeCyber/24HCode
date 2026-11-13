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
  test('stale acknowledgments are separate from confirmed results', () {
    final now = DateTime.utc(2026, 11, 11, 5);
    expect(
      displayPromptStatus('running', null, '2026-11-11T04:59:00Z', now),
      'running',
    );
    expect(
      displayPromptStatus('running', null, '2026-11-11T04:10:00Z', now),
      'stale',
    );
    expect(
      displayPromptStatus('delivered', null, '2026-11-11T04:00:00Z', now),
      'stale',
    );
    expect(
      displayPromptStatus('running', '结果已返回', '2026-11-11T04:00:00Z', now),
      'done',
    );
    expect(
      displayPromptStatus(
        'running',
        '[agent-error] 已停止',
        '2026-11-11T04:00:00Z',
        now,
      ),
      'failed',
    );
    expect(
      displayPromptStatus('queued', null, '2026-11-10T00:00:00Z', now),
      'queued',
    );
  });

  test('late acknowledgments cannot overwrite a terminal delivery', () {
    expect(
      acceptsPromptUpdate(
        previousStatus: 'done',
        previousUpdatedMillis: 10,
        incomingStatus: 'running',
        incomingUpdatedMillis: 20,
      ),
      isFalse,
    );
    expect(
      acceptsPromptUpdate(
        previousStatus: 'running',
        previousUpdatedMillis: 20,
        incomingStatus: 'failed',
        incomingUpdatedMillis: 10,
      ),
      isTrue,
    );
  });

  test(
    'recent sends move projects ahead of stable slots and survive restore',
    () {
      final order = StableProjectOrder();
      final a = project('a', 'A');
      final b = project('b', 'B');
      final c = project('c', 'C');
      order.merge([a, b, c]);
      order.recordSend(b, 10);
      order.recordSend(c, 20);
      expect(order.merge([a, b, c]).map((p) => p.id), ['c', 'b', 'a']);
      expect(order.recordSend(b, 5), isFalse);
      final restored = StableProjectOrder(order.keys, order.lastSentAt);
      expect(restored.merge([c, b, a]).map((p) => p.id), ['c', 'b', 'a']);
      restored.recordSend(b, 30);
      expect(restored.merge([c, b, a]).map((p) => p.id), ['b', 'c', 'a']);
    },
  );

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

  test('new approval requests alert once, historical requests stay silent', () {
    final now = DateTime.parse('2026-11-09T08:00:00Z');
    TaskEvent approval(String createdAt) => TaskEvent(
      id: 'approval',
      projectId: 'project',
      type: 'pending',
      title: '需要确认',
      detail: '',
      status: 'awaiting_decision',
      requireDecision: true,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
    final fresh = approval('2026-11-09T08:01:00Z');
    expect(shouldNotifyTask(null, fresh, now), isTrue);
    expect(shouldNotifyTask(fresh, fresh, now), isFalse);
    expect(
      shouldNotifyTask(task('approved', fresh.createdAt), fresh, now),
      isFalse,
    );
    expect(
      shouldNotifyTask(null, approval('2026-11-08T08:01:00Z'), now),
      isFalse,
    );
  });

  test('pending poll cannot overwrite a decision received while fetching', () {
    final now = DateTime.parse('2026-11-09T08:00:00Z');
    final approved = task('approved', '2026-11-08T12:00:00Z');
    final pending = task('awaiting_decision', '2026-11-08T12:00:00Z');
    expect(
      mergePendingTasks([approved], [pending], now).single.status,
      'approved',
    );
    expect(mergePendingTasks([pending], [], now), isEmpty);
  });
}
