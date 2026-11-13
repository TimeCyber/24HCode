import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../client_update_policy.dart';
import '../models.dart';
import '../remote_request.dart';

class ProjectsTab extends StatefulWidget {
  const ProjectsTab({super.key, required this.onOpenProject});
  final Future<void> Function(String projectId, String? chatSessionId)
  onOpenProject;

  @override
  State<ProjectsTab> createState() => _ProjectsTabState();
}

class _ProjectsTabState extends State<ProjectsTab> {
  bool _opening = false;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _statusTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _open(String projectId, [String? chatId]) async {
    if (_opening) return;
    _opening = true;
    try {
      await widget.onOpenProject(projectId, chatId);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final projects = state.visibleProjects;
    final now = DateTime.now();
    final contextByProject = {
      for (final session in state.sessions) session.projectId: session,
    };
    final activityByProject = <String, List<ProjectActivity>>{};
    for (final activity in state.projectActivities) {
      if (!activity.isIncomingFile) {
        (activityByProject[activity.projectId] ??= []).add(activity);
      }
    }
    final pendingByProject = <String, List<TaskEvent>>{};
    for (final task in state.tasks) {
      if (task.status != 'awaiting_decision' ||
          (RemoteRequest.parse(task.detail)?.expired ?? false)) {
        continue;
      }
      (pendingByProject[task.projectId] ??= []).add(task);
    }
    return RefreshIndicator(
      onRefresh: state.refreshAll,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
        itemCount: projects.isEmpty ? 1 : projects.length,
        itemBuilder: (context, index) {
          if (projects.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(state.connecting ? '正在加载项目…' : '暂无项目，下拉刷新'),
              ),
            );
          }
          final project = projects[index];
          return _ProjectRow(
            key: ValueKey(project.id),
            project: project,
            activities: activityByProject[project.id] ?? const [],
            pending: pendingByProject[project.id] ?? const [],
            pcContext: contextByProject[project.id],
            now: now,
            loaded: state.projectActivityLoaded.contains(project.id),
            onOpen: (chatId) => _open(project.id, chatId),
          );
        },
      ),
    );
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    super.key,
    required this.project,
    required this.activities,
    required this.pending,
    this.pcContext,
    required this.loaded,
    required this.now,
    required this.onOpen,
  });
  final Project project;
  final List<ProjectActivity> activities;
  final List<TaskEvent> pending;
  final SessionContext? pcContext;
  final bool loaded;
  final DateTime now;
  final void Function(String? chatId) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waitingChats = <String>{};
    for (final task in pending) {
      final request = RemoteRequest.parse(task.detail);
      if (request?.turnId != null && request?.chatSessionId != null) {
        waitingChats.add(request!.chatSessionId!);
      }
    }
    final items = activities
        .map(
          (activity) => (
            activity: activity,
            status: displayPromptStatus(
              activity.status,
              activity.result,
              activity.updatedAt,
              now,
            ),
          ),
        )
        .where(
          (row) =>
              row.status != 'running' ||
              !waitingChats.contains(row.activity.chatSessionId),
        )
        .toList();
    int count(String status) =>
        items.where((row) => row.status == status).length;
    final running = count('running');
    final queued = count('queued');
    final delivered = count('delivered');
    final completed = count('done');
    final failed = count('failed');
    final stale = count('stale');
    final summary = [
      if (running > 0) '执行中 $running',
      if (pending.isNotEmpty) '待确认 ${pending.length}',
      if (queued > 0) '排队 $queued',
      if (delivered > 0) '已接收 $delivered',
      if (completed > 0) '完成 $completed',
      if (failed > 0) '失败 $failed',
      if (stale > 0) '未更新 $stale',
      if (!loaded) '等待同步',
    ].join(' · ');
    final ordered = [...items]
      ..sort((a, b) {
        final aTime =
            DateTime.tryParse(a.activity.createdAt ?? a.activity.updatedAt) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bTime =
            DateTime.tryParse(b.activity.createdAt ?? b.activity.updatedAt) ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return bTime.compareTo(aTime);
      });
    final rows = [
      for (final task in pending)
        _ActivityRow(
          label: '待确认',
          title: task.title,
          onTap: () => onOpen(RemoteRequest.parse(task.detail)?.chatSessionId),
        ),
      for (final row in ordered)
        _ActivityRow(
          label: switch (row.status) {
            'queued' => '排队中',
            'delivered' => '已接收',
            'running' => '执行中',
            'done' => '已完成',
            'failed' => '执行失败',
            'stale' => '状态未更新',
            _ => row.status,
          },
          title: row.activity.content,
          onTap: () => onOpen(row.activity.chatSessionId),
        ),
    ];
    final online = project.isEffectivelyOnline();
    final snapshot = pcContext;
    final contextIsActive = const {
      'coding',
      'thinking',
      'waiting_user',
    }.contains(snapshot?.status);
    final contextExpired =
        snapshot != null &&
        contextIsActive &&
        displayPromptStatus('running', null, snapshot.updatedAt, now) ==
            'stale';
    final pcStep = contextExpired
        ? '状态未更新'
        : snapshot?.currentStep.trim() ?? '';

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            minVerticalPadding: 0,
            title: Text(project.displayName),
            subtitle: Text(
              '${online ? '在线' : '离线'} · ${project.ideLabel}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => onOpen(null),
          ),
          if (summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: pending.isNotEmpty
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (pcStep.isNotEmpty && pcContext?.status != 'idle')
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Text(
                '最近 PC · $pcStep',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ...rows.take(2),
        ],
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.label,
    required this.title,
    required this.onTap,
  });
  final String label;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    visualDensity: VisualDensity.compact,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
    minVerticalPadding: 0,
    title: Text(
      title,
      style: Theme.of(context).textTheme.bodySmall,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: Text(label, style: Theme.of(context).textTheme.labelSmall),
    onTap: onTap,
  );
}
