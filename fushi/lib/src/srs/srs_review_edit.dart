/// 复习时编辑（反馈 cbzyXZlK-t / yrXhexdOaR）：卡面上选中的文字 → 写回对应字段的加粗 / 高亮 / 清除格式。
///
/// 卡面是字段渲染出来的（原生 Fushi 卡面、释义 WebView、整面模板 WebView），选区只有「选中的纯文字」
/// （释义 WebView 还给出它是文档里第几处同样的文字）。这里按纯文字回到字段 HTML：
///
/// - 字段的「可匹配文字」= 正文文字节点（实体解码；`<rt>` / `<rp>` / `<script>` / `<style>` 里的不算，
///   注音在卡面上另行画出），比对时去掉全部空白（卡面换行 / 分栏与源码的空白对不上）；
/// - 加粗 / 高亮按文字节点逐段包标签（`<b>` / `<span style="background-color: …">`），跨标签的选区
///   不会打乱原有嵌套；
/// - 清除：去掉与选区相交的加粗 / 斜体 / 下划线 / 高亮元素（开闭标签成对删，内容保留）。
///
/// 纯函数，单测直接调。
library;

import 'package:fushi/src/srs/srs_field_markup.dart' show srsCssColor;
import 'package:fushi/src/srs/srs_fushi_card_fields.dart'
    show srsDecodeEntities, srsInlineHighlightOf;
import 'package:fushi/src/srs/srs_rich_format.dart' show kSrsHighlightDefault;

/// 复习时编辑的格式操作。
enum SrsQuickFormat { bold, highlight, clear }

/// 卡面上的一次选区：选中的纯文字；[occurrence] = 它是所在文档（释义区）里第几处同样的文字（从 0 数，
/// 不知道 = null）；[definitionsOnly] = 选区来自 Fushi 卡片的释义区（只在释义字段里找）。
class SrsCardSelection {
  const SrsCardSelection(
    this.text, {
    this.occurrence,
    this.definitionsOnly = false,
  });

  final String text;
  final int? occurrence;
  final bool definitionsOnly;

  /// 去掉空白后的比对键（空 = 没选中什么）。
  String get key => srsCompactText(text);
}

final RegExp _space = RegExp(r'\s+');

/// 去掉全部空白（比对用）。
String srsCompactText(String s) => s.replaceAll(_space, '');

final RegExp _token = RegExp(
  r'<!--[\s\S]*?-->|<(/?)([a-zA-Z][a-zA-Z0-9]*)\b([^>]*?)(/?)>',
);

const Set<String> _voidTags = <String>{
  'br',
  'img',
  'hr',
  'input',
  'meta',
  'link',
  'source',
  'wbr',
  'col',
  'area',
  'base',
  'embed',
  'track',
};

/// 文字不算进可匹配文字的元素。
const Set<String> _hiddenTags = <String>{'rt', 'rp', 'script', 'style'};

/// 字段 HTML 里一个可匹配字符：解码后的字符与它在源码里的区间。
class _Char {
  const _Char(this.char, this.start, this.end);
  final String char;
  final int start;
  final int end;
}

/// 一个元素：开标签区间、闭标签区间（没闭合 = null）、它包住的可匹配字符区间 [from, to)。
class _Element {
  _Element(this.name, this.attrs, this.openStart, this.openEnd, this.from);
  final String name;
  final String attrs;
  final int openStart;
  final int openEnd;
  final int from;
  int? closeStart;
  int? closeEnd;
  int to = 0;
}

class _Scan {
  _Scan(this.chars, this.elements);
  final List<_Char> chars;
  final List<_Element> elements;
}

_Scan _scan(String html) {
  final List<_Char> chars = <_Char>[];
  final List<_Element> elements = <_Element>[];
  final List<_Element> open = <_Element>[];
  int hidden = 0;
  int last = 0;

  void text(int start, int end) {
    if (hidden > 0 || start >= end) return;
    int i = start;
    while (i < end) {
      // 实体整段算一个字符。
      if (html.codeUnitAt(i) == 0x26) {
        final int semi = html.indexOf(';', i);
        if (semi > i && semi < end && semi - i <= 10) {
          final String decoded = srsDecodeEntities(html.substring(i, semi + 1));
          if (decoded.length == 1 || decoded.runes.length == 1) {
            if (decoded.trim().isNotEmpty) {
              chars.add(_Char(decoded, i, semi + 1));
            }
            i = semi + 1;
            continue;
          }
        }
      }
      final int unit = html.codeUnitAt(i);
      final int len = (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < end) ? 2 : 1;
      final String ch = html.substring(i, i + len);
      if (ch.trim().isNotEmpty) chars.add(_Char(ch, i, i + len));
      i += len;
    }
  }

  for (final Match m in _token.allMatches(html)) {
    text(last, m.start);
    last = m.end;
    final String? name = m.group(2)?.toLowerCase();
    if (name == null) continue; // 注释
    final bool closing = m.group(1)!.isNotEmpty;
    final bool selfClosing = m.group(4)!.isNotEmpty || _voidTags.contains(name);
    if (closing) {
      // 关最近一个同名元素（其间没闭合的一并结束）。
      for (int k = open.length - 1; k >= 0; k--) {
        if (open[k].name == name) {
          final _Element e = open[k];
          e.closeStart = m.start;
          e.closeEnd = m.end;
          e.to = chars.length;
          for (int j = open.length - 1; j > k; j--) {
            open[j].to = chars.length;
          }
          open.removeRange(k, open.length);
          break;
        }
      }
      if (_hiddenTags.contains(name) && hidden > 0) hidden--;
      continue;
    }
    if (selfClosing) continue;
    final _Element e = _Element(
      name,
      m.group(3) ?? '',
      m.start,
      m.end,
      chars.length,
    );
    open.add(e);
    elements.add(e);
    if (_hiddenTags.contains(name)) hidden++;
  }
  text(last, html.length);
  for (final _Element e in open) {
    e.to = chars.length;
  }
  return _Scan(chars, elements);
}

/// 字段 HTML 的可匹配文字（去空白）。
String srsFieldMatchText(String html) =>
    _scan(html).chars.map((_Char c) => c.char).join();

/// [key] 在 [hay] 里各处出现的起点。
List<int> _occurrences(String hay, String key) {
  final List<int> out = <int>[];
  if (key.isEmpty) return out;
  int from = 0;
  while (true) {
    final int i = hay.indexOf(key, from);
    if (i < 0) return out;
    out.add(i);
    from = i + 1;
  }
}

/// 选区出现在哪些字段里（[fields] 按卡面顺序给：字段 id → HTML）。没选中什么 = 空。
List<String> srsFieldsContaining(
  Map<String, String> fields,
  SrsCardSelection selection,
) {
  final String key = selection.key;
  if (key.isEmpty) return const <String>[];
  return <String>[
    for (final MapEntry<String, String> f in fields.entries)
      if (srsFieldMatchText(f.value).contains(key)) f.key,
  ];
}

bool _isFormatting(_Element e) => switch (e.name) {
  'b' || 'strong' || 'i' || 'em' || 'u' || 'mark' => true,
  'span' => srsInlineHighlightOf(e.attrs) != null,
  _ => false,
};

/// 对字段 [html] 里 [selection] 那段文字做 [format]；找不到返回 null。
///
/// 同一段文字在字段里出现多次时：给了 [SrsCardSelection.occurrence] 且在范围内就用那一处，否则第一处。
String? srsApplyQuickFormat(
  String html,
  SrsCardSelection selection,
  SrsQuickFormat format, {
  int highlightColor = kSrsHighlightDefault,
}) {
  final String key = selection.key;
  if (key.isEmpty) return null;
  final _Scan scan = _scan(html);
  final String hay = scan.chars.map((_Char c) => c.char).join();
  final List<int> at = _occurrences(hay, key);
  if (at.isEmpty) return null;
  final int? want = selection.occurrence;
  final int from = want != null && want >= 0 && want < at.length
      ? at[want]
      : at.first;
  final int to = from + key.length;
  // hay 的下标 = chars 的下标（每个 _Char 恰好一个 UTF-16 码元？不一定：代理对 / 实体占 1 个 _Char
  // 但可能 2 个码元）。按码元累加换算。
  final List<int> unitStart = <int>[];
  int acc = 0;
  for (final _Char c in scan.chars) {
    unitStart.add(acc);
    acc += c.char.length;
  }
  int charIndexOf(int unit) {
    int lo = 0, hi = unitStart.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (unitStart[mid] < unit) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  final int first = charIndexOf(from);
  final int end = charIndexOf(to);
  if (first >= end) return null;

  if (format == SrsQuickFormat.clear) {
    final List<(int, int)> cuts = <(int, int)>[];
    for (final _Element e in scan.elements) {
      if (!_isFormatting(e)) continue;
      if (e.to <= first || e.from >= end || e.from == e.to) continue;
      cuts.add((e.openStart, e.openEnd));
      if (e.closeStart != null) cuts.add((e.closeStart!, e.closeEnd!));
    }
    if (cuts.isEmpty) return html;
    cuts.sort(((int, int) a, (int, int) b) => a.$1.compareTo(b.$1));
    final StringBuffer out = StringBuffer();
    int last = 0;
    for (final (int s, int e) in cuts) {
      out.write(html.substring(last, s));
      last = e;
    }
    out.write(html.substring(last));
    return out.toString();
  }

  final String open = format == SrsQuickFormat.bold
      ? '<b>'
      : '<span style="background-color: ${srsCssColor(highlightColor)};">';
  final String close = format == SrsQuickFormat.bold ? '</b>' : '</span>';
  // 按源码里连续的字符分段（中间隔着标签就断开），每段各包一层。
  final List<(int, int)> runs = <(int, int)>[];
  int runStart = scan.chars[first].start;
  int runEnd = scan.chars[first].end;
  for (int i = first + 1; i < end; i++) {
    final _Char c = scan.chars[i];
    final String between = html.substring(runEnd, c.start);
    if (between.trim().isEmpty && !between.contains('<')) {
      runEnd = c.end;
    } else {
      runs.add((runStart, runEnd));
      runStart = c.start;
      runEnd = c.end;
    }
  }
  runs.add((runStart, runEnd));
  final StringBuffer out = StringBuffer();
  int last = 0;
  for (final (int s, int e) in runs) {
    out
      ..write(html.substring(last, s))
      ..write(open)
      ..write(html.substring(s, e))
      ..write(close);
    last = e;
  }
  out.write(html.substring(last));
  return out.toString();
}
