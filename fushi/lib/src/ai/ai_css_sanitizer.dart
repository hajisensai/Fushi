/// AI 产出的补充 CSS 的白名单校验器。
///
/// 两个样式类 AI 功能（词典弹窗样式、Lapis 卡片样式）都让模型在结构化规则之外
/// 再补一段自由 CSS；这段 CSS 最终会被注入真实 WebView / Anki 卡片，所以**不能
/// 原样信任**：模型偶尔会写 `body{}` 这种把整个弹窗底色改掉的规则、`@import`
/// 拉外部资源、或 `url(` 指向不存在的路径。这里按「规则块」为单位做保守过滤——
/// 选择器必须锚在已知选择器集合里，含危险 token 的块整块丢弃，其余块原样保留。
///
/// 纯 Dart、零依赖，故意不做完整 CSS 解析：输入是模型刚生成的短片段，宁可多丢
/// 一块也不放过一块。
library;

/// 在选择器 / 声明里出现即整块丢弃的 token（不分大小写）。
///
/// `url(` 一并禁掉是有意的：词典弹窗和 Anki 卡片里没有 AI 能合法引用的资源路径，
/// 放行只会得到一条永远 404 的背景图。
const List<String> kAiCssForbiddenTokens = <String>[
  '@import',
  'url(',
  'expression(',
  'javascript:',
  '<script',
  'behavior:',
  '-moz-binding',
];

/// 允许递归进入的条件 at-rule 前缀；其它 `@` 规则（`@import`/`@font-face`/
/// `@keyframes`…）整块丢弃。
const List<String> _kAiCssNestedAtRules = <String>[
  '@media',
  '@supports',
  '@container',
];

/// 一块顶层 CSS 规则：`prelude { body }`。
class _CssBlock {
  const _CssBlock({required this.prelude, required this.body});

  final String prelude;
  final String body;
}

/// 按白名单过滤一段 CSS。
///
/// [allowedSelectors] 是「简单选择器 token」集合（形如 `.entry`、`#hint`、
/// `summary.dict-label`）。一个复合选择器只要**包含**其中任一 token（且 token
/// 之后不再紧跟标识符字符，避免 `.entry` 误放行 `.entry-foo`）就算锚定成功；
/// 一个块的逗号列表里只保留锚定成功的选择器，全军覆没则整块丢弃。
///
/// 通配 `*`（属性选择器 `[attr*=x]` 里的除外）、裸 `body` / `html` / 元素选择器
/// 都没有 token 可锚，自然被丢掉。
String sanitizeAiCss(String css, {required Iterable<String> allowedSelectors}) {
  final List<String> tokens = allowedSelectors
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList();
  final List<String> kept = <String>[];
  for (final _CssBlock block in _splitCssBlocks(_stripCssComments(css))) {
    final String? sanitized = _sanitizeBlock(block, tokens);
    if (sanitized != null) {
      kept.add(sanitized);
    }
  }
  return kept.join('\n\n');
}

String? _sanitizeBlock(_CssBlock block, List<String> tokens) {
  final String prelude = block.prelude.trim();
  if (prelude.isEmpty) {
    return null;
  }
  if (_containsForbiddenToken(prelude)) {
    return null;
  }
  if (prelude.startsWith('@')) {
    final String lower = prelude.toLowerCase();
    final bool nested = _kAiCssNestedAtRules.any(
      (String rule) => lower.startsWith(rule),
    );
    if (!nested) {
      return null;
    }
    // 条件 at-rule 的正文本身又是一组规则块，递归过滤后非空才保留外壳。
    final String inner = sanitizeAiCss(block.body, allowedSelectors: tokens);
    if (inner.trim().isEmpty) {
      return null;
    }
    return '$prelude {\n${_indent(inner)}\n}';
  }
  final String body = block.body.trim();
  if (body.isEmpty || _containsForbiddenToken(body)) {
    return null;
  }
  final List<String> selectors = prelude
      .split(',')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty && _isAnchoredSelector(s, tokens))
      .toList();
  if (selectors.isEmpty) {
    return null;
  }
  return '${selectors.join(', ')} {\n${_indent(_normalizeDeclarations(body))}\n}';
}

bool _containsForbiddenToken(String text) {
  final String lower = text.toLowerCase();
  return kAiCssForbiddenTokens.any(lower.contains);
}

/// 选择器是否锚定在某个允许的 token 上。
bool _isAnchoredSelector(String selector, List<String> tokens) {
  // 属性选择器里的 `*=` 是合法语法，先抠掉再判通配。
  final String withoutAttrs = selector.replaceAll(RegExp(r'\[[^\]]*\]'), '');
  if (withoutAttrs.contains('*')) {
    return false;
  }
  for (final String token in tokens) {
    int from = 0;
    while (true) {
      final int at = selector.indexOf(token, from);
      if (at < 0) {
        break;
      }
      final int end = at + token.length;
      final bool boundaryOk =
          end >= selector.length || !_isIdentChar(selector.codeUnitAt(end));
      if (boundaryOk) {
        return true;
      }
      from = at + 1;
    }
  }
  return false;
}

bool _isIdentChar(int code) =>
    (code >= 0x30 && code <= 0x39) || // 0-9
    (code >= 0x41 && code <= 0x5A) || // A-Z
    (code >= 0x61 && code <= 0x7A) || // a-z
    code == 0x2D || // -
    code == 0x5F; // _

String _stripCssComments(String css) =>
    css.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');

/// 把 `a:b;c:d` 这种挤在一行的声明拆成一行一条，方便用户在编辑器里读。
String _normalizeDeclarations(String body) {
  final List<String> lines = body
      .split(';')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .map((String s) => '$s;')
      .toList();
  return lines.join('\n');
}

String _indent(String text) => text
    .split('\n')
    .map((String line) => line.isEmpty ? line : '  $line')
    .join('\n');

/// 把 CSS 拆成顶层 `prelude { body }` 块。花括号配平时跳过字符串字面量。
List<_CssBlock> _splitCssBlocks(String css) {
  final List<_CssBlock> blocks = <_CssBlock>[];
  int i = 0;
  while (i < css.length) {
    final int open = _indexOfBraceOutsideString(css, '{', i);
    if (open < 0) {
      break;
    }
    final String prelude = css.substring(i, open);
    int depth = 0;
    int j = open;
    int close = -1;
    String? quote;
    while (j < css.length) {
      final String ch = css[j];
      if (quote != null) {
        if (ch == r'\') {
          j += 1;
        } else if (ch == quote) {
          quote = null;
        }
      } else if (ch == '"' || ch == "'") {
        quote = ch;
      } else if (ch == '{') {
        depth += 1;
      } else if (ch == '}') {
        depth -= 1;
        if (depth == 0) {
          close = j;
          break;
        }
      }
      j += 1;
    }
    if (close < 0) {
      // 括号不配平：后面这段没法安全判定，整段放弃。
      break;
    }
    blocks.add(
      _CssBlock(prelude: prelude, body: css.substring(open + 1, close)),
    );
    i = close + 1;
  }
  return blocks;
}

int _indexOfBraceOutsideString(String css, String brace, int from) {
  String? quote;
  for (int i = from; i < css.length; i += 1) {
    final String ch = css[i];
    if (quote != null) {
      if (ch == r'\') {
        i += 1;
      } else if (ch == quote) {
        quote = null;
      }
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
    } else if (ch == brace) {
      return i;
    }
  }
  return -1;
}
