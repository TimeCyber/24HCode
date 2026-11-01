import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

/// 保留文件；项目选择已合并到 Prompt 页右上角。
class ProjectsTab extends StatelessWidget {
  const ProjectsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return ListView.separated(
      itemCount: state.projects.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final p = state.projects[index];
        final selected = state.activeProjectId == p.id;
        return ListTile(
          selected: selected,
          title: Text(p.displayName),
          subtitle: Text('${p.ideLabel} · ${p.workspacePath}'),
          trailing: Text(p.isEffectivelyOnline() ? '在线' : '离线'),
          onTap: () => state.selectProject(p.id),
        );
      },
    );
  }
}
