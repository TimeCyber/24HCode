import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../screens/in_app_webview_screen.dart';

/// 文本中的 http(s) 链接可点开（应用内 WebView）。
class LinkifiedText extends StatefulWidget {
  const LinkifiedText(
    this.text, {
    super.key,
    this.style,
    this.linkStyle,
    this.showOpenButtons = true,
  });

  final String text;
  final TextStyle? style;
  final TextStyle? linkStyle;
  final bool showOpenButtons;

  static final RegExp urlPattern = RegExp(
    r'''https?://[^\s<>"'\])\}，。；、】）》〉」』]+''',
    caseSensitive: false,
  );

  static List<String> extractUrls(String text) {
    final seen = <String>{};
    final out = <String>[];
    for (final m in urlPattern.allMatches(text)) {
      var raw = m.group(0)!;
      // 去掉常见尾随标点
      while (raw.isNotEmpty && '.,;:!?)]}>》」』'.contains(raw[raw.length - 1])) {
        raw = raw.substring(0, raw.length - 1);
      }
      if (raw.isEmpty || !seen.add(raw)) continue;
      out.add(raw);
    }
    return out;
  }

  static Future<bool> openUrl(String url, {BuildContext? context}) async {
    final normalized = InAppWebViewScreen.normalizeUrl(url);
    final uri = Uri.tryParse(normalized);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return false;
    }
    if (context == null || !context.mounted) return false;
    try {
      await InAppWebViewScreen.open(context, normalized);
      return true;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开失败：$e')),
        );
      }
      return false;
    }
  }

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    super.dispose();
  }

  List<InlineSpan> _spans(TextStyle base, TextStyle link) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final text = widget.text;
    final matches = LinkifiedText.urlPattern.allMatches(text).toList();
    if (matches.isEmpty) {
      return [TextSpan(text: text, style: base)];
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final m in matches) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, m.start), style: base));
      }
      var url = m.group(0)!;
      while (url.isNotEmpty && '.,;:!?)]}>》」』'.contains(url[url.length - 1])) {
        url = url.substring(0, url.length - 1);
      }
      final trailing = m.group(0)!.substring(url.length);
      final recognizer = TapGestureRecognizer()
        ..onTap = () {
          LinkifiedText.openUrl(url, context: context);
        };
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: url,
          style: link,
          recognizer: recognizer,
        ),
      );
      if (trailing.isNotEmpty) {
        spans.add(TextSpan(text: trailing, style: base));
      }
      cursor = m.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor), style: base));
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    final link = widget.linkStyle ??
        base.copyWith(
          color: scheme.primary,
          decoration: TextDecoration.underline,
          decorationColor: scheme.primary,
        );
    final urls = LinkifiedText.extractUrls(widget.text);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectableText.rich(TextSpan(style: base, children: _spans(base, link))),
        if (widget.showOpenButtons && urls.isNotEmpty) ...[
          const SizedBox(height: 8),
          ...urls.map(
            (u) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: OutlinedButton.icon(
                onPressed: () => LinkifiedText.openUrl(u, context: context),
                icon: const Icon(Icons.public, size: 18),
                label: Text(
                  urls.length == 1 ? '在应用内打开网页' : u,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
