// BUG-3543：删牌组等「作用于多条笔记 / 多张卡」的操作的往返次数守卫（与 BUG-3548 / 3541 同一根因族）。
//
// 库在 app 里开在后台 isolate（createInBackground），每条语句都是一次跨 isolate 往返；这里数语句
// （不测墙钟），钉住「语句数不随卡数 / 笔记数线性增长」：同一操作在 4 倍规模上的语句数只允许按
// 分块（每块几百条）摊薄地增长。修前每张卡 / 每条笔记各十几次往返，删一个几千张卡的牌组要几万次往返、
// 几千个事务、每个事务各一次修改记录全表扫描。
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/apkg/srs_apkg_export.dart';
import 'package:fushi_engine/srs/srs_browse_ops.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_note_type_store.dart';
import 'package:fushi_engine/srs/srs_optimizer.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'support/srs_bulk_fixture.dart';

/// 一个操作在 [small] / [large] 两个规模上的语句数。
Future<(int, int)> measure(
  Future<void> Function(SrsDbStore store) op, {
  int small = 40,
  int large = 160,
  Future<void> Function(SrsDbStore store)? prepare,
}) async {
  Future<int> at(int notes) async {
    final BulkFixture f = await BulkFixture.open(notes: notes);
    if (prepare != null) await prepare(f.store);
    f.counter.reset();
    await op(f.store);
    // ignore: avoid_print
    print('  notes=$notes total=${f.counter.total} ${f.counter.summary()}');
    return f.counter.total;
  }

  final int s = await at(small);
  final int l = await at(large);
  return (s, l);
}

/// 4 倍规模上语句数的增长上界：分块大小 200–500，[large] 规模的卡 / 笔记都落在一两块里，
/// 增长量是常数级（每块几条）。修前增长量 ≈ 每项往返数 × 新增项数（几百到几千）。
void expectFlat(String what, (int, int) counts, {int slack = 40}) {
  final (int small, int large) = counts;
  // ignore: avoid_print
  print('ROUNDTRIPS $what: small=$small large=$large');
  expect(
    large - small,
    lessThanOrEqualTo(slack),
    reason: '$what: $small → $large statements',
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('删牌组（含子牌组）：语句数不随卡数增长', () async {
    expectFlat(
      'deleteDeck',
      await measure(
        (SrsDbStore s) async => s.deleteDeck(await deckId(s, 'Lang')),
      ),
    );
  });

  test('批量移动 / 暂停 / 搁置 / 旗标：语句数不随卡数增长', () async {
    Future<List<String>> cards(SrsDbStore s) async => <String>[
      for (final SrsCardCacheRow c in await s.allCardRows()) c.id,
    ];
    expectFlat(
      'moveCards',
      await measure(
        (SrsDbStore s) async =>
            srsBatchMoveCards(s, await cards(s), s.defaultDeckId),
      ),
    );
    expectFlat(
      'suspend',
      await measure(
        (SrsDbStore s) async =>
            srsBatchSetSuspended(s, await cards(s), suspended: true),
      ),
    );
    expectFlat(
      'bury',
      await measure(
        (SrsDbStore s) async =>
            srsBatchSetBuried(s, await cards(s), buried: true),
      ),
    );
    expectFlat(
      'flag',
      await measure(
        (SrsDbStore s) async => srsBatchSetFlag(s, await cards(s), 3),
      ),
    );
  });

  test('批量改标签 / 删笔记：语句数不随笔记数增长', () async {
    Future<List<String>> notes(SrsDbStore s) async => <String>[
      for (final SrsNoteCacheRow n in await s.listNotes(limit: 100000)) n.id,
    ];
    expectFlat(
      'editTags',
      await measure(
        (SrsDbStore s) async =>
            srsBatchEditTags(s, await notes(s), add: <String>['x']),
      ),
    );
    expectFlat(
      'deleteNotes',
      await measure(
        (SrsDbStore s) async => srsBatchDeleteNotes(s, await notes(s)),
      ),
    );
  });

  test('重置 / 设置到期 / 撤销 / 立即重排：语句数不随卡数增长', () async {
    Future<List<String>> cards(SrsDbStore s) async => <String>[
      for (final SrsCardCacheRow c in await s.allCardRows()) c.id,
    ];
    expectFlat(
      'resetCards',
      await measure(
        (SrsDbStore s) async => srsBatchResetCards(s, await cards(s)),
      ),
    );
    expectFlat(
      'setDue',
      await measure(
        (SrsDbStore s) async =>
            srsBatchSetDue(s, await cards(s), from: 3, to: 3),
      ),
    );
    late SrsBatchOutcome reset;
    expectFlat(
      'undoLogs',
      await measure(
        prepare: (SrsDbStore s) async =>
            reset = await srsBatchResetCards(s, await cards(s)),
        (SrsDbStore s) async => reset.revert!(s),
      ),
    );
    expectFlat(
      'rescheduleDeck',
      await measure(
        (SrsDbStore s) async => s.rescheduleDeck(await deckId(s, 'Lang')),
      ),
    );
  });

  test('更改笔记类型 / 删笔记类型：语句数不随笔记数增长', () async {
    expectFlat(
      'changeNoteType',
      await measure((SrsDbStore s) async {
        final ChangeSpec c = await reversedChange(s);
        await s.changeNoteType(
          noteIds: c.noteIds,
          targetTypeId: c.targetTypeId,
          fieldMap: c.fieldMap,
          templateMap: c.templateMap,
        );
      }),
    );
    expectFlat(
      'deleteNoteType',
      await measure((SrsDbStore s) async => s.deleteNoteType(basicTypeId(s))),
    );
    expectFlat(
      'notesWithFieldContent',
      await measure((SrsDbStore s) async {
        final SrsNoteTypeView t = (await s.noteType(basicTypeId(s)))!;
        await s.notesWithFieldContent(t.id, t.fields.first.id);
      }),
    );
  });

  test('导出 / 优化器取数：语句数不随卡数增长', () async {
    expectFlat(
      'exportApkg',
      await measure((SrsDbStore s) async => exportAnkiPackage(store: s)),
    );
    expectFlat(
      'prepareOptimization',
      await measure(
        (SrsDbStore s) async =>
            srsPrepareOptimization(s, await deckId(s, 'Lang')),
      ),
    );
  });

  test('缓存刷新找后继卡：查询走前身链接的部分覆盖索引，不全表扫描修改记录表', () async {
    // 每次缓存刷新（每次评分、每次改卡）都要找「哪些卡继承了这张卡的历史」。修前按无索引的
    // field_key 扫整张修改记录表：语句数不变，但每次的扫描量随表长线性增长。
    final BulkFixture f = await BulkFixture.open(notes: 20);
    final String plan =
        (await f.db
                .customSelect(
                  'EXPLAIN QUERY PLAN SELECT entity_id, field_key '
                  'FROM srs_field_edits WHERE $kSrsHistoryFromCondition '
                  "AND +entity_kind = 'card'",
                )
                .get())
            .map((QueryRow r) => r.read<String>('detail'))
            .join(' / ');
    expect(
      plan,
      contains('COVERING INDEX idx_srs_field_edits_history_from'),
      reason: plan,
    );
    // 部分索引的条件与 fushi_srs 的前缀一致（fushi_core 不依赖 fushi_srs，另写了一次）。
    const String prefix = SrsFieldKeys.cardHistoryFromPrefix;
    expect(
      kSrsHistoryFromCondition,
      "substr(field_key, 1, ${prefix.length}) = '$prefix'",
    );
    // 单次改卡 / 评分：语句数是常数。
    final String card = (await f.store.allCardRows()).first.id;
    f.counter.reset();
    await f.store.setFlag(card, 2);
    await f.store.answer(card, 3);
    expect(f.counter.total, lessThan(40), reason: f.counter.summary());
  });

  test('同步：应用对端事件 / 取发件箱 / 重新入队：语句数不随事件数增长', () async {
    Future<int> applyAt(int notes) async {
      final BulkFixture src = await BulkFixture.open(notes: notes);
      final List<SrsEvent> events = await src.store.exportAll();
      final BulkFixture dst = await BulkFixture.open(
        notes: 0,
        deviceId: 'other',
      );
      dst.counter.reset();
      await dst.store.applyRemote(events, serverTimeMs: 1);
      return dst.counter.total;
    }

    expectFlat('applyRemote', (await applyAt(40), await applyAt(160)));
    expectFlat(
      'unpublishedEvents',
      await measure((SrsDbStore s) async => s.unpublishedEvents()),
    );
    expectFlat(
      'requeue',
      await measure((SrsDbStore s) async {
        await s.requeue(<String>[
          for (final SrsEvent e in await s.exportAll()) e.id,
        ]);
      }),
    );
  });
}
