import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../widgets/session_status_sheet.dart';
import 'crash_log_screen.dart';
import 'devices_screen.dart';
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
    } else if (project.isEffectivelyOnline()) {
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
                      : (project.isEffectivelyOnline()
                          ? '项目在线'
                          : '项目离线')),
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
              padding: EdgeInsets.symmetric(horizontal: 8),
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
            tooltip: '选择 / 打开项目',
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
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) async {
              if (v == 'crash') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CrashLogScreen()),
                );
              } else if (v == 'setup') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SetupScreen()),
                );
              } else if (v == 'devices') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DevicesScreen()),
                );
              } else if (v == 'logout') {
                await state.logout();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已断开连接')),
                  );
                }
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'setup', child: Text('连接设置 / 账号')),
              if (!state.isLanMode)
                const PopupMenuItem(value: 'devices', child: Text('设备配对')),
              const PopupMenuItem(value: 'crash', child: Text('闪退日志')),
              PopupMenuItem(
                value: 'logout',
                child: Text(state.isLanMode ? '断开内网' : '退出登录'),
              ),
            ],
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
            height: MediaQuery.of(context).size.height * 0.72,
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
                      TextButton.icon(
                        onPressed: () => _showOpenOnPcDialog(context),
                        icon: const Icon(Icons.computer_outlined, size: 18),
                        label: const Text('在 PC 打开'),
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
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              '暂无项目。\n可点「在 PC 打开」让电脑 Cursor/Codex 打开目录，然后刷新。',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
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
                                color: p.isEffectivelyOnline()
                                    ? Colors.green
                                    : Colors.grey,
                              ),
                              title: Text(p.displayName),
                              subtitle: Text(
                                '${p.isEffectivelyOnline() ? '在线' : '离线'} · ${p.ideLabel} · ${p.workspacePath}',
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

  Future<void> _showOpenOnPcDialog(BuildContext context) async {
    final state = context.read<AppState>();
    final pathCtrl = TextEditingController(
      text: state.recentWorkspacePaths.isNotEmpty
          ? state.recentWorkspacePaths.first
          : (state.activeProject?.workspacePath ?? ''),
    );
    var ide = state.activeProject?.ide == 'codex' ? 'codex' : 'cursor';
    var busy = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('在 PC 打开项目'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '填写电脑上的绝对路径，将由在线 MCP/桥接打开 Cursor 或 Codex，并注册到列表。',
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: pathCtrl,
                      decoration: const InputDecoration(
                        labelText: 'PC 项目路径',
                        hintText: r'D:\androidproject\OtherApp',
                        border: OutlineInputBorder(),
                      ),
                      autocorrect: false,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: ide,
                      decoration: const InputDecoration(
                        labelText: 'AI 工具',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'cursor', child: Text('Cursor')),
                        DropdownMenuItem(value: 'codex', child: Text('Codex')),
                      ],
                      onChanged: busy
                          ? null
                          : (v) {
                              if (v != null) setLocal(() => ide = v);
                            },
                    ),
                    if (state.recentWorkspacePaths.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        '最近打开',
                        style: Theme.of(ctx).textTheme.labelMedium,
                      ),
                      const SizedBox(height: 4),
                      ...state.recentWorkspacePaths.take(5).map(
                            (p) => ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                p,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(ctx).textTheme.bodySmall,
                              ),
                              onTap: busy
                                  ? null
                                  : () => setLocal(() => pathCtrl.text = p),
                            ),
                          ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: busy ? null : () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          setLocal(() => busy = true);
                          try {
                            final msg = await state.openWorkspaceOnPc(
                              workspacePath: pathCtrl.text,
                              ide: ide,
                            );
                            if (!ctx.mounted) return;
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(msg)),
                            );
                          } catch (e) {
                            setLocal(() => busy = false);
                            if (!ctx.mounted) return;
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(
                                content: Text(
                                  e.toString().replaceFirst('Exception: ', ''),
                                ),
                              ),
                            );
                          }
                        },
                  child: Text(busy ? '打开中…' : '打开并刷新'),
                ),
              ],
            );
          },
        );
      },
    );
    pathCtrl.dispose();
  }
}
