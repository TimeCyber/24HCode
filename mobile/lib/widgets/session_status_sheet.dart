import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import 'linkified_text.dart';

/// 右上角按钮打开：查看当前会话处理状态与结果。
Future<void> showSessionStatusSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _SessionStatusSheet(),
  );
}

class _SessionStatusSheet extends StatelessWidget {
  const _SessionStatusSheet();

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final chat = state.activeChatSession;
        final messages = state.chatMessages;
        final scheme = Theme.of(context).colorScheme;
        PromptJob? latestWithResult;
        PromptJob? inFlight;
        for (final m in messages.reversed) {
          final r = m.result?.trim();
          final hasResult = r != null && r.isNotEmpty;
          if (hasResult) {
            latestWithResult ??= m;
          } else if (m.status == 'queued' ||
              m.status == 'delivered' ||
              m.status == 'running') {
            inFlight ??= m;
          }
          if (latestWithResult != null && inFlight != null) break;
        }

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              bottom: MediaQuery.of(context).viewInsets.bottom + 16,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.72,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '本会话状态',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      chat?.title ?? '未选择会话',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 16),
                    _SectionCard(
                      title: '处理状态',
                      child: Text(
                        inFlight != null
                            ? '进行中 · ${_statusLabel(inFlight.status)}'
                            : (chat?.contextStatus?.trim().isNotEmpty == true
                                ? chat!.contextStatus!
                                : '空闲'),
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                    if (chat?.contextSummary?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: 10),
                      _SectionCard(
                        title: '摘要',
                        child: SelectableText(chat!.contextSummary!),
                      ),
                    ],
                    if (chat?.contextStep?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: 10),
                      _SectionCard(
                        title: '当前步骤',
                        child: SelectableText(chat!.contextStep!),
                      ),
                    ],
                    if (chat?.contextExtra?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: 10),
                      _SectionCard(
                        title: '详情',
                        child: LinkifiedText(
                          chat!.contextExtra!,
                          showOpenButtons: true,
                        ),
                      ),
                    ],
                    if (inFlight != null) ...[
                      const SizedBox(height: 10),
                      _SectionCard(
                        title: '进行中的指令',
                        child: SelectableText(inFlight.content),
                      ),
                    ],
                    if (latestWithResult != null) ...[
                      const SizedBox(height: 10),
                      _SectionCard(
                        title: latestWithResult.status == 'failed'
                            ? '最近结果（失败）'
                            : '最近结果',
                        child: LinkifiedText(
                          latestWithResult.result!,
                          showOpenButtons: true,
                        ),
                      ),
                    ],
                    if (chat == null ||
                        (!chat.hasContext &&
                            inFlight == null &&
                            latestWithResult == null)) ...[
                      const SizedBox(height: 24),
                      Text(
                        '暂无会话上下文或结果',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static String _statusLabel(String status) {
    switch (status) {
      case 'queued':
        return '排队等待';
      case 'delivered':
        return '已拉取';
      case 'running':
        return '执行中';
      case 'done':
        return '完成';
      case 'failed':
        return '失败';
      default:
        return status;
    }
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.primary,
                  ),
            ),
            const SizedBox(height: 6),
            child,
          ],
        ),
      ),
    );
  }
}
