import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

/// 设备配对页：生成配对码、管理已绑定的家里电脑
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  String? _code;
  int _expiresIn = 0;
  Timer? _ticker;
  bool _loading = false;
  bool _loadingList = false;
  String? _error;
  List<Map<String, dynamic>> _devices = [];

  @override
  void initState() {
    super.initState();
    unawaited(_refreshDevices());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _refreshDevices() async {
    final api = context.read<AppState>().apiOrNull;
    if (api == null) {
      setState(() => _error = '请先登录');
      return;
    }
    setState(() {
      _loadingList = true;
      _error = null;
    });
    try {
      final list = await api.listPairedDevices();
      if (!mounted) return;
      setState(() => _devices = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loadingList = false);
    }
  }

  Future<void> _createCode() async {
    final api = context.read<AppState>().apiOrNull;
    if (api == null) {
      setState(() => _error = '请先登录');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await api.createPairCode();
      if (!mounted) return;
      final code = (data['code'] as String?)?.trim() ?? '';
      final expires = (data['expiresInSeconds'] as num?)?.toInt() ?? 300;
      _ticker?.cancel();
      setState(() {
        _code = code;
        _expiresIn = expires;
      });
      _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        if (_expiresIn <= 1) {
          t.cancel();
          setState(() {
            _expiresIn = 0;
            _code = null;
          });
          return;
        }
        setState(() => _expiresIn -= 1);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _revoke(String id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解除配对'),
        content: Text('确定解除「$name」？解除后该电脑将无法接收指令。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('解除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final api = context.read<AppState>().apiOrNull;
    if (api == null) return;
    try {
      await api.revokePairedDevice(id);
      await _refreshDevices();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已解除配对')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('设备配对'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loadingList ? null : _refreshDevices,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '把家里跑 Cursor/Codex 的电脑绑到当前账号：手机生成配对码 → 电脑兑换 deviceToken。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('配对码', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  if (_code != null && _expiresIn > 0) ...[
                    SelectableText(
                      _code!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.displaySmall?.copyWith(
                        letterSpacing: 6,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '有效期 $_expiresIn 秒',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: _code!));
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制配对码')),
                        );
                      },
                      icon: const Icon(Icons.copy),
                      label: const Text('复制'),
                    ),
                  ] else
                    Text(
                      '点击下方按钮生成 6 位配对码（5 分钟有效）',
                      style: theme.textTheme.bodySmall,
                    ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _loading ? null : _createCode,
                    child: Text(_loading ? '生成中…' : '生成配对码'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '电脑端兑换（推荐）',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          SelectableText(
            '在电脑项目目录双击或运行：\n'
            'packages\\mcp-server\\pair-claim.bat 配对码\n\n'
            '例：pair-claim.bat ABCD12\n'
            '成功后会生成 .codeassist-device.env，\n'
            '再运行 start-codex-bridge.bat 即可连云端。\n\n'
            '手动接口（可选）：\n'
            'POST {API根}/codeassist/pair/claim\n'
            '{"code":"配对码","deviceName":"家里电脑"}',
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
          const SizedBox(height: 24),
          Text('已配对设备', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (_loadingList)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_devices.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('暂无已配对设备'),
            )
          else
            ..._devices.map((d) {
              final id = d['id']?.toString() ?? '';
              final name = d['deviceName']?.toString() ?? '未命名设备';
              final last = d['lastSeenAt']?.toString() ?? '';
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.computer_outlined),
                title: Text(name),
                subtitle: Text(last.isEmpty ? id : '最近：$last'),
                trailing: IconButton(
                  tooltip: '解除配对',
                  onPressed: id.isEmpty ? null : () => _revoke(id, name),
                  icon: const Icon(Icons.link_off),
                ),
              );
            }),
        ],
      ),
    );
  }
}
