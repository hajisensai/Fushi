/// 笔记编辑页富文本的扩展子集：在 srs_field_markup.dart 的白名单（b / strong / i / em / u /
/// br / div / p / 只带颜色的 span / font）之上，再认**高亮**——
///
/// - `<mark>`（浏览器 / Yomitan 常见写法）与 `<span style="background-color: …">`；
/// - 同一个 span 里 `color` 与 `background-color` 两条声明并存；
/// - **注音** `<ruby>基字<rt>读音</rt></ruby>`（可带 `<rp>`、一个 ruby 里多组基字 / 读音、
///   基字里带加粗等行内格式）。读音只收纯文字，基字不跨行。
///
/// 这样「加了高亮的例句」仍走所见即所得编辑，而不是掉进「结构化 HTML，只能改源码」。
/// 子集之外照旧返回 null，由调用方按结构化内容处理（原 HTML 一字不动）。
///
/// 序列化与旧子集**逐字节一致**（只有加粗 / 斜体 / 下划线 / 颜色时输出不变）；有高亮时写成
/// `<span style="background-color: #rrggbb;">`（有颜色时与颜色合成一个 span）。
///
/// 纯函数，单测直接调。
library;

import 'package:flutter/foundation.dart';

import 'package:fushi/src/srs/srs_field_markup.dart'
    show
        SrsFieldKind,
        SrsFuriganaPair,
        SrsRichAttr,
        srsCssColor,
        srsFieldKindOf,
        srsFuriganaPairs,
        srsParseCssColor;
import 'package:fushi/src/srs/srs_fushi_card_fields.dart'
    show srsDecodeEntities;

/// 高亮默认色（`<mark>` 与工具栏「高亮」按钮）：浅黄。
const int kSrsHighlightDefault = 0xFFFFF59D;

/// 工具栏高亮色板（ARGB）。
const List<int> kSrsHighlightPalette = <int>[
  kSrsHighlightDefault,
  0xFFC8E6C9,
  0xFFBBDEFB,
  0xFFF8BBD0,
  0xFFFFE0B2,
];

/// 一组注音：同一组的字带同一个 [SrsRuby]（[id] 区分相邻两组读音相同的词）。
@immutable
class SrsRuby {
  const SrsRuby(this.id, this.reading);

  /// 文档内唯一的组号。
  final int id;

  /// 读音（纯文字）。
  final String reading;

  @override
  bool operator ==(Object other) =>
      other is SrsRuby && other.id == id && other.reading == reading;

  @override
  int get hashCode => Object.hash(id, reading);
}

/// 一个字符的行内格式（含高亮、注音）。
@immutable
class SrsRichFormat {
  const SrsRichFormat({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.color,
    this.highlight,
    this.ruby,
  });

  static const SrsRichFormat plain = SrsRichFormat();

  final bool bold;
  final bool italic;
  final bool underline;

  /// 文字颜色 ARGB；null = 默认。
  final int? color;

  /// 高亮（背景）ARGB；null = 无。
  final int? highlight;

  /// 所在的注音组；null = 不带注音。
  final SrsRuby? ruby;

  bool has(SrsRichAttr attr) => switch (attr) {
    SrsRichAttr.bold => bold,
    SrsRichAttr.italic => italic,
    SrsRichAttr.underline => underline,
  };

  SrsRichFormat withAttr(SrsRichAttr attr, bool on) => SrsRichFormat(
    bold: attr == SrsRichAttr.bold ? on : bold,
    italic: attr == SrsRichAttr.italic ? on : italic,
    underline: attr == SrsRichAttr.underline ? on : underline,
    color: color,
    highlight: highlight,
    ruby: ruby,
  );

  SrsRichFormat withColor(int? argb) => SrsRichFormat(
    bold: bold,
    italic: italic,
    underline: underline,
    color: argb,
    highlight: highlight,
    ruby: ruby,
  );

  SrsRichFormat withHighlight(int? argb) => SrsRichFormat(
    bold: bold,
    italic: italic,
    underline: underline,
    color: color,
    highlight: argb,
    ruby: ruby,
  );

  SrsRichFormat withRuby(SrsRuby? value) => SrsRichFormat(
    bold: bold,
    italic: italic,
    underline: underline,
    color: color,
    highlight: highlight,
    ruby: value,
  );

  @override
  bool operator ==(Object other) =>
      other is SrsRichFormat &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.color == color &&
      other.highlight == highlight &&
      other.ruby == ruby;

  @override
  int get hashCode =>
      Object.hash(bold, italic, underline, color, highlight, ruby);
}

/// 解析结果：纯文字 + 逐 UTF-16 码元的格式（长度相同）。
@immutable
class SrsRichFormatDoc {
  const SrsRichFormatDoc(this.text, this.formats);

  final String text;
  final List<SrsRichFormat> formats;
}

final RegExp _tagOrComment = RegExp(
  r'<!--[\s\S]*?-->|<(/?)([a-zA-Z][a-zA-Z0-9]*)\b([^>]*)>',
);
final RegExp _styleAttr = RegExp(
  r'''^\s*style\s*=\s*(["'])([^"']*)\1\s*$''',
  caseSensitive: false,
);
final RegExp _colorAttr = RegExp(
  r'''^\s*color\s*=\s*(["']?)([^"'\s>]+)\1\s*$''',
  caseSensitive: false,
);

/// span 的 style：只认 `color` / `background-color` / `background`（各至多一条、值必须是
/// 认得的颜色）。返回 (颜色, 高亮)；有任何别的声明返回 null。
(int?, int?)? _spanColors(String style) {
  int? color;
  int? background;
  final List<String> decls = style
      .split(';')
      .map((String d) => d.trim())
      .where((String d) => d.isNotEmpty)
      .toList();
  if (decls.isEmpty) return null;
  for (final String d in decls) {
    final int colon = d.indexOf(':');
    if (colon < 0) return null;
    final String prop = d.substring(0, colon).trim().toLowerCase();
    final int? value = srsParseCssColor(d.substring(colon + 1));
    if (value == null) return null;
    switch (prop) {
      case 'color' when color == null:
        color = value;
      case 'background-color' || 'background' when background == null:
        background = value;
      default:
        return null;
    }
  }
  return (color, background);
}

/// 解析扩展子集；子集之外（任何其它标签、属性、注释）返回 null。
SrsRichFormatDoc? srsParseRichFormatHtml(String html) {
  final StringBuffer text = StringBuffer();
  final List<SrsRichFormat> formats = <SrsRichFormat>[];
  final List<(String, SrsRichFormat)> stack = <(String, SrsRichFormat)>[];
  SrsRichFormat current = SrsRichFormat.plain;
  // 注音：在 <ruby> 里 / 当前组基字起点 / 正在收的读音（<rt> 里）/ 在 <rp> 里（括号，丢弃）。
  bool inRuby = false;
  int rubyStart = 0;
  StringBuffer? reading;
  bool inRp = false;
  int nextRubyId = 1;

  void emit(String raw) {
    if (raw.isEmpty || inRp) return;
    final String s = srsDecodeEntities(raw);
    if (reading != null) {
      reading.write(s);
      return;
    }
    text.write(s);
    formats.addAll(List<SrsRichFormat>.filled(s.length, current));
  }

  void newline() {
    text.write('\n');
    formats.add(current);
  }

  int last = 0;
  for (final RegExpMatch m in _tagOrComment.allMatches(html)) {
    emit(html.substring(last, m.start));
    last = m.end;
    final String? name = m.group(2)?.toLowerCase();
    if (name == null) return null;
    final bool closing = m.group(1)!.isNotEmpty;
    String attrs = m.group(3)!.trim();
    if (attrs.endsWith('/')) attrs = attrs.substring(0, attrs.length - 1);
    if (reading != null || inRp) {
      // <rt> / <rp> 里只收纯文字。
      if (!closing || attrs.isNotEmpty) return null;
      if (inRp) {
        if (name != 'rp') return null;
        inRp = false;
        continue;
      }
      if (name != 'rt') return null;
      final String r = reading.toString().trim();
      reading = null;
      if (r.isNotEmpty && text.length > rubyStart) {
        final SrsRuby ruby = SrsRuby(nextRubyId++, r);
        for (int i = rubyStart; i < text.length; i++) {
          formats[i] = formats[i].withRuby(ruby);
        }
      }
      rubyStart = text.length;
      continue;
    }
    if (closing) {
      if (attrs.isNotEmpty) return null;
      if (name == 'br') continue;
      final int at = stack.lastIndexWhere(
        ((String, SrsRichFormat) e) => e.$1 == name,
      );
      if (at < 0) {
        if (name == 'div' || name == 'p') continue;
        return null;
      }
      current = stack[at].$2;
      stack.removeRange(at, stack.length);
      inRuby = stack.any(((String, SrsRichFormat) e) => e.$1 == 'ruby');
      continue;
    }
    switch (name) {
      case 'br':
        if (attrs.isNotEmpty || inRuby) return null;
        newline();
      case 'ruby':
        if (attrs.isNotEmpty || inRuby) return null;
        stack.add((name, current));
        inRuby = true;
        rubyStart = text.length;
      case 'rt':
        if (attrs.isNotEmpty || !inRuby) return null;
        reading = StringBuffer();
      case 'rp':
        if (attrs.isNotEmpty || !inRuby) return null;
        inRp = true;
      case 'div' || 'p':
        if (attrs.isNotEmpty || inRuby) return null;
        if (text.isNotEmpty && !text.toString().endsWith('\n')) newline();
        stack.add((name, current));
      case 'b' || 'strong':
        if (attrs.isNotEmpty) return null;
        stack.add((name, current));
        current = current.withAttr(SrsRichAttr.bold, true);
      case 'i' || 'em':
        if (attrs.isNotEmpty) return null;
        stack.add((name, current));
        current = current.withAttr(SrsRichAttr.italic, true);
      case 'u':
        if (attrs.isNotEmpty) return null;
        stack.add((name, current));
        current = current.withAttr(SrsRichAttr.underline, true);
      case 'mark':
        if (attrs.isNotEmpty) return null;
        stack.add((name, current));
        current = current.withHighlight(kSrsHighlightDefault);
      case 'span':
        (int?, int?)? colors;
        if (attrs.isNotEmpty) {
          final RegExpMatch? style = _styleAttr.firstMatch(attrs);
          if (style == null) return null;
          colors = _spanColors(style.group(2)!);
          if (colors == null) return null;
        }
        stack.add((name, current));
        if (colors?.$1 != null) current = current.withColor(colors!.$1);
        if (colors?.$2 != null) current = current.withHighlight(colors!.$2);
      case 'font':
        final RegExpMatch? c = _colorAttr.firstMatch(attrs);
        final int? color = c == null ? null : srsParseCssColor(c.group(2)!);
        if (color == null) return null;
        stack.add((name, current));
        current = current.withColor(color);
      default:
        return null;
    }
  }
  emit(html.substring(last));
  if (reading != null || inRp) return null;
  return SrsRichFormatDoc(text.toString(), formats);
}

String _escapeText(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll(' ', '&nbsp;');

/// 富文本 → HTML（Anki 写法）。只有加粗 / 斜体 / 下划线 / 颜色时与旧序列化逐字节一致；
/// 一组注音写成 `<ruby>基字<rt>读音</rt></ruby>`（基字里的行内格式写在 ruby 里面）。
String srsRichFormatToHtml(String text, List<SrsRichFormat> formats) {
  assert(text.length == formats.length);
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < text.length) {
    final SrsRuby? ruby = formats[i].ruby;
    int j = i;
    if (ruby == null) {
      while (j < text.length && formats[j] == formats[i]) {
        j++;
      }
      _writeRun(out, text.substring(i, j), formats[i]);
    } else {
      while (j < text.length && formats[j].ruby == ruby) {
        j++;
      }
      out.write('<ruby>');
      int k = i;
      while (k < j) {
        final SrsRichFormat s = formats[k].withRuby(null);
        int e = k;
        while (e < j && formats[e].withRuby(null) == s) {
          e++;
        }
        _writeRun(out, text.substring(k, e), s);
        k = e;
      }
      out.write('<rt>${_escapeText(ruby.reading)}</rt></ruby>');
    }
    i = j;
  }
  return out.toString();
}

void _writeRun(StringBuffer out, String text, SrsRichFormat s) {
  final String run = text.split('\n').map(_escapeText).join('<br>');
  final List<String> decls = <String>[
    if (s.color != null) 'color: ${srsCssColor(s.color!)};',
    if (s.highlight != null) 'background-color: ${srsCssColor(s.highlight!)};',
  ];
  final List<(String, String)> tags = <(String, String)>[
    if (s.bold) ('b', ''),
    if (s.italic) ('i', ''),
    if (s.underline) ('u', ''),
    if (decls.isNotEmpty) ('span', ' style="${decls.join(' ')}"'),
  ];
  for (final (String tag, String attrs) in tags) {
    out.write('<$tag$attrs>');
  }
  out.write(run);
  for (final (String tag, String _) in tags.reversed) {
    out.write('</$tag>');
  }
}

bool srsSameFormats(List<SrsRichFormat> a, List<SrsRichFormat> b) =>
    listEquals(a, b);

final RegExp _imgOrSound = RegExp(r'<img\b|\[sound:', caseSensitive: false);
final RegExp _kanaOnly = RegExp(r'^[ぁ-ゟ゠-ヿー・]+$');

/// 编辑器用的字段类型：在 [srsFieldKindOf] 之上，把落在扩展子集（带高亮）里的内容
/// 也交给所见即所得（振假名照旧判给振假名编辑器）。
SrsFieldKind srsEditorFieldKindOf(
  String name,
  String value, {
  bool toggle = false,
}) {
  final SrsFieldKind kind = srsFieldKindOf(name, value, toggle: toggle);
  if (kind != SrsFieldKind.structured) return kind;
  final String v = value.trim();
  if (_imgOrSound.hasMatch(v) || srsParseRichFormatHtml(v) == null) {
    return kind;
  }
  final bool furigana =
      name.toLowerCase().contains('furigana') ||
      srsFuriganaPairs(
        v,
      ).any((SrsFuriganaPair p) => _kanaOnly.hasMatch(p.reading));
  return furigana ? SrsFieldKind.furigana : SrsFieldKind.rich;
}
