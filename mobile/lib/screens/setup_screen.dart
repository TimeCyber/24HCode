import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _url;
  late final TextEditingController _token;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _url = TextEditingController(text: state.serverUrl);
    _token = TextEditingController(text: state.token);
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _url.text.trim();
    final token = _token.text.trim();
    if (url.isEmpty || token.isEmpty) {
      setState(() => _error = '请填写中继服务地址和 Token');
      return;
    }
    if (!(url.startsWith('http://') || url.startsWith('https://'))) {
      setState(() => _error = '地址需以 http:// 或 https:// 开头，例如 http://192.168.1.10:8787');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await context.read<AppState>().saveConfig(url, token);
      if (!mounted) return;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已连接到中继服务')),
      );
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('连接中继服务'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              '填写电脑所在内网的中继地址，真机与电脑需在同一局域网。',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: '中继服务地址（内网）',
                hintText: 'http://192.168.1.10:8787',
                helperText: '电脑局域网 IP + 端口，默认 8787',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _token,
              decoration: const InputDecoration(
                labelText: 'Access Token',
                hintText: 'codeassist-dev-token',
                helperText: '与服务端 ACCESS_TOKEN 保持一致',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? '连接中…' : '保存并连接'),
            ),
            const SizedBox(height: 16),
            Text(
              '示例：\n'
              '· 真机内网：http://192.168.x.x:8787\n'
              '· Android 模拟器访问本机：http://10.0.2.2:8787\n'
              '· 服务端需监听 0.0.0.0（默认已开启）',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
