// srs.db 的写入只有一条路：内核命令。源码守卫，钉住三件事：
//
// 1. 测试专用的原始通道（`SrsCore.debugExecRaw` / `debugSelectRaw` / `debugExecBatchRaw`：在写连接上执行任意语句）
//    只许出现在测试里。生产代码（各包的 lib / bin / tool）一处都不许调——Drift 执行器只读之后，它是唯一能绕开
//    内核命令改库的入口。
// 2. Dart 与内核对「经 Drift 执行器只读」用同一条报错（`kSrsReadOnlyExecutor` = Rust `store::READ_ONLY`）：
//    执行器靠消息前缀把内核的拒绝转成 `SrsReadOnlyDatabaseError`。
// 3. Dart 的改投影命令集合与内核 `PROJECTING_OPS` 同一组（Dart 据此断言这些命令在独占区里发、吸收回包里的投影变化）。
import 'dart:io';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart' show kSrsReadOnlyExecutor;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 仓库根（本测试在 packages/fushi_engine 下跑）。
const String _kRepoRoot = '../..';

/// 原始通道的三个入口。
final RegExp _kRawExec = RegExp(
  r'\b(debugExecRaw|debugSelectRaw|debugExecBatchRaw)\b',
);

/// 声明它们的文件（相对仓库根，正斜杠）。
const String _kDeclaredIn = 'packages/fushi_srs/lib/src/store/srs_core.dart';

/// 生产代码目录：各包与 app 的 lib / bin / tool。
List<Directory> _productionDirs() {
  final List<Directory> out = <Directory>[];
  final List<Directory> packages = <Directory>[
    Directory(p.join(_kRepoRoot, 'fushi')),
    ...Directory(
      p.join(_kRepoRoot, 'packages'),
    ).listSync().whereType<Directory>(),
  ];
  for (final Directory pkg in packages) {
    for (final String sub in const <String>['lib', 'bin', 'tool']) {
      final Directory d = Directory(p.join(pkg.path, sub));
      if (d.existsSync()) out.add(d);
    }
  }
  return out;
}

String _relative(String path) =>
    p.relative(path, from: _kRepoRoot).replaceAll(r'\', '/');

void main() {
  test('原始通道（debugExecRaw 等）只在测试里用：生产代码不调', () {
    final List<Directory> dirs = _productionDirs();
    // 扫描范围没有悄悄变空：至少覆盖 app、引擎、内核绑定、服务端的 lib。
    expect(
      <String>{for (final Directory d in dirs) _relative(d.path)},
      containsAll(<String>[
        'fushi/lib',
        'packages/fushi_engine/lib',
        'packages/fushi_srs/lib',
        'packages/fushi_server/lib',
      ]),
    );
    final List<String> offenders = <String>[];
    int scanned = 0;
    for (final Directory dir in dirs) {
      for (final File f in dir.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        scanned++;
        final String rel = _relative(f.path);
        final List<String> lines = f.readAsLinesSync();
        for (int i = 0; i < lines.length; i++) {
          final String line = lines[i];
          if (!_kRawExec.hasMatch(line)) continue;
          // 声明处与文档注释里的引用不算调用。
          if (line.trimLeft().startsWith('//')) continue;
          if (rel == _kDeclaredIn) continue;
          offenders.add('$rel:${i + 1}: ${line.trim()}');
        }
      }
    }
    expect(scanned, greaterThan(100));
    expect(offenders, isEmpty, reason: offenders.join('\n'));
    // 声明文件里确实有这三个入口（改名后这条守卫不会悄悄失效）。
    final String declared = File(
      p.join(_kRepoRoot, _kDeclaredIn),
    ).readAsStringSync();
    expect(
      <String>{
        for (final RegExpMatch m in _kRawExec.allMatches(declared)) m.group(1)!,
      },
      <String>{'debugExecRaw', 'debugSelectRaw', 'debugExecBatchRaw'},
    );
  });

  test('只读报错的消息 Dart 与内核同文', () {
    final String src = File(
      p.join(_kRepoRoot, 'native/fushi_fsrs/src/store/mod.rs'),
    ).readAsStringSync();
    final RegExpMatch? m = RegExp(
      r'pub const READ_ONLY: &str = "([^"]+)";',
    ).firstMatch(src);
    expect(m, isNotNull);
    expect(kSrsReadOnlyExecutor, m!.group(1));
  });

  test('Dart 的改投影命令集合与内核 PROJECTING_OPS 同一组', () {
    final String src = File(
      p.join(_kRepoRoot, 'native/fushi_fsrs/src/store/ffi.rs'),
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final int from = src.indexOf('const PROJECTING_OPS: &[&str] = &[');
    expect(from, greaterThanOrEqualTo(0));
    final String body = src.substring(from, src.indexOf('];', from));
    final Set<String> rust = <String>{
      for (final RegExpMatch m in RegExp(r'"([a-z_0-9]+)"').allMatches(body))
        m.group(1)!,
    };
    expect(rust, isNotEmpty);
    expect(SrsDbStore.kSrsSync2ProjectingOps, rust);
  });
}
