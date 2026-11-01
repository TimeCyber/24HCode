import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// 鸿蒙版：链接用系统浏览器打开（暂不内嵌 WebView）
class LinkifiedText extends StatelessWidget {
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
      while (raw.isNotEmpty && '.,;:!?)]}>》」』'.contains(raw[raw.length - 1])) {
        raw = raw.substring(0, raw.length - 1);
      }
      if (raw.isEmpty || !seen.add(raw)) continue;
      out.add(raw);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final link = linkStyle ??
        base.copyWith(
          color: Theme.of(context).colorScheme.primary,
          decoration: TextDecoration.underline,
        );
    final spans = <InlineSpan>[];
    var start = 0;
    for (final m in urlPattern.allMatches(text)) {
      if (m.start > start) {
        spans.add(TextSpan(text: text.substring(start, m.start), style: base));
      }
      var raw = m.group(0)!;
      while (raw.isNotEmpty && '.,;:!?)]}>》」』'.contains(raw[raw.length - 1])) {
        raw = raw.substring(0, raw.length - 1);
      }
      final url = raw;
      spans.add(
        TextSpan(
          text: raw,
          style: link,
          recognizer: TapGestureRecognizer()
            ..onTap = () {
              final uri = Uri.tryParse(url);
              if (uri != null) {
                unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
              }
            },
        ),
      );
      start = m.end;
    }
    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start), style: base));
    }

    final urls = showOpenButtons ? extractUrls(text) : const <String>[];
    if (urls.isEmpty) {
      return Text.rich(TextSpan(children: spans));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(TextSpan(children: spans)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            for (final u in urls.take(3))
              TextButton(
                onPressed: () {
                  final uri = Uri.tryParse(u);
                  if (uri != null) {
                    unawaited(
                      launchUrl(uri, mode: LaunchMode.externalApplication),
                    );
                  }
                },
                child: const Text('打开链接'),
              ),
          ],
        ),
      ],
    );
  }
}
