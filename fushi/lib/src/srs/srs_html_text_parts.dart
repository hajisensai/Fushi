/// 结构化字段（Yomitan 释义等子集之外的 HTML）的「只改文字」编辑：把 HTML 拆成固定的
/// 标签骨架 + 一段段可见文字，用户逐段改文字，标签、class、data-*、内联样式一字不动。
///
/// - 只拆可见文字：`<style>` / `<script>` 里的内容、注释、纯空白都算骨架；
/// - 每段文字两侧的空白留在骨架里（排版用的换行缩进不变）；
/// - 没改过的段原样输出原始写法（实体不会被重新转义），改过的段按纯文本转义。
///
/// 纯函数，单测直接调。
library;

import 'package:flutter/foundation.dart';

import 'package:fushi/src/srs/srs_fushi_card_fields.dart'
    show srsDecodeEntities;

final RegExp _markup = RegExp(r'<!--[\s\S]*?-->|<[^>]*>');
final RegExp _rawOpen = RegExp(r'^<(style|script)\b', caseSensitive: false);

/// 拆好的一份 HTML：`skeleton[0] + 段0 + skeleton[1] + 段1 + … + skeleton[n]`。
@immutable
class SrsHtmlTextParts {
  const SrsHtmlTextParts._(this.skeleton, this.raws, this.texts);

  /// 段与段之间的骨架（比段多一个）。
  final List<String> skeleton;

  /// 每段的原始写法（含实体）。
  final List<String> raws;

  /// 每段解码后的可见文字。
  final List<String> texts;

  int get length => texts.length;

  /// 用 [values]（与 [texts] 一一对应）拼回 HTML；与原文字相同的段输出原写法。
  String join(List<String> values) {
    assert(values.length == texts.length);
    final StringBuffer out = StringBuffer(skeleton.first);
    for (int i = 0; i < texts.length; i++) {
      out.write(values[i] == texts[i] ? raws[i] : _escape(values[i]));
      out.write(skeleton[i + 1]);
    }
    return out.toString();
  }
}

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('\n', '<br>');

/// 拆 [html]。
SrsHtmlTextParts srsSplitHtmlText(String html) {
  final List<String> skeleton = <String>[];
  final List<String> raws = <String>[];
  final List<String> texts = <String>[];
  final StringBuffer pending = StringBuffer();
  String? rawElement;

  void text(String raw) {
    if (raw.isEmpty) return;
    if (rawElement != null || raw.trim().isEmpty) {
      pending.write(raw);
      return;
    }
    final int lead = raw.length - raw.trimLeft().length;
    final int trail = raw.length - raw.trimRight().length;
    pending.write(raw.substring(0, lead));
    skeleton.add(pending.toString());
    pending.clear();
    final String body = raw.substring(lead, raw.length - trail);
    raws.add(body);
    texts.add(srsDecodeEntities(body));
    pending.write(raw.substring(raw.length - trail));
  }

  int last = 0;
  for (final RegExpMatch m in _markup.allMatches(html)) {
    text(html.substring(last, m.start));
    final String tag = m.group(0)!;
    pending.write(tag);
    if (rawElement == null) {
      final RegExpMatch? open = _rawOpen.firstMatch(tag);
      if (open != null && !tag.endsWith('/>')) {
        rawElement = open.group(1)!.toLowerCase();
      }
    } else if (tag.toLowerCase().startsWith('</$rawElement')) {
      rawElement = null;
    }
    last = m.end;
  }
  text(html.substring(last));
  skeleton.add(pending.toString());
  return SrsHtmlTextParts._(
    List<String>.unmodifiable(skeleton),
    List<String>.unmodifiable(raws),
    List<String>.unmodifiable(texts),
  );
}
