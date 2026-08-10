// P4 写侧收敛 A1：recordMiningEvent（一次成功制卡的唯一记账入口）定向测试。
//
// 锁四件事：
// 1. 一次调用同事务写两份投影（mining_statistics 全局 + lookup_mining_counters
//    per-book），dateKey 由 DB 层从同一 at 派生——两表 dateKey 结构上不可能漂移；
// 2. 身份键域同 addMineCountPerBook（v76 per-identity）：带 bookKey/title 落身份行
//    （PDF/漫画补身份走的就是这条），无书来源落 '' 汇总桶；
// 3. 新写入下恒等式 `Σ MiningStatistics.count == Σ mineCount`（per sourceType）
//    结构性成立——旧的两处单边写点（只写全局漏 per-book）不再可能；
// 4. 清统计墓碑语义原样保留（经 addMineCountPerBook，重新制卡 = 新活动）。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

Future<FushiDatabase> _openDb() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  test('一次调用同份时刻落全局汇总与 per-book 计数（dateKey 同源派生）', () async {
    final FushiDatabase db = await _openDb();
    final DateTime at = DateTime(2026, 8, 10, 23, 55);

    await db.recordMiningEvent(
      bookKey: 'book_1',
      title: '吾輩は猫である',
      sourceType: FushiDatabase.statSourceBook,
      at: at,
    );

    final MiningStatisticRow global =
        (await db.getMiningStatisticsBySource(FushiDatabase.statSourceBook))
            .single;
    expect(global.dateKey, '2026-08-10');
    expect(global.count, 1);

    final LookupMiningCounterRow perBook =
        (await db.getAllLookupMiningCounters()).single;
    expect(perBook.bookKey, 'book_1');
    expect(perBook.title, '吾輩は猫である');
    expect(perBook.sourceType, FushiDatabase.statSourceBook);
    expect(perBook.dateKey, global.dateKey,
        reason: '两份投影的 dateKey 由同一 at 在 DB 层派生一次，结构上不可能漂移');
    expect(perBook.mineCount, 1);
    expect(perBook.lookupCount, 0);
  });

  test('无书来源（bookKey/title 缺省）落 \'\' 汇总桶，仍两表同写', () async {
    final FushiDatabase db = await _openDb();
    await db.recordMiningEvent(
      sourceType: FushiDatabase.statSourceBook,
      at: DateTime(2026, 8, 10, 12),
    );

    final LookupMiningCounterRow row =
        (await db.getAllLookupMiningCounters()).single;
    expect(row.bookKey, '');
    expect(row.title, '');
    expect(row.mineCount, 1);
    expect(
        (await db.getMiningStatisticsBySource(FushiDatabase.statSourceBook))
            .single
            .count,
        1);
  });

  test('新写入下恒等式成立：Σ MiningStatistics.count == Σ mineCount', () async {
    final FushiDatabase db = await _openDb();
    // 混合场景：EPUB 带身份、PDF 带身份、app 外无身份、视频源、跨日。
    await db.recordMiningEvent(
        bookKey: 'b1',
        title: 'A',
        sourceType: FushiDatabase.statSourceBook,
        at: DateTime(2026, 8, 9, 10));
    await db.recordMiningEvent(
        bookKey: 'b1',
        title: 'A',
        sourceType: FushiDatabase.statSourceBook,
        at: DateTime(2026, 8, 9, 11));
    await db.recordMiningEvent(
        bookKey: 'b2',
        title: 'B',
        sourceType: FushiDatabase.statSourceBook,
        at: DateTime(2026, 8, 10, 9));
    await db.recordMiningEvent(
        sourceType: FushiDatabase.statSourceBook, at: DateTime(2026, 8, 10));
    await db.recordMiningEvent(
        bookKey: 'v1',
        title: 'Ep1',
        sourceType: FushiDatabase.statSourceVideo,
        at: DateTime(2026, 8, 10, 22));

    final List<MiningStatisticRow> globals = await db.getAllMiningStatistics();
    final List<LookupMiningCounterRow> counters =
        await db.getAllLookupMiningCounters();
    for (final String source in <String>[
      FushiDatabase.statSourceBook,
      FushiDatabase.statSourceVideo,
    ]) {
      final int globalSum = globals
          .where((MiningStatisticRow r) => r.sourceType == source)
          .fold(0, (int acc, MiningStatisticRow r) => acc + r.count);
      final int perBookSum = counters
          .where((LookupMiningCounterRow r) => r.sourceType == source)
          .fold(0, (int acc, LookupMiningCounterRow r) => acc + r.mineCount);
      expect(perBookSum, globalSum, reason: '复合入口下每次记账两表各 +1，恒等式（$source）不许漂移');
    }
  });

  test('同 (身份, 日) 重复制卡累加同一行，不裂新行', () async {
    final FushiDatabase db = await _openDb();
    await db.recordMiningEvent(
        bookKey: 'b1',
        title: 'A',
        sourceType: FushiDatabase.statSourceBook,
        at: DateTime(2026, 8, 10, 9));
    await db.recordMiningEvent(
        bookKey: 'b1',
        title: 'A',
        sourceType: FushiDatabase.statSourceBook,
        at: DateTime(2026, 8, 10, 21));

    expect((await db.getAllLookupMiningCounters()).single.mineCount, 2);
    expect((await db.getAllMiningStatistics()).single.count, 2);
  });

  test('清统计墓碑语义保留（重新制卡 = 新活动）', () async {
    final FushiDatabase db = await _openDb();
    await db.insertStatisticsTombstone('A', FushiDatabase.statSourceBook);

    await db.recordMiningEvent(
      bookKey: 'b1',
      title: 'A',
      sourceType: FushiDatabase.statSourceBook,
      at: DateTime(2026, 8, 10),
    );

    expect(
        await db.getStatisticsTombstoneKeys(), isNot(contains(('A', 'book'))),
        reason: '经 addMineCountPerBook 落 per-book 行，清碑语义原样保留');
  });

  test('recordMiningEvent 不产 activity 行（制卡不是 session 事件）', () async {
    final FushiDatabase db = await _openDb();
    await db.recordMiningEvent(
      bookKey: 'b1',
      title: 'A',
      sourceType: FushiDatabase.statSourceBook,
      at: DateTime(2026, 8, 10),
    );
    expect(await db.getRecentActivityEvents(limit: 5), isEmpty);
  });
}
