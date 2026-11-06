// BUG-3545：本机写入的「分配序号 → 落库」不被别的写入插队。
//
// 同步 v2：本机操作的序号（seq）与 HLC 在 Rust `apply` 里同一个保存点内分配并落进操作日志
// （sync2_ops）。若分配与落库之间插进别的写入，日志里就会出现序号与 HLC 顺序不一致、或序号有洞。
// 这里让长操作（导入攒批、更改笔记类型的多实体写）与零碎的本机写入（改旗标）并发，核对：每台设备的
// 操作按 seq 排列时 seq 从 1 起连续、HLC（wall, logical）严格递增。第一个用例在修前的代码（旧发件箱）
// 上实测复现过乱序；第二个用例是独占区的性质守卫。
import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/srs_apkg_import_bench_test.dart' show benchApkg;
import 'apkg/srs_apkg_import_test.dart' show kFullOptions;
import 'support/srs_bulk_fixture.dart';

/// 操作日志里每台设备的操作，按 seq 排：(seq, wall, logical)。
Future<Map<String, List<(int, int, int)>>> opsByDevice(BulkFixture f) async {
  final Map<String, List<(int, int, int)>> out =
      <String, List<(int, int, int)>>{};
  for (final QueryRow r
      in await f.db
          .customSelect(
            'SELECT hex(device) AS d, seq, wall, logical FROM sync2_ops '
            'WHERE profile_uid = ? ORDER BY device, seq',
            variables: <Variable<Object>>[
              Variable<String>(f.store.profileUid, srsIdType),
            ],
          )
          .get()) {
    (out[r.read<String>('d')] ??= <(int, int, int)>[]).add((
      r.read<int>('seq'),
      r.read<int>('wall'),
      r.read<int>('logical'),
    ));
  }
  return out;
}

/// 每台设备：seq 从 1 起连续，HLC 随 seq 严格递增。返回操作总数。
Future<int> expectOrdered(BulkFixture f) async {
  int total = 0;
  for (final MapEntry<String, List<(int, int, int)>> d in (await opsByDevice(
    f,
  )).entries) {
    final List<(int, int, int)> ops = d.value;
    for (int i = 0; i < ops.length; i++) {
      expect(ops[i].$1, i + 1, reason: 'device ${d.key}: seq hole at $i');
      if (i == 0) continue;
      final (int, int, int) a = ops[i - 1];
      final (int, int, int) b = ops[i];
      expect(
        b.$2 > a.$2 || (b.$2 == a.$2 && b.$3 > a.$3),
        isTrue,
        reason:
            'device ${d.key}: seq ${b.$1} HLC (${b.$2}, ${b.$3}) '
            'not after seq ${a.$1} (${a.$2}, ${a.$3})',
      );
    }
    total += ops.length;
  }
  return total;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('导入攒批期间插进来的本机写入：操作日志 seq 连续、HLC 随 seq 递增', () async {
    final BulkFixture f = await BulkFixture.open(notes: 2, background: true);
    final SrsDbStore s = f.store;
    // 每次写不同的卡：同一字段键上后写的会支配并删掉先写的，乱序就看不见了。
    final List<String> cards = <String>[
      for (final SrsCardCacheRow c in await s.allCardRows()) c.id,
    ];
    final List<Future<void>> writes = <Future<void>>[];
    int flag = 0;
    await importAnkiPackage(
      store: s,
      bytes: benchApkg(300),
      storeMedia: (String name, Uint8List b) async => name,
      options: kFullOptions,
      zstdDecompress: (Uint8List b) => null,
      // 每导入 50 条笔记（攒批中途、本批还没落库）写一条本机记录。resolveConflict 不先读库，
      // 当场分配序号——正好落在「本批已攒、未落库」的窗口里。
      onProgress: (double _) => writes.add(
        s.resolveConflict(
          SrsEntityKind.card,
          cards[flag++ % cards.length],
          SrsFieldKeys.flag,
          2,
        ),
      ),
    );
    await Future.wait(writes);
    expect(writes.length, greaterThan(3));
    expect(await expectOrdered(f), greaterThan(300));
  });

  test('更改笔记类型（多实体一次写）期间插进来的本机写入：操作日志 seq 连续、HLC 随 seq 递增', () async {
    final BulkFixture f = await BulkFixture.open(notes: 120, background: true);
    final SrsDbStore s = f.store;
    final List<String> cards = <String>[
      for (final SrsCardCacheRow c in await s.allCardRows()) c.id,
    ];
    final ChangeSpec c = await fushiCardChange(s);
    final Future<void> change = s.changeNoteType(
      noteIds: c.noteIds,
      targetTypeId: c.targetTypeId,
      fieldMap: c.fieldMap,
      templateMap: c.templateMap,
    );
    bool done = false;
    unawaited(change.whenComplete(() => done = true));
    final List<Future<void>> writes = <Future<void>>[];
    // 更改笔记类型跑的整段时间里（读笔记、读现值、分配、落库）不停地插零碎写入。
    // 每次写不同的卡（同一字段键上后写的会支配并删掉先写的，乱序就看不见了）。
    const List<String> keys = <String>[
      SrsFieldKeys.flag,
      SrsFieldKeys.suspended,
      SrsFieldKeys.buriedUntilDay,
    ];
    for (int i = 0; !done && i < cards.length * keys.length; i++) {
      await Future<void>.delayed(Duration.zero);
      final String key = keys[i ~/ cards.length];
      writes.add(
        s.editField(
          SrsEntityKind.card,
          cards[i % cards.length],
          key,
          key == SrsFieldKeys.suspended ? true : 2,
        ),
      );
    }
    await Future.wait(<Future<void>>[change, ...writes]);
    expect(writes.length, greaterThan(5));
    expect(await expectOrdered(f), greaterThan(120));
  });
}
