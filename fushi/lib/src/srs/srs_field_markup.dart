/// 笔记编辑页的字段标记：按内容判字段类型，以及可视化编辑用到的纯函数——
///
/// - 行内富文本的「白名单子集」解析与序列化（b / strong / i / em / u / br / div / p，
///   以及只带文字颜色的 span / font）。子集之外的 HTML（Yomitan 结构化释义的
///   class / data-* / 表格 / 列表……）一律判成 [SrsFieldKind.structured]，只做渲染预览 +
///   改源码，**不经序列化**，保证原 HTML 一字不动；
/// - 图片（`<img src>`）、声音（`[sound:x]`）、Anki 振假名（`漢字[かな]`）的定位与替换。
///
/// 纯函数，不依赖 Flutter widget，单测直接调。
library;

import 'package:flutter/foundation.dart';

import 'package:fushi/src/srs/srs_fushi_card_fields.dart'
    show srsDecodeEntities;

/// 字段在编辑页里用哪种编辑器。
enum SrsFieldKind {
  /// 行内富文本：所见即所得（加粗 / 斜体 / 下划线 / 颜色）+ HTML 源码切换。
  rich,

  /// 结构化 HTML（子集之外）：渲染预览 + 改源码。
  structured,

  /// Anki 振假名 `漢字[かな]`：上方注音显示，点词改读音。
  furigana,

  /// 只有图片的字段：缩略图 + 选择 / 替换 / 粘贴 / 删除。
  image,

  /// 只有 `[sound:]` 的字段：播放 + 选择文件 / 录音 / 删除。
  audio,

  /// 卡型开关（非空 = 开）。
  toggle,
}

final RegExp _imgTag = RegExp(r'<img\b[^>]*>', caseSensitive: false);
final RegExp _imgSrc = RegExp(
  r'''\ssrc\s*=\s*(["'])([^"']*)\1''',
  caseSensitive: false,
);
final RegExp _soundTag = RegExp(r'\[sound:([^\]]+)\]');
final RegExp _filler = RegExp(r'<br\s*/?>|&nbsp;|\s', caseSensitive: false);

/// Anki 振假名：可选的前导空格（分词）+ 基字 + `[读音]`。基字不跨标签。
final RegExp _furiganaPair = RegExp(r' ?([^ >\[\]\n<]+?)\[([^\]\[]+?)\]');
final RegExp _kanaOnly = RegExp(r'^[ぁ-ゟ゠-ヿー・]+$');

bool _onlyImages(String v) =>
    v.replaceAll(_imgTag, '').replaceAll(_filler, '').isEmpty;

bool _onlySounds(String v) =>
    v.replaceAll(_soundTag, '').replaceAll(_filler, '').isEmpty;

bool _nameHas(String name, List<String> words) {
  final String n = name.toLowerCase();
  return words.any(n.contains);
}

/// 按字段名与当前值判编辑器类型。[toggle] = 调用方已知这是卡型开关字段。
SrsFieldKind srsFieldKindOf(String name, String value, {bool toggle = false}) {
  final String v = value.trim();
  final bool hasImg = _imgTag.hasMatch(v);
  final bool hasSound = _soundTag.hasMatch(v);
  if (toggle && !hasImg && !hasSound && !v.contains('<')) {
    return SrsFieldKind.toggle;
  }
  if (hasImg && _onlyImages(v)) return SrsFieldKind.image;
  if (hasSound && _onlySounds(v)) return SrsFieldKind.audio;
  if (v.isEmpty) {
    if (_nameHas(name, const <String>['picture', 'image', 'photo', 'media'])) {
      return SrsFieldKind.image;
    }
    if (_nameHas(name, const <String>['audio', 'sound'])) {
      return SrsFieldKind.audio;
    }
  }
  if (srsParseRichHtml(v) == null) return SrsFieldKind.structured;
  if (hasImg || hasSound) return SrsFieldKind.structured;
  if (_nameHas(name, const <String>['furigana']) || _looksLikeFurigana(v)) {
    return SrsFieldKind.furigana;
  }
  return SrsFieldKind.rich;
}

/// 内容里有 `漢字[かな]`（读音全是假名）。
bool _looksLikeFurigana(String v) => srsFuriganaPairs(
  v,
).any((SrsFuriganaPair p) => _kanaOnly.hasMatch(p.reading));

// ---------------------------------------------------------------- 富文本子集

/// 一个字符的行内样式。
@immutable
class SrsRichStyle {
  const SrsRichStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.color,
  });

  static const SrsRichStyle plain = SrsRichStyle();

  final bool bold;
  final bool italic;
  final bool underline;

  /// ARGB；null = 默认颜色。
  final int? color;

  bool has(SrsRichAttr attr) => switch (attr) {
    SrsRichAttr.bold => bold,
    SrsRichAttr.italic => italic,
    SrsRichAttr.underline => underline,
  };

  SrsRichStyle withAttr(SrsRichAttr attr, bool on) => SrsRichStyle(
    bold: attr == SrsRichAttr.bold ? on : bold,
    italic: attr == SrsRichAttr.italic ? on : italic,
    underline: attr == SrsRichAttr.underline ? on : underline,
    color: color,
  );

  SrsRichStyle withColor(int? argb) => SrsRichStyle(
    bold: bold,
    italic: italic,
    underline: underline,
    color: argb,
  );

  @override
  bool operator ==(Object other) =>
      other is SrsRichStyle &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.color == color;

  @override
  int get hashCode => Object.hash(bold, italic, underline, color);
}

/// 可开关的行内格式。
enum SrsRichAttr { bold, italic, underline }

/// 解析后的富文本：纯文字 + 逐 UTF-16 码元的样式（长度相同）。
@immutable
class SrsRichDoc {
  const SrsRichDoc(this.text, this.styles);

  final String text;
  final List<SrsRichStyle> styles;
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

/// CSS 颜色（`#rgb` / `#rrggbb` / `rgb(r, g, b)`）→ ARGB；认不出返回 null。
int? srsParseCssColor(String raw) {
  final String s = raw.trim().toLowerCase();
  final RegExpMatch? hex = RegExp(
    r'^#([0-9a-f]{3}|[0-9a-f]{6})$',
  ).firstMatch(s);
  if (hex != null) {
    String h = hex.group(1)!;
    if (h.length == 3) h = h.split('').map((String c) => '$c$c').join();
    return 0xFF000000 | int.parse(h, radix: 16);
  }
  final RegExpMatch? rgb = RegExp(
    r'^rgb\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*\)$',
  ).firstMatch(s);
  if (rgb != null) {
    final List<int> c = <int>[
      for (int i = 1; i <= 3; i++) int.parse(rgb.group(i)!),
    ];
    if (c.any((int v) => v > 255)) return null;
    return 0xFF000000 | (c[0] << 16) | (c[1] << 8) | c[2];
  }
  return null;
}

/// ARGB → `#rrggbb`。
String srsCssColor(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// 只认 `color: X` 一条声明的 style 值；返回颜色，否则 null。
int? _colorOfStyle(String style) {
  final List<String> decls = style
      .split(';')
      .map((String d) => d.trim())
      .where((String d) => d.isNotEmpty)
      .toList();
  if (decls.length != 1) return null;
  final int colon = decls.single.indexOf(':');
  if (colon < 0) return null;
  if (decls.single.substring(0, colon).trim().toLowerCase() != 'color') {
    return null;
  }
  return srsParseCssColor(decls.single.substring(colon + 1));
}

/// 解析行内富文本子集；子集之外（任何其它标签、属性、注释）返回 null。
SrsRichDoc? srsParseRichHtml(String html) {
  final StringBuffer text = StringBuffer();
  final List<SrsRichStyle> styles = <SrsRichStyle>[];
  // 打开中的标签：名字 + 进入它之前的样式。
  final List<(String, SrsRichStyle)> stack = <(String, SrsRichStyle)>[];
  SrsRichStyle current = SrsRichStyle.plain;

  void emit(String raw) {
    if (raw.isEmpty) return;
    final String s = srsDecodeEntities(raw);
    text.write(s);
    styles.addAll(List<SrsRichStyle>.filled(s.length, current));
  }

  void newline() {
    text.write('\n');
    styles.add(current);
  }

  int last = 0;
  for (final RegExpMatch m in _tagOrComment.allMatches(html)) {
    emit(html.substring(last, m.start));
    last = m.end;
    final String? name = m.group(2)?.toLowerCase();
    if (name == null) return null; // 注释
    final bool closing = m.group(1)!.isNotEmpty;
    String attrs = m.group(3)!.trim();
    if (attrs.endsWith('/')) attrs = attrs.substring(0, attrs.length - 1);
    if (closing) {
      if (attrs.isNotEmpty) return null;
      if (name == 'br') continue;
      final int at = stack.lastIndexWhere(
        ((String, SrsRichStyle) e) => e.$1 == name,
      );
      if (at < 0) {
        if (name == 'div' || name == 'p') continue;
        return null;
      }
      current = stack[at].$2;
      stack.removeRange(at, stack.length);
      continue;
    }
    switch (name) {
      case 'br':
        if (attrs.isNotEmpty) return null;
        newline();
      case 'div' || 'p':
        if (attrs.isNotEmpty) return null;
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
      case 'span':
        int? color;
        if (attrs.isNotEmpty) {
          final RegExpMatch? style = _styleAttr.firstMatch(attrs);
          if (style == null) return null;
          color = _colorOfStyle(style.group(2)!);
          if (color == null) return null;
        }
        stack.add((name, current));
        if (color != null) current = current.withColor(color);
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
  return SrsRichDoc(text.toString(), styles);
}

String _escapeText(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll(' ', '&nbsp;');

String _escapeAttr(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// 富文本 → HTML（Anki 的写法：`<b>` / `<i>` / `<u>` / `<span style="color: …">` / `<br>`）。
String srsRichToHtml(String text, List<SrsRichStyle> styles) {
  assert(text.length == styles.length);
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < text.length) {
    final SrsRichStyle s = styles[i];
    int j = i;
    while (j < text.length && styles[j] == s) {
      j++;
    }
    final String run = text
        .substring(i, j)
        .split('\n')
        .map(_escapeText)
        .join('<br>');
    final List<(String, String)> tags = <(String, String)>[
      if (s.bold) ('b', ''),
      if (s.italic) ('i', ''),
      if (s.underline) ('u', ''),
      if (s.color != null)
        ('span', ' style="color: ${srsCssColor(s.color!)};"'),
    ];
    for (final (String tag, String attrs) in tags) {
      out.write('<$tag$attrs>');
    }
    out.write(run);
    for (final (String tag, String _) in tags.reversed) {
      out.write('</$tag>');
    }
    i = j;
  }
  return out.toString();
}

// ---------------------------------------------------------------- 图片

/// 字段里第 [index] 个 `<img>` 换成 [name] 的图片；[name] 为 null = 删除这张。
String srsReplaceImage(String html, int index, String? name) {
  int k = 0;
  return html.replaceAllMapped(_imgTag, (Match m) {
    if (k++ != index) return m.group(0)!;
    if (name == null) return '';
    final String tag = m.group(0)!;
    // 只换 src，其余属性（width / class…）原样保留。
    if (_imgSrc.hasMatch(tag)) {
      return tag.replaceFirstMapped(
        _imgSrc,
        (Match s) => ' src="${_escapeAttr(name)}"',
      );
    }
    return srsImageTag(name);
  });
}

/// 一张媒体库图片的 `<img>`。
String srsImageTag(String name) => '<img src="${_escapeAttr(name)}">';

/// 字段末尾追加一张图片。
String srsAppendImage(String html, String name) =>
    '${html.trimRight()}${srsImageTag(name)}';

// ---------------------------------------------------------------- 声音

/// `[sound:x]`。
String srsSoundTag(String name) => '[sound:$name]';

/// 字段里第 [index] 个 `[sound:]` 换成 [name]；null = 删除。
String srsReplaceSound(String field, int index, String? name) {
  int k = 0;
  return field.replaceAllMapped(_soundTag, (Match m) {
    if (k++ != index) return m.group(0)!;
    return name == null ? '' : srsSoundTag(name);
  });
}

/// 字段末尾追加一段声音。
String srsAppendSound(String field, String name) =>
    '${field.trimRight()}${srsSoundTag(name)}';

// ---------------------------------------------------------------- 振假名

/// 原文里的一组 `基字[读音]`（位置是原串下标）。
@immutable
class SrsFuriganaPair {
  const SrsFuriganaPair(this.start, this.end, this.base, this.reading);

  final int start;
  final int end;
  final String base;
  final String reading;
}

/// 原文里全部 `基字[读音]`（跳过 `[sound:]`）。
List<SrsFuriganaPair> srsFuriganaPairs(String raw) => <SrsFuriganaPair>[
  for (final RegExpMatch m in _furiganaPair.allMatches(raw))
    if (!m.group(2)!.startsWith('sound:'))
      SrsFuriganaPair(m.start, m.end, m.group(1)!, m.group(2)!),
];

/// 改第 [index] 组的读音；[reading] 为空 = 去掉注音（连分词空格一起，只留基字）。
String srsSetFuriganaReading(String raw, int index, String reading) {
  final List<SrsFuriganaPair> pairs = srsFuriganaPairs(raw);
  if (index < 0 || index >= pairs.length) return raw;
  final SrsFuriganaPair p = pairs[index];
  final String r = reading.replaceAll(RegExp(r'[\[\]\n]'), '').trim();
  final bool spaced = raw.startsWith(' ', p.start);
  final String replacement = r.isEmpty
      ? p.base
      : '${spaced ? ' ' : ''}${p.base}[$r]';
  return raw.replaceRange(p.start, p.end, replacement);
}

/// 两份列表逐项相等（富文本的「未改动」判据用）。
bool srsSameStyles(List<SrsRichStyle> a, List<SrsRichStyle> b) =>
    listEquals(a, b);
