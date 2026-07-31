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
  final int open = src.indexOf('{', start);
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
