// srs.db 的写入只有一条路：内核命令。源码守卫，钉住这几件事：
//
// 1. 测试专用的原始通道（`SrsCore.debugExecRaw` / `debugSelectRaw` / `debugExecBatchRaw`：在写连接上执行任意语句）
//    只许出现在测试里。生产代码（各包的 lib / bin / tool）一处都不许调：发布构建的原生库不带它（cargo feature
//    `raw_sql`），调用报 `kSrsRawSqlAbsent`；而测试用的库带着，生产代码里的调用在测试里是绿的、到发布包里才失败。
// 1b. 原始通道只编进测试用的库：内核三处入口都在 `cfg(any(test, feature = "raw_sql"))` 之下、feature 不在 default 里；
//    发布 / 随包的 workflow 不出现 `raw_sql`（只有包测试那一步与 test-native-linux 带）；verify_abi.sh 核对产物里没有它；
//    报错文案 Dart 与内核同文。
// 2. Dart 与内核对「经 Drift 执行器只读」用同一条报错（`kSrsReadOnlyExecutor` = Rust `store::READ_ONLY`）：
//    执行器靠消息前缀把内核的拒绝转成 `SrsReadOnlyDatabaseError`。
// 3. Dart 的改投影命令集合与内核 `PROJECTING_OPS` 同一组（Dart 据此断言这些命令在独占区里发、吸收回包里的投影变化）。
import 'dart:io';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart'
    show kSrsRawSqlAbsent, kSrsReadOnlyExecutor;
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

  group('原始通道只编进测试用的库（cargo feature raw_sql）', () {
    String read(String rel) => File(
      p.join(_kRepoRoot, rel),
    ).readAsStringSync().replaceAll('\r\n', '\n');

    test('feature 不在 default 里；内核三处入口都在 cfg 门之下', () {
      final String cargo = read('native/fushi_fsrs/Cargo.toml');
      expect(cargo, contains('\nraw_sql = []\n'));
      final RegExpMatch? dflt = RegExp(
        r'^default\s*=\s*\[([^\]]*)\]',
        multiLine: true,
      ).firstMatch(cargo);
      expect(dflt?.group(1) ?? '', isNot(contains('raw_sql')));

      const String gate = '#[cfg(any(test, feature = "raw_sql"))]';
      final String mod = read('native/fushi_fsrs/src/store/mod.rs');
      for (final String f in const <String>[
        'pub fn exec_raw(',
        'pub fn exec_batch_raw(',
      ]) {
        final int at = mod.indexOf(f);
        expect(at, greaterThan(0), reason: f);
        final List<String> before = mod
            .substring(0, at)
            .trimRight()
            .split('\n');
        expect(before.last.trim(), gate, reason: '$f 前一行要是 cfg 门');
      }
      final String ffi = read('native/fushi_fsrs/src/store/ffi.rs');
      expect(
        ffi,
        contains(
          '#[cfg(not(any(test, feature = "raw_sql")))]\n'
          '            4 | 5 => return Err(crate::store::RAW_SQL_ABSENT.to_string()),',
        ),
      );
      expect(
        ffi,
        contains('$gate\nfn exec_batch_raw_entry('),
        reason: 'ffsrs_store_exec_batch 的执行体只在带 feature 的构建里',
      );
    });

    test('报错文案 Dart 与内核同文', () {
      final String mod = read('native/fushi_fsrs/src/store/mod.rs');
      final RegExpMatch? m = RegExp(
        r'pub const RAW_SQL_ABSENT: &str =\s*"([^"]+)";',
      ).firstMatch(mod);
      expect(m, isNotNull);
      expect(kSrsRawSqlAbsent, m!.group(1));
    });

    test('发布 / 随包的流水线不带它，产物核对接在 verify_abi.sh 上', () {
      // 只有这两处编测试用的库：包测试那一步（main.yml）与单测矩阵的 test-native-linux。
      const Set<String> allowed = <String>{
        '.github/workflows/main.yml',
        '.github/actions/test-native-linux/action.yml',
      };
      final List<String> offenders = <String>[];
      int scanned = 0;
      for (final String dir in const <String>[
        '.github/workflows',
        '.github/actions',
      ]) {
        for (final File f in Directory(
          p.join(_kRepoRoot, dir),
        ).listSync(recursive: true).whereType<File>()) {
          if (!f.path.endsWith('.yml') && !f.path.endsWith('.yaml')) continue;
          scanned++;
          final String rel = _relative(f.path);
          if (allowed.contains(rel)) continue;
          if (f.readAsStringSync().contains('raw_sql')) offenders.add(rel);
        }
      }
      expect(scanned, greaterThan(10));
      expect(offenders, isEmpty, reason: offenders.join('\n'));
      // 两处测试库都核对真的带上了（不带的话几十个测试文件成片红，先给出明确原因）。
      for (final String rel in allowed) {
        expect(read(rel), contains('verify_raw_sql.sh'), reason: rel);
        expect(read(rel), contains('.so present'), reason: rel);
      }
      expect(
        read('native/fushi_fsrs/verify_abi.sh'),
        contains(r'verify_raw_sql.sh" "$BIN" absent'),
      );
      expect(
        read('tool/linux/build_bundle.sh'),
        contains('FUSHI_RELEASE_NATIVE=1 bash tool/bootstrap.sh'),
      );
    });
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
