import 'package:flutter/material.dart';

import '../chat_activity.dart';

class ChatActivityBubble extends StatefulWidget {
  const ChatActivityBubble({super.key, required this.activity});
  final ChatActivity activity;

  @override
  State<ChatActivityBubble> createState() => _ChatActivityBubbleState();
}

class _ChatActivityBubbleState extends State<ChatActivityBubble> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final activity = widget.activity;
    final theme = Theme.of(context);
    final label = switch (activity.status) {
      'thinking' => '正在分析',
      'coding' => '执行中',
      'waiting_user' => '等待确认',
      'blocked' => '执行受阻',
      'done' => '已完成',
      _ => '任务动态',
    };
    final progress = activity.step.trim().isNotEmpty
        ? activity.step.trim()
        : activity.summary.trim();
    final statusLine = [
      activity.chatId == null ? '项目' : 'PC',
      label,
      if (progress.isNotEmpty) progress,
    ].join(' · ');
    final detail = activity.extra.trim().isNotEmpty
        ? activity.extra.trim()
        : activity.summary.trim() != progress
        ? activity.summary.trim()
        : '';

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          statusLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      AnimatedRotation(
                        turns: _expanded ? 0.25 : 0,
                        duration: const Duration(milliseconds: 160),
                        child: Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 24, 6),
                child: SelectableText(
                  detail.isEmpty ? '暂无详细返回内容' : detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
