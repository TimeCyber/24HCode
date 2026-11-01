/// 多 AI 工具显示名（勿在 UI 写死 Cursor）。
String ideDisplayName(String? ide) {
  final key = (ide ?? '').trim().toLowerCase();
  switch (key) {
    case 'cursor':
      return 'Cursor';
    case 'codex':
      return 'Codex';
    case 'trae':
    case 'trea':
      return 'Trae';
    case 'workbuddy':
      return 'WorkBuddy';
    case 'claude':
    case 'claude-code':
      return 'Claude';
    case '':
      return 'AI 工具';
    default:
      if (key.isEmpty) return 'AI 工具';
      return key[0].toUpperCase() + key.substring(1);
  }
}

/// 未选项目时的统称。
const String kGenericIdeLabel = 'AI 工具';
