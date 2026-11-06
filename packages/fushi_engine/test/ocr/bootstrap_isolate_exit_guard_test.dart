import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 契约守卫（BUG-3997 同根因）：凡是 `Isolate.spawn` 时带宿主 bootstrap
/// （app 里会在后台 isolate 挂 `BackgroundIsolateBinaryMessenger`，它持有一个没有
/// 关闭入口的 `ReceivePort`）的 isolate 入口，都必须显式 `Isolate.exit`——
/// 「入口返回即退出」在这种 isolate 上永远不成立，每跑一次就漏一个 isolate。
///
/// 扫本包 `lib/`，以及同仓的 `fushi/lib/`、`packages/fushi_server/lib/`（存在时）：
/// 找出参数里带 `bootstrap` / `RootIsolateToken` 的 `Isolate.spawn(入口, ...)`，
/// 要求同文件里该入口函数体内出现 `Isolate.exit(`。

/// 从 [open]（指向 `(` 或 `{`）起按括号配对，返回到配对闭括号为止的文本。
String _balanced(String source, int open) {
  final String opener = source[open];
  final String closer = opener == '(' ? ')' : '}';
  int depth = 0;
  for (int i = open; i < source.length; i++) {
    final String c = source[i];
    if (c == opener) depth++;
    if (c == closer) {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  return source.substring(open);
}

List<Directory> _roots() {
  final Directory pkg = Directory.current;
  return <Directory>[
    Directory(p.join(pkg.path, 'lib')),
    Directory(p.normalize(p.join(pkg.path, '..', '..', 'fushi', 'lib'))),
    Directory(p.normalize(p.join(pkg.path, '..', 'fushi_server', 'lib'))),
  ].where((Directory d) => d.existsSync()).toList();
}

void main() {
  test('带 bootstrap 的 Isolate.spawn 入口都显式 Isolate.exit', () {
    final RegExp spawn = RegExp(
      r'Isolate\.spawn(?:<[^>(]*>)?\(\s*([A-Za-z_]\w*)\s*,',
    );
    final List<String> checked = <String>[];
    final List<String> violations = <String>[];
    for (final Directory root in _roots()) {
      for (final FileSystemEntity entity in root.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String source = entity.readAsStringSync();
        if (!source.contains('Isolate.spawn')) continue;
        for (final RegExpMatch match in spawn.allMatches(source)) {
          final int open = source.indexOf('(', match.start);
          final String call = _balanced(source, open);
          if (!call.contains('bootstrap') &&
              !call.contains('RootIsolateToken')) {
            continue;
          }
          final String entry = match.group(1)!;
          final String where = '${p.relative(entity.path)} → $entry';
          final RegExpMatch? def = RegExp(
            '^(?:Future<void>|void)\\s+${RegExp.escape(entry)}\\(',
            multiLine: true,
          ).firstMatch(source);
          if (def == null) {
            violations.add('$where（同文件里找不到入口函数定义）');
            continue;
          }
          final int bodyOpen = source.indexOf('{', def.end);
          final String body = _balanced(source, bodyOpen);
          checked.add(where);
          if (!body.contains('Isolate.exit(')) {
            violations.add('$where（入口没有显式 Isolate.exit）');
          }
        }
      }
    }
    // 反向锚点：至少扫到漫画 OCR 的两条入口，否则守卫是空转。
    expect(
      checked.where((String w) => w.contains('manga_ocr_service_impl')),
      hasLength(greaterThanOrEqualTo(2)),
      reason: '没扫到漫画 OCR 的 isolate 入口，守卫的匹配规则失效了：$checked',
    );
    expect(violations, isEmpty);
  });
}
