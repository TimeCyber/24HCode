import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../models.dart';
import '../remote_request.dart';

class RemoteTaskCard extends StatefulWidget {
  const RemoteTaskCard({super.key, required this.task});
  final TaskEvent task;
  @override
  State<RemoteTaskCard> createState() => _RemoteTaskCardState();
}

class _RemoteTaskCardState extends State<RemoteTaskCard> {
  bool _busy = false;
  Timer? _expiry;
  @override
  void initState() {
    super.initState();
    _scheduleExpiry();
  }

  @override
  void didUpdateWidget(RemoteTaskCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleExpiry();
  }

  void _scheduleExpiry() {
    _expiry?.cancel();
    final request = RemoteRequest.parse(widget.task.detail);
    if (request == null || request.expired) return;
    _expiry = Timer(request.expiresAt.difference(DateTime.now()), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final request = RemoteRequest.parse(task.detail);
    final state = context.read<AppState>();
    final project = state.projects
        .where((p) => p.id == task.projectId)
        .firstOrNull;
    final awaiting = task.status == 'awaiting_decision';
    final expired = request?.expired ?? false;
    final label = switch (task.status) {
      'awaiting_decision' => expired ? '已过期' : '等待你确认',
      'approved' => '已同意',
      'rejected' => didApprovalTimeOut(task) ? '已超时' : '已拒绝或已关闭',
      _ => switch (task.type) {
        'completed' => '已完成',
        'blocked' => '受阻',
        'pending' => '进行中',
        _ => '任务动态',
      },
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    project?.name ?? task.projectId,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  label,
                  style: TextStyle(
                    color: awaiting && !expired
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(task.title, style: Theme.of(context).textTheme.titleMedium),
            if (didApprovalTimeOut(task)) Text(task.decisionComment!),
            if (request == null && task.detail.isNotEmpty) ...[
              const SizedBox(height: 6),
              SelectableText(task.detail),
            ],
            if (request != null) ...[
              const SizedBox(height: 6),
              Text(request.reason),
              if (request.permissionsText != null) ...[
                const Text('申请权限：'),
                SelectableText(request.permissionsText!),
                Text(
                  request.kind == 'permissions' ? '同意仅在本轮任务有效。' : '权限仅用于本次命令。',
                ),
              ],
              if (request.command?.isNotEmpty == true) ...[
                const SizedBox(height: 8),
                SelectableText(
                  request.command!,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ],
              if (request.cwd != null) Text('目录：${request.cwd}'),
              for (final path in request.paths) Text('文件：$path'),
              for (final question in request.questions)
                Text(question['question'] as String? ?? ''),
              if (awaiting && !expired)
                Text(
                  '有效至 ${request.expiresAt.toLocal().toString().substring(0, 19)}',
                ),
              if (request.kind == 'command' || request.kind == 'fileChange')
                const Text('同意仅用于本次请求。'),
            ],
            if (awaiting && !expired) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton(
                    onPressed: _busy ? null : () => _decide(true),
                    child: Text(
                      _busy
                          ? '提交中…'
                          : request?.kind == 'question'
                          ? '回答问题'
                          : '同意',
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _decide(false),
                    child: const Text('拒绝'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _decide(bool approve) async {
    final task = widget.task;
    final request = RemoteRequest.parse(task.detail);
    if (_busy || (request?.expired ?? false)) return;
    final questions = approve
        ? request?.questions ?? <Map<String, dynamic>>[]
        : <Map<String, dynamic>>[];
    final comment = TextEditingController();
    final answers = {
      for (final q in questions) q['id'] as String: TextEditingController(),
    };
    final formKey = GlobalKey<FormState>();
    String buildPayload() => questions.isEmpty
        ? comment.text
        : jsonEncode({
            'answers': {
              for (final q in questions)
                q['id'] as String: {
                  'answers': [answers[q['id']]!.text.trim()],
                },
            },
          });
    String? payload;
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            approve
                ? questions.isEmpty
                      ? '确认同意'
                      : '回答 Codex'
                : '确认拒绝',
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final q in questions) ...[
                      Text(q['question'] as String? ?? ''),
                      for (final option
                          in (q['options'] as List? ?? []).whereType<Map>())
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(option['label'] as String? ?? ''),
                          subtitle: option['description'] is String
                              ? Text(option['description'] as String)
                              : null,
                          onTap: () => answers[q['id']]!.text =
                              option['label'] as String? ?? '',
                        ),
                      TextFormField(
                        controller: answers[q['id']],
                        maxLength: 800,
                        minLines: 1,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: '选择上方选项或输入回答',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) =>
                            v == null || v.trim().isEmpty ? '请填写回答' : null,
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (questions.isEmpty)
                      TextField(
                        controller: comment,
                        maxLength: 1000,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: '备注（可选）',
                          border: OutlineInputBorder(),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? true) {
                  // The existing cloud decision_comment column holds 1024 characters.
                  if (buildPayload().length > 1000) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('回答合计过长，请精简后提交')),
                    );
                    return;
                  }
                  Navigator.pop(ctx, true);
                }
              },
              child: Text(approve ? '确认提交' : '拒绝'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      if (request?.expired ?? false) throw Exception('确认请求已过期，请在 PC 重新发起');
      payload = buildPayload();
      setState(() => _busy = true);
      final state = context.read<AppState>();
      if (approve) {
        await state.approveTask(task.id, comment: payload);
      } else {
        await state.rejectTask(task.id, comment: payload);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      // Dialog route animations can still refer to controllers after pop.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        comment.dispose();
        for (final controller in answers.values) {
          controller.dispose();
        }
      });
      if (mounted) setState(() => _busy = false);
    }
  }
}
