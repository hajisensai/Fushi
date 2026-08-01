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
int _scanStringLiteral(
  String src,
  int i,
  StringBuffer out, {
  required bool mask,
  required bool raw,
}) {
  final int n = src.length;
  final String quote = src[i];
  final bool triple = i + 2 < n && src[i + 1] == quote && src[i + 2] == quote;
  final int quoteLen = triple ? 3 : 1;
  for (int k = 0; k < quoteLen; k++) {
    _emit(out, quote, mask);
  }
  i += quoteLen;
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
          i = _scanStringLiteral(src, i, out, mask: mask, raw: false);
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
      int depth = 0; // Dart 的块注释可嵌套，按深度收口。
      while (i < n) {
        if (source[i] == '/' && i + 1 < n && source[i + 1] == '*') {
          depth++;
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
            mask: maskStringContent, raw: false);
        continue;
      }
      if ((c == 'r' || c == 'R') &&
          i + 1 < n &&
          (source[i + 1] == "'" || source[i + 1] == '"') &&
          (i == 0 || !_identifierChar.hasMatch(source[i - 1]))) {
        _emit(out, c, maskStringContent);
        i = _scanStringLiteral(source, i + 1, out,
            mask: maskStringContent, raw: true);
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
/// 同样等长，可直接拿下标回原串切片。
String maskCssComments(String source) => _mask(
      source,
      lineComments: false,
      stringLiterals: false,
      maskStringContent: false,
    );

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
String methodBody(String src, String signature) {
  // 找签名：只掩码注释（签名可能落在被扫描的字符串语料里，串要保留）。
  final String searchable = maskComments(src);
  // 配对：注释与字符串都掩掉，只剩真结构。
  final String structural = maskCommentsAndStrings(src);
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
