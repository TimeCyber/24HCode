import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:codeassist_mobile/app_state.dart';
import 'package:codeassist_mobile/chat_activity.dart';
import 'package:codeassist_mobile/models.dart';
import 'package:codeassist_mobile/remote_request.dart';
import 'package:codeassist_mobile/screens/prompts_tab.dart';
import 'package:codeassist_mobile/widgets/chat_activity_bubble.dart';
import 'package:codeassist_mobile/widgets/remote_task_card.dart';

ChatActivity activity(
  String step, {
  String chat = 'chat',
  String extra = '',
  String timestamp = '2026-11-11T04:01:00Z',
}) => ChatActivity(
  projectId: 'project',
  chatId: chat,
  timestamp: timestamp,
  status: 'coding',
  step: step,
  summary: '执行当前任务',
  extra: extra,
);

void main() {
  test(
    'same step updates one message; new steps append and survive restore',
    () {
      final log = ChatActivityLog();
      log.add(activity('读取文件'));
      final id = log.items.single.id;
      expect(log.add(activity('读取文件')), isFalse);
      log.add(
        activity('读取文件', extra: '读取完成', timestamp: '2026-11-11T04:02:00Z'),
      );
      expect(log.items.single.id, id);
      log.add(activity('修改文件', timestamp: '2026-11-11T04:03:00Z'));
      expect(log.items.length, 2);
      final restored = ChatActivityLog()..restore(log.encode());
      expect(restored.items.map((e) => e.id), log.items.map((e) => e.id));
      expect(
        restored.add(activity('读取旧状态', timestamp: '2026-11-11T04:00:00Z')),
        isFalse,
      );
    },
  );

  test('separate conversations do not coalesce each other', () {
    final log = ChatActivityLog();
    log.add(activity('读取文件'));
    log.add(activity('读取文件', chat: 'other'));
    expect(log.items.length, 2);
  });

  testWidgets('chat progress is compact and reveals the actual return', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatActivityBubble(
            activity: activity('正在检查构建结果', extra: '构建成功，APK 已就绪'),
          ),
        ),
      ),
    );

    final statusFinder = find.text('PC · 执行中 · 正在检查构建结果');
    expect(statusFinder, findsOneWidget);
    final status = tester.widget<Text>(statusFinder);
    expect(status.maxLines, 1);
    expect(
      status.style?.color,
      Theme.of(tester.element(statusFinder)).colorScheme.onSurfaceVariant,
    );
    expect(find.text('构建成功，APK 已就绪'), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('构建成功，APK 已就绪'), findsOneWidget);
  });

  testWidgets(
    'progress and confirmation are inside the chat list, scoped to the selected chat',
    (tester) async {
      final state = AppState()
        ..connectionMode = 'lan'
        ..activeProjectId = 'project'
        ..activeChatSessionId = 'chat';
      state.projects = [
        Project(
          id: 'project',
          name: '项目',
          workspacePath: 'D:/project',
          ide: 'codex',
          lastSeenAt: '',
          online: true,
        ),
      ];
      state.chatSessions = [
        ChatSession(
          id: 'chat',
          projectId: 'project',
          title: '会话',
          createdAt: '',
          updatedAt: '',
          contextSummary: '任务',
        ),
      ];
      state.chatActivityLog.add(activity('修改配置'));
      state.chatActivityLog.add(activity('不应显示', chat: 'other'));
      state.tasks = [
        TaskEvent(
          id: 'confirm',
          projectId: 'project',
          type: 'pending',
          title: '确认执行命令',
          detail:
              RemoteRequest.prefix +
              jsonEncode({
                'version': 1,
                'requestId': 'request',
                'kind': 'command',
                'reason': '请确认',
                'chatSessionId': 'chat',
                'command': 'echo hello',
                'expiresAt': DateTime.now()
                    .add(const Duration(minutes: 10))
                    .toIso8601String(),
              }),
          status: 'awaiting_decision',
          requireDecision: true,
          createdAt: '2026-11-11T04:02:00Z',
          updatedAt: '',
        ),
      ];
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: Scaffold(body: PromptsTab())),
        ),
      );
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(ChatActivityBubble),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(RemoteTaskCard),
        ),
        findsOneWidget,
      );
      expect(find.text('不应显示'), findsNothing);
      expect(find.text('同意'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
