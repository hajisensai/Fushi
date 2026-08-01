import 'package:flutter_test/flutter_test.dart';

/// 源码扫描守卫的共享窗口原语。
///
/// 源码守卫经常要「只在某个方法体内」断言，旧写法是 `src.substring(start, start + 800)`
/// 或 `src.indexOf('  }', start)`：
/// - 固定字符窗口随方法体变长/变短而漂移，方法一重构断言就凭空变假；
/// - `'  }'` 会命中任意更深缩进行的尾部（`'    }'` 里就含 `'  }'`），方法体里出现
///   第一个嵌套块（`if (...) { ... }`）窗口就被截断在那儿。
///
/// 两种漂移都不是「行为退化」，而是守卫自身塌掉——本仓已因此在 CI 上红过。
/// [methodBody] 用花括号配对定边界：窗口由源码结构决定，与长度、嵌套无关。
///
/// 找不到签名、找不到左花括号、花括号不配对一律 `fail`，绝不返回空串——
/// 空串会让后续 `contains` 静默变假，是最典型的假绿源。
String methodBody(String src, String signature) {
  final int start = src.indexOf(signature);
  if (start < 0) {
    fail('源码中找不到方法签名：$signature');
  }
  // 命名参数 `foo({required int a})` 的 `{` 就在参数表里：直接取「签名后第一个 `{`」
  // 会把**参数表**当成方法体，配对结束即返回——`contains` 型断言随之全假，
  // `isFalse` 那类禁止型断言更是静默变绿。先跳过参数表：若签名后的第一个 `(` 出现在
  // 第一个 `{` 之前，就把它配对到 `)`，方法体的 `{` 只可能在那之后。
  // （无参 / 位置参数的老用法落到同一个 `{`，行为不变。）
  int bodySearchFrom = start;
  final int firstBrace = src.indexOf('{', start);
  final int paren = src.indexOf('(', start);
  if (paren >= 0 && firstBrace >= 0 && paren < firstBrace) {
    int parenDepth = 0;
    for (int i = paren; i < src.length; i++) {
      if (src[i] == '(') parenDepth++;
      if (src[i] == ')') {
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
  final int open = src.indexOf('{', bodySearchFrom);
  if (open < 0) {
    fail('方法签名后找不到左花括号：$signature');
  }
  int depth = 0;
  for (int i = open; i < src.length; i++) {
    final String c = src[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  fail('方法体花括号不配对：$signature');
}

/// 在 [body] 的**代码行**上查找 [needle]，注释行不算数。
///
/// 裸 `body.contains('foo()')` 会被注释里的同名字面量喂成假绿——本仓一天抓到过 6 起
/// 这种守卫假绿。这里跳过整行注释（`//` / `///` / doc 续行 `*`），并在不含引号的
/// 行上剪掉行尾 `//` 注释（含引号的行不剪，避免误伤 `'http://…'` 这类字面量）。
bool containsCodeLine(String body, String needle) {
  for (String line in body.split('\n')) {
    line = line.trim();
    if (line.startsWith('//') || line.startsWith('*')) continue;
    if (!line.contains("'") && !line.contains('"')) {
      final int comment = line.indexOf('//');
      if (comment >= 0) line = line.substring(0, comment);
    }
    if (line.contains(needle)) return true;
  }
  return false;
}

/// 构造「以独立标识符身份出现的 [name] 调用/构造」的正则。
///
/// 源码守卫里最常见的判据是裸字面量 `contains('Image(')`。这个写法**两个方向都错**：
/// - **漏真阳**：真实写法多半带命名构造器（`Image.file(` / `Image.memory(` /
///   `Image.network(` / `Image.asset(`），`Image` 后面是 `.` 不是 `(`，子串匹配不到——
///   守卫对它声称要防的回归形态零覆盖。
/// - **报假阳**：`PortraitCoverImage(` / `LandscapeCoverImage(` 这类**以 `Image` 结尾**
///   的更长标识符本身就含子串 `Image(`，于是正确写法反被判红。本仓已因此两次踩坑
///   （BUG-1272/1299 守卫、合集 hero 守卫）。
///
/// 这里用负向后顾 `(?<![A-Za-z0-9_$])` 定前边界（Dart 标识符合法字符全含），并可选
/// 吃掉命名构造器和泛型实参，一次把两个方向都堵上：
/// - `Image(` 命中、`Image.file(` 命中、`Image .memory (` 命中、`Image<T>(` 命中
/// - `PortraitCoverImage(` 不命中、`resolveMediaCoverImage(` 不命中、`_buildImage(` 不命中
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

/// [identifierCall] 的 `contains` 形态：[source] 里是否出现以独立标识符身份调用的
/// [name]。守卫断言一律用它替代裸 `contains('Name(')`。
bool containsIdentifierCall(
  String source,
  String name, {
  bool allowNamedConstructor = true,
}) {
  return identifierCall(
    name,
    allowNamedConstructor: allowNamedConstructor,
  ).hasMatch(source);
}

/// 截出 `switch` 里某个 `case` 标签到**下一个 `case` / `default` / switch 结束**之间
/// 的分支体。
///
/// 用于「某分支必须做某事」的守卫：右边界由下一个同级标签给出，而不是数字窗口。
/// [searchFrom] 用来把搜索限制在目标 switch 之后（例如先定位到方法签名）。
///
/// 找不到 [caseLabel] 直接 `fail`；找不到后继标签时退到 [src] 末尾（switch 是最后
/// 一个分支的情形），不会像 `indexOf` 返回 -1 那样让 `substring` 抛 RangeError。
String switchCaseBody(
  String src,
  String caseLabel, {
  int searchFrom = 0,
  List<String> nextLabels = const <String>[],
}) {
  final int start = src.indexOf(caseLabel, searchFrom);
  if (start < 0) {
    fail('源码中找不到 case 标签：$caseLabel');
  }
  int end = src.length;
  for (final String label in nextLabels) {
    final int idx = src.indexOf(label, start + caseLabel.length);
    if (idx >= 0 && idx < end) end = idx;
  }
  return src.substring(start, end);
}
