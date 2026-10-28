import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';

class ContextTab extends StatelessWidget {
  const ContextTab({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.sessions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '暂无会话上下文。\nCursor / Codex 调用 sync_session_context 后会显示在这里。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: state.sessions.length,
      itemBuilder: (context, index) {
        final session = state.sessions[index];
        final projectName = state.projects
                .where((p) => p.id == session.projectId)
                .map((p) => p.name)
                .firstOrNull ??
            session.projectId;
        return _SessionCard(session: session, projectName: projectName);
      },
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.session, required this.projectName});

  final SessionContext session;
  final String projectName;

  @override
  Widget build(BuildContext context) {
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
                  label: Text(session.status),
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
              ],
            ),
            const SizedBox(height: 8),
            Text(
              session.summary,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (session.currentStep.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '当前步骤：${session.currentStep}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
            if (session.openFiles.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('相关文件', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              ...session.openFiles.take(8).map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        f,
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
            ],
            if (session.extra != null && session.extra!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(session.extra!),
            ],
            const SizedBox(height: 8),
            Text(
              '更新于 ${session.updatedAt}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }
}
