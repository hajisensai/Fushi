// 内核命令（`ffsrs_store_sync2` 的 `op`）的元数据只在内核声明一次（native/fushi_fsrs/src/store/ops.rs），Dart 用的是
// 由它生成的类型化绑定 `SrsOp`（packages/fushi_srs/lib/src/ffi/srs_ops.g.dart；生成物与 Rust 表的一致性由
// cargo 测试 `store::ops::tests::dart_bindings_are_current` 钉）。这里钉 Dart 这一侧：
//
// 1. 宿主的分流（进不进独占区、走哪条 worker 道、带不带缓存配置、浏览入口放行哪些）都取自 [SrsOp]，与表一致。
// 2. 生产代码里发出去的 `'op': '<名字>'` 都是内核认识的命令（拼错的命令名在这里就红，不用等运行时内核报不认识）。
// 3. 生产代码里没有手抄的命令集合（三个以上内核命令名组成的集合 / 列表字面量）：新增的分流判据要加进内核的表。
import 'dart:io';

import 'package:fushi_engine/srs/srs_core_workers.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 仓库根（本测试在 packages/fushi_engine 下跑）。
const String _kRepoRoot = '../..';

/// 发内核命令的生产代码目录（`ffsrs_call` 那一组 JSON 命令不在这些目录里，见 ffi_fsrs_engine.dart / kernel_ids.dart）。
const List<String> _kSrsDirs = <String>[
  'packages/fushi_engine/lib/srs',
  'packages/fushi_srs/lib/src/store',
  'fushi/lib/src/srs',
  'fushi/lib/src/pages/implementations/srs',
];

/// 生成物本身（命令名一条一行）。
const String _kGenerated = 'packages/fushi_srs/lib/src/ffi/srs_ops.g.dart';

List<File> _dartFiles(List<String> dirs) => <File>[
  for (final String d in dirs)
    ...Directory(p.join(_kRepoRoot, d))
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart')),
];

String _rel(File f) =>
    p.relative(f.path, from: _kRepoRoot).replaceAll(r'\', '/');

void main() {
  test('命令表规模与一条命令的元数据（哨兵）', () {
    expect(SrsOp.values.length, greaterThan(100));
    expect(SrsOp.byWire('apply'), SrsOp.apply);
    expect(SrsOp.apply.projecting, isTrue);
    expect(SrsOp.apply.caches, isTrue);
    expect(SrsOp.apply.lane, SrsOpLane.interactive);
    expect(SrsOp.plan.lock, SrsOpLock.readFirst);
    expect(SrsOp.profileUids.global, isTrue);
    expect(SrsOp.byWire('no_such_op'), isNull);
    expect(SrsOp.byWire(null), isNull);
  });

  test('宿主的分流都取自内核的命令表', () {
    Set<String> where(bool Function(SrsOp) t) => <String>{
      for (final SrsOp o in SrsOp.values)
        if (t(o)) o.wire,
    };
    expect(
      SrsDbStore.kSrsSync2LockFreeOps,
      where((SrsOp o) => o.lock == SrsOpLock.free),
    );
    expect(SrsDbStore.kSrsSync2ProjectingOps, where((SrsOp o) => o.projecting));
    expect(SrsDbStore.kSrsBrowseOps, where((SrsOp o) => o.browse));
    for (final SrsOp o in SrsOp.values) {
      expect(srsCoreLaneOf(o.wire).name, o.lane.name, reason: o.wire);
    }
    expect(srsCoreLaneOf('no_such_op'), SrsCoreLane.bulk);
  });

  test('生产代码发出去的命令名都是内核命令', () {
    final RegExp lit = RegExp(r"'op':\s*'([a-z0-9_]+)'");
    final List<String> unknown = <String>[];
    int seen = 0;
    for (final File f in _dartFiles(_kSrsDirs)) {
      for (final RegExpMatch m in lit.allMatches(f.readAsStringSync())) {
        seen++;
        if (SrsOp.byWire(m.group(1)) == null) {
          unknown.add('${_rel(f)}: ${m.group(1)}');
        }
      }
    }
    expect(seen, greaterThan(80), reason: '扫描规模哨兵');
    expect(unknown, isEmpty, reason: unknown.join('\n'));
  });

  test('生产代码里没有手抄的命令集合', () {
    // 集合 / 列表字面量：`<String>{ ... }`、`<String>[ ... ]`、`{ ... }`（只看字符串元素）。
    final RegExp block = RegExp(r'<String>\s*[\{\[]([^\{\}\[\]]*)[\}\]]');
    final RegExp str = RegExp(r"'([a-z0-9_]+)'");
    final List<String> offenders = <String>[];
    int scanned = 0;
    for (final File f in _dartFiles(<String>[
      'packages/fushi_engine/lib',
      'packages/fushi_srs/lib',
      'fushi/lib/src/srs',
    ])) {
      final String rel = _rel(f);
      if (rel == _kGenerated) continue;
      scanned++;
      for (final RegExpMatch m in block.allMatches(f.readAsStringSync())) {
        final List<String> ops = <String>[
          for (final RegExpMatch s in str.allMatches(m.group(1)!))
            if (SrsOp.byWire(s.group(1)) != null) s.group(1)!,
        ];
        if (ops.length >= 3) offenders.add('$rel: ${ops.join(', ')}');
      }
    }
    expect(scanned, greaterThan(100), reason: '扫描规模哨兵');
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
