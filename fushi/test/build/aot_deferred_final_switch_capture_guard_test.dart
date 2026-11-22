import 'dart:io';

import 'package:test/test.dart';

/// 守卫：**推迟赋值的 `final` 局部变量在 `switch` 语句里赋值、之后又被闭包捕获**
/// ——这个形状在 Dart 3.14.0 的 AOT 编译器里会崩（dart-lang/sdk#64917）。
///
/// ## 起因（BUG-5204）
///
/// Flutter 3.50.0（Dart 3.14.0）下，`home_page.dart` 的
/// `_openRemoteAiVideoAcquisition` 让全平台 release 构建在 `gen_snapshot` 里挂掉：
///
///     linearscan.cc: 3013: error: unreachable code
///
/// CFE 把穷尽的 pattern `switch` 降成一串 `if`，最后一个 case 的 `if` 不带
/// else，于是「唯一一次初始化写入」在 IL 里并不支配后面的读；被闭包捕获的
/// 变量住在 Context 里，`LoadFieldInstr::Canonicalize` 却把那次写入的值直接转发
/// 给读，生成了「使用不被定义支配」的非法 IL，寄存器分配时崩。上游修复是
/// dart-lang/sdk@7848cfe821d（"[vm/compiler] Fix forwarding of initializing
/// stores"，2026-11-13 进 main），截至 2026-11-15 还没有含它的 Dart 3.14.x /
/// Flutter 3.50.x 补丁版。
///
/// **debug 运行、`flutter analyze`、`flutter test` 全绿，只有 release AOT 会崩**
/// （JIT 不走这条优化），所以必须靠源码守卫在 PR 阶段拦住。
///
/// ## 规则
///
/// 扫描范围是所有会进 AOT 的 Dart 源：`fushi/lib`、`packages/*/lib`、
/// `third_party/*/lib`（vendored 插件同样编进 release 快照），以及
/// `fushi/integration_test`（profile 模式的性能测试走 AOT）。这些目录里，没有
/// 初始值的 `final` 局部变量若在随后的 `switch` 语句里被赋值，就不能再被闭包
/// （`() {}` / `() =>` / 局部函数）引用。
/// 改写成不推迟赋值的形状：把每个 case 的后续工作挪进 case 里（或抽成方法），
/// 或者用 `switch` 表达式在声明处直接取值。
///
/// 清理条件：Flutter 升到所带 Dart 含 7848cfe821d 的补丁版后，本守卫可删；
/// 已改写的代码不必还原。
void main() {
  group('scanner self-check', () {
    test('flags the upstream repro shape', () {
      const String source = '''
class Picker {
  void onSelected(Opt opt) {
    final Object value;
    switch (opt) {
      case Query(:final text):
        print(text);
        return;
      case Item(value: final picked):
        value = picked;
    }
    run(() {
      committed = value;
    });
    print(value);
  }
}
''';
      expect(findDeferredFinalSwitchCaptures(source), <String>['value']);
    });

    test('flags arrow-closure capture inside a call argument', () {
      const String source = '''
  Future<void> open(Outcome outcome) async {
    final Target target;
    switch (outcome) {
      case Available(:final Target t):
        target = t;
      case Unavailable():
        return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Page(label: target.label),
      ),
    );
  }
''';
      expect(findDeferredFinalSwitchCaptures(source), <String>['target']);
    });

    test('ignores deferred finals that no closure reads', () {
      const String source = '''
  Future<void> open(Outcome outcome) async {
    final Target target;
    switch (outcome) {
      case Available(:final Target t):
        target = t;
      case Unavailable():
        return;
    }
    if (!target.supports('x')) {
      return;
    }
    use(target);
  }
''';
      expect(findDeferredFinalSwitchCaptures(source), isEmpty);
    });

    test('ignores switch expressions and named arguments', () {
      const String source = '''
  Widget build(Kind kind) {
    final String label = switch (kind) {
      Kind.a => 'a',
      Kind.b => 'b',
    };
    return Builder(builder: (_) => Text(label));
  }
  void other(Kind kind) {
    final int target;
    switch (kind) {
      case Kind.a:
        target = 1;
      case Kind.b:
        target = 2;
    }
    run(() => call(target: 3));
    print(target);
  }
''';
      expect(findDeferredFinalSwitchCaptures(source), isEmpty);
    });
  });

  test('进 AOT 的代码里没有「推迟赋值 final + switch 赋值 + 闭包捕获」（#64917）', () {
    final List<Directory> roots = <Directory>[
      Directory('lib'),
      Directory('integration_test'),
    ];
    for (final String parent in <String>['../packages', '../third_party']) {
      final Directory dir = Directory(parent);
      expect(dir.existsSync(), isTrue, reason: dir.absolute.path);
      for (final FileSystemEntity entity in dir.listSync()) {
        if (entity is Directory) {
          final Directory lib = Directory('${entity.path}/lib');
          if (lib.existsSync()) roots.add(lib);
        }
      }
    }
    expect(roots.first.existsSync() && roots[1].existsSync(), isTrue);
    expect(
      roots.where(
        (Directory d) =>
            d.path.replaceAll(r'\', '/').startsWith('../third_party/'),
      ),
      isNotEmpty,
      reason: 'vendored 插件同样编进 release AOT，必须在扫描范围内',
    );
    int scanned = 0;
    final List<String> offenders = <String>[];
    for (final Directory root in roots) {
      for (final FileSystemEntity entity in root.listSync(recursive: true)) {
        if (entity is! File) continue;
        final String path = entity.path.replaceAll(r'\', '/');
        if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
        scanned++;
        for (final String name in findDeferredFinalSwitchCaptures(
          entity.readAsStringSync(),
        )) {
          offenders.add('$path: $name');
        }
      }
    }
    expect(scanned, greaterThan(3000), reason: '扫描根目录找错了');
    expect(
      offenders,
      isEmpty,
      reason:
          '以下推迟赋值的 final 在 switch 语句里赋值、又被闭包捕获，'
          'Dart 3.14.0 release AOT 会崩在 linearscan.cc:3013'
          '（dart-lang/sdk#64917，debug / analyze / test 都看不出来）。'
          '把后续工作挪进 case 或改用 switch 表达式：\n${offenders.join('\n')}',
    );
  });
}

final RegExp _deferredFinal = RegExp(
  r'^(\s+)final\s+[\w<>?,. ()]+?\s+(\w+);\s*$',
);
final RegExp _controlKeyword = RegExp(
  r'(?:^|[^\w$])(if|for|while|switch|catch)\s*$',
);
final RegExp _closureBrace = RegExp(r'\)\s*(?:async\s*\*?|sync\s*\*)?\s*\{');
final RegExp _arrow = RegExp(r'\)\s*(?:async\s*)?=>');

/// 返回 [source] 里命中 #64917 形状的变量名。
List<String> findDeferredFinalSwitchCaptures(String source) {
  final List<String> lines = source
      .split('\n')
      .map((String l) => l.replaceFirst(RegExp(r'(^|\s)//.*$'), ''))
      .toList();
  final List<String> hits = <String>[];
  for (int i = 0; i < lines.length; i++) {
    final RegExpMatch? decl = _deferredFinal.firstMatch(lines[i]);
    if (decl == null) continue;
    final int indent = decl.group(1)!.length;
    final String name = decl.group(2)!;
    final RegExp assign = RegExp('(?<![\\w\$.])$name\\s*=(?!=)');
    // 同一缩进层上、赋值之前出现的第一个 switch 语句。
    int switchLine = -1;
    int blockEnd = lines.length;
    for (int j = i + 1; j < lines.length; j++) {
      final String line = lines[j];
      if (line.trim().isEmpty) continue;
      final int lineIndent = line.length - line.trimLeft().length;
      if (lineIndent < indent) {
        blockEnd = j;
        break;
      }
      if (switchLine < 0) {
        if (lineIndent == indent && line.trimLeft().startsWith('switch (')) {
          switchLine = j;
        } else if (assign.hasMatch(line)) {
          break; // 赋值不在 switch 里：不是这个形状。
        }
      }
    }
    if (switchLine < 0) continue;
    final int switchEnd = _matchingBraceLine(lines, switchLine);
    if (switchEnd < 0 || switchEnd >= blockEnd) continue;
    final String switchBody = lines
        .sublist(switchLine, switchEnd + 1)
        .join('\n');
    if (!assign.hasMatch(switchBody)) continue;
    final String rest = lines.sublist(switchEnd + 1, blockEnd).join('\n');
    if (_capturedInClosure(rest, name)) hits.add(name);
  }
  return hits;
}

int _matchingBraceLine(List<String> lines, int start) {
  int depth = 0;
  bool opened = false;
  for (int j = start; j < lines.length; j++) {
    for (final int c in lines[j].codeUnits) {
      if (c == 0x7B) {
        depth++;
        opened = true;
      } else if (c == 0x7D) {
        depth--;
        if (opened && depth == 0) return j;
      }
    }
  }
  return -1;
}

bool _capturedInClosure(String text, String name) {
  final RegExp use = RegExp('(?<![\\w\$.])$name(?![\\w\$]|\\s*:(?!:))');
  for (final (int, int) region in _closureRegions(text)) {
    if (use.hasMatch(text.substring(region.$1, region.$2))) return true;
  }
  return false;
}

/// 文本里闭包 / 局部函数体的 `[start, end)` 区间（近似：只认 `(...) {` 与
/// `(...) =>`，括号前是控制流关键字的不算；`Foo(...) =>` 是 switch 表达式的对象
/// 模式，不算）。
List<(int, int)> _closureRegions(String text) {
  final List<(int, int)> regions = <(int, int)>[];
  for (final RegExpMatch m in _closureBrace.allMatches(text)) {
    final int open = _matchingOpenParen(text, m.start);
    if (open < 0) continue;
    if (_controlKeyword.hasMatch(text.substring(0, open))) continue;
    final int brace = m.end - 1;
    regions.add((brace, _matchingClose(text, brace)));
  }
  for (final RegExpMatch m in _arrow.allMatches(text)) {
    final int open = _matchingOpenParen(text, m.start);
    if (open < 0) continue;
    final String before = text.substring(0, open).trimRight();
    if (before.isNotEmpty &&
        RegExp(r'[\w$>]$').hasMatch(before) &&
        !RegExp(r'(?:^|[^\w$])(return|await|yield)$').hasMatch(before)) {
      continue; // `Foo(...) =>` 对象模式，或带名字的局部函数（极少见）。
    }
    regions.add((m.end, _arrowBodyEnd(text, m.end)));
  }
  return regions;
}

int _matchingOpenParen(String text, int close) {
  int depth = 0;
  for (int k = close; k >= 0; k--) {
    final int c = text.codeUnitAt(k);
    if (c == 0x29) depth++;
    if (c == 0x28) {
      depth--;
      if (depth == 0) return k;
    }
  }
  return -1;
}

int _matchingClose(String text, int open) {
  int depth = 0;
  for (int k = open; k < text.length; k++) {
    final int c = text.codeUnitAt(k);
    if (c == 0x28 || c == 0x5B || c == 0x7B) depth++;
    if (c == 0x29 || c == 0x5D || c == 0x7D) {
      depth--;
      if (depth == 0) return k + 1;
    }
  }
  return text.length;
}

int _arrowBodyEnd(String text, int start) {
  int depth = 0;
  for (int k = start; k < text.length; k++) {
    final int c = text.codeUnitAt(k);
    if (c == 0x28 || c == 0x5B || c == 0x7B) depth++;
    if (c == 0x29 || c == 0x5D || c == 0x7D) {
      depth--;
      if (depth < 0) return k;
    }
    if (depth == 0 && (c == 0x2C || c == 0x3B)) return k;
  }
  return text.length;
}
