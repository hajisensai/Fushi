// BUG-3548 / BUG-3549：复习库写入 / 计数路径的往返次数守卫。
//
// 库在 app 里开在后台 isolate（createInBackground），每条语句都是一次跨 isolate 往返；
// 慢的根因是「每条事件 / 每张卡各查几次库」与「整表读回 UI isolate 解析」。这里用语句计数
// 钉住结构性的上界（不测墙钟，不受机器快慢影响）：
// - 导入：SELECT 次数与笔记数无关地按批摊薄（修前每条笔记约 13 次）；
// - 新建牌组：语句数不随库里笔记数增长；
// - 同步冲突扫描：只读回有 ≥ 2 条记录的字段键，不整表读回修改记录。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'apkg/srs_apkg_import_bench_test.dart' show benchApkg;
import 'apkg/srs_apkg_import_test.dart' show kFullOptions;
import 'support/srs_query_counter.dart';
import 'support/srs_test_storage.dart';

const String kUid = '01928c3e-0000-7000-8000-00000000c0de';

Future<(SrsDbStore, CountingInterceptor)> openCounted() async {
  final CountingInterceptor counter = CountingInterceptor();
  final Directory tmp = Directory.systemTemp.createTempSync('srs_wp_');
  addTearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄晚释放。
    }
  });
  final TestSrs srs = await openTestSrsAt(
    '${tmp.path}/srs.db',
    interceptor: counter,
  );
  final SrsDbStore store = await SrsDbStore.open(
    db: srs.db,
    core: srs.core,
    profileUid: kUid,
    deviceId: 'dev',
    engine: const FakeFsrsEngine(),
    fallbackRolloverHour: () => 4,
  );
  return (store, counter);
}

Future<SrsImportReport> importBench(SrsDbStore store, int notes) =>
    importAnkiPackage(
      store: store,
      bytes: benchApkg(notes),
      storeMedia: (String name, Uint8List b) async => name,
      options: kFullOptions,
      zstdDecompress: (Uint8List b) => null,
    );

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('导入 300 条笔记（600 张卡、1800 条日志）：SELECT 往返按批摊薄，每条笔记不到 1 次', () async {
    final (SrsDbStore store, CountingInterceptor counter) = await openCounted();
    counter.reset();
    final SrsImportReport r = await importBench(store, 300);
    expect(r.notesAdded, 300);
    expect(r.cardsAdded, 600);
    expect(r.reviewLogsImported, 1800);
    // 修前：每条笔记约 13 次 SELECT（身份记录 / 修改记录 / 服务器时刻 / 日志 / 前身逐卡全表扫）。
    expect(
      counter.count('select'),
      lessThan(300),
      reason: 'statements: ${counter.summary()}',
    );
    // 结果与逐条落库一致：卡片缓存与笔记缓存都齐。
    expect(
      (await store.deckSummaries()).fold<int>(
        0,
        (int s, SrsDeckSummary d) => d.depth == 0 ? s + d.totalCards : s,
      ),
      600,
    );
    expect((await store.listNotes()).length, 300);
  });

  test('导入的批量落库与逐条落库同结果：再导入一次全部判为未变（幂等），不新增事件', () async {
    final (SrsDbStore store, CountingInterceptor _) = await openCounted();
    await importBench(store, 40);
    final List<SrsEvent> before = await store.exportAll();
    final SrsImportReport again = await importBench(store, 40);
    expect(again.notesAdded, 0);
    expect(again.notesSkipped, 40);
    expect((await store.exportAll()).length, before.length);
  });

  test('新建牌组：语句数不随库里的笔记数增长', () async {
    final (SrsDbStore store, CountingInterceptor counter) = await openCounted();
    await importBench(store, 20);
    counter.reset();
    await store.createDeck('B');
    final int small = counter.count('select') + counter.count('insert');
    // 再导入一批（同一组牌组），笔记数 ×15。
    await importBench(store, 300);
    counter.reset();
    final String id = await store.createDeck('C');
    final int large = counter.count('select') + counter.count('insert');
    // 牌组树多了一个 B（每个牌组读一次修改记录 + 服务器时刻）：允许 +3，不允许随笔记数增长。
    expect(large, lessThanOrEqualTo(small + 3), reason: counter.summary());
    // 新牌组立刻在牌组列表数据里。
    expect(
      (await store.deckSummaries()).map((SrsDeckSummary d) => d.deck.id),
      contains(id),
    );
  });

  test('同步冲突扫描：没有冲突时不把修改记录整表读回', () async {
    final (SrsDbStore store, CountingInterceptor counter) = await openCounted();
    await importBench(store, 200);
    counter.reset();
    expect(await store.syncConflicts(), isEmpty);
    // 修前：读回本 profile 全部修改记录（这里约 1000 行：每条笔记 4–5 条）再逐条解析。
    expect(counter.rowsRead, 0, reason: counter.summary());
  });
}
