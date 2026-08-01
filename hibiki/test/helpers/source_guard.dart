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

/// [maskComments] 的保守超集：额外把**整行以 `//` 开头**的行也掩成等长空白，
/// 包括落在 Dart 三引号串里的那些。
///
/// 为什么需要它：本仓有一批 Dart 文件把大段 JS/CSS 放在三引号串里
/// （`reader_hibiki/webview.part.dart`、`reader_visual_novel_scripts.dart`、
/// `reader_content_styles.dart`）。[maskComments] **按设计保留串内容**（这样
/// `'https://x'` 里的 `//` 才不会被当注释砍掉），代价是串内的 JS 注释也原样留着，
/// 于是扫描这些语料的守卫会被一条 JS 注释骗绿 / 误红。
///
/// 这些守卫原来手写的剥离是「整行以 `//` 开头就丢掉」，正好能吃掉串内 JS 注释，
/// 但既不认块注释、也不认行尾注释。本函数取两者的并集：Dart 词法掩码 **加**
/// 整行 `//`，两侧都不放松，且仍然等长。
///
/// 它**不是**完整的 JS 词法器：JS 的行尾注释、模板串、正则字面量（`/^a\/\//i`
/// 里的 `//`）都不处理。要在 JS 上做逐 token 判定，需要单独的 JS 掩码原语。
String maskCommentsAndScriptLines(String source) {
  final List<String> masked = maskComments(source).split('\n');
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
