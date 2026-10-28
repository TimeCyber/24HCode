import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// 应用内打开 http(s) 地址，不跳系统浏览器。
class InAppWebViewScreen extends StatefulWidget {
  const InAppWebViewScreen({super.key, required this.url, this.title});

  final String url;
  final String? title;

  /// 补全协议：`192.168.1.5:8080` → `http://192.168.1.5:8080`
  static String normalizeUrl(String raw) {
    var u = raw.trim();
    if (u.isEmpty) return u;
    if (!u.contains('://')) {
      u = 'http://$u';
    }
    return u;
  }

  static Future<void> open(BuildContext context, String url, {String? title}) {
    final normalized = normalizeUrl(url);
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => InAppWebViewScreen(url: normalized, title: title),
      ),
    );
  }

  @override
  State<InAppWebViewScreen> createState() => _InAppWebViewScreenState();
}

class _InAppWebViewScreenState extends State<InAppWebViewScreen> {
  late final WebViewController _controller;
  var _loading = true;
  var _progress = 0;
  String? _pageTitle;
  String? _error;

  @override
  void initState() {
    super.initState();
    final uri = Uri.parse(InAppWebViewScreen.normalizeUrl(widget.url));
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _loading = true;
              _error = null;
            });
          },
          onProgress: (p) {
            if (!mounted) return;
            setState(() => _progress = p);
          },
          onPageFinished: (url) async {
            final title = await _controller.getTitle();
            if (!mounted) return;
            setState(() {
              _loading = false;
              _progress = 100;
              if (title != null && title.trim().isNotEmpty) {
                _pageTitle = title;
              }
            });
          },
          onWebResourceError: (err) {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _error = err.description;
            });
          },
        ),
      )
      ..loadRequest(uri);

    // Android WebView：开启 DOM Storage，放宽混合内容（内网 http）
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(false);
      platform.setMediaPlaybackRequiresUserGesture(false);
    }
  }

  Future<void> _openExternal() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title ?? _pageTitle ?? '网页';
    return Scaffold(
      appBar: AppBar(
        title: Text(title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () => _controller.reload(),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '用系统浏览器打开',
            onPressed: _openExternal,
            icon: const Icon(Icons.open_in_browser),
          ),
        ],
        bottom: _loading
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: _progress > 0 && _progress < 100
                      ? _progress / 100
                      : null,
                ),
              )
            : null,
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('加载失败：$_error', textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () {
                        setState(() => _error = null);
                        _controller.loadRequest(Uri.parse(widget.url));
                      },
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            )
          : WebViewWidget(controller: _controller),
    );
  }
}
