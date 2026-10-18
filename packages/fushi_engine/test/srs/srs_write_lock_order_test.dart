// BUG-3524：本机写入的「分配序号 → 落库」不被别的写入插队。
//
// 修改记录的序号（dot）在内存里分配、立刻并进因果上下文；若分配与落库之间插进别的写入，后分配的
// 记录先落库、先进发件箱，它的 ctx 还声称看见了尚未落库的记录。这里让长操作（导入攒批、更改笔记类型
// 的多实体写）与零碎的本机写入（改旗标）并发，核对：本机写入者的修改记录按发件箱顺序排，序号严格递增。
// 修前两处都会乱序：导入在攒批时就分配序号；writeEdits「读一个实体的现值、分配一个实体的序号」交替
// 进行，中间夹着几百次往返。
import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:test/test.dart';

import 'apkg/srs_apkg_import_bench_test.dart' show benchApkg;
import 'apkg/srs_apkg_import_test.dart' show kFullOptions;
import 'support/srs_bulk_fixture.dart';

/// 本机写入者的修改记录按发件箱顺序给出的序号。
Future<List<int>> outboxSeqs(BulkFixture f) async => <int>[
  for (final QueryRow r
      in await f.db
          .customSelect(
            'SELECT e.seq AS seq FROM srs_event_local l '
            'JOIN srs_field_edits e ON e.id = l.event_id '
            'WHERE l.outbox_seq IS NOT NULL AND e.writer_id = ? '
            'ORDER BY l.outbox_seq',
            variables: <Variable<Object>>[Variable<String>(f.store.writerId)],
          )
          .get())
    r.read<int>('seq'),
];

void expectIncreasing(List<int> seqs) {
  for (int i = 1; i < seqs.length; i++) {
    expect(
      seqs[i],
      greaterThan(seqs[i - 1]),
      reason: 'outbox position $i: seq ${seqs[i]} after ${seqs[i - 1]}',
    );
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('导入攒批期间插进来的本机写入：发件箱顺序 = 序号顺序', () async {
    final BulkFixture f = await BulkFixture.open(notes: 2);
    final SrsDbStore s = f.store;
    final String card = (await s.allCardRows()).first.id;
    final List<Future<void>> writes = <Future<void>>[];
    int flag = 0;
    await importAnkiPackage(
      store: s,
      bytes: benchApkg(300),
      storeMedia: (String name, Uint8List b) async => name,
      options: kFullOptions,
      zstdDecompress: (Uint8List b) => null,
      // 每导入 50 条笔记（攒批中途、还没落库）改一次旗标。
      onProgress: (double _) => writes.add(s.setFlag(card, ++flag % 4)),
    );
    await Future.wait(writes);
    expect(writes.length, greaterThan(3));
    final List<int> seqs = await outboxSeqs(f);
    expect(seqs.length, greaterThan(300));
    expectIncreasing(seqs);
  });

  test('更改笔记类型（多实体一次写）期间插进来的本机写入：发件箱顺序 = 序号顺序', () async {
    final BulkFixture f = await BulkFixture.open(notes: 120);
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
    final List<Future<void>> writes = <Future<void>>[];
    // 让更改笔记类型先跑起来（读现值的往返），再零零碎碎插写入。
    for (int i = 0; i < 30; i++) {
      await Future<void>.delayed(Duration.zero);
      writes.add(s.setFlag(cards[i], 1));
    }
    await Future.wait(<Future<void>>[change, ...writes]);
    final List<int> seqs = await outboxSeqs(f);
    expect(seqs.length, greaterThan(120));
    expectIncreasing(seqs);
  });
}
