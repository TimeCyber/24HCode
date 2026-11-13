import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:codeassist_mobile/app_state.dart';
import 'package:codeassist_mobile/models.dart';
import 'package:codeassist_mobile/remote_request.dart';
import 'package:codeassist_mobile/widgets/remote_task_card.dart';

String detail({bool expired = false, String kind = 'command'}) =>
    RemoteRequest.prefix +
    jsonEncode({
      'version': 1,
      'requestId': 'request',
      'kind': kind,
      'reason': '测试命令确认',
      'command': 'echo hello',
      'cwd': 'D:/project',
      'chatSessionId': 'chat',
      'expiresAt': DateTime.now()
          .add(Duration(minutes: expired ? -1 : 10))
          .toUtc()
          .toIso8601String(),
      if (kind == 'question')
        'questions': [
          {
            'id': 'choice',
            'question': '选择版本',
            'options': [
              {'label': '个人版'},
            ],
          },
        ],
    });

class TestState extends AppState {
  String? submitted;
  int submissions = 0;
  @override
  Future<void> approveTask(String taskId, {String? comment}) async {
    submissions++;
    submitted = comment;
  }
}

Future<void> card(
  WidgetTester tester,
  TestState state,
  String body, {
  String status = 'awaiting_decision',
  String? decisionComment,
}) => tester.pumpWidget(
  ChangeNotifierProvider<AppState>.value(
    value: state,
    child: MaterialApp(
      home: Scaffold(
        body: RemoteTaskCard(
          task: TaskEvent(
            id: 'task',
            projectId: 'project',
            type: 'pending',
            title: 'Codex 请求确认',
            detail: body,
            status: status,
            decisionComment: decisionComment,
            requireDecision: true,
            createdAt: '',
            updatedAt: '',
          ),
        ),
      ),
    ),
  ),
);

void main() {
  test('legacy tasks and malformed metadata remain readable', () {
    expect(RemoteRequest.parse('普通任务'), isNull);
    expect(RemoteRequest.parse('${RemoteRequest.prefix}{}'), isNull);
    expect(RemoteRequest.parse(detail())!.chatSessionId, 'chat');
    expect(RemoteRequest.parse(detail(expired: true))!.expired, isTrue);
  });

  testWidgets('expired request has no action button', (tester) async {
    final state = TestState();
    await card(tester, state, detail(expired: true));
    expect(find.text('已过期'), findsOneWidget);
    expect(find.text('同意'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('a cloud rejection caused by expiry is shown as timeout', (
    tester,
  ) async {
    final state = TestState();
    await card(
      tester,
      state,
      detail(expired: true),
      status: 'rejected',
      decisionComment: '手机确认已超时，请重新发起',
    );
    expect(find.text('已超时'), findsOneWidget);
    expect(find.text('已拒绝或已关闭'), findsNothing);
    expect(find.text('同意'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets(
    'question validates required answer and sends structured response',
    (tester) async {
      final state = TestState();
      await card(tester, state, detail(kind: 'question'));
      await tester.tap(find.text('回答问题'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认提交'));
      await tester.pump();
      expect(find.text('请填写回答'), findsOneWidget);
      await tester.tap(find.text('个人版'));
      await tester.pump();
      await tester.tap(find.text('确认提交'));
      await tester.pumpAndSettle();
      expect(state.submissions, 1);
      expect(jsonDecode(state.submitted!), {
        'answers': {
          'choice': {
            'answers': ['个人版'],
          },
        },
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
