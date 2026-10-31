import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

/// 连接设置：云端短信登录 / 内网中继地址+Token
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late bool _lanMode;
  late final TextEditingController _root;
  late final TextEditingController _phone;
  late final TextEditingController _sms;
  late final TextEditingController _lanUrl;
  late final TextEditingController _lanToken;
  bool _saving = false;
  bool _sendingSms = false;
  int _smsCooldown = 0;
  Timer? _smsTimer;
  String? _error;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _lanMode = state.isLanMode;
    _root = TextEditingController(
      text: state.apiRoot.isNotEmpty
          ? state.apiRoot
          : 'https://mcp-x.com/prod-api',
    );
    _phone = TextEditingController(
      text: RegExp(r'^1\d{10}$').hasMatch(state.username) ? state.username : '',
    );
    _sms = TextEditingController();
    _lanUrl = TextEditingController(
      text: state.isLanMode && state.serverUrl.isNotEmpty
          ? state.serverUrl
          : 'http://192.168.1.9:8787',
    );
    _lanToken = TextEditingController(
      text: state.isLanMode && state.token.isNotEmpty
          ? state.token
          : 'codeassist-dev-token',
    );
  }

  @override
  void dispose() {
    _smsTimer?.cancel();
    _root.dispose();
    _phone.dispose();
    _sms.dispose();
    _lanUrl.dispose();
    _lanToken.dispose();
    super.dispose();
  }

  void _startSmsCooldown([int seconds = 60]) {
    _smsTimer?.cancel();
    setState(() => _smsCooldown = seconds);
    _smsTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_smsCooldown <= 1) {
        t.cancel();
        setState(() => _smsCooldown = 0);
      } else {
        setState(() => _smsCooldown -= 1);
      }
    });
  }

  Future<void> _sendSms() async {
    final root = _root.text.trim();
    final phone = _phone.text.trim();
    if (root.isEmpty || phone.isEmpty) {
      setState(() => _error = '请填写服务地址和手机号');
      return;
    }
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) {
      setState(() => _error = '请输入11位中国大陆手机号');
      return;
    }
    if (!(root.startsWith('http://') || root.startsWith('https://'))) {
      setState(() => _error = '地址需以 http:// 或 https:// 开头');
      return;
    }
    if (_smsCooldown > 0 || _sendingSms) return;

    setState(() {
      _sendingSms = true;
      _error = null;
    });
    try {
      await context.read<AppState>().sendSmsCode(root: root, phoneNumber: phone);
      if (!mounted) return;
      _startSmsCooldown();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('验证码已发送')),
      );
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _sendingSms = false);
    }
  }

  Future<void> _loginCloud() async {
    final root = _root.text.trim();
    final phone = _phone.text.trim();
    final sms = _sms.text.trim();
    if (root.isEmpty || phone.isEmpty || sms.isEmpty) {
      setState(() => _error = '请填写服务地址、手机号和短信验证码');
      return;
    }
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) {
      setState(() => _error = '请输入11位中国大陆手机号');
      return;
    }
    if (!(root.startsWith('http://') || root.startsWith('https://'))) {
      setState(() => _error = '地址需以 http:// 或 https:// 开头');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await context.read<AppState>().login(
            root: root,
            phoneNumber: phone,
            smsCode: sms,
          );
      if (!mounted) return;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('云端登录成功')),
      );
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _connectLan() async {
    final url = _lanUrl.text.trim();
    final token = _lanToken.text.trim();
    if (url.isEmpty || token.isEmpty) {
      setState(() => _error = '请填写内网中继地址和 Token');
      return;
    }
    if (!(url.startsWith('http://') || url.startsWith('https://'))) {
      setState(() => _error = '地址需以 http:// 或 https:// 开头');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await context.read<AppState>().saveLanConfig(
            relayUrl: url,
            accessToken: token,
          );
      if (!mounted) return;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已连接内网中继')),
      );
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final loggedIn = state.configured && state.token.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(loggedIn ? '连接设置' : '连接'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              loggedIn
                  ? (state.isLanMode
                      ? '当前：内网直连。可切换云端登录，或修改内网地址后重新连接。'
                      : '当前：云端账号。可切换到内网中继，或重新登录切换账号。')
                  : '选择连接方式：家里局域网直连中继，或手机号短信登录 mcp-x 走云端。',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            if (loggedIn) ...[
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  child: Icon(state.isLanMode ? Icons.lan_outlined : Icons.cloud_outlined),
                ),
                title: Text(
                  state.isLanMode
                      ? '内网中继'
                      : (state.nickName.isNotEmpty
                          ? state.nickName
                          : (state.username.isNotEmpty ? state.username : '云端')),
                ),
                subtitle: Text(
                  state.isLanMode
                      ? state.serverUrl
                      : '${state.username}\n${state.serverUrl}',
                ),
                isThreeLine: !state.isLanMode && state.username.isNotEmpty,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _saving
                    ? null
                    : () async {
                        await context.read<AppState>().logout();
                        if (!mounted) return;
                        Navigator.of(context).popUntil((r) => r.isFirst);
                      },
                icon: const Icon(Icons.logout),
                label: const Text('断开 / 退出'),
              ),
              const Divider(height: 32),
              Text(
                '切换或重新连接',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ],
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment<bool>(
                  value: false,
                  label: Text('云端'),
                  icon: Icon(Icons.cloud_outlined),
                ),
                ButtonSegment<bool>(
                  value: true,
                  label: Text('内网'),
                  icon: Icon(Icons.lan_outlined),
                ),
              ],
              selected: {_lanMode},
              onSelectionChanged: (s) {
                setState(() {
                  _lanMode = s.first;
                  _error = null;
                });
              },
            ),
            const SizedBox(height: 20),
            if (!_lanMode) ..._cloudFields(context) else ..._lanFields(context),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _saving
                  ? null
                  : (_lanMode ? _connectLan : _loginCloud),
              child: Text(
                _saving
                    ? (_lanMode ? '连接中…' : '登录中…')
                    : (_lanMode ? '连接内网' : '登录云端'),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _lanMode
                  ? '内网说明：\n'
                      '· 中继地址示例：http://192.168.1.9:8787\n'
                      '· Token 与电脑端 ACCESS_TOKEN 一致（默认 codeassist-dev-token）\n'
                      '· 手机与电脑需同一 Wi‑Fi，且防火墙放行 8787'
                  : '云端说明：\n'
                      '· 发送验证码：{服务地址}/web/auth/sms/send-code\n'
                      '· 短信登录：{服务地址}/web/auth/sms/login\n'
                      '· 中继接口：{服务地址}/codeassist/api/...\n'
                      '· 登录后到「设备配对」生成配对码绑定家里电脑',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _cloudFields(BuildContext context) {
    final canSend = !_sendingSms && _smsCooldown == 0;
    return [
      TextField(
        controller: _root,
        decoration: const InputDecoration(
          labelText: '服务地址（API 根）',
          hintText: 'https://mcp-x.com/prod-api',
          helperText: 'RuoYi 网关；中继自动使用 /codeassist',
          border: OutlineInputBorder(),
        ),
        keyboardType: TextInputType.url,
        autocorrect: false,
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _phone,
        decoration: const InputDecoration(
          labelText: '手机号',
          hintText: '11位中国大陆手机号',
          border: OutlineInputBorder(),
        ),
        keyboardType: TextInputType.phone,
        autocorrect: false,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 16),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _sms,
              decoration: const InputDecoration(
                labelText: '短信验证码',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              onSubmitted: (_) => _saving ? null : _loginCloud(),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            height: 56,
            child: OutlinedButton(
              onPressed: canSend ? _sendSms : null,
              child: Text(
                _sendingSms
                    ? '发送中'
                    : (_smsCooldown > 0 ? '${_smsCooldown}s' : '获取验证码'),
              ),
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _lanFields(BuildContext context) {
    return [
      TextField(
        controller: _lanUrl,
        decoration: const InputDecoration(
          labelText: '内网中继地址',
          hintText: 'http://192.168.1.9:8787',
          helperText: '电脑上 npm run start:server 的地址，不要加 /codeassist',
          border: OutlineInputBorder(),
        ),
        keyboardType: TextInputType.url,
        autocorrect: false,
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _lanToken,
        decoration: const InputDecoration(
          labelText: 'Access Token',
          hintText: 'codeassist-dev-token',
          helperText: '与中继环境变量 ACCESS_TOKEN 相同',
          border: OutlineInputBorder(),
        ),
        autocorrect: false,
        onSubmitted: (_) => _saving ? null : _connectLan(),
      ),
    ];
  }
}
