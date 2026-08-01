import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// 最小词法扫描：把注释（可选：字符串字面量）替换成**等长空白**
// ---------------------------------------------------------------------------
//
// 为什么必须「等长」而不是「删掉」：所有守卫都用 indexOf/substring 在源码上切片。
// 只要掩码后长度与换行位置与原文逐字节一致，就能在掩码串上算下标、回原串上取子串。
// 删除式剥离（`replaceAll(..., '')`）做不到这点，切片会整体错位。
//
// 为什么必须词法扫描而不是「按行看开头 + 引号数量启发式」：
// - `/* needle */` 既不以 `//` 开头也不以 `*` 开头，行式规则一概放行 ⇒ 要求型断言
//   （isTrue）可以被「把断言字面量塞进块注释」骗绿；
// - 「含引号的行整行放行」是用「可能漏剪」换「可能误剪」的权宜之计，
//   `final u = 'https://x/a'; // Fnv1a` 会把注释里的 Fnv1a 当命中；
// - 三引号多行串（全仓 27 个 .dart 在用，lib/src/reader/ 注入 JS/CSS 占 6 个）里的
//   花括号会把 methodBody 的配对扫描当场带偏。
// 三类洞的成因是同一个：没有真的分辨「这个字符处在什么词法状态里」。

void _emit(StringBuffer out, String c, bool mask) {
  if (!mask) {
    out.write(c);
  } else {
    out.write(c == '\n' ? '\n' : ' ');
  }
}

final RegExp _identifierChar = RegExp(r'[A-Za-z0-9_$]');

/// 扫一段字符串字面量，从开引号处 [i] 起，返回闭引号之后的下标。
///
/// 认得：单/双引号、三引号多行串、`r` 前缀原始串、反斜杠转义、`${...}` 插值
/// （插值内部是真代码，可能再含引号与花括号，按深度配对跳过）。
///
/// [tripleSpans] 非空时，把每个**三引号串的内容区间** `[起, 止)` 追加进去（不含引号
/// 本身）。这是 [maskCommentsAndScriptLines] 用来定位「内嵌 JS/CSS 语料」的唯一依据：
/// 本仓把大段脚本放在三引号串里，而单引号串里放的多半是 URL 之类的普通常量，两者
/// 必须区别对待，否则 `'https://x'` 会被 JS 词法器当成 `https:` + 行注释砍掉。
int _scanStringLiteral(
  String src,
  int i,
  StringBuffer out, {
  required bool mask,
  required bool raw,
  List<List<int>>? tripleSpans,
}) {
  final int n = src.length;
  final String quote = src[i];
  final bool triple = i + 2 < n && src[i + 1] == quote && src[i + 2] == quote;
  final int quoteLen = triple ? 3 : 1;
  for (int k = 0; k < quoteLen; k++) {
    _emit(out, quote, mask);
  }
  i += quoteLen;
  final int contentStart = i;
  while (i < n) {
    final String c = src[i];
    if (!raw && c == r'\' && i + 1 < n) {
      _emit(out, c, mask);
      _emit(out, src[i + 1], mask);
      i += 2;
      continue;
    }
    if (!triple && c == '\n') {
      // 单行串没闭合（源码本就不该出现）：就地收口，绝不把文件剩余部分吞成串。
      out.write('\n');
      return i + 1;
    }
    if (c == quote) {
      if (!triple) {
        _emit(out, c, mask);
        return i + 1;
      }
      if (i + 2 < n && src[i + 1] == quote && src[i + 2] == quote) {
        for (int k = 0; k < 3; k++) {
          _emit(out, quote, mask);
        }
        tripleSpans?.add(<int>[contentStart, i]);
        return i + 3;
      }
    }
    if (!raw && c == r'$' && i + 1 < n && src[i + 1] == '{') {
      _emit(out, c, mask);
      _emit(out, '{', mask);
      i += 2;
      int depth = 1;
      while (i < n && depth > 0) {
        final String d = src[i];
        if (d == "'" || d == '"') {
          i = _scanStringLiteral(src, i, out,
              mask: mask, raw: false, tripleSpans: tripleSpans);
          continue;
        }
        if (d == '{') depth++;
        if (d == '}') depth--;
        _emit(out, d, mask);
        i++;
      }
      continue;
    }
    _emit(out, c, mask);
    i++;
  }
  return i;
}

String _mask(
  String source, {
  required bool lineComments,
  required bool stringLiterals,
  required bool maskStringContent,
  bool nestedBlockComments = true,
  List<List<int>>? tripleSpans,
}) {
  final StringBuffer out = StringBuffer();
  final int n = source.length;
  int i = 0;
  while (i < n) {
    final String c = source[i];
    if (lineComments && c == '/' && i + 1 < n && source[i + 1] == '/') {
      while (i < n && source[i] != '\n') {
        out.write(' ');
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < n && source[i + 1] == '*') {
      // Dart 的块注释**可嵌套**，按深度收口；CSS / JS 的**不嵌套**，首个 `*/` 就收口。
      // 拿 Dart 规则去扫 CSS 会在「注释掉一段本身含注释的规则」时把文件剩余部分整段
      // 吞掉（深度永远回不到 0）——那之后所有断言都对着空串跑，静默全绿。
      int depth = 0;
      while (i < n) {
        if (nestedBlockComments &&
            source[i] == '/' &&
            i + 1 < n &&
            source[i + 1] == '*') {
          depth++;
          out.write('  ');
          i += 2;
          continue;
        }
        if (!nestedBlockComments && depth == 0) {
          depth = 1;
          out.write('  ');
          i += 2;
          continue;
        }
        if (source[i] == '*' && i + 1 < n && source[i + 1] == '/') {
          depth--;
          out.write('  ');
          i += 2;
          if (depth <= 0) break;
          continue;
        }
        out.write(source[i] == '\n' ? '\n' : ' ');
        i++;
      }
      continue;
    }
    if (stringLiterals) {
      if (c == "'" || c == '"') {
        i = _scanStringLiteral(source, i, out,
            mask: maskStringContent, raw: false, tripleSpans: tripleSpans);
        continue;
      }
      if ((c == 'r' || c == 'R') &&
          i + 1 < n &&
          (source[i + 1] == "'" || source[i + 1] == '"') &&
          (i == 0 || !_identifierChar.hasMatch(source[i - 1]))) {
        _emit(out, c, maskStringContent);
        i = _scanStringLiteral(source, i + 1, out,
            mask: maskStringContent, raw: true, tripleSpans: tripleSpans);
        continue;
      }
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 把 Dart / C++ / JS 源码里的 `//` 行注释与 `/* */` 块注释换成等长空白，
/// **字符串字面量原样保留**（`'https://x'` 里的 `//` 不会被当注释）。
///
/// 长度与换行位置与 [source] 逐字节一致，可直接拿掩码串的下标回原串切片。
String maskComments(String source) => _mask(
      source,
      lineComments: true,
      stringLiterals: true,
      maskStringContent: false,
    );

/// 同 [maskComments]，并把字符串字面量的内容也换成空白。
///
/// 用于花括号 / 圆括号配对这类**结构**扫描：串里的花括号（尤其是三引号里注入的
/// JS/CSS）不再参与配对。
String maskCommentsAndStrings(String source) => _mask(
      source,
      lineComments: true,
      stringLiterals: true,
      maskStringContent: true,
    );

/// CSS 版：只剥 `/* */`（CSS 没有 `//` 注释，也不按 Dart 规则解析引号）。
/// CSS 的块注释**不嵌套**，首个 `*/` 收口。同样等长，可直接拿下标回原串切片。
String maskCssComments(String source) => _mask(
      source,
      lineComments: false,
      stringLiterals: false,
      maskStringContent: false,
      nestedBlockComments: false,
    );

/// HTML 版：把 `<!-- ... -->` 换成等长空白。
///
/// 为什么不能用 `replaceAll(RegExp(r'<!--.*?-->'), '')`：删除式剥离会让后续
/// `indexOf` 的下标与原文错位，「meta 是否出现在第一个 script 之前」这类**位置**断言
/// 就只能在删除后的串里自洽，一旦还要回原串取证就全错。等长掩码没有这个问题。
String maskHtmlComments(String source) {
  final StringBuffer out = StringBuffer();
  final int n = source.length;
  int i = 0;
  while (i < n) {
    if (source.startsWith('<!--', i)) {
      final int end = source.indexOf('-->', i + 4);
      final int stop = end < 0 ? n : end + 3;
      for (int k = i; k < stop; k++) {
        out.write(source[k] == '\n' ? '\n' : ' ');
      }
      i = stop;
      continue;
    }
    out.write(source[i]);
    i++;
  }
  return out.toString();
}

// ---------------------------------------------------------------------------
// JS 词法掩码
// ---------------------------------------------------------------------------
//
// 为什么 Dart 那套掩码扫 JS 会出错：JS 多了两种 Dart 没有的词法状态，而它们都能
// 藏住 `/`：
// - **模板串** `` `a ${b} c` ``：反引号在 Dart 里不是引号，[maskComments] 会把
//   模板串里的 `//` 当行注释砍掉（假红），或把 `'` 当串起点后一路错到文件尾；
// - **正则字面量** `/^https?:\/\//i`：里面就写着 `//`。按 Dart 规则扫，`/` 后面的
//   `/` 触发行注释，从这里到行尾整段被抹掉——被守的代码凭空消失，要求型断言变红、
//   禁止型断言变假绿。`str.split('/')` 这类除号/正则歧义同理。
//
// 所以 JS 语料必须用 JS 的词法器。下面这套认：`//`、`/* */`（JS 不嵌套）、
// `'` / `"` 串、模板串（含 `${}` 里的真代码）、正则字面量（含 `[...]` 字符类里
// 不收口的 `/`）。仍然**等长**，下标可回原串切片。

/// 正则字面量前**允许**出现的字符。JS 里 `/` 是正则还是除号只能靠前一个有意义
/// token 判定：这些之后必然是「求值起点」，`/` 只能是正则开头。
///
/// `)` 与 `]` 有意不在表里（`(a+b)/2`、`arr[0]/2` 是除法）；`}` 在表里，因为语句块
/// 收口后跟正则是常见写法，而「对象字面量除以某数」在真实代码里不存在。
const String _kJsRegexAllowedAfter = r'(,=:[!&|?{};+-*%^~<>';

/// 这些关键字之后的 `/` 也只能是正则。
const Set<String> _kJsRegexAllowedKeywords = <String>{
  'return',
  'typeof',
  'instanceof',
  'in',
  'of',
  'new',
  'delete',
  'void',
  'throw',
  'do',
  'else',
  'yield',
  'await',
  'case',
};

/// 从 [i]（一个 `/`）起试着扫一条正则字面量，返回**标志位之后**的下标；
/// 不是合法正则（跨行未收口 / 空正则）返回 -1。
///
/// 先试扫再决定，避免「进了正则状态才发现不对」需要回退 [StringBuffer]。
int _jsRegexEnd(String src, int i) {
  final int n = src.length;
  int j = i + 1;
  if (j < n && (src[j] == '/' || src[j] == '*')) return -1; // 是注释不是正则。
  bool inClass = false;
  while (j < n) {
    final String c = src[j];
    if (c == '\n') return -1; // 正则不能跨行 ⇒ 这个 `/` 是除号或别的东西。
    if (c == r'\') {
      j += 2;
      continue;
    }
    if (c == '[') inClass = true;
    if (c == ']') inClass = false;
    if (c == '/' && !inClass) {
      j++;
      while (j < n && _identifierChar.hasMatch(src[j])) {
        j++; // 标志位 gimsuy。
      }
      return j;
    }
    j++;
  }
  return -1;
}

/// JS 词法掩码器。
///
/// 用类而不是一串嵌套闭包，是因为「代码 → 模板串 → `${}` 里又是代码」必须**互相
/// 递归**：插值里可以再写注释、正则、模板串。第一版把插值当成「按花括号深度跳过」
/// 的哑循环，结果 `${f(/* x */ 1)}` 里的注释掩不掉——单测当场抓到。
class _JsMasker {
  _JsMasker(this.src, {required this.maskLiteralContent});

  final String src;
  final bool maskLiteralContent;
  final StringBuffer out = StringBuffer();

  /// 最近一个有意义字符与它所在的标识符。注释是透明的，不更新这两个。
  String _lastChar = '';
  String _lastWord = '';

  int get _n => src.length;

  void _note(String c) {
    if (c.trim().isEmpty) return;
    if (_identifierChar.hasMatch(c)) {
      _lastWord = _identifierChar.hasMatch(_lastChar) ? '$_lastWord$c' : c;
    } else {
      _lastWord = '';
    }
    _lastChar = c;
  }

  /// 刚吐出一个「值」（串 / 模板 / 正则）：其后的 `/` 必然是除号。
  void _noteValue(String c) {
    _lastChar = c;
    _lastWord = '';
  }

  bool get _regexAllowed {
    if (_lastChar.isEmpty) return true;
    if (_identifierChar.hasMatch(_lastChar)) {
      return _kJsRegexAllowedKeywords.contains(_lastWord);
    }
    return _kJsRegexAllowedAfter.contains(_lastChar);
  }

  /// 是注释就整段掩成等长空白并返回注释后的下标；不是返回 -1。
  int _scanComment(int i) {
    if (i + 1 >= _n || src[i] != '/') return -1;
    if (src[i + 1] == '/') {
      int j = i;
      while (j < _n && src[j] != '\n') {
        out.write(' ');
        j++;
      }
      return j;
    }
    if (src[i + 1] == '*') {
      // JS 的块注释**不嵌套**：首个 `*/` 就收口（写成嵌套是语法错）。
      out.write('  ');
      int j = i + 2;
      while (j < _n) {
        if (src[j] == '*' && j + 1 < _n && src[j + 1] == '/') {
          out.write('  ');
          return j + 2;
        }
        out.write(src[j] == '\n' ? '\n' : ' ');
        j++;
      }
      return j;
    }
    return -1;
  }

  /// 扫 `'` / `"` 串：JS 的单双引号串不跨行（`\` 续行按转义吃掉）。
  int _scanQuoted(int i) {
    final String quote = src[i];
    _emit(out, quote, maskLiteralContent);
    int j = i + 1;
    while (j < _n) {
      final String c = src[j];
      if (c == r'\' && j + 1 < _n) {
        _emit(out, c, maskLiteralContent);
        _emit(out, src[j + 1], maskLiteralContent);
        j += 2;
        continue;
      }
      if (c == '\n') {
        out.write('\n');
        return j + 1; // 未闭合：就地收口，绝不吞掉文件剩余部分。
      }
      _emit(out, c, maskLiteralContent);
      j++;
      if (c == quote) return j;
    }
    return j;
  }

  /// 扫模板串。`${}` 里是**真代码**，交回 [_scanCode] 递归处理。
  int _scanTemplate(int i) {
    _emit(out, '`', maskLiteralContent);
    int j = i + 1;
    while (j < _n) {
      final String c = src[j];
      if (c == r'\' && j + 1 < _n) {
        _emit(out, c, maskLiteralContent);
        _emit(out, src[j + 1], maskLiteralContent);
        j += 2;
        continue;
      }
      if (c == '`') {
        _emit(out, c, maskLiteralContent);
        return j + 1;
      }
      if (c == r'$' && j + 1 < _n && src[j + 1] == '{') {
        _emit(out, c, maskLiteralContent);
        _emit(out, '{', maskLiteralContent);
        j = _scanCode(j + 2, stopAtCloseBrace: true);
        if (j < _n && src[j] == '}') {
          _emit(out, '}', maskLiteralContent);
          j++;
        }
        continue;
      }
      _emit(out, c, maskLiteralContent);
      j++;
    }
    return j;
  }

  /// 扫一段代码，直到源码末尾；[stopAtCloseBrace] 时在**多余的** `}` 处停下
  /// 并把它留给调用方（模板插值的收口）。
  int _scanCode(int i, {required bool stopAtCloseBrace}) {
    int depth = 0;
    while (i < _n) {
      final String c = src[i];
      final int afterComment = _scanComment(i);
      if (afterComment >= 0) {
        i = afterComment;
        continue;
      }
      if (c == '/' && _regexAllowed) {
        final int end = _jsRegexEnd(src, i);
        if (end > 0) {
          for (int k = i; k < end; k++) {
            _emit(out, src[k], maskLiteralContent);
          }
          i = end;
          _noteValue('/');
          continue;
        }
      }
      if (c == "'" || c == '"') {
        i = _scanQuoted(i);
        _noteValue(c);
        continue;
      }
      if (c == '`') {
        i = _scanTemplate(i);
        _noteValue('`');
        continue;
      }
      if (c == '}') {
        if (stopAtCloseBrace && depth == 0) return i;
        depth--;
      }
      if (c == '{') depth++;
      out.write(c);
      _note(c);
      i++;
    }
    return i;
  }

  String run() {
    _scanCode(0, stopAtCloseBrace: false);
    return out.toString();
  }
}

String _maskJs(String source, {required bool maskLiteralContent}) =>
    _JsMasker(source, maskLiteralContent: maskLiteralContent).run();

/// 把 **JS 源码**里的 `//` 行注释与 `/* */` 块注释换成等长空白，串 / 模板串 /
/// 正则字面量的内容原样保留。
///
/// 扫 `.js` 资产（`assets/`、`tools/browser-extension/`、`lib/src/reader/` 注入的
/// 脚本）的守卫一律用它，别用 [maskComments]——后者不认模板串与正则字面量，
/// `/^https?:\/\//i` 会被当成「除号 + 行注释」，从正则处到行尾整段凭空消失。
String maskJsComments(String source) =>
    _maskJs(source, maskLiteralContent: false);

/// 同 [maskJsComments]，并把串 / 模板串 / 正则的内容也换成空白。
///
/// 用于 JS 上的花括号 / 圆括号**结构**扫描（见 [methodBody] 的 [SourceLexicon.js]）：
/// 串里的花括号不再参与配对。
String maskJsCommentsAndStrings(String source) =>
    _maskJs(source, maskLiteralContent: true);

/// 取 [src] 里所有**三引号串的内容区间** `[起, 止)`。
List<List<int>> _tripleQuotedSpans(String src) {
  final List<List<int>> spans = <List<int>>[];
  _mask(
    src,
    lineComments: true,
    stringLiterals: true,
    maskStringContent: false,
    tripleSpans: spans,
  );
  return spans;
}

/// [maskComments] 的超集，专供**「Dart 文件里用三引号串装 JS/CSS」**这种语料：
/// 先按 Dart 词法掩码，再对每个三引号串的内容按 **JS 词法**掩一遍。
///
/// 为什么需要它：本仓有一批 Dart 文件把大段 JS/CSS 放在三引号串里
/// （`reader_hibiki/webview.part.dart`、`reader_visual_novel_scripts.dart`、
/// `reader_content_styles.dart`）。[maskComments] **按设计保留串内容**（这样
/// `'https://x'` 里的 `//` 才不会被当注释砍掉），代价是串内的 JS/CSS 注释原样留着，
/// 扫这些语料的守卫会被一条 JS 注释骗绿。
///
/// 为什么只对**三引号**串套 JS 词法、不对全文件套：单引号串里放的多半是 URL 之类
/// 的普通常量，`'https://x'` 交给 JS 词法器会被读成 `https:` + 行注释而砍掉半行。
/// 三引号串是本仓「这里面是脚本」的事实约定，边界就取在这里。
///
/// 相对旧版「整行以 `//` 开头就掩掉」的改进：行尾注释（`foo(); // note`）、块注释
/// （`/* note */`）现在都掩得掉，而模板串与正则字面量里的 `//` 不再被误砍。为了
/// 绝不比旧版**放松**，整行 `//` 那一遍仍然保留（取并集）。
String maskCommentsAndScriptLines(String source) {
  final List<String> chars = maskComments(source).split('');
  for (final List<int> span in _tripleQuotedSpans(source)) {
    final String masked = maskJsComments(source.substring(span[0], span[1]));
    for (int k = 0; k < masked.length; k++) {
      // JS 掩码只会把字符变空白，不会引入新内容：原本已被 Dart 掩掉的位置保持空白。
      if (masked[k] == ' ' || masked[k] == '\n') chars[span[0] + k] = masked[k];
    }
  }
  final List<String> masked = chars.join().split('\n');
  final List<String> original = source.split('\n');
  for (int i = 0; i < masked.length; i++) {
    if (original[i].trimLeft().startsWith('//')) {
      masked[i] = ' ' * masked[i].length;
    }
  }
  return masked.join('\n');
}

// ---------------------------------------------------------------------------
// 窗口原语
// ---------------------------------------------------------------------------

/// 源码扫描守卫的共享窗口原语。
///
/// 源码守卫经常要「只在某个方法体内」断言，旧写法是 `src.substring(start, start + 800)`
/// 或 `src.indexOf('  }', start)`：
/// - 固定字符窗口随方法体变长/变短而漂移，方法一重构断言就凭空变假；
/// - `'  }'` 会命中任意更深缩进行的尾部，方法体里出现第一个嵌套块窗口就被截断。
///
/// 两种漂移都不是「行为退化」，而是守卫自身塌掉——本仓已因此在 CI 上红过。
/// [methodBody] 用花括号配对定边界：窗口由源码结构决定，与长度、嵌套无关。
///
/// 三处词法保护：
/// - 签名在**注释里**首现时不再锚错（先掩码注释再 indexOf）；
/// - 命名参数 `foo({required int a})` 的左花括号在参数表里，先把参数表圆括号配对掉；
/// - 方法体里字符串（含三引号 JS/CSS）与注释中的花括号不参与配对。
///
/// 找不到签名、找不到左花括号、花括号不配对一律 `fail`，绝不返回空串——
/// 空串会让后续 `contains` 静默变假，是最典型的假绿源。
/// 被扫描语料的词法族。决定 [methodBody] 用哪套掩码去找签名与配对花括号。
///
/// [SourceLexicon.dart] 同时适用 C++（`//`、`/* */`、单双引号，规则一致；C++ 的
/// 原始串 `R"(...)"` 不认，目标文件里有就别用结构窗口）。
/// [SourceLexicon.js] 额外认模板串与正则字面量。
enum SourceLexicon { dart, js }

String methodBody(
  String src,
  String signature, {
  SourceLexicon lexicon = SourceLexicon.dart,
}) {
  // 找签名：只掩码注释（签名可能落在被扫描的字符串语料里，串要保留）。
  final String searchable =
      lexicon == SourceLexicon.js ? maskJsComments(src) : maskComments(src);
  // 配对：注释与字符串都掩掉，只剩真结构。
  final String structural = lexicon == SourceLexicon.js
      ? maskJsCommentsAndStrings(src)
      : maskCommentsAndStrings(src);
  final int start = searchable.indexOf(signature);
  if (start < 0) {
    fail('源码中找不到方法签名（注释内的同名文本不算）：$signature');
  }
  int bodySearchFrom = start;
  final int firstBrace = structural.indexOf('{', start);
  final int paren = structural.indexOf('(', start);
  if (paren >= 0 && firstBrace >= 0 && paren < firstBrace) {
    int parenDepth = 0;
    for (int i = paren; i < structural.length; i++) {
      if (structural[i] == '(') parenDepth++;
      if (structural[i] == ')') {
        parenDepth--;
        if (parenDepth == 0) {
          bodySearchFrom = i;
          break;
        }
      }
    }
    if (parenDepth != 0) {
      fail('方法签名的参数表圆括号不配对：$signature');
    }
  }
  final int open = structural.indexOf('{', bodySearchFrom);
  if (open < 0) {
    fail('方法签名后找不到左花括号：$signature');
  }
  int depth = 0;
  for (int i = open; i < structural.length; i++) {
    final String c = structural[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  fail('方法体花括号不配对：$signature');
}

/// 在 [body] 的**代码行**上查找 [needle]，注释里的同名文本不算数。
///
/// 裸 `body.contains('foo()')` 会被注释里的同名字面量喂成假绿——本仓一天抓到过 6 起
/// 这种守卫假绿。这里先做词法掩码（`//` 行注释、`/* */` 块注释，含跨行块注释里
/// 不以 `*` 开头的行），再逐行找；字符串字面量保留，`'https://…'` 不会被拦腰砍掉，
/// 而含引号行的**行尾**注释仍被正确剪除。
bool containsCodeLine(String body, String needle) {
  for (final String line in maskComments(body).split('\n')) {
    if (line.contains(needle)) return true;
  }
  return false;
}

/// 构造「以独立标识符身份出现的 [name] 调用/构造」的正则。
///
/// 源码守卫里最常见的判据是裸字面量 `contains('Image(')`。这个写法**两个方向都错**：
/// - **漏真阳**：真实写法多半带命名构造器（`Image.file(` / `Image.memory(` /
///   `Image.network(` / `Image.asset(`），`Image` 后面是点不是括号，子串匹配不到——
///   守卫对它声称要防的回归形态零覆盖。
/// - **报假阳**：`PortraitCoverImage(` / `LandscapeCoverImage(` 这类**以 Image 结尾**
///   的更长标识符本身就含子串 `Image(`，于是正确写法反被判红。本仓已因此两次踩坑
///   （BUG-1272/1299 守卫、合集 hero 守卫）。
///
/// 这里用负向后顾定前边界（Dart 标识符合法字符全含），并可选吃掉命名构造器和泛型
/// 实参，一次把两个方向都堵上：
/// - `Image(` 命中、`Image.file(` 命中、`Image<T>(` 命中
/// - `PortraitCoverImage(` 不命中、`resolveMediaCoverImage(` 不命中
///
/// [allowNamedConstructor] 置 false 时只匹配裸调用，用于「命名构造器是合法写法、
/// 只禁裸构造」的场景。
RegExp identifierCall(String name, {bool allowNamedConstructor = true}) {
  return RegExp(
    r'(?<![A-Za-z0-9_$])' +
        RegExp.escape(name) +
        (allowNamedConstructor ? r'(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)?' : '') +
        r'(?:\s*<[^>]*>)?\s*\(',
  );
}

/// [identifierCall] 的 `contains` 形态：[source] 的**代码**里是否出现以独立标识符
/// 身份调用的 [name]。守卫断言一律用它替代裸 `contains('Name(')`。
///
/// 与 [containsCodeLine] 同一纪律：先掩码注释，注释里写着 `Image.file(` 不算数。
bool containsIdentifierCall(
  String source,
  String name, {
  bool allowNamedConstructor = true,
}) {
  return identifierCall(
    name,
    allowNamedConstructor: allowNamedConstructor,
  ).hasMatch(maskComments(source));
}

/// 一次调用 `Name(...)` 的结构切片。
class EnclosingCall {
  const EnclosingCall({
    required this.name,
    required this.text,
    required this.start,
    required this.end,
  });

  /// 被调标识符，含命名构造器（`SettingsCustomItem` / `EdgeInsets.symmetric`）。
  /// 匿名调用（`(fn)(x)`）取不到名字时是空串。
  final String name;

  /// `Name(...)` 的完整原文切片（含结尾右括号）。
  final String text;

  /// [text] 在原串中的起止下标（[end] 为右括号后一位）。
  final int start;
  final int end;
}

/// 取 [src] 中下标 [index] 所在的**最内层调用**。
///
/// 用来替掉两类塌陷窗口：
/// - `src.substring(anchor, anchor + 520)` 这种**定长字符窗口**——被守的那一项一旦
///   多写两行属性，`group:` 就漂出窗口、守卫凭空变假；反过来项变短又会把**下一项**
///   的属性读进来，断言指向错误对象。
/// - `'SettingsCustomItem(\n            id: ...'` 这种把**缩进与换行写进锚点**的
///   字面量——`dart format` 重排或多包一层就红，而守的根本不是格式。
///
/// 换成本函数后窗口由括号配对给出：断言的是「这个 id 落在哪个构造器里 / 这个构造器
/// 体内有什么」，与长度、缩进、属性顺序全部无关。
///
/// 配对跑在掩码串上，注释与字符串里的括号不参与。方括号 / 花括号忽略不计——它们在
/// 实参内部总是配平的，跳过后拿到的就是最近一层**调用**括号。
EnclosingCall enclosingCall(String src, int index) {
  final String structural = maskCommentsAndStrings(src);
  if (index < 0 || index >= structural.length) {
    fail('enclosingCall 的下标越界：$index');
  }
  int depth = 0;
  int open = -1;
  for (int i = index - 1; i >= 0; i--) {
    final String c = structural[i];
    if (c == ')') depth++;
    if (c == '(') {
      if (depth == 0) {
        open = i;
        break;
      }
      depth--;
    }
  }
  if (open < 0) {
    fail('下标 $index 不在任何调用的实参里（找不到未配对的左括号）');
  }
  // 名字：跳过空白 →（可选）泛型实参 → 标识符 / 点链。
  int nameEnd = open;
  while (nameEnd > 0 && structural[nameEnd - 1].trim().isEmpty) {
    nameEnd--;
  }
  if (nameEnd > 0 && structural[nameEnd - 1] == '>') {
    int generic = 0;
    while (nameEnd > 0) {
      final String c = structural[nameEnd - 1];
      if (c == '>') generic++;
      if (c == '<') {
        generic--;
        if (generic == 0) {
          nameEnd--;
          break;
        }
      }
      nameEnd--;
    }
    while (nameEnd > 0 && structural[nameEnd - 1].trim().isEmpty) {
      nameEnd--;
    }
  }
  int nameStart = nameEnd;
  while (nameStart > 0 &&
      (_identifierChar.hasMatch(structural[nameStart - 1]) ||
          structural[nameStart - 1] == '.')) {
    nameStart--;
  }
  int close = -1;
  int forward = 0;
  for (int i = open; i < structural.length; i++) {
    if (structural[i] == '(') forward++;
    if (structural[i] == ')') {
      forward--;
      if (forward == 0) {
        close = i;
        break;
      }
    }
  }
  if (close < 0) {
    fail('下标 $index 所在调用的括号不配对');
  }
  final String name =
      nameStart < nameEnd ? src.substring(nameStart, nameEnd) : '';
  final int start = nameStart < nameEnd ? nameStart : open;
  return EnclosingCall(
    name: name,
    text: src.substring(start, close + 1),
    start: start,
    end: close + 1,
  );
}

/// [enclosingCall] 的定位版：先在**代码**里找 [anchor]（注释/字符串内容里的同名
/// 文本不算数），再取它所在的调用。
///
/// [anchor] 找不到直接 `fail`，不会像 `indexOf` 返回 -1 那样把 `substring` 变成
/// RangeError 或把窗口静默锚到文件头。
EnclosingCall enclosingCallOf(String src, String anchor, {int searchFrom = 0}) {
  final int index = maskComments(src).indexOf(anchor, searchFrom);
  if (index < 0) {
    fail('源码中找不到锚点（注释内的同名文本不算）：$anchor');
  }
  return enclosingCall(src, index);
}

/// 取 [src] 里所有以**实参身份**出现的命名参数 `label:` 的实参表达式原文。
///
/// 用于把「间距必须来自设计令牌」这类契约从**逐条字面量拼写**抬上来。旧写法要
/// `contains('insetPadding: EdgeInsets.symmetric(')` 加 `contains('horizontal:
/// tokens.spacing.card')` 三条各自扫全文件（三条命中的还可能是三个互不相干的位置），
/// 外加一串 `isNot(contains('const EdgeInsets.symmetric(horizontal: 16, vertical:
/// 16)'))` —— 后者只堵住**一种**拼写，把 16 改成 20 就静默放行。
///
/// 拿到实参表达式后直接断言「里面没有数字字面量」「引用了 tokens.spacing.」，与
/// 换行、参数顺序、用哪个 `EdgeInsets` 构造器全部无关。
///
/// 只认实参位置（前一个非空白字符是 `(` / `,` / `{`），因此
/// `cond ? insetPadding : other` 这类表达式里的同名标识符不会被误当命名参数；
/// map 字面量的 `'insetPadding':` 因为键是字符串、已被掩码，同样不会命中。
List<String> namedArgumentValues(String src, String label) {
  final String structural = maskCommentsAndStrings(src);
  final List<String> values = <String>[];
  final RegExp pattern = RegExp(
    r'(?<![A-Za-z0-9_$])' + RegExp.escape(label) + r'\s*:',
  );
  for (final RegExpMatch match in pattern.allMatches(structural)) {
    int before = match.start;
    while (before > 0 && structural[before - 1].trim().isEmpty) {
      before--;
    }
    if (before == 0) continue;
    final String prev = structural[before - 1];
    if (prev != '(' && prev != ',' && prev != '{') continue;
    int i = match.end;
    while (i < structural.length && structural[i].trim().isEmpty) {
      i++;
    }
    final int valueStart = i;
    int depth = 0;
    while (i < structural.length) {
      final String c = structural[i];
      if (c == '(' || c == '[' || c == '{') depth++;
      if (c == ')' || c == ']' || c == '}') {
        if (depth == 0) break;
        depth--;
      }
      if (c == ',' && depth == 0) break;
      i++;
    }
    values.add(src.substring(valueStart, i));
  }
  return values;
}

/// 截出 `switch` 里某个 `case` 标签到**下一个 case / default / switch 结束**之间
/// 的分支体。
///
/// 用于「某分支必须做某事」的守卫：右边界由下一个同级标签给出，而不是数字窗口。
/// [searchFrom] 用来把搜索限制在目标 switch 之后（例如先定位到方法签名）。
///
/// 找不到 [caseLabel] 直接 `fail`；找不到后继标签时退到 [src] 末尾（switch 是最后
/// 一个分支的情形），不会像 `indexOf` 返回 -1 那样让 `substring` 抛 RangeError。
///
/// 标签定位跑在掩码串上：注释里写着同样的 case 标签不会把窗口锚歪。
String switchCaseBody(
  String src,
  String caseLabel, {
  int searchFrom = 0,
  List<String> nextLabels = const <String>[],
}) {
  final String searchable = maskComments(src);
  final int start = searchable.indexOf(caseLabel, searchFrom);
  if (start < 0) {
    fail('源码中找不到 case 标签：$caseLabel');
  }
  int end = src.length;
  for (final String label in nextLabels) {
    final int idx = searchable.indexOf(label, start + caseLabel.length);
    if (idx >= 0 && idx < end) end = idx;
  }
  return src.substring(start, end);
}
