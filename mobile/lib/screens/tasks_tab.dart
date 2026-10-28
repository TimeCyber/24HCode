import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';

class TasksTab extends StatelessWidget {
  const TasksTab({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.tasks.isEmpty) {
      return const Center(child: Text('暂无任务事件'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: state.tasks.length,
      itemBuilder: (context, index) {
        final task = state.tasks[index];
        return _TaskCard(task: task);
      },
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task});

  final TaskEvent task;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final projectName = state.projects
            .where((p) => p.id == task.projectId)
            .map((p) => p.name)
            .firstOrNull ??
        task.projectId;
    final awaiting = task.status == 'awaiting_decision';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Chip(
                  label: Text(task.type),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    projectName,
                    style: Theme.of(context).textTheme.labelMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  task.status,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              task.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (task.detail.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(task.detail),
            ],
            if (awaiting) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton(
                    onPressed: () => _decide(context, approve: true),
                    child: const Text('提交'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => _decide(context, approve: false),
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

  Future<void> _decide(BuildContext context, {required bool approve}) async {
    final commentCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(approve ? '提交确认' : '拒绝确认'),
        content: TextField(
          controller: commentCtrl,
          decoration: const InputDecoration(
            labelText: '备注（可选）',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(approve ? '提交' : '拒绝'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final state = context.read<AppState>();
    try {
      if (approve) {
        await state.approveTask(task.id, comment: commentCtrl.text);
      } else {
        await state.rejectTask(task.id, comment: commentCtrl.text);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    } finally {
      commentCtrl.dispose();
    }
  }
}
