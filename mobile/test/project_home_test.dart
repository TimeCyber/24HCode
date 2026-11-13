import 'dart:convert';

import 'package:codeassist_mobile/app_state.dart';
import 'package:codeassist_mobile/chat_activity.dart';
import 'package:codeassist_mobile/models.dart';
import 'package:codeassist_mobile/remote_request.dart';
import 'package:codeassist_mobile/screens/home_shell.dart';
import 'package:codeassist_mobile/screens/projects_tab.dart';
import 'package:codeassist_mobile/screens/prompts_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Codex quota button shows remaining quota and details', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState()
      ..connectionMode = 'lan'
      ..activeProjectId = 'codex-project';
    state.projects = [
      Project(
        id: 'codex-project',
        name: 'Codex 项目',
        workspacePath: 'D:/codex-project',
        ide: 'codex',
        lastSeenAt: '',
        online: true,
      ),
    ];
    state.codexUsageByProject['codex-project'] = CodexUsageSnapshot(
      projectId: 'codex-project',
      planType: 'plus',
      primary: CodexUsageWindow(usedPercent: 25, windowDurationMins: 300),
      secondary: CodexUsageWindow(usedPercent: 60, windowDurationMins: 10080),
      updatedAt: DateTime.now().toIso8601String(),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: HomeShell()),
      ),
    );

    expect(find.text('5 小时剩余 75% · 每周剩余 40%'), findsOneWidget);
    await tester.tap(find.text('Codex 额度 · Plus'));
    await tester.pumpAndSettle();
    expect(find.text('Codex 用量详情 · Plus'), findsOneWidget);
    expect(find.textContaining('已用 25%'), findsOneWidget);
    expect(find.textContaining('已用 60%'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  test(
    'project progress appears in an existing chat without duplicating scoped updates',
    () {
      final log = ChatActivityLog();
      ChatActivity activity(String step, String timestamp, {String? chat}) =>
          ChatActivity(
            projectId: 'project',
            chatId: chat,
            timestamp: timestamp,
            status: 'coding',
            step: step,
            summary: '执行任务',
          );
      log.add(activity('正在测试', '2026-11-11T04:00:00Z', chat: 'existing'));
      log.add(activity('正在测试', '2026-11-11T04:00:00.100Z'));
      log.add(activity('正在打包', '2026-11-11T04:01:00Z'));
      log.add(activity('其他会话', '2026-11-11T04:01:00Z', chat: 'other'));
      expect(
        log.forConversation('project', 'existing').map((item) => item.step),
        ['正在测试', '正在打包'],
      );
    },
  );

  testWidgets('pending approval marks and opens its existing chat', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final state = AppState()
      ..connectionMode = 'lan'
      ..activeProjectId = 'project'
      ..activeChatSessionId = 'current';
    state.projects = [
      Project(
        id: 'project',
        name: '测试项目',
        workspacePath: 'D:/project',
        ide: 'codex',
        lastSeenAt: '',
        online: true,
      ),
    ];
    state.chatSessions = [
      ChatSession(
        id: 'current',
        projectId: 'project',
        title: '当前会话',
        createdAt: '',
        updatedAt: '',
      ),
      ChatSession(
        id: 'existing',
        projectId: 'project',
        title: '已有会话',
        createdAt: '',
        updatedAt: '',
      ),
    ];
    state.projectActivityLoaded.add('project');
    ProjectActivity delivery(
      String id,
      String status, {
      String? chat,
      bool file = false,
      int minutesAgo = 1,
      String? result,
    }) => ProjectActivity(
      id: id,
      promptId: id,
      projectId: 'project',
      content: id,
      status: status,
      updatedAt: DateTime.now()
          .subtract(Duration(minutes: minutesAgo))
          .toIso8601String(),
      result: result,
      chatSessionId: chat,
      isIncomingFile: file,
    );
    state.projectActivities = [
      delivery('等待批准的指令', 'running', chat: 'existing'),
      delivery('正在执行的指令', 'running'),
      delivery('排队的指令', 'queued'),
      delivery('已完成的指令', 'done'),
      delivery('收到文件', 'done', file: true),
      delivery('旧执行记录', 'running', minutesAgo: 120),
      delivery('旧接收记录', 'delivered', minutesAgo: 120),
      delivery('已回传结果的指令', 'running', minutesAgo: 120, result: '执行结果'),
    ];
    TaskEvent approval(String status) => TaskEvent(
      id: 'approval',
      projectId: 'project',
      type: 'pending',
      title: '批准命令',
      detail:
          RemoteRequest.prefix +
          jsonEncode({
            'version': 1,
            'requestId': 'approval',
            'kind': 'command',
            'turnId': 'turn',
            'chatSessionId': 'existing',
            'command': 'echo hello',
            'expiresAt': DateTime.now()
                .add(const Duration(minutes: 10))
                .toIso8601String(),
          }),
      status: status,
      requireDecision: true,
      createdAt: '2026-11-11T04:00:01Z',
      updatedAt: '',
    );
    state.tasks = [approval('awaiting_decision')];
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: HomeShell()),
      ),
    );
    expect(find.byType(ProjectsTab), findsOneWidget);
    expect(find.byType(PromptsTab), findsNothing);
    expect(find.text('执行中 1 · 待确认 1 · 排队 1 · 完成 2 · 未更新 2'), findsOneWidget);
    await tester.tap(find.text(state.projects.single.displayName));
    await tester.pumpAndSettle();
    expect(find.textContaining('Codex 额度'), findsNothing);
    expect(state.activeChatSessionId, 'current');
    expect(find.text('PC 会话'), findsNothing);
    expect(find.text('待确认（已有会话）'), findsOneWidget);
    expect(find.text('同意'), findsNothing);
    await tester.tap(find.text('待确认（已有会话）'));
    await tester.pumpAndSettle();
    expect(state.activeChatSessionId, 'existing');
    expect(find.text('同意'), findsOneWidget);
    await tester.tap(find.text('当前会话'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('批准命令'));
    await tester.pumpAndSettle();
    expect(find.byType(PromptsTab), findsOneWidget);
    expect(state.activeChatSessionId, 'existing');
    expect(find.text('同意'), findsOneWidget);
    expect(state.chatSessions.length, 2);
    state.tasks = [approval('approved')];
    await tester.tap(find.text('当前会话'));
    await tester.pumpAndSettle();
    expect(find.text('待确认（已有会话）'), findsNothing);
    expect(find.text('已有会话'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ProjectsTab), findsOneWidget);

    await tester.tap(find.text(state.projects.single.displayName));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('断开内网'));
    await tester.pumpAndSettle();
    expect(find.byType(PromptsTab), findsNothing);
    expect(find.byType(ProjectsTab), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
