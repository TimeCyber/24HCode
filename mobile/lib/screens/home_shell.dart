import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../widgets/session_status_sheet.dart';
import 'crash_log_screen.dart';
import 'devices_screen.dart';
import 'prompts_tab.dart';
import 'scheduled_prompts_screen.dart';
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
                        : (project.isEffectivelyOnline() ? '项目在线' : '项目离线')),
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
            tooltip: '定时任务',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ScheduledPromptsScreen()),
            ),
            icon: const Icon(Icons.schedule),
          ),
          IconButton(
            tooltip: '本会话状态',
            onPressed: () => showSessionStatusSheet(context),
            icon: const Icon(Icons.info_outline),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: () => state.refreshAll(),
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) async {
              if (v == 'project') {
                await showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const _ProjectSheet(),
                );
              } else if (v == 'crash') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CrashLogScreen()),
                );
              } else if (v == 'setup') {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const SetupScreen()));
              } else if (v == 'devices') {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DevicesScreen()),
                );
                if (context.mounted) {
                  await context.read<AppState>().refreshPairedDevices();
                }
              } else if (v == 'logout') {
                await state.logout();
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('已断开连接')));
                }
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'project', child: Text('选择 / 打开项目')),
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
          if (project?.ide == 'codex')
            _CodexUsageCard(usage: state.activeCodexUsage),
          if (state.needsDevicePairing) const _PairDeviceBanner(),
          const Expanded(child: PromptsTab()),
        ],
      ),
    );
  }
}

class _CodexUsageCard extends StatelessWidget {
  const _CodexUsageCard({required this.usage});

  final CodexUsageSnapshot? usage;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final updated = DateTime.tryParse(usage?.updatedAt ?? '')?.toLocal();
    final stale =
        updated == null ||
        DateTime.now().difference(updated) > const Duration(minutes: 10);
    final plan = usage?.planType;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.data_usage, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Codex 额度${plan == null ? '' : ' · ${_planLabel(plan)}'}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Text(
                  updated == null
                      ? '等待同步'
                      : '${stale ? '数据较旧 · ' : ''}${_clockLabel(updated)}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: stale ? colors.error : colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (usage == null) ...[
              const SizedBox(height: 6),
              Text(
                '等待电脑端 Codex 同步用量；请确认 Codex CLI 已登录。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ] else ...[
              const SizedBox(height: 8),
              if (usage!.primary != null)
                _CodexUsageWindowRow(window: usage!.primary!),
              if (usage!.primary != null && usage!.secondary != null)
                const SizedBox(height: 8),
              if (usage!.secondary != null)
                _CodexUsageWindowRow(window: usage!.secondary!),
              if (usage!.primary == null && usage!.secondary == null)
                Text(
                  '当前没有可展示的额度窗口。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ],
        ),
      ),
    );
  }

  static String _planLabel(String value) {
    switch (value.toLowerCase()) {
      case 'plus':
        return 'Plus';
      case 'pro':
        return 'Pro';
      case 'team':
        return 'Team';
      case 'business':
        return 'Business';
      case 'enterprise':
        return 'Enterprise';
      default:
        return value;
    }
  }

  static String _clockLabel(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}

class _CodexUsageWindowRow extends StatelessWidget {
  const _CodexUsageWindowRow({required this.window});

  final CodexUsageWindow window;

  @override
  Widget build(BuildContext context) {
    final reset = window.resetsAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            window.resetsAt! * 1000,
          ).toLocal();
    final resetText = reset == null
        ? ''
        : ' · 重置 ${reset.month}/${reset.day} ${reset.hour.toString().padLeft(2, '0')}:${reset.minute.toString().padLeft(2, '0')}';
    final percent = window.usedPercent.clamp(0, 100);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _windowLabel(window.windowDurationMins),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Text(
              '剩余 ${100 - percent}%',
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: percent / 100),
        const SizedBox(height: 2),
        Text(
          '已用 $percent%$resetText',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
  }

  static String _windowLabel(int minutes) {
    if (minutes == 300) return '5 小时窗口';
    if (minutes == 10080) return '每周窗口';
    if (minutes % 1440 == 0) return '${minutes ~/ 1440} 天窗口';
    if (minutes % 60 == 0) return '${minutes ~/ 60} 小时窗口';
    return '$minutes 分钟窗口';
  }
}

/// 云端登录后尚未配对电脑时，在首页给出明确下一步
class _PairDeviceBanner extends StatelessWidget {
  const _PairDeviceBanner();

  Future<void> _openPairing(BuildContext context) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const DevicesScreen()));
    if (!context.mounted) return;
    await context.read<AppState>().refreshPairedDevices();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.link, color: scheme.onPrimaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '下一步：配对连接家里电脑',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '登录成功后还需要绑定运行 Cursor/Codex 的电脑，否则无法下发指令。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _openPairing(context),
              icon: const Icon(Icons.qr_code_2),
              label: const Text('去配对连接'),
            ),
          ],
        ),
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
        final visibleProjects = s.visibleProjects;
        final hiddenProjects = s.hiddenProjects;
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
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    '同一工作区若在多个 AI 工具中在线，会分别列出；请选择要接收指令的工具。隐藏只影响这台手机的显示。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 8),
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
                          itemCount:
                              visibleProjects.length +
                              (hiddenProjects.isEmpty ? 0 : 1),
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            if (i == visibleProjects.length &&
                                hiddenProjects.isNotEmpty) {
                              return ExpansionTile(
                                leading: const Icon(
                                  Icons.visibility_off_outlined,
                                ),
                                title: Text('已隐藏项目（${hiddenProjects.length}）'),
                                children: [
                                  for (final p in hiddenProjects)
                                    ListTile(
                                      leading: const Icon(
                                        Icons.visibility_off_outlined,
                                      ),
                                      title: Text(p.displayName),
                                      subtitle: Text(
                                        '${p.ideLabel} · ${p.workspacePath}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      trailing: IconButton(
                                        tooltip: '恢复显示',
                                        onPressed: () =>
                                            s.setProjectHidden(p.id, false),
                                        icon: const Icon(
                                          Icons.visibility_outlined,
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            }
                            final p = visibleProjects[i];
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
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (selected) const Icon(Icons.check),
                                  PopupMenuButton<String>(
                                    tooltip: '项目显示选项',
                                    onSelected: (value) {
                                      if (value == 'hide') {
                                        s.setProjectHidden(p.id, true);
                                      }
                                    },
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: 'hide',
                                        child: Text('在手机端隐藏'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
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
                        DropdownMenuItem(
                          value: 'cursor',
                          child: Text('Cursor'),
                        ),
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
                      Text('最近打开', style: Theme.of(ctx).textTheme.labelMedium),
                      const SizedBox(height: 4),
                      ...state.recentWorkspacePaths
                          .take(5)
                          .map(
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
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text(msg)));
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
