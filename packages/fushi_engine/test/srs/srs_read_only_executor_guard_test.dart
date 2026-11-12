// srs.db 的写入只有一条路：内核命令。源码守卫，钉住三件事：
//
// 1. 测试专用的原始通道（`SrsCore.debugExecRaw` / `debugSelectRaw` / `debugExecBatchRaw`：在写连接上执行任意语句）
//    只许出现在测试里。生产代码（各包的 lib / bin / tool）一处都不许调——它是唯一能绕开内核命令碰库的入口。
// 2. `ffsrs_store_exec` 只剩这条测试通道（mode 4 / 5）：srs.db 上的 Drift 执行器（mode 0–3、只读报错
//    `READ_ONLY`）已删，读只有内核读命令 `read` / `read_lib`（store/reads.rs）。
// 3. Dart 的改投影命令集合与内核 `PROJECTING_OPS` 同一组（Dart 据此断言这些命令在独占区里发、吸收回包里的投影变化）。
import 'dart:io';

import 'package:fushi_engine/srs/srs_db_store.dart';
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

  test('ffsrs_store_exec 只剩测试通道：Drift 执行器的模式与只读报错都不在了', () {
    final String mod = File(
      p.join(_kRepoRoot, 'native/fushi_fsrs/src/store/mod.rs'),
    ).readAsStringSync();
    expect(mod, isNot(contains('pub const READ_ONLY')));
    final String ffi = File(
      p.join(_kRepoRoot, 'native/fushi_fsrs/src/store/ffi.rs'),
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final int from = ffi.indexOf('pub extern "C" fn ffsrs_store_exec(');
    expect(from, greaterThanOrEqualTo(0));
    final String body = ffi.substring(from, ffi.indexOf('\n}\n', from));
    // 模式分发只认 4 / 5。
    expect(RegExp(r'\b[0-3]\s*=>').hasMatch(body), isFalse, reason: body);
    expect(body, contains('4 => c.exec_raw('));
    expect(body, contains('5 => c.exec_raw('));
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
