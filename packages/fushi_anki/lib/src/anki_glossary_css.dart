/// 制卡释义里词典 CSS 的瘦身（BUG-3224）。
///
/// popup.js 导出释义时与 Yomitan 同形：每段 `<div class="yomitan-glossary">` 末尾带一份
/// 该词典**整份** `styles.css`，选择器全部加了 `.yomitan-glossary [data-dictionary="名"]`
/// 作用域前缀。整份 CSS 是给弹窗里所有可能出现的结构准备的，单条词条只用到其中很少一部分；
/// 牛津（OALDPE）一类词典的 styles.css 有 210 KB（约七成是 hover 态 / 设置面板图标的
/// data URI 与内嵌字体），加前缀后约 247 KB，而 Lapis 出厂把 `{glossary}` 与
/// `{glossary-first}` 映射到两个字段，一张卡就背了约 500 KB CSS。AnkiDroid 的预览把整条
/// 笔记的字段塞进 Intent 过 Binder，事务超过 1 MB 共享上限就
/// `TransactionTooLargeException`，预览打不开。
///
/// 这里在 payload 进 handlebar 渲染之前，按**本段释义实际内容**裁掉命中不到任何元素的
/// 作用域规则，并去掉注释与多余空白。判据只做「放宽」：
///
/// * 只裁选择器以 `.yomitan-glossary` 开头的规则（词典作用域规则）。其它规则可能命中
///   卡片模板里的元素，这一层看不见模板，一律原样保留。
/// * 判断命中前先把伪类 / 伪元素整段去掉（`:hover`、`::before`、`:not(…)`、`:nth-child(…)`
///   等）。去掉它们只会让选择器命中更多元素，所以只可能多留，不会误删：hover 态、
///   结构伪类在卡片上照常生效。交互态（`:hover` / `:active` / `:focus*`）**不**整条丢：
///   Anki 桌面有鼠标 hover，Android WebView 点按也会触发 `:hover`（「点一下显示」的
///   提示 / 展开写法靠它），只留命中本条元素的那几条，体积代价有限。交互态属性
///   `[open]` 同理：导出时 `<details>` 多半关着，卡片上点开后才有 `open`，判断前一并去掉。
/// * 选择器解析不了（本实现不认识的语法）就当作命中，整条保留。
/// * `@media` / `@supports` / `@container` / `@layer` 等条件组递归裁剪，裁空了整组去掉；
///   `@font-face` / `@keyframes` 只在剩下的规则或释义 HTML 本身（MDX 词典常见的内联
///   `style="font-family:…"`、`<font face>`）还引用它们时保留；其余 at-rule 原样保留。
///
/// 规则命中不到本段释义里的任何元素，就不可能影响这段释义的渲染：作用域前缀把它限定在
/// `.yomitan-glossary [data-dictionary=…]` 之内，同一张卡上别的字段各自带着自己裁过的那份。
/// 所以卡面效果与裁剪前一致；代价是用户事后在 Anki 里手改字段、加进本来不存在的结构时，
/// 那部分不再有词典样式。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// 导出释义里的 `<style>` 块。
final RegExp _styleBlock = RegExp(
  r'<style(\s[^>]*)?>([\s\S]*?)</style>',
  caseSensitive: false,
);

/// 只裁这个作用域开头的规则（popup.js `constructDictCss` 给制卡导出加的前缀）。
const String _glossaryScope = '.yomitan-glossary';

/// 按释义内容裁掉用不到的词典 CSS、去注释压空白，并去掉同一段 HTML 里重复的 `<style>`。
///
/// 没有 `<style>` 的 HTML 原样返回（同一个实例）。
String slimAnkiGlossaryHtml(String html) {
  if (html.isEmpty || !html.toLowerCase().contains('<style')) return html;
  final dom.Document document = html_parser.parse(html);
  final _SelectorProbe probe = _SelectorProbe(document);
  final Set<String> seen = <String>{};
  // 释义正文（去掉 <style> 本身）：内联样式也可能引用词典 @font-face / @keyframes。
  final String markup = html.replaceAll(_styleBlock, '');
  return html.replaceAllMapped(_styleBlock, (Match match) {
    final String attributes = match.group(1) ?? '';
    final String css = slimGlossaryCss(
      match.group(2)!,
      probe.matches,
      referencingMarkup: markup,
    );
    if (css.isEmpty || !seen.add('$attributes\u0000$css')) return '';
    return '<style$attributes>$css</style>';
  });
}

/// 一次制卡内复用的瘦身器：`{glossary-first}` 与某本词典的 `{single-glossary-*}` 是
/// 同一段 HTML，同一份内容只裁一次。
class AnkiGlossaryCssSlimmer {
  final Map<String, String> _memo = <String, String>{};

  String slim(String html) =>
      _memo.putIfAbsent(html, () => slimAnkiGlossaryHtml(html));

  /// 逐词典版本（`AnkiMiningPayload.singleGlossaries`）；空 Map 原样返回。
  Map<String, String> slimMap(Map<String, String> glossaries) {
    if (glossaries.isEmpty) return glossaries;
    return <String, String>{
      for (final MapEntry<String, String> e in glossaries.entries)
        e.key: slim(e.value),
    };
  }
}

/// 裁剪一份 CSS：[matches] 判断一条（已去掉伪类的）作用域选择器是否命中内容；
/// [referencingMarkup] 是释义正文，`@font-face` / `@keyframes` 被它引用（内联样式）也保留。
///
/// 公开给测试；生产代码走 [slimAnkiGlossaryHtml]。
String slimGlossaryCss(
  String css,
  bool Function(String selector) matches, {
  String referencingMarkup = '',
}) {
  final List<_CssNode> nodes = _CssParser(
    css,
  ).parseBlockContents(nested: false);
  final List<_CssNode> kept = _prune(nodes, matches);
  final String rulesText = kept
      .where((_CssNode n) => !n.isNamedResource)
      .map((_CssNode n) => n.text)
      .join();
  // 引用面 = 留下的规则 + 释义正文（内联 style / `<font face>`），统一小写只算一次。
  final String references = '$rulesText\u0000$referencingMarkup'.toLowerCase();
  final List<_CssNode> result = kept.where((_CssNode n) {
    if (!n.isNamedResource) return true;
    // 引用不到的 @font-face / @keyframes 不会被用到，留着只是背着 base64 字体走。
    final String? name = n.resourceName;
    if (name == null || name.isEmpty) return true;
    return references.contains(name.toLowerCase());
  }).toList();
  return result.map((_CssNode n) => n.text).join().trim();
}

List<_CssNode> _prune(
  List<_CssNode> nodes,
  bool Function(String selector) matches,
) {
  final List<_CssNode> out = <_CssNode>[];
  for (final _CssNode node in nodes) {
    switch (node.kind) {
      case _CssKind.style:
        if (_ruleMayApply(node.prelude, matches)) out.add(node);
      case _CssKind.group:
        final List<_CssNode> inner = _prune(node.children, matches);
        if (inner.isNotEmpty) out.add(node.withChildren(inner));
      case _CssKind.other:
        out.add(node);
    }
  }
  return out;
}

/// 一条规则在本段释义上可能生效吗？只有「全是作用域选择器且一个都命中不到」才算不可能。
bool _ruleMayApply(String selectorList, bool Function(String) matches) {
  final List<String> selectors = _splitTopLevel(selectorList, ',');
  for (final String raw in selectors) {
    final String selector = raw.trim();
    if (!selector.startsWith(_glossaryScope)) return true;
    final String? relaxed = _stripPseudos(selector);
    if (relaxed == null) return true;
    if (matches(relaxed)) return true;
  }
  return false;
}

/// 去掉选择器里所有伪类 / 伪元素（含函数式的括号部分）与交互态属性条件（`[open]`）；
/// 去掉后某个复合选择器空了就补 `*`。
/// 返回 null 表示形状不认识（交给调用方按「命中」保守处理）。
String? _stripPseudos(String selector) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < selector.length) {
    final String c = selector[i];
    if (c == '\\') {
      if (i + 1 >= selector.length) return null;
      out.write(selector.substring(i, i + 2));
      i += 2;
      continue;
    }
    if (c == '"' || c == "'") {
      final int end = _skipString(selector, i);
      if (end < 0) return null;
      out.write(selector.substring(i, end));
      i = end;
      continue;
    }
    if (c == '[') {
      final int close = _skipAttribute(selector, i);
      if (close < 0) return null;
      if (_interactiveAttributes.contains(_attributeName(selector, i, close))) {
        // 交互态属性（`details[open]`）：导出时多半是关着的，卡片上点开才出现——与
        // 交互态伪类同样放宽，否则展开后的样式在制卡时就被裁掉了（BUG-3265）。
        _dropSimpleSelector(out, selector, close);
      } else {
        out.write(selector.substring(i, close));
      }
      i = close;
      continue;
    }
    if (c == ':') {
      int j = i + 1;
      if (j < selector.length && selector[j] == ':') j++;
      while (j < selector.length && _isIdentChar(selector[j])) {
        j++;
      }
      if (j < selector.length && selector[j] == '(') {
        final int close = _skipParens(selector, j);
        if (close < 0) return null;
        j = close;
      }
      _dropSimpleSelector(out, selector, j);
      i = j;
      continue;
    }
    out.write(c);
    i++;
  }
  final String result = out.toString().trim();
  return result.isEmpty ? null : result;
}

/// 用户在卡片上点一下就会变的 HTML 属性（不靠脚本）：`<details open>` / `<dialog open>`。
/// 带这些属性条件的规则按「属性不在」判断命中，与 `:hover` 等交互态伪类同一口径。
const Set<String> _interactiveAttributes = <String>{'open'};

/// 去掉了一个简单选择器（伪类 / 交互态属性）之后：它所在的复合选择器若因此空了，补 `*`
/// 占位（`ul > :hover` → `ul > *`）。[next] 是被去掉部分之后的下标。
void _dropSimpleSelector(StringBuffer out, String selector, int next) {
  final String before = out.toString();
  final bool compoundEmpty =
      before.isEmpty || RegExp(r'[\s>+~]$').hasMatch(before);
  final bool compoundContinues =
      next < selector.length && !RegExp(r'[\s>+~,]').hasMatch(selector[next]);
  if (compoundEmpty && !compoundContinues) out.write('*');
}

/// [s] 在 [start] 处是 `[`，返回配对 `]` 之后的下标（跳过引号里的内容）；不闭合返回 -1。
int _skipAttribute(String s, int start) {
  int i = start + 1;
  while (i < s.length) {
    final String c = s[i];
    if (c == '\\') {
      i += 2;
      continue;
    }
    if (c == '"' || c == "'") {
      final int end = _skipString(s, i);
      if (end < 0) return -1;
      i = end;
      continue;
    }
    if (c == ']') return i + 1;
    i++;
  }
  return -1;
}

/// 属性选择器 `[name op value i]`（[start] 是 `[`、[end] 是 `]` 之后）里的属性名，小写。
String _attributeName(String s, int start, int end) {
  final String inner = s.substring(start + 1, end - 1).trimLeft();
  final Match? m = RegExp(r'^(?:[-\w]*\|)?([-\w\u0080-\uffff]+)').firstMatch(inner);
  return m?.group(1)?.toLowerCase() ?? '';
}

bool _isIdentChar(String c) => RegExp(r'[-\w\u0080-￿]').hasMatch(c);

/// [s] 在 [start] 处是引号，返回字符串结束后的下标；不闭合返回 -1。
int _skipString(String s, int start) {
  final String quote = s[start];
  int i = start + 1;
  while (i < s.length) {
    final String c = s[i];
    if (c == '\\') {
      i += 2;
      continue;
    }
    if (c == quote) return i + 1;
    i++;
  }
  return -1;
}

/// [s] 在 [start] 处是 `(`，返回配对 `)` 之后的下标；不闭合返回 -1。
int _skipParens(String s, int start) {
  int depth = 0;
  int i = start;
  while (i < s.length) {
    final String c = s[i];
    if (c == '\\') {
      i += 2;
      continue;
    }
    if (c == '"' || c == "'") {
      final int end = _skipString(s, i);
      if (end < 0) return -1;
      i = end;
      continue;
    }
    if (c == '(') depth++;
    if (c == ')') {
      depth--;
      if (depth == 0) return i + 1;
    }
    i++;
  }
  return -1;
}

/// 按顶层 [separator] 切分（跳过字符串、括号、方括号里的）。
List<String> _splitTopLevel(String s, String separator) {
  final List<String> parts = <String>[];
  int depth = 0;
  int start = 0;
  int i = 0;
  while (i < s.length) {
    final String c = s[i];
    if (c == '\\') {
      i += 2;
      continue;
    }
    if (c == '"' || c == "'") {
      final int end = _skipString(s, i);
      i = end < 0 ? s.length : end;
      continue;
    }
    if (c == '(' || c == '[') depth++;
    if (c == ')' || c == ']') depth--;
    if (c == separator && depth == 0) {
      parts.add(s.substring(start, i));
      start = i + 1;
    }
    i++;
  }
  parts.add(s.substring(start));
  return parts;
}

/// 对一份解析好的释义 DOM 判断选择器是否命中；同一选择器只查一次。
class _SelectorProbe {
  _SelectorProbe(this._document);

  final dom.Document _document;
  final Map<String, bool> _cache = <String, bool>{};

  bool matches(String selector) => _cache.putIfAbsent(selector, () {
    try {
      return _document.querySelector(selector) != null;
    } catch (_) {
      // package:html 不认识的选择器语法：按命中处理，整条规则保留。
      return true;
    }
  });
}

enum _CssKind { style, group, other }

/// 解析后的一条 CSS 语句；[text] 是已压缩的输出形态。
class _CssNode {
  _CssNode.style(this.prelude, String body)
    : kind = _CssKind.style,
      children = const <_CssNode>[],
      _body = body,
      atName = null;

  _CssNode.group(this.prelude, this.atName, this.children)
    : kind = _CssKind.group,
      _body = null;

  _CssNode.other(this.prelude, this.atName, String? body)
    : kind = _CssKind.other,
      children = const <_CssNode>[],
      _body = body;

  final _CssKind kind;
  final String prelude;
  final String? atName;
  final List<_CssNode> children;
  final String? _body;

  _CssNode withChildren(List<_CssNode> next) =>
      _CssNode.group(prelude, atName, next);

  bool get isNamedResource =>
      atName == 'font-face' ||
      atName == 'keyframes' ||
      atName == '-webkit-keyframes';

  /// `@font-face` 的 font-family / `@keyframes` 的名字。
  String? get resourceName {
    if (atName == 'font-face') {
      final RegExpMatch? m = RegExp(
        r'font-family\s*:\s*([^;}]+)',
        caseSensitive: false,
      ).firstMatch(_body ?? '');
      return m?.group(1)?.trim().replaceAll(RegExp(r'''^["']|["']$'''), '');
    }
    if (atName == 'keyframes' || atName == '-webkit-keyframes') {
      return prelude
          .replaceFirst(RegExp(r'^@[-\w]+', caseSensitive: false), '')
          .trim()
          .replaceAll(RegExp(r'''^["']|["']$'''), '');
    }
    return null;
  }

  String get text => switch (kind) {
    _CssKind.style => '$prelude{$_body}',
    _CssKind.group => '$prelude{${children.map((n) => n.text).join()}}',
    _CssKind.other => _body == null ? '$prelude;' : '$prelude{$_body}',
  };
}

/// 最小的 CSS 语句解析器：认识注释、字符串、转义、嵌套块，不做声明级解析。
class _CssParser {
  _CssParser(this._s);

  final String _s;
  int _i = 0;

  static const Set<String> _groupAtRules = <String>{
    'media',
    'supports',
    'container',
    'layer',
    'scope',
    'document',
    '-moz-document',
  };

  /// [nested] 为 true 时遇到 `}` 即本块结束；顶层的多余 `}` 直接跳过（浏览器同样忽略）。
  List<_CssNode> parseBlockContents({required bool nested}) {
    final List<_CssNode> nodes = <_CssNode>[];
    while (true) {
      _skipWhitespaceAndComments();
      if (_i >= _s.length) break;
      if (_s[_i] == '}') {
        _i++;
        if (nested) break;
        continue;
      }
      final int preludeStart = _i;
      final int stop = _scanPrelude();
      final String prelude = _minify(_s.substring(preludeStart, stop));
      if (stop >= _s.length) {
        // 结尾残缺的语句（没有块、没有分号）：原样带上，不丢内容。
        if (prelude.isNotEmpty) nodes.add(_CssNode.other(prelude, null, null));
        break;
      }
      final bool isAt = prelude.startsWith('@');
      final String? atName = isAt
          ? RegExp(r'^@([-\w]+)').firstMatch(prelude)?.group(1)?.toLowerCase()
          : null;
      if (_s[stop] == ';') {
        _i = stop + 1;
        nodes.add(_CssNode.other(prelude, atName, null));
        continue;
      }
      // `{`
      _i = stop + 1;
      if (isAt && _groupAtRules.contains(atName)) {
        final List<_CssNode> children = parseBlockContents(nested: true);
        // `@layer a, b;` 已走分号分支；块形式的 @layer 与 @media 一样递归。
        nodes.add(_CssNode.group(prelude, atName, children));
        continue;
      }
      final int bodyStart = _i;
      final int bodyEnd = _scanBlockEnd();
      final String body = _minify(_s.substring(bodyStart, bodyEnd));
      _i = bodyEnd < _s.length ? bodyEnd + 1 : bodyEnd;
      nodes.add(
        isAt
            ? _CssNode.other(prelude, atName, body)
            : _CssNode.style(prelude, body),
      );
    }
    return nodes;
  }

  void _skipWhitespaceAndComments() {
    while (_i < _s.length) {
      if (_isSpace(_s[_i])) {
        _i++;
      } else if (_s.startsWith('/*', _i)) {
        final int end = _s.indexOf('*/', _i + 2);
        _i = end < 0 ? _s.length : end + 2;
      } else {
        break;
      }
    }
  }

  /// 从 [_i] 扫到顶层的 `{` 或 `;`（跳过字符串、注释、括号），返回其下标；没有则返回长度。
  int _scanPrelude() {
    int depth = 0;
    int i = _i;
    while (i < _s.length) {
      final String c = _s[i];
      if (c == '\\') {
        i += 2;
        continue;
      }
      if (c == '"' || c == "'") {
        final int end = _skipString(_s, i);
        i = end < 0 ? _s.length : end;
        continue;
      }
      if (_s.startsWith('/*', i)) {
        final int end = _s.indexOf('*/', i + 2);
        i = end < 0 ? _s.length : end + 2;
        continue;
      }
      if (c == '(' || c == '[') depth++;
      if (c == ')' || c == ']') depth--;
      if (depth <= 0 && (c == '{' || c == ';')) return i;
      i++;
    }
    return _s.length;
  }

  /// 从 [_i]（块内第一个字符）扫到配对的 `}`，返回其下标；不闭合返回长度。
  int _scanBlockEnd() {
    int depth = 1;
    int i = _i;
    while (i < _s.length) {
      final String c = _s[i];
      if (c == '\\') {
        i += 2;
        continue;
      }
      if (c == '"' || c == "'") {
        final int end = _skipString(_s, i);
        i = end < 0 ? _s.length : end;
        continue;
      }
      if (_s.startsWith('/*', i)) {
        final int end = _s.indexOf('*/', i + 2);
        i = end < 0 ? _s.length : end + 2;
        continue;
      }
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return i;
      }
      i++;
    }
    return _s.length;
  }
}

bool _isSpace(String c) =>
    c == ' ' || c == '\n' || c == '\r' || c == '\t' || c == '\f';

/// 去注释、把字符串外的连续空白压成一个空格，并去掉 `{ } ; ,` 两侧的空白。
///
/// 冒号两侧不动：选择器里 `a :hover` 与 `a:hover` 含义不同。
String _minify(String text) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  bool pendingSpace = false;
  void flushSpace(String next) {
    if (!pendingSpace) return;
    pendingSpace = false;
    final String current = out.toString();
    if (current.isEmpty) return;
    final String last = current[current.length - 1];
    if ('{};,'.contains(last) || '{};,'.contains(next)) return;
    out.write(' ');
  }

  while (i < text.length) {
    final String c = text[i];
    if (text.startsWith('/*', i)) {
      final int end = text.indexOf('*/', i + 2);
      i = end < 0 ? text.length : end + 2;
      pendingSpace = true;
      continue;
    }
    if (_isSpace(c)) {
      pendingSpace = true;
      i++;
      continue;
    }
    if (c == '"' || c == "'") {
      final int end = _skipString(text, i);
      final int stop = end < 0 ? text.length : end;
      flushSpace(c);
      out.write(text.substring(i, stop));
      i = stop;
      continue;
    }
    if (c == '\\' && i + 1 < text.length) {
      flushSpace(c);
      out.write(text.substring(i, i + 2));
      i += 2;
      continue;
    }
    flushSpace(c);
    out.write(c);
    i++;
  }
  String result = out.toString();
  // 去掉声明块末尾多余的分号前空白已由上面处理；末尾分号保留（无害）。
  result = result.trim();
  return result;
}
