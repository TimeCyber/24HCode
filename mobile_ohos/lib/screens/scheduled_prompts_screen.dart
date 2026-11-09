import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';

class ScheduledPromptsScreen extends StatelessWidget {
  const ScheduledPromptsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('定时任务')),
      body: state.scheduledPrompts.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Text(
                  '创建一个定时任务，客户端在前台时会按间隔发送固定 prompt。',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: state.scheduledPrompts.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) => _ScheduledPromptCard(
                schedule: state.scheduledPrompts[index],
                projectName: _projectName(
                  state.visibleProjects,
                  state.scheduledPrompts[index].projectId,
                ),
              ),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createSchedule(context),
        icon: const Icon(Icons.add),
        label: const Text('新建任务'),
      ),
    );
  }

  String _projectName(List<Project> projects, String projectId) {
    for (final project in projects) {
      if (project.id == projectId) return project.displayName;
    }
    return '已隐藏或已移除的项目';
  }

  Future<void> _createSchedule(BuildContext context) async {
    final state = context.read<AppState>();
    final projects = state.visibleProjects;
    if (projects.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            state.projects.isEmpty ? '请先连接一个 AI 项目' : '所有项目都已隐藏，请先恢复显示一个项目',
          ),
        ),
      );
      return;
    }

    final promptController = TextEditingController();
    final intervalController = TextEditingController(text: '60');
    final formKey = GlobalKey<FormState>();
    var projectId = projects.any((p) => p.id == state.activeProjectId)
        ? state.activeProjectId!
        : projects.first.id;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('新建定时任务'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<String>(
                    key: ValueKey(projectId),
                    initialValue: projectId,
                    decoration: const InputDecoration(
                      labelText: '目标项目',
                      border: OutlineInputBorder(),
                    ),
                    items: projects
                        .map(
                          (project) => DropdownMenuItem(
                            value: project.id,
                            child: Text(
                              project.displayName,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => projectId = value);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: intervalController,
                    decoration: const InputDecoration(
                      labelText: '执行间隔（分钟）',
                      helperText: '首次执行会在一个间隔后开始，最多 7 天',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    validator: (value) {
                      final minutes = int.tryParse(value?.trim() ?? '');
                      if (minutes == null || minutes < 1 || minutes > 10080) {
                        return '请输入 1 到 10080 之间的分钟数';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: promptController,
                    decoration: const InputDecoration(
                      labelText: '固定 prompt',
                      hintText: '例如：检查当前项目的 CI 状态并汇报结果',
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                    minLines: 3,
                    maxLines: 6,
                    validator: (value) => (value?.trim().isNotEmpty ?? false)
                        ? null
                        : '请输入要定时发送的 prompt',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                if (!(formKey.currentState?.validate() ?? false)) return;
                await state.addScheduledPrompt(
                  prompt: promptController.text,
                  projectId: projectId,
                  intervalMinutes: int.parse(intervalController.text.trim()),
                );
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    promptController.dispose();
    intervalController.dispose();
  }
}

class _ScheduledPromptCard extends StatelessWidget {
  const _ScheduledPromptCard({
    required this.schedule,
    required this.projectName,
  });

  final ScheduledPrompt schedule;
  final String projectName;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.schedule, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    projectName,
                    style: Theme.of(context).textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Switch.adaptive(
                  value: schedule.enabled,
                  onChanged: (value) =>
                      state.setScheduledPromptEnabled(schedule.id, value),
                ),
                IconButton(
                  tooltip: '删除任务',
                  onPressed: () => _confirmDelete(context, state),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            Text(schedule.prompt, maxLines: 3, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
            Text(
              schedule.enabled
                  ? '每 ${schedule.intervalMinutes} 分钟 · 下次执行 ${_formatTime(schedule.nextRunAt)}'
                  : '已暂停 · 每 ${schedule.intervalMinutes} 分钟',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (schedule.lastRunAt != null) ...[
              const SizedBox(height: 4),
              Text(
                '上次触发 ${_formatTime(schedule.lastRunAt!)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (schedule.lastError != null) ...[
              const SizedBox(height: 4),
              Text(
                '上次发送失败：${schedule.lastError}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _confirmDelete(BuildContext context, AppState state) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除定时任务？'),
        content: const Text('删除后不会再发送这个固定 prompt。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (remove == true) await state.removeScheduledPrompt(schedule.id);
  }
}
