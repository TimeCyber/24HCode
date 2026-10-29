import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../widgets/session_status_sheet.dart';
import 'prompts_tab.dart';
import 'setup_screen.dart';

class HomeShell extends StatelessWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final project = state.activeProject;

    // 绿=在线，红=离线，黄=连接中/未选项目
    final Color statusDot;
    if (state.connecting) {
      statusDot = Colors.amber.shade600;
    } else if (project == null) {
      statusDot = Colors.amber.shade700;
    } else if (project.online) {
      statusDot = Colors.green.shade600;
    } else {
      statusDot = Colors.red.shade600;
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Flexible(
              child: Text(
                project?.displayName ?? 'CodeAssist',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: state.connecting
                  ? '连接中'
                  : (project == null
                      ? '未选择项目'
                      : (project.online ? '项目在线' : '项目离线')),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: statusDot,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (state.connecting)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          IconButton(
            tooltip: '本会话状态',
            onPressed: () => showSessionStatusSheet(context),
            icon: const Icon(Icons.info_outline),
          ),
          IconButton(
            tooltip: '选择 / 连接项目',
            onPressed: () {
              showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => const _ProjectSheet(),
              );
            },
            icon: Icon(
              project == null ? Icons.link_off : Icons.folder_outlined,
            ),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: () => state.refreshAll(),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SetupScreen()),
              );
            },
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: Column(
        children: [
          if (state.error != null)
            MaterialBanner(
              content: Text(state.error!),
              actions: [
                TextButton(
                  onPressed: () => state.connect(),
                  child: const Text('重试'),
                ),
              ],
            ),
          const Expanded(child: PromptsTab()),
        ],
      ),
    );
  }
}

class _ProjectSheet extends StatelessWidget {
  const _ProjectSheet();

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, s, _) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.65,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '连接 / 选择 AI 项目',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        onPressed: () => s.refreshAll(),
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: s.projects.isEmpty
                      ? const Center(
                          child: Text('暂无项目，请先在 PC 打开 AI 工具并启用 MCP'),
                        )
                      : ListView.separated(
                          itemCount: s.projects.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final p = s.projects[i];
                            final selected = s.activeProjectId == p.id;
                            return ListTile(
                              selected: selected,
                              leading: Icon(
                                Icons.circle,
                                size: 12,
                                color: p.online ? Colors.green : Colors.grey,
                              ),
                              title: Text(p.displayName),
                              subtitle: Text(
                                '${p.online ? '在线' : '离线'} · ${p.ideLabel} · ${p.workspacePath}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing:
                                  selected ? const Icon(Icons.check) : null,
                              onTap: () async {
                                await s.selectProject(p.id);
                                if (context.mounted) Navigator.pop(context);
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
