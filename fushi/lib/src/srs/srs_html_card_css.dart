/// 卡面原生渲染（[srs_html_card.dart]）用的 CSS 子集：样式表解析、选择器匹配、特异度、
/// 值的词法（长度 / 颜色 / `var()`）。纯 Dart，不依赖 Flutter。
///
/// 判据是「认得的才画」：不认识的 at-rule、选择器、属性、值一律抛
/// [SrsHtmlUnsupported]，调用方整张卡回退 WebView，不画一个近似的样子出来。只有对静态
/// 画面没有影响的属性（光标、过渡、选中行为、平滑字体等）列入 [_kIgnoredProperties] 直接忽略。
library;

import 'package:html/dom.dart' as dom;

/// 卡面里有原生渲染不认识的东西：整张卡回退 WebView。[reason] 只用于日志与测试。
class SrsHtmlUnsupported implements Exception {
  const SrsHtmlUnsupported(this.reason);

  final String reason;

  @override
  String toString() => 'SrsHtmlUnsupported($reason)';
}

Never srsHtmlUnsupported(String reason) => throw SrsHtmlUnsupported(reason);

/// 一条声明（简写已展开成长写）。
class SrsCssDeclaration {
  const SrsCssDeclaration(this.property, this.value, {this.important = false});

  final String property;
  final String value;
  final bool important;
}

/// 一条样式规则：选择器表里每个选择器单独成一条（特异度各算各的）。
class SrsCssRule {
  const SrsCssRule({
    required this.selector,
    required this.declarations,
    required this.order,
  });

  final SrsCssSelector selector;
  final List<SrsCssDeclaration> declarations;

  /// 在全部样式表里的出现顺序（特异度相同时后者胜）。
  final int order;
}

// ---------------------------------------------------------------- 属性表

/// 原生能画的属性（长写）。简写在 [_expand] 里展开成这些。
const Set<String> _kSupportedProperties = <String>{
  'color',
  'background-color',
  'font-size',
  'font-weight',
  'font-style',
  'font-family',
  'text-align',
  'line-height',
  'letter-spacing',
  'text-decoration-line',
  'white-space',
  'visibility',
  'opacity',
  'display',
  'margin-top',
  'margin-right',
  'margin-bottom',
  'margin-left',
  'padding-top',
  'padding-right',
  'padding-bottom',
  'padding-left',
  'border-top-width',
  'border-right-width',
  'border-bottom-width',
  'border-left-width',
  'border-top-style',
  'border-right-style',
  'border-bottom-style',
  'border-left-style',
  'border-top-color',
  'border-right-color',
  'border-bottom-color',
  'border-left-color',
  'border-radius',
  'width',
  'height',
  'max-width',
  'max-height',
  'min-height',
  'flex-direction',
  'flex-wrap',
  'flex-grow',
  'justify-content',
  'align-items',
  'row-gap',
  'column-gap',
  'list-style-type',
  'vertical-align',
};

/// 对静态画面没有影响（或只是交互 / 动画 / 打印 / 渲染提示）的属性：忽略。
const Set<String> _kIgnoredProperties = <String>{
  'cursor',
  'user-select',
  '-webkit-user-select',
  '-moz-user-select',
  '-ms-user-select',
  'transition',
  'transition-property',
  'transition-duration',
  'transition-timing-function',
  'transition-delay',
  '-webkit-font-smoothing',
  '-moz-osx-font-smoothing',
  'font-smooth',
  'text-rendering',
  'font-display',
  'pointer-events',
  'outline',
  'outline-color',
  'outline-style',
  'outline-width',
  'outline-offset',
  'box-sizing',
  '-webkit-box-sizing',
  'box-shadow',
  '-webkit-box-shadow',
  'text-shadow',
  'object-fit',
  'word-wrap',
  'overflow-wrap',
  'word-break',
  'line-break',
  'hyphens',
  '-webkit-tap-highlight-color',
  'touch-action',
  'will-change',
  'page-break-inside',
  'break-inside',
  'speak',
  'resize',
  'flex-shrink',
  'flex-basis',
  'align-self',
  'align-content',
  'text-decoration-color',
  'text-decoration-style',
  'text-decoration-thickness',
  'text-underline-offset',
  'font-variant',
  'font-feature-settings',
  'font-kerning',
  'image-rendering',
  'list-style-position',
  'caret-color',
  'scroll-behavior',
  'color-scheme',
};

// ---------------------------------------------------------------- 词法工具

/// 去掉 `/* … */` 注释（引号里的不动）。
String srsCssStripComments(String css) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  String? quote;
  while (i < css.length) {
    final String c = css[i];
    if (quote != null) {
      out.write(c);
      if (c == '\\' && i + 1 < css.length) {
        out.write(css[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i++;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && i + 1 < css.length && css[i + 1] == '*') {
      final int end = css.indexOf('*/', i + 2);
      i = end < 0 ? css.length : end + 2;
      out.write(' ');
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 按 [sep] 切分，括号 / 引号里的不切。
List<String> srsCssSplitTopLevel(String s, String sep) {
  final List<String> out = <String>[];
  int depth = 0;
  String? quote;
  int start = 0;
  for (int i = 0; i < s.length; i++) {
    final String c = s[i];
    if (quote != null) {
      if (c == '\\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '(' || c == '[') {
      depth++;
    } else if (c == ')' || c == ']') {
      depth--;
    } else if (depth == 0 && c == sep) {
      out.add(s.substring(start, i));
      start = i + 1;
    }
  }
  out.add(s.substring(start));
  return out;
}

/// 按空白切分值的各个分量（括号 / 引号里的空白不切）。
List<String> srsCssValueParts(String value) {
  final List<String> out = <String>[];
  final StringBuffer cur = StringBuffer();
  int depth = 0;
  String? quote;
  for (int i = 0; i < value.length; i++) {
    final String c = value[i];
    if (quote != null) {
      cur.write(c);
      if (c == quote) quote = null;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      cur.write(c);
    } else if (c == '(') {
      depth++;
      cur.write(c);
    } else if (c == ')') {
      depth--;
      cur.write(c);
    } else if (depth == 0 &&
        (c == ' ' || c == '\t' || c == '\n' || c == '\r')) {
      if (cur.isNotEmpty) {
        out.add(cur.toString());
        cur.clear();
      }
    } else {
      cur.write(c);
    }
  }
  if (cur.isNotEmpty) out.add(cur.toString());
  return out;
}

// ---------------------------------------------------------------- 样式表

/// 解析一张样式表，规则编号从 [orderBase] 起。
///
/// - `@charset` 忽略；`@media` / `@font-face` / `@import` / `@keyframes` / `@supports` 等其它
///   at-rule 一律不支持（原生没法按 Anki 的语义求值）。
/// - 选择器只认能静态匹配的（见 [SrsCssSelector.parse]）；只在交互态生效的伪类（`:hover` 等）
///   规则永不命中，直接丢掉。
List<SrsCssRule> srsParseStylesheet(String css, {int orderBase = 0}) {
  final String src = srsCssStripComments(css);
  final List<SrsCssRule> rules = <SrsCssRule>[];
  int order = orderBase;
  int i = 0;
  while (i < src.length) {
    // 跳过空白与多余的分号 / HTML 注释记号。
    final int open = src.indexOf('{', i);
    final String head = (open < 0 ? src.substring(i) : src.substring(i, open))
        .replaceAll('<!--', ' ')
        .replaceAll('-->', ' ');
    if (open < 0) {
      if (head.trim().isNotEmpty && !_isCharset(head)) {
        srsHtmlUnsupported('css: dangling "${_short(head)}"');
      }
      break;
    }
    String prelude = head.trim();
    // `@charset "x";` 这类以分号结束的语句可能粘在下一条规则前面。
    while (prelude.startsWith('@')) {
      final int semi = prelude.indexOf(';');
      if (semi < 0) break;
      final String stmt = prelude.substring(0, semi);
      if (!_isCharset(stmt)) {
        srsHtmlUnsupported('css: at-rule "${_short(stmt)}"');
      }
      prelude = prelude.substring(semi + 1).trim();
    }
    final int close = _matchingBrace(src, open);
    if (close < 0) srsHtmlUnsupported('css: unbalanced braces');
    final String body = src.substring(open + 1, close);
    i = close + 1;
    if (prelude.startsWith('@')) {
      srsHtmlUnsupported('css: at-rule "${_short(prelude)}"');
    }
    if (prelude.isEmpty) continue;
    final List<SrsCssDeclaration> decls = srsParseDeclarations(body);
    for (final String raw in srsCssSplitTopLevel(prelude, ',')) {
      final SrsCssSelector? sel = SrsCssSelector.parse(raw.trim(), decls);
      if (sel == null) continue;
      rules.add(SrsCssRule(selector: sel, declarations: decls, order: order++));
    }
  }
  return rules;
}

bool _isCharset(String s) => s.trim().toLowerCase().startsWith('@charset');

String _short(String s) {
  final String t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
  return t.length > 60 ? '${t.substring(0, 60)}…' : t;
}

int _matchingBrace(String s, int open) {
  int depth = 0;
  String? quote;
  for (int i = open; i < s.length; i++) {
    final String c = s[i];
    if (quote != null) {
      if (c == '\\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// 解析声明块（`style` 属性也走这里），简写展开成长写；不认识的属性抛 [SrsHtmlUnsupported]。
List<SrsCssDeclaration> srsParseDeclarations(String block) {
  final List<SrsCssDeclaration> out = <SrsCssDeclaration>[];
  for (final String raw in srsCssSplitTopLevel(
    srsCssStripComments(block),
    ';',
  )) {
    final int colon = raw.indexOf(':');
    if (colon < 0) {
      if (raw.trim().isNotEmpty) {
        srsHtmlUnsupported('css: bad declaration "${_short(raw)}"');
      }
      continue;
    }
    final String prop = raw.substring(0, colon).trim().toLowerCase();
    String value = raw.substring(colon + 1).trim();
    bool important = false;
    final RegExpMatch? imp = RegExp(
      r'!\s*important\s*$',
      caseSensitive: false,
    ).firstMatch(value);
    if (imp != null) {
      important = true;
      value = value.substring(0, imp.start).trim();
    }
    if (prop.isEmpty) continue;
    out.addAll(_expand(prop, value, important));
  }
  return out;
}

List<SrsCssDeclaration> _expand(String prop, String value, bool important) {
  SrsCssDeclaration d(String p, String v) =>
      SrsCssDeclaration(p, v, important: important);
  // `content` 只对 ::before / ::after 有效（那两种规则见 [SrsCssSelector.parse]）。
  if (prop.startsWith('--') || prop == 'content') {
    return <SrsCssDeclaration>[d(prop, value)];
  }
  if (_kIgnoredProperties.contains(prop)) return const <SrsCssDeclaration>[];
  if (_kSupportedProperties.contains(prop)) {
    return <SrsCssDeclaration>[d(prop, value)];
  }
  // 值里有 var() 的简写没法在解析期拆：Anki 模板里少见，直接不支持。
  final bool hasVar = value.contains('var(');
  List<SrsCssDeclaration> fourSides(String base, [String suffix = '']) {
    if (hasVar && srsCssValueParts(value).length > 1) {
      srsHtmlUnsupported('css: var() in shorthand $prop');
    }
    final List<String> v = srsCssValueParts(value);
    if (v.isEmpty || v.length > 4) srsHtmlUnsupported('css: $prop "$value"');
    final String top = v[0];
    final String right = v.length > 1 ? v[1] : top;
    final String bottom = v.length > 2 ? v[2] : top;
    final String left = v.length > 3 ? v[3] : right;
    return <SrsCssDeclaration>[
      d('$base-top$suffix', top),
      d('$base-right$suffix', right),
      d('$base-bottom$suffix', bottom),
      d('$base-left$suffix', left),
    ];
  }

  switch (prop) {
    case 'margin':
    case 'padding':
      return fourSides(prop);
    case 'border-width':
      return fourSides('border', '-width');
    case 'border-style':
      return fourSides('border', '-style');
    case 'border-color':
      return fourSides('border', '-color');
    case 'border':
    case 'border-top':
    case 'border-right':
    case 'border-bottom':
    case 'border-left':
      final List<String> sides = prop == 'border'
          ? const <String>['top', 'right', 'bottom', 'left']
          : <String>[prop.substring('border-'.length)];
      final ({String width, String style, String color}) b = _borderParts(
        value,
      );
      return <SrsCssDeclaration>[
        for (final String s in sides) ...<SrsCssDeclaration>[
          d('border-$s-width', b.width),
          d('border-$s-style', b.style),
          d('border-$s-color', b.color),
        ],
      ];
    case 'background':
      final String v = value.trim().toLowerCase();
      if (v == 'none' || v == 'transparent') {
        return <SrsCssDeclaration>[d('background-color', 'transparent')];
      }
      if (v.contains('url(') || v.contains('gradient(')) {
        srsHtmlUnsupported('css: background image');
      }
      if (srsCssValueParts(value).length != 1) {
        srsHtmlUnsupported('css: background "$value"');
      }
      return <SrsCssDeclaration>[d('background-color', value)];
    case 'background-image':
      if (value.trim().toLowerCase() == 'none') {
        return const <SrsCssDeclaration>[];
      }
      srsHtmlUnsupported('css: background-image');
    case 'text-decoration':
      final List<String> lines = <String>[
        for (final String p in srsCssValueParts(value.toLowerCase()))
          if (const <String>{
            'none',
            'underline',
            'line-through',
            'overline',
          }.contains(p))
            p,
      ];
      return <SrsCssDeclaration>[
        d('text-decoration-line', lines.isEmpty ? 'none' : lines.join(' ')),
      ];
    case 'list-style':
      final List<String> parts = srsCssValueParts(value.toLowerCase());
      if (parts.any((String p) => p.contains('url('))) {
        srsHtmlUnsupported('css: list-style image');
      }
      final String type = parts.firstWhere(
        (String p) => p != 'inside' && p != 'outside',
        orElse: () => 'disc',
      );
      return <SrsCssDeclaration>[d('list-style-type', type)];
    case 'flex':
      final List<String> parts = srsCssValueParts(value.toLowerCase());
      if (parts.length == 1 && parts.first == 'none') {
        return <SrsCssDeclaration>[d('flex-grow', '0')];
      }
      if (parts.length == 1 && parts.first == 'auto') {
        return <SrsCssDeclaration>[d('flex-grow', '1')];
      }
      final double? grow = double.tryParse(parts.first);
      if (grow == null) srsHtmlUnsupported('css: flex "$value"');
      return <SrsCssDeclaration>[d('flex-grow', parts.first)];
    case 'flex-flow':
      final List<SrsCssDeclaration> out = <SrsCssDeclaration>[];
      for (final String p in srsCssValueParts(value.toLowerCase())) {
        out.add(
          d(
            p.startsWith('row') || p.startsWith('column')
                ? 'flex-direction'
                : 'flex-wrap',
            p,
          ),
        );
      }
      return out;
    case 'gap':
    case 'grid-gap':
      final List<String> parts = srsCssValueParts(value);
      return <SrsCssDeclaration>[
        d('row-gap', parts.first),
        d('column-gap', parts.length > 1 ? parts[1] : parts.first),
      ];
    case 'border-top-left-radius':
    case 'border-top-right-radius':
    case 'border-bottom-left-radius':
    case 'border-bottom-right-radius':
      // 只取统一圆角：分角圆角少见，按最后一次写的值整体用。
      return <SrsCssDeclaration>[d('border-radius', value)];
    case 'overflow':
    case 'overflow-x':
    case 'overflow-y':
      // 内容不溢出时没有效果；visible / auto / hidden 在卡面（整体滚动）上的差别只在
      // 固定高度的盒子里，而固定高度原生不支持（height 只认 auto）。
      final String v = value.trim().toLowerCase();
      if (const <String>{
        'visible',
        'auto',
        'hidden',
        'scroll',
        'clip',
      }.contains(v)) {
        return const <SrsCssDeclaration>[];
      }
      srsHtmlUnsupported('css: overflow "$value"');
  }
  srsHtmlUnsupported('css: property "$prop"');
}

({String width, String style, String color}) _borderParts(String value) {
  final String v = value.trim();
  if (v.toLowerCase() == 'none' || v == '0') {
    return (width: '0', style: 'none', color: 'currentcolor');
  }
  String width = 'medium';
  String style = 'none';
  String color = 'currentcolor';
  for (final String p in srsCssValueParts(v)) {
    final String l = p.toLowerCase();
    if (_kBorderStyles.contains(l)) {
      style = l;
    } else if (l == 'thin' ||
        l == 'medium' ||
        l == 'thick' ||
        RegExp(r'^[\d.]').hasMatch(l)) {
      width = l;
    } else {
      color = p;
    }
  }
  return (width: width, style: style, color: color);
}

const Set<String> _kBorderStyles = <String>{
  'none',
  'hidden',
  'solid',
  'dashed',
  'dotted',
  'double',
  'groove',
  'ridge',
  'inset',
  'outset',
};

// ---------------------------------------------------------------- 选择器

enum _Combinator { descendant, child, adjacent, sibling }

/// 一个复合选择器里的单个条件。
sealed class _Simple {
  const _Simple();
  bool matches(dom.Element e);
}

class _Type extends _Simple {
  const _Type(this.name);
  final String name;
  @override
  bool matches(dom.Element e) => e.localName == name;
}

class _Id extends _Simple {
  const _Id(this.id);
  final String id;
  @override
  bool matches(dom.Element e) => e.id == id;
}

class _Class extends _Simple {
  const _Class(this.name);
  final String name;
  @override
  bool matches(dom.Element e) => e.classes.contains(name);
}

class _Attr extends _Simple {
  const _Attr(this.name, this.op, this.value);
  final String name;
  final String? op;
  final String value;
  @override
  bool matches(dom.Element e) {
    final String? v = e.attributes[name];
    if (v == null) return false;
    return switch (op) {
      null => true,
      '=' => v == value,
      '~=' => v.split(RegExp(r'\s+')).contains(value),
      '|=' => v == value || v.startsWith('$value-'),
      '^=' => value.isNotEmpty && v.startsWith(value),
      r'$=' => value.isNotEmpty && v.endsWith(value),
      '*=' => value.isNotEmpty && v.contains(value),
      _ => false,
    };
  }
}

class _Pseudo extends _Simple {
  const _Pseudo(this.test);
  final bool Function(dom.Element e) test;
  @override
  bool matches(dom.Element e) => test(e);
}

class _Not extends _Simple {
  const _Not(this.inner);
  final List<_Simple> inner;
  @override
  bool matches(dom.Element e) => !inner.every((_Simple s) => s.matches(e));
}

List<dom.Element> _siblings(dom.Element e) {
  final dom.Node? p = e.parentNode;
  if (p == null) return <dom.Element>[e];
  return p.nodes.whereType<dom.Element>().toList();
}

/// 一个完整选择器：复合选择器链（从左到右）+ 之间的组合子。
class SrsCssSelector {
  SrsCssSelector._(this._compounds, this._combinators, this.specificity);

  final List<List<_Simple>> _compounds;
  final List<_Combinator> _combinators;

  /// (id, class, type) 压成一个整数，越大越优先。
  final int specificity;

  /// 解析一个选择器；永不命中的（交互伪类、`::selection` 等）返回 null；认不得的抛
  /// [SrsHtmlUnsupported]。[decls] 用来判断 `::before` / `::after` 是否真的生成内容。
  static SrsCssSelector? parse(String src, List<SrsCssDeclaration> decls) {
    if (src.isEmpty) return null;
    final List<List<_Simple>> compounds = <List<_Simple>>[<_Simple>[]];
    final List<_Combinator> combinators = <_Combinator>[];
    int ids = 0, classes = 0, types = 0;
    int i = 0;
    bool pendingSpace = false;
    String ident() {
      final int start = i;
      while (i < src.length && RegExp(r'[\w\-\\]').hasMatch(src[i])) {
        if (src[i] == '\\' && i + 1 < src.length) i++;
        i++;
      }
      if (i == start) srsHtmlUnsupported('css: selector "$src"');
      return src.substring(start, i).replaceAll('\\', '');
    }

    void combine(_Combinator c) {
      if (compounds.last.isEmpty) {
        srsHtmlUnsupported('css: selector "$src"');
      }
      combinators.add(c);
      compounds.add(<_Simple>[]);
    }

    while (i < src.length) {
      final String c = src[i];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        pendingSpace = true;
        i++;
        continue;
      }
      if (c == '>' || c == '+' || c == '~') {
        combine(switch (c) {
          '>' => _Combinator.child,
          '+' => _Combinator.adjacent,
          _ => _Combinator.sibling,
        });
        pendingSpace = false;
        i++;
        continue;
      }
      if (pendingSpace && compounds.last.isNotEmpty) {
        combine(_Combinator.descendant);
      }
      pendingSpace = false;
      if (c == '*') {
        i++;
        continue;
      }
      if (c == '#') {
        i++;
        compounds.last.add(_Id(ident()));
        ids++;
        continue;
      }
      if (c == '.') {
        i++;
        compounds.last.add(_Class(ident()));
        classes++;
        continue;
      }
      if (c == '[') {
        final int end = src.indexOf(']', i);
        if (end < 0) srsHtmlUnsupported('css: selector "$src"');
        final String body = src.substring(i + 1, end).trim();
        i = end + 1;
        final RegExpMatch? m = RegExp(
          r'''^([\w\-]+)\s*(?:([~|^$*]?=)\s*(?:"([^"]*)"|'([^']*)'|([^\s\]]+))\s*(i)?)?$''',
        ).firstMatch(body);
        if (m == null) srsHtmlUnsupported('css: selector "$src"');
        compounds.last.add(
          _Attr(
            m.group(1)!.toLowerCase(),
            m.group(2),
            m.group(3) ?? m.group(4) ?? m.group(5) ?? '',
          ),
        );
        classes++;
        continue;
      }
      if (c == ':') {
        final bool element = i + 1 < src.length && src[i + 1] == ':';
        i += element ? 2 : 1;
        final String name = ident().toLowerCase();
        String? arg;
        if (i < src.length && src[i] == '(') {
          int depth = 0;
          final int start = i + 1;
          for (; i < src.length; i++) {
            if (src[i] == '(') depth++;
            if (src[i] == ')' && --depth == 0) break;
          }
          if (i >= src.length) srsHtmlUnsupported('css: selector "$src"');
          arg = src.substring(start, i).trim();
          i++;
        }
        if (element || name == 'before' || name == 'after') {
          if (name == 'before' || name == 'after') {
            final bool generates = decls.any(
              (SrsCssDeclaration d) =>
                  d.property == 'content' &&
                  !const <String>{
                    'none',
                    'normal',
                    '""',
                    "''",
                  }.contains(d.value.trim()),
            );
            if (generates) srsHtmlUnsupported('css: ::$name content');
            return null;
          }
          if (name == 'selection' ||
              name == 'placeholder' ||
              name == 'marker' ||
              name.startsWith('-webkit-') ||
              name.startsWith('-moz-')) {
            return null;
          }
          srsHtmlUnsupported('css: pseudo-element ::$name');
        }
        switch (name) {
          case 'hover':
          case 'active':
          case 'focus':
          case 'focus-visible':
          case 'focus-within':
          case 'visited':
          case 'target':
          case 'checked':
          case 'disabled':
          case 'enabled':
            return null;
          case 'root':
            compounds.last.add(
              _Pseudo((dom.Element e) => e.localName == 'html'),
            );
          case 'link':
          case 'any-link':
            compounds.last.add(
              _Pseudo(
                (dom.Element e) =>
                    e.localName == 'a' && e.attributes.containsKey('href'),
              ),
            );
          case 'first-child':
            compounds.last.add(
              _Pseudo((dom.Element e) => _siblings(e).first == e),
            );
          case 'last-child':
            compounds.last.add(
              _Pseudo((dom.Element e) => _siblings(e).last == e),
            );
          case 'only-child':
            compounds.last.add(
              _Pseudo((dom.Element e) => _siblings(e).length == 1),
            );
          case 'first-of-type':
            compounds.last.add(
              _Pseudo(
                (dom.Element e) =>
                    _siblings(e).firstWhere(
                      (dom.Element s) => s.localName == e.localName,
                    ) ==
                    e,
              ),
            );
          case 'last-of-type':
            compounds.last.add(
              _Pseudo(
                (dom.Element e) =>
                    _siblings(e).lastWhere(
                      (dom.Element s) => s.localName == e.localName,
                    ) ==
                    e,
              ),
            );
          case 'empty':
            compounds.last.add(
              _Pseudo(
                (dom.Element e) => e.nodes.every(
                  (dom.Node n) =>
                      n is dom.Comment || (n is dom.Text && n.data.isEmpty),
                ),
              ),
            );
          case 'nth-child':
          case 'nth-of-type':
            final bool ofType = name == 'nth-of-type';
            final bool Function(int) at = _nth(arg ?? '', src);
            compounds.last.add(
              _Pseudo((dom.Element e) {
                final List<dom.Element> sib = ofType
                    ? _siblings(e)
                          .where((dom.Element s) => s.localName == e.localName)
                          .toList()
                    : _siblings(e);
                return at(sib.indexOf(e) + 1);
              }),
            );
          case 'not':
            final SrsCssSelector? inner = SrsCssSelector.parse(
              arg ?? '',
              const <SrsCssDeclaration>[],
            );
            if (inner == null || inner._compounds.length != 1) {
              srsHtmlUnsupported('css: :not($arg)');
            }
            compounds.last.add(_Not(inner._compounds.single));
          default:
            srsHtmlUnsupported('css: pseudo-class :$name');
        }
        classes++;
        continue;
      }
      if (RegExp(r'[A-Za-z_\-]').hasMatch(c)) {
        compounds.last.add(_Type(ident().toLowerCase()));
        types++;
        continue;
      }
      srsHtmlUnsupported('css: selector "$src"');
    }
    if (compounds.last.isEmpty && combinators.isNotEmpty) {
      srsHtmlUnsupported('css: selector "$src"');
    }
    return SrsCssSelector._(
      compounds,
      combinators,
      ids * 10000 + classes * 100 + types,
    );
  }

  static bool Function(int) _nth(String arg, String src) {
    final String a = arg.replaceAll(' ', '').toLowerCase();
    if (a == 'odd') return (int n) => n.isOdd;
    if (a == 'even') return (int n) => n.isEven;
    final int? k = int.tryParse(a);
    if (k != null) return (int n) => n == k;
    final RegExpMatch? m = RegExp(r'^([+-]?\d*)n([+-]\d+)?$').firstMatch(a);
    if (m == null) srsHtmlUnsupported('css: nth "$arg" in "$src"');
    final String sa = m.group(1)!;
    final int step = sa.isEmpty || sa == '+'
        ? 1
        : sa == '-'
        ? -1
        : int.parse(sa);
    final int offset = int.tryParse(m.group(2) ?? '0') ?? 0;
    return (int n) {
      if (step == 0) return n == offset;
      final int d = n - offset;
      return d % step == 0 && d ~/ step >= 0;
    };
  }

  bool _compound(int index, dom.Element e) =>
      _compounds[index].every((_Simple s) => s.matches(e));

  /// [e] 是否命中（从右往左回溯）。
  bool matches(dom.Element e) => _matchFrom(_compounds.length - 1, e);

  bool _matchFrom(int index, dom.Element e) {
    if (!_compound(index, e)) return false;
    if (index == 0) return true;
    switch (_combinators[index - 1]) {
      case _Combinator.child:
        final dom.Element? p = e.parent;
        return p != null && _matchFrom(index - 1, p);
      case _Combinator.descendant:
        for (dom.Element? p = e.parent; p != null; p = p.parent) {
          if (_matchFrom(index - 1, p)) return true;
        }
        return false;
      case _Combinator.adjacent:
        final dom.Element? prev = e.previousElementSibling;
        return prev != null && _matchFrom(index - 1, prev);
      case _Combinator.sibling:
        for (
          dom.Element? prev = e.previousElementSibling;
          prev != null;
          prev = prev.previousElementSibling
        ) {
          if (_matchFrom(index - 1, prev)) return true;
        }
        return false;
    }
  }
}

// ---------------------------------------------------------------- 值

/// `var(--x[, fallback])` 换成 [vars] 里的值（可嵌套）；未定义且无回落值时抛不支持。
String srsCssResolveVars(
  String value,
  Map<String, String> vars, [
  int depth = 0,
]) {
  if (!value.contains('var(')) return value;
  if (depth > 8) srsHtmlUnsupported('css: var() recursion');
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (true) {
    final int at = value.indexOf('var(', i);
    if (at < 0) {
      out.write(value.substring(i));
      break;
    }
    out.write(value.substring(i, at));
    int depthP = 0;
    int end = at + 3;
    for (; end < value.length; end++) {
      if (value[end] == '(') depthP++;
      if (value[end] == ')' && --depthP == 0) break;
    }
    if (end >= value.length) srsHtmlUnsupported('css: var() "$value"');
    final String inner = value.substring(at + 4, end);
    final int comma = inner.indexOf(',');
    final String name = (comma < 0 ? inner : inner.substring(0, comma)).trim();
    final String? fallback = comma < 0
        ? null
        : inner.substring(comma + 1).trim();
    final String? v = vars[name] ?? fallback;
    if (v == null) srsHtmlUnsupported('css: undefined $name');
    out.write(srsCssResolveVars(v, vars, depth + 1));
    i = end + 1;
  }
  return out.toString();
}

/// 长度单位。
enum SrsCssUnit { px, em, rem, percent, vw, vh }

/// 一个长度（`em` / `rem` 已在层叠时换算成 px；`%` / `vw` / `vh` 留到排版时按容器 / 视口算）。
class SrsCssLength {
  const SrsCssLength(this.value, this.unit);

  static const SrsCssLength zero = SrsCssLength(0, SrsCssUnit.px);

  final double value;
  final SrsCssUnit unit;

  /// 按容器宽 [container] 与视口 [viewportW] / [viewportH] 换算成 px。
  double resolve({
    required double container,
    required double viewportW,
    required double viewportH,
  }) => switch (unit) {
    SrsCssUnit.px => value,
    SrsCssUnit.percent => container * value / 100,
    SrsCssUnit.vw => viewportW * value / 100,
    SrsCssUnit.vh => viewportH * value / 100,
    // 层叠时已换算，这里不会出现。
    SrsCssUnit.em || SrsCssUnit.rem => value,
  };

  @override
  bool operator ==(Object other) =>
      other is SrsCssLength && other.value == value && other.unit == unit;

  @override
  int get hashCode => Object.hash(value, unit);

  @override
  String toString() => '$value${unit.name}';
}

/// 解析长度：[em] 是 1em 对应的 px，[rem] 是根字号。`calc()` 等不认识的抛不支持。
SrsCssLength srsCssParseLength(
  String raw, {
  required double em,
  required double rem,
  bool allowPercent = true,
  bool allowViewport = true,
}) {
  final String v = raw.trim().toLowerCase();
  if (v == '0') return SrsCssLength.zero;
  final RegExpMatch? m = RegExp(
    r'^([+-]?(?:\d+\.?\d*|\.\d+))(px|pt|em|rem|%|vw|vh|vmin|vmax|ex|ch|pc|cm|mm|in)?$',
  ).firstMatch(v);
  if (m == null) srsHtmlUnsupported('css: length "$raw"');
  final double n = double.parse(m.group(1)!);
  switch (m.group(2)) {
    case null:
      if (n == 0) return SrsCssLength.zero;
      srsHtmlUnsupported('css: unitless length "$raw"');
    case 'px':
      return SrsCssLength(n, SrsCssUnit.px);
    case 'pt':
      return SrsCssLength(n * 4 / 3, SrsCssUnit.px);
    case 'pc':
      return SrsCssLength(n * 16, SrsCssUnit.px);
    case 'in':
      return SrsCssLength(n * 96, SrsCssUnit.px);
    case 'cm':
      return SrsCssLength(n * 96 / 2.54, SrsCssUnit.px);
    case 'mm':
      return SrsCssLength(n * 96 / 25.4, SrsCssUnit.px);
    case 'em':
      return SrsCssLength(n * em, SrsCssUnit.px);
    case 'ex':
    case 'ch':
      return SrsCssLength(n * em / 2, SrsCssUnit.px);
    case 'rem':
      return SrsCssLength(n * rem, SrsCssUnit.px);
    case '%':
      if (!allowPercent) srsHtmlUnsupported('css: percent "$raw"');
      return SrsCssLength(n, SrsCssUnit.percent);
    case 'vw':
      if (!allowViewport) srsHtmlUnsupported('css: viewport unit "$raw"');
      return SrsCssLength(n, SrsCssUnit.vw);
    case 'vh':
      if (!allowViewport) srsHtmlUnsupported('css: viewport unit "$raw"');
      return SrsCssLength(n, SrsCssUnit.vh);
  }
  srsHtmlUnsupported('css: length "$raw"');
}

/// 解析颜色成 ARGB；`currentcolor` 返回 [current]。不认识的抛不支持。
int srsCssParseColor(String raw, {required int current}) {
  final String v = raw.trim().toLowerCase();
  if (v == 'currentcolor') return current;
  if (v == 'transparent') return 0x00000000;
  final int? named = _kNamedColors[v];
  if (named != null) return 0xFF000000 | named;
  if (v.startsWith('#')) {
    final String h = v.substring(1);
    if (!RegExp(r'^[0-9a-f]+$').hasMatch(h)) {
      srsHtmlUnsupported('css: color "$raw"');
    }
    String expand(String s) => s.split('').map((String c) => '$c$c').join();
    switch (h.length) {
      case 3:
        return 0xFF000000 | int.parse(expand(h), radix: 16);
      case 4:
        final String e = expand(h);
        return int.parse(e.substring(6), radix: 16) << 24 |
            int.parse(e.substring(0, 6), radix: 16);
      case 6:
        return 0xFF000000 | int.parse(h, radix: 16);
      case 8:
        return int.parse(h.substring(6), radix: 16) << 24 |
            int.parse(h.substring(0, 6), radix: 16);
    }
    srsHtmlUnsupported('css: color "$raw"');
  }
  final RegExpMatch? fn = RegExp(r'^(rgba?|hsla?)\((.*)\)$').firstMatch(v);
  if (fn != null) {
    final List<String> parts = fn
        .group(2)!
        .replaceAll('/', ' ')
        .replaceAll(',', ' ')
        .split(RegExp(r'\s+'))
        .where((String s) => s.isNotEmpty)
        .toList();
    if (parts.length < 3 || parts.length > 4) {
      srsHtmlUnsupported('css: color "$raw"');
    }
    double num(String s, double scale) {
      final bool pct = s.endsWith('%');
      final double? n = double.tryParse(
        pct ? s.substring(0, s.length - 1) : s.replaceAll('deg', ''),
      );
      if (n == null) srsHtmlUnsupported('css: color "$raw"');
      return pct ? n * scale / 100 : n;
    }

    final double alpha = parts.length == 4
        ? num(parts[3], 1).clamp(0, 1).toDouble()
        : 1;
    int r, g, b;
    if (fn.group(1)!.startsWith('rgb')) {
      r = num(parts[0], 255).round().clamp(0, 255);
      g = num(parts[1], 255).round().clamp(0, 255);
      b = num(parts[2], 255).round().clamp(0, 255);
    } else {
      final ({int r, int g, int b}) c = srsHslToRgb(
        num(parts[0], 360) % 360,
        (num(parts[1], 1) * (parts[1].endsWith('%') ? 1 : 0.01)).clamp(0, 1),
        (num(parts[2], 1) * (parts[2].endsWith('%') ? 1 : 0.01)).clamp(0, 1),
      );
      r = c.r;
      g = c.g;
      b = c.b;
    }
    return (alpha * 255).round() << 24 | r << 16 | g << 8 | b;
  }
  srsHtmlUnsupported('css: color "$raw"');
}

/// HSL（h 度，s / l 0–1）→ RGB。
({int r, int g, int b}) srsHslToRgb(double h, double s, double l) {
  double hue(double p, double q, double t) {
    double x = t;
    if (x < 0) x += 1;
    if (x > 1) x -= 1;
    if (x < 1 / 6) return p + (q - p) * 6 * x;
    if (x < 1 / 2) return q;
    if (x < 2 / 3) return p + (q - p) * (2 / 3 - x) * 6;
    return p;
  }

  if (s == 0) {
    final int v = (l * 255).round();
    return (r: v, g: v, b: v);
  }
  final double q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  final double p = 2 * l - q;
  final double hh = h / 360;
  return (
    r: (hue(p, q, hh + 1 / 3) * 255).round(),
    g: (hue(p, q, hh) * 255).round(),
    b: (hue(p, q, hh - 1 / 3) * 255).round(),
  );
}

const Map<String, int> _kNamedColors = <String, int>{
  'black': 0x000000,
  'white': 0xffffff,
  'red': 0xff0000,
  'green': 0x008000,
  'blue': 0x0000ff,
  'yellow': 0xffff00,
  'orange': 0xffa500,
  'purple': 0x800080,
  'gray': 0x808080,
  'grey': 0x808080,
  'silver': 0xc0c0c0,
  'maroon': 0x800000,
  'olive': 0x808000,
  'lime': 0x00ff00,
  'aqua': 0x00ffff,
  'cyan': 0x00ffff,
  'teal': 0x008080,
  'navy': 0x000080,
  'fuchsia': 0xff00ff,
  'magenta': 0xff00ff,
  'pink': 0xffc0cb,
  'brown': 0xa52a2a,
  'gold': 0xffd700,
  'crimson': 0xdc143c,
  'coral': 0xff7f50,
  'tomato': 0xff6347,
  'orangered': 0xff4500,
  'darkred': 0x8b0000,
  'darkgreen': 0x006400,
  'darkblue': 0x00008b,
  'darkorange': 0xff8c00,
  'darkgray': 0xa9a9a9,
  'darkgrey': 0xa9a9a9,
  'dimgray': 0x696969,
  'dimgrey': 0x696969,
  'lightgray': 0xd3d3d3,
  'lightgrey': 0xd3d3d3,
  'gainsboro': 0xdcdcdc,
  'whitesmoke': 0xf5f5f5,
  'lightblue': 0xadd8e6,
  'lightgreen': 0x90ee90,
  'lightyellow': 0xffffe0,
  'lightpink': 0xffb6c1,
  'skyblue': 0x87ceeb,
  'steelblue': 0x4682b4,
  'royalblue': 0x4169e1,
  'dodgerblue': 0x1e90ff,
  'deepskyblue': 0x00bfff,
  'cornflowerblue': 0x6495ed,
  'slategray': 0x708090,
  'slategrey': 0x708090,
  'indigo': 0x4b0082,
  'violet': 0xee82ee,
  'orchid': 0xda70d6,
  'plum': 0xdda0dd,
  'salmon': 0xfa8072,
  'khaki': 0xf0e68c,
  'beige': 0xf5f5dc,
  'ivory': 0xfffff0,
  'linen': 0xfaf0e6,
  'wheat': 0xf5deb3,
  'tan': 0xd2b48c,
  'chocolate': 0xd2691e,
  'firebrick': 0xb22222,
  'forestgreen': 0x228b22,
  'seagreen': 0x2e8b57,
  'limegreen': 0x32cd32,
  'darkviolet': 0x9400d3,
  'mediumpurple': 0x9370db,
  'hotpink': 0xff69b4,
  'deeppink': 0xff1493,
  'turquoise': 0x40e0d0,
  'aliceblue': 0xf0f8ff,
  'ghostwhite': 0xf8f8ff,
  'snow': 0xfffafa,
  'honeydew': 0xf0fff0,
  'mintcream': 0xf5fffa,
  'lavender': 0xe6e6fa,
  'midnightblue': 0x191970,
  'darkslategray': 0x2f4f4f,
  'darkslategrey': 0x2f4f4f,
};
