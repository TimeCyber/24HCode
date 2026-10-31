import 'dart:convert';

import 'package:http/http.dart' as http;

class LoginResult {
  LoginResult({
    required this.token,
    this.username,
    this.nickName,
    this.userId,
  });

  final String token;
  final String? username;
  final String? nickName;
  final dynamic userId;
}

/// 对接 mcp-x / RuoYi（与 Web 端一致）
class AuthApi {
  static String normalizeRoot(String root) {
    var r = root.trim().replaceAll(RegExp(r'/+$'), '');
    // 若用户误填到 /codeassist，回退到 API 根
    if (r.endsWith('/codeassist')) {
      r = r.substring(0, r.length - '/codeassist'.length);
    }
    return r;
  }

  static String relayBaseFromRoot(String apiRoot) {
    return '${normalizeRoot(apiRoot)}/codeassist';
  }

  static Map<String, dynamic> _decodeJson(http.Response res) {
    try {
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw Exception('响应无效（HTTP ${res.statusCode}）');
    }
  }

  static void _ensureOk(Map<String, dynamic> json, {String fallback = '请求失败'}) {
    final codeNum = json['code'];
    final msg = (json['msg'] as String?)?.trim() ??
        (json['message'] as String?)?.trim();
    if (codeNum != 200) {
      throw Exception(
        (msg == null || msg.isEmpty) ? '$fallback（code=$codeNum）' : msg,
      );
    }
  }

  static LoginResult _parseLogin(Map<String, dynamic> json, String fallbackUser) {
    _ensureOk(json, fallback: '登录失败');

    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw Exception('登录成功但未返回 token');
    }

    final token = (data['access_token'] as String?)?.trim().isNotEmpty == true
        ? (data['access_token'] as String).trim()
        : ((data['token'] as String?)?.trim().isNotEmpty == true
            ? (data['token'] as String).trim()
            : (json['token'] as String?)?.trim());
    if (token == null || token.isEmpty) {
      throw Exception('登录成功但未返回 token');
    }

    String? uname;
    String? nick;
    dynamic uid;
    final userInfo = data['userInfo'];
    if (userInfo is Map<String, dynamic>) {
      uname = userInfo['username'] as String?;
      nick = userInfo['nickName'] as String?;
      uid = userInfo['userId'];
    }

    return LoginResult(
      token: token,
      username: uname ?? fallbackUser,
      nickName: nick,
      userId: uid,
    );
  }

  /// Web：POST /web/auth/sms/send-code?phoneNumber=
  static Future<void> sendSmsCode({
    required String apiRoot,
    required String phoneNumber,
  }) async {
    final root = normalizeRoot(apiRoot);
    final phone = phoneNumber.trim();
    if (phone.isEmpty) {
      throw Exception('请填写手机号');
    }
    final uri = Uri.parse('$root/web/auth/sms/send-code').replace(
      queryParameters: {'phoneNumber': phone},
    );

    final res = await http
        .post(
          uri,
          headers: const {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 20));

    _ensureOk(_decodeJson(res), fallback: '验证码发送失败');
  }

  /// Web：POST /web/auth/sms/login  body: { phoneNumber, smsCode }
  static Future<LoginResult> smsLogin({
    required String apiRoot,
    required String phoneNumber,
    required String smsCode,
    String? inviteCode,
  }) async {
    final root = normalizeRoot(apiRoot);
    final phone = phoneNumber.trim();
    final code = smsCode.trim();
    if (phone.isEmpty || code.isEmpty) {
      throw Exception('请填写手机号和短信验证码');
    }

    final body = <String, dynamic>{
      'phoneNumber': phone,
      'smsCode': code,
    };
    final invite = inviteCode?.trim();
    if (invite != null && invite.isNotEmpty) {
      body['inviteCode'] = invite;
    }

    final uri = Uri.parse('$root/web/auth/sms/login');
    final res = await http
        .post(
          uri,
          headers: const {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));

    return _parseLogin(_decodeJson(res), phone);
  }
}
