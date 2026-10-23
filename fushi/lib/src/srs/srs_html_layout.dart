/// 结构化字段（Yomitan 释义等子集之外的 HTML）的「在排版里改字」：把 HTML 排成一棵块 / 段落
/// 的版面树，编辑器按它原生画出排版（列表符号、缩进、表格行、加粗 / 斜体 / 颜色……），每个
/// 段落是一个输入框，用户直接在排版里改字。
///
/// - 文字仍按 srs_html_text_parts.dart 拆段：段落里的每段可见文字对应一段 [SrsHtmlTextParts]，
///   改字只换那段文字，**标签、class、data-*、内联样式一字不动**；
/// - 段与段之间的空白、`<br>`、图片在段落里显示成不可改的分隔（[SrsLayoutSeg.part] 为 null）；
/// - 外观只认标签语义与内联 `style`（Yomitan 导出到 Anki 的结构化内容用的就是内联样式），
///   笔记类型 CSS 里按 class 写的样式这里不套——要看卡面精确效果，退出编辑看卡片预览。
///
/// 纯函数，单测直接调。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:fushi/src/srs/srs_field_markup.dart' show srsParseCssColor;
import 'package:fushi/src/srs/srs_fushi_card_fields.dart'
    show srsDecodeEntities;
import 'package:fushi/src/srs/srs_html_text_parts.dart';

/// 一段文字的外观（按祖先标签 / 内联样式累积）。
@immutable
class SrsHtmlLook {
  const SrsHtmlLook({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.scale = 1,
    this.color,
    this.background,
    this.monospace = false,
    this.link = false,
  });

  static const SrsHtmlLook plain = SrsHtmlLook();

  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;

  /// 相对正文的字号倍数。
  final double scale;

  /// 文字颜色 ARGB；null = 默认。
  final int? color;

  /// 背景色 ARGB；null = 无。
  final int? background;
  final bool monospace;

  /// 在 `<a>` 里（编辑器按主题色画）。
  final bool link;

  SrsHtmlLook copyWith({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strike,
    double? scale,
    int? color,
    int? background,
    bool? monospace,
    bool? link,
  }) => SrsHtmlLook(
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    strike: strike ?? this.strike,
    scale: scale ?? this.scale,
    color: color ?? this.color,
    background: background ?? this.background,
    monospace: monospace ?? this.monospace,
    link: link ?? this.link,
  );

  @override
  bool operator ==(Object other) =>
      other is SrsHtmlLook &&
      other.bold == bold &&
      other.italic == italic &&
      other.underline == underline &&
      other.strike == strike &&
      other.scale == scale &&
      other.color == color &&
      other.background == background &&
      other.monospace == monospace &&
      other.link == link;

  @override
  int get hashCode => Object.hash(
    bold,
    italic,
    underline,
    strike,
    scale,
    color,
    background,
    monospace,
    link,
  );
}

/// 版面里的一个盒子：块或段落。
sealed class SrsLayoutBox {
  const SrsLayoutBox();
}

/// 块的种类（决定编辑器怎么摆子盒子）。
enum SrsLayoutBlockKind {
  /// 普通块：子盒子竖排。
  block,

  /// 列表项：左边列表符号（[SrsLayoutBlock.marker]），右边内容。
  listItem,

  /// 表格行：单元格横排。
  tableRow,

  /// 单元格。
  tableCell,

  /// 分隔线 `<hr>`。
  rule,
}

/// 一个块。
@immutable
class SrsLayoutBlock extends SrsLayoutBox {
  const SrsLayoutBlock({
    required this.kind,
    required this.children,
    this.tag = '',
    this.marker,
    this.indent = 0,
  });

  final SrsLayoutBlockKind kind;

  /// 来源标签名（小写；根块为空）。
  final String tag;
  final List<SrsLayoutBox> children;

  /// 列表项的符号（`•` / `3.` / 自定义串）；空串 = 不画符号。
  final String? marker;

  /// 左缩进（em，来自 `margin-left` / `padding-left`）。
  final double indent;
}

/// 段落里的一节：一段可改的文字（[part] 非 null）或不可改的分隔（空白 / 换行 / 图片）。
@immutable
class SrsLayoutSeg {
  const SrsLayoutSeg({this.part, required this.text, required this.look});

  /// 对应 [SrsHtmlTextParts] 的段号；null = 分隔。
  final int? part;

  /// 初始文字（分隔的显示文字）。
  final String text;
  final SrsHtmlLook look;
}

/// 一个段落：一串行内内容，编辑器里是一个输入框。
@immutable
class SrsLayoutParagraph extends SrsLayoutBox {
  const SrsLayoutParagraph(this.segs);

  final List<SrsLayoutSeg> segs;
}

/// 图片在段落里的占位字。
const String kSrsLayoutImageGlyph = '\u{1F5BC}';

const Set<String> _voidTags = <String>{
  'br',
  'img',
  'hr',
  'wbr',
  'input',
  'meta',
  'link',
  'source',
  'area',
  'col',
  'embed',
  'param',
  'track',
  'base',
};

const Set<String> _blockTags = <String>{
  'div',
  'p',
  'ul',
  'ol',
  'li',
  'table',
  'thead',
  'tbody',
  'tfoot',
  'tr',
  'td',
  'th',
  'caption',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'blockquote',
  'details',
  'summary',
  'section',
  'article',
  'header',
  'footer',
  'nav',
  'aside',
  'main',
  'dl',
  'dt',
  'dd',
  'hr',
  'pre',
  'figure',
  'figcaption',
  'center',
};

const Set<String> _rawTags = <String>{'style', 'script'};

final RegExp _tag = RegExp(
  r'<!--[\s\S]*?-->|<(/?)([a-zA-Z][a-zA-Z0-9-]*)\b([^>]*)>',
);
final RegExp _attr = RegExp(
  r'''([^\s=/"']+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?''',
);

// ------------------------------------------------------------ DOM

sealed class _Node {}

final class _Element extends _Node {
  _Element(this.tag, this.attrs);

  final String tag;
  final Map<String, String> attrs;
  final List<_Node> children = <_Node>[];

  late final Map<String, String> style = _parseStyle(attrs['style'] ?? '');
}

final class _Text extends _Node {
  _Text(this.part);

  final int part;
}

final class _Space extends _Node {}

Map<String, String> _parseStyle(String style) {
  final Map<String, String> out = <String, String>{};
  for (final String decl in style.split(';')) {
    final int colon = decl.indexOf(':');
    if (colon <= 0) continue;
    out[decl.substring(0, colon).trim().toLowerCase()] = decl
        .substring(colon + 1)
        .trim();
  }
  return out;
}

Map<String, String> _parseAttrs(String raw) => <String, String>{
  for (final RegExpMatch m in _attr.allMatches(raw))
    m.group(1)!.toLowerCase(): srsDecodeEntities(
      m.group(2) ?? m.group(3) ?? m.group(4) ?? '',
    ),
};

_Element _buildTree(SrsHtmlTextParts parts) {
  final _Element root = _Element('', const <String, String>{});
  final List<_Element> stack = <_Element>[root];

  void open(String tag, String rawAttrs, bool selfClosing) {
    // 隐式闭合：新的 li / p / tr / td 前面同名（或同组）的还开着就先关掉。
    bool closes(String top) => switch (tag) {
      'li' => top == 'li',
      'p' => top == 'p',
      'td' || 'th' => top == 'td' || top == 'th',
      'dt' || 'dd' => top == 'dt' || top == 'dd',
      'tr' => top == 'tr' || top == 'td' || top == 'th',
      _ => false,
    };
    while (stack.length > 1 && closes(stack.last.tag)) {
      stack.removeLast();
    }
    final _Element el = _Element(tag, _parseAttrs(rawAttrs));
    stack.last.children.add(el);
    if (!selfClosing && !_voidTags.contains(tag)) stack.add(el);
  }

  void close(String tag) {
    for (int i = stack.length - 1; i > 0; i--) {
      if (stack[i].tag == tag) {
        stack.removeRange(i, stack.length);
        return;
      }
    }
  }

  void skeleton(String s) {
    int last = 0;
    bool hadSpace = false;
    void gap(String between) {
      if (between.isNotEmpty && between.trim().isEmpty) hadSpace = true;
    }

    int at = 0;
    while (at < s.length) {
      final RegExpMatch? m = _tag.allMatches(s, at).firstOrNull;
      if (m == null) break;
      gap(s.substring(last, m.start));
      if (hadSpace) {
        stack.last.children.add(_Space());
        hadSpace = false;
      }
      last = m.end;
      at = m.end;
      final String? name = m.group(2)?.toLowerCase();
      if (name == null) continue;
      if (m.group(1)!.isNotEmpty) {
        close(name);
        continue;
      }
      String attrs = m.group(3)!;
      final bool selfClosing = attrs.trimRight().endsWith('/');
      if (selfClosing) attrs = attrs.substring(0, attrs.lastIndexOf('/'));
      if (_rawTags.contains(name)) {
        // style / script 的内容不进版面（里面的 `<` 也不当标签）。
        final int end = s.toLowerCase().indexOf('</$name', m.end);
        if (end < 0) {
          last = at = s.length;
        } else {
          final int gt = s.indexOf('>', end);
          last = at = gt < 0 ? s.length : gt + 1;
        }
        continue;
      }
      open(name, attrs, selfClosing);
    }
    gap(s.substring(last));
    if (hadSpace) stack.last.children.add(_Space());
  }

  for (int i = 0; i < parts.length; i++) {
    skeleton(parts.skeleton[i]);
    stack.last.children.add(_Text(i));
  }
  skeleton(parts.skeleton.last);
  return root;
}

// ------------------------------------------------------------ 外观

double? _em(String? v) {
  if (v == null) return null;
  final RegExpMatch? m = RegExp(
    r'^(-?[0-9]*\.?[0-9]+)\s*(em|rem|px|%)?$',
  ).firstMatch(v.trim().toLowerCase());
  if (m == null) return null;
  final double n = double.parse(m.group(1)!);
  return switch (m.group(2)) {
    'px' => n / 16,
    '%' => n / 100,
    _ => n,
  };
}

const Map<String, double> _headingScale = <String, double>{
  'h1': 2,
  'h2': 1.5,
  'h3': 1.17,
  'h4': 1,
  'h5': 0.83,
  'h6': 0.67,
};

SrsHtmlLook _lookOf(_Element el, SrsHtmlLook parent) {
  SrsHtmlLook look = parent;
  switch (el.tag) {
    case 'b' || 'strong' || 'th' || 'dt' || 'summary':
      look = look.copyWith(bold: true);
    case 'i' || 'em' || 'cite' || 'var' || 'dfn':
      look = look.copyWith(italic: true);
    case 'u' || 'ins':
      look = look.copyWith(underline: true);
    case 's' || 'del' || 'strike':
      look = look.copyWith(strike: true);
    case 'small' || 'sup' || 'sub':
      look = look.copyWith(scale: look.scale * 0.8);
    case 'rt':
      look = look.copyWith(scale: look.scale * 0.6);
    case 'code' || 'kbd' || 'samp' || 'pre':
      look = look.copyWith(monospace: true);
    case 'a':
      look = look.copyWith(link: true);
    case 'mark':
      look = look.copyWith(background: 0xFFFFF59D);
    case final String h when _headingScale.containsKey(h):
      look = look.copyWith(bold: true, scale: look.scale * _headingScale[h]!);
  }
  final Map<String, String> style = el.style;
  final String? weight = style['font-weight']?.toLowerCase();
  if (weight != null) {
    final int? n = int.tryParse(weight);
    look = look.copyWith(
      bold: weight == 'bold' || weight == 'bolder' || (n != null && n >= 600),
    );
  }
  final String? fontStyle = style['font-style']?.toLowerCase();
  if (fontStyle != null) {
    look = look.copyWith(italic: fontStyle != 'normal');
  }
  final String? deco =
      (style['text-decoration-line'] ?? style['text-decoration'])
          ?.toLowerCase();
  if (deco != null) {
    look = look.copyWith(
      underline: deco.contains('underline'),
      strike: deco.contains('line-through'),
    );
  }
  final double? size = _em(style['font-size']);
  if (size != null && size > 0) {
    // px 是绝对值（按 16px 正文折算），em / % 相对父级。
    final bool absolute = style['font-size']!.trim().endsWith('px');
    look = look.copyWith(scale: absolute ? size : look.scale * size);
  }
  final int? color = style['color'] == null
      ? null
      : srsParseCssColor(style['color']!);
  if (color != null) look = look.copyWith(color: color);
  final String? bg = style['background-color'] ?? style['background'];
  final int? background = bg == null ? null : srsParseCssColor(bg);
  if (background != null) look = look.copyWith(background: background);
  return look;
}

bool _hidden(_Element el) =>
    el.style['display']?.toLowerCase() == 'none' ||
    el.attrs.containsKey('hidden');

bool _isBlock(_Element el) {
  final String? display = el.style['display']?.toLowerCase();
  if (display != null) {
    if (display.startsWith('inline')) return false;
    if (display == 'block' ||
        display == 'list-item' ||
        display == 'flex' ||
        display == 'grid' ||
        display.startsWith('table')) {
      return true;
    }
  }
  return _blockTags.contains(el.tag);
}

/// 子树里有没有块（行内元素里套了 div 时，整个按块排）。
bool _containsBlock(_Element el) => el.children.any(
  (_Node n) => n is _Element && (_isBlock(n) || _containsBlock(n)),
);

String _marker(_Element li, _Element? list, int ordinal) {
  final String type =
      (li.style['list-style-type'] ?? list?.style['list-style-type'] ?? '')
          .trim();
  if (type.length >= 2 &&
      (type.startsWith('"') || type.startsWith("'")) &&
      type.endsWith(type[0])) {
    return type.substring(1, type.length - 1);
  }
  switch (type.toLowerCase()) {
    case 'none':
      return '';
    case 'circle':
      return '◦';
    case 'square':
      return '▪';
    case 'disc':
      return '•';
    case 'decimal':
      return '$ordinal.';
  }
  return list?.tag == 'ol' ? '$ordinal.' : '•';
}

// ------------------------------------------------------------ 排版

class _Builder {
  _Builder(this.parts);

  final SrsHtmlTextParts parts;

  List<SrsLayoutBox> children(_Element el, SrsHtmlLook look) {
    final List<SrsLayoutBox> out = <SrsLayoutBox>[];
    final List<SrsLayoutSeg> run = <SrsLayoutSeg>[];
    void flush() {
      final SrsLayoutParagraph? p = _paragraph(run);
      if (p != null) out.add(p);
      run.clear();
    }

    int ordinal = int.tryParse(el.attrs['start'] ?? '') ?? 1;
    for (final _Node n in el.children) {
      if (n is _Element) {
        if (_hidden(n)) continue;
        if (_isBlock(n) || _containsBlock(n)) {
          flush();
          out.add(block(n, look, parent: el, ordinal: ordinal));
          if (n.tag == 'li') ordinal++;
          continue;
        }
      }
      inline(n, look, run);
    }
    flush();
    return out;
  }

  void inline(_Node n, SrsHtmlLook look, List<SrsLayoutSeg> run) {
    switch (n) {
      case _Text(:final int part):
        run.add(SrsLayoutSeg(part: part, text: parts.texts[part], look: look));
      case _Space():
        run.add(SrsLayoutSeg(text: ' ', look: look));
      case _Element(tag: 'br'):
        run.add(SrsLayoutSeg(text: '\n', look: look));
      case _Element(tag: 'img'):
        run.add(SrsLayoutSeg(text: kSrsLayoutImageGlyph, look: look));
      case final _Element el:
        if (_hidden(el)) return;
        final SrsHtmlLook inner = _lookOf(el, look);
        for (final _Node c in el.children) {
          inline(c, inner, run);
        }
    }
  }

  SrsLayoutBlock block(
    _Element el,
    SrsHtmlLook look, {
    _Element? parent,
    int ordinal = 1,
  }) {
    final SrsHtmlLook inner = _lookOf(el, look);
    final double indent =
        (_em(el.style['margin-left']) ?? 0) +
        (_em(el.style['padding-left']) ?? 0);
    final SrsLayoutBlockKind kind = switch (el.tag) {
      'hr' => SrsLayoutBlockKind.rule,
      'tr' => SrsLayoutBlockKind.tableRow,
      'td' || 'th' => SrsLayoutBlockKind.tableCell,
      'li' => SrsLayoutBlockKind.listItem,
      _ when el.style['display']?.toLowerCase() == 'list-item' =>
        SrsLayoutBlockKind.listItem,
      _ => SrsLayoutBlockKind.block,
    };
    return SrsLayoutBlock(
      kind: kind,
      tag: el.tag,
      indent: indent < 0 ? 0 : indent,
      marker: kind == SrsLayoutBlockKind.listItem
          ? _marker(
              el,
              parent != null && (parent.tag == 'ul' || parent.tag == 'ol')
                  ? parent
                  : null,
              ordinal,
            )
          : null,
      children: kind == SrsLayoutBlockKind.rule
          ? const <SrsLayoutBox>[]
          : children(el, inner),
    );
  }
}

/// 收拾一串行内节：合并连续空白、去掉段首段尾空白；没有可改文字的段落丢掉。
SrsLayoutParagraph? _paragraph(List<SrsLayoutSeg> run) {
  final List<SrsLayoutSeg> segs = <SrsLayoutSeg>[];
  for (final SrsLayoutSeg s in run) {
    final bool space = s.part == null && s.text == ' ';
    if (space &&
        (segs.isEmpty ||
            (segs.last.part == null &&
                (segs.last.text == ' ' || segs.last.text == '\n')))) {
      continue;
    }
    if (s.part == null && s.text == '\n' && segs.isNotEmpty) {
      if (segs.last.part == null && segs.last.text == ' ') segs.removeLast();
    }
    segs.add(s);
  }
  while (segs.isNotEmpty && segs.last.part == null && segs.last.text == ' ') {
    segs.removeLast();
  }
  if (!segs.any((SrsLayoutSeg s) => s.part != null)) return null;
  return SrsLayoutParagraph(List<SrsLayoutSeg>.unmodifiable(segs));
}

/// 排 [parts] 拆好的 HTML 的版面（根块）。
SrsLayoutBlock srsLayoutHtml(SrsHtmlTextParts parts) {
  final _Builder b = _Builder(parts);
  final _Element root = _buildTree(parts);
  return SrsLayoutBlock(
    kind: SrsLayoutBlockKind.block,
    children: b.children(root, SrsHtmlLook.plain),
  );
}

/// 版面里全部段落（先序）。
List<SrsLayoutParagraph> srsLayoutParagraphs(SrsLayoutBox box) => switch (box) {
  SrsLayoutParagraph() => <SrsLayoutParagraph>[box],
  SrsLayoutBlock(:final List<SrsLayoutBox> children) => <SrsLayoutParagraph>[
    for (final SrsLayoutBox c in children) ...srsLayoutParagraphs(c),
  ],
};

/// 段落的分段编辑：把一次文本框改动（整段文字从 [segs] 拼起来的旧值 → [next]）落回各节。
///
/// 改动按公共前后缀定位成「旧文字 [start, end) 换成 inserted」（[caret] 约束插入落点），
/// 被删掉的范围里只删可改文字、分隔原样保留；插入的字归进改动起点所在的可改节（落在分隔上
/// 时归后面最近的一节，后面没有就归前面）。返回各节的新文字与新光标位置；没有可改的节返回
/// null。
({List<String> texts, int caret})? srsApplySegmentEdit(
  List<SrsLayoutSeg> segs,
  List<String> current,
  String next,
  int caret,
) {
  assert(segs.length == current.length);
  final String old = current.join();
  int prefix = 0;
  final int maxPrefix = math.min(math.min(old.length, next.length), caret);
  while (prefix < maxPrefix &&
      old.codeUnitAt(prefix) == next.codeUnitAt(prefix)) {
    prefix++;
  }
  int suffix = 0;
  final int maxSuffix = math.min(
    math.min(old.length, next.length) - prefix,
    next.length - math.max(caret, prefix),
  );
  while (suffix < maxSuffix &&
      old.codeUnitAt(old.length - 1 - suffix) ==
          next.codeUnitAt(next.length - 1 - suffix)) {
    suffix++;
  }
  final int start = prefix;
  final int end = old.length - suffix;
  final String inserted = next.substring(prefix, next.length - suffix);

  // 插入落在哪一节。
  int? target;
  int offset = 0;
  final List<int> starts = <int>[];
  for (int i = 0; i < segs.length; i++) {
    starts.add(offset);
    offset += current[i].length;
  }
  for (int i = 0; i < segs.length && target == null; i++) {
    final int s = starts[i];
    final int e = s + current[i].length;
    if (segs[i].part != null && s <= start && start <= e) target = i;
  }
  if (target == null) {
    for (int i = 0; i < segs.length && target == null; i++) {
      if (segs[i].part != null && starts[i] >= start) target = i;
    }
    for (int i = segs.length - 1; i >= 0 && target == null; i--) {
      if (segs[i].part != null) target = i;
    }
  }
  if (target == null) return null;

  final List<String> texts = <String>[];
  int newCaret = 0;
  int written = 0;
  for (int i = 0; i < segs.length; i++) {
    final String t = current[i];
    final int s = starts[i];
    if (segs[i].part == null) {
      texts.add(t);
      written += t.length;
      continue;
    }
    final int cutFrom = (start - s).clamp(0, t.length);
    final int cutTo = (end - s).clamp(0, t.length);
    final String head = t.substring(0, cutFrom);
    final String tail = t.substring(cutTo < cutFrom ? cutFrom : cutTo);
    if (i == target) {
      newCaret = written + head.length + inserted.length;
      texts.add('$head$inserted$tail');
    } else {
      texts.add('$head$tail');
    }
    written += texts.last.length;
  }
  return (texts: texts, caret: newCaret);
}
