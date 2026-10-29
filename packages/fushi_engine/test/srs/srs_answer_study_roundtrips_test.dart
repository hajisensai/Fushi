// 复习页「评分 → 下一张」的往返守卫与基准。
//
// 一次作答 = 预览（一次内核命令）+ 写日志 / 刷缓存 / 排队（同一次 `apply` 命令，study.rs）：内核命令数是常数，
// 不随库大小增长；计数、下一张、预取的猜测都出自这一次排队（复习页不再另调 deckSummary / nextCard）。
//
// 基准（手动；默认跳过）：FUSHI_SRS_ANSWER_BENCH=<笔记数>（每条两张卡）dart test test/srs/srs_answer_study_roundtrips_test.dart
// 库开在临时文件上、走后台 isolate 连接（与 app 相同）。大库导入很慢：再设 FUSHI_SRS_ANSWER_BENCH_DB=<文件>，
// 文件不存在时只导入并存到那里（不计时作答），存在时拷一份来量（前后两版量同一份库）。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:fushi_engine/srs/apkg/srs_apkg_import.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';
import 'apkg/srs_apkg_import_bench_test.dart' show benchApkg;
import 'apkg/srs_apkg_import_test.dart' show kFullOptions;
import 'support/srs_query_counter.dart';
import 'support/srs_test_storage.dart';

const String _uid = '01928c3e-0000-7000-8000-0000000a5e01';

Future<(SrsDbStore, CountingInterceptor)> _open({
  bool inline = true,
  String? path,
  String? copyFrom,
}) async {
  final CountingInterceptor counter = CountingInterceptor();
  final Directory tmp = Directory.systemTemp.createTempSync('srs_ans_');
  if (copyFrom != null) File(copyFrom).copySync('${tmp.path}/srs.db');
  addTearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄晚释放。
    }
  });
  final TestSrs srs = await openTestSrsAt(
    path ?? '${tmp.path}/srs.db',
    interceptor: counter,
    inline: inline,
  );
  final SrsDbStore store = await SrsDbStore.open(
    db: srs.db,
    core: srs.core,
    profileUid: _uid,
    deviceId: 'dev',
    engine: const FakeFsrsEngine(),
    fallbackRolloverHour: () => 4,
  );
  return (store, counter);
}

Future<void> _import(SrsDbStore store, int notes) async {
  await importAnkiPackage(
    store: store,
    bytes: benchApkg(notes),
    storeMedia: (String name, Uint8List b) async => name,
    options: kFullOptions,
    zstdDecompress: (Uint8List b) => null,
  );
}

/// 卡最多的顶层牌组。
Future<String> _biggestRoot(SrsDbStore store) async =>
    (await store.deckSummaries())
        .where((SrsDeckSummary d) => d.depth == 0)
        .reduce(
          (SrsDeckSummary a, SrsDeckSummary b) =>
              a.totalCards >= b.totalCards ? a : b,
        )
        .deck
        .id;

/// 一次作答的开销：内核命令数与 Drift 语句数。
typedef _Cost = ({int core, int statements});

/// 连答 [answers] 张（都按「良好」），返回每次作答的最大开销。每次都核对排出的下一张与重新排队一致。
Future<_Cost> _answerLoop(
  SrsDbStore store,
  CountingInterceptor counter,
  String deck,
  int answers,
) async {
  String? next = (await store.studyState(deck))!.next;
  int core = 0;
  int statements = 0;
  for (int i = 0; i < answers && next != null; i++) {
    final int before = store.debugCoreCommands;
    counter.reset();
    final SrsAnswerOutcome out = await store.answerAndStudy(
      next,
      3,
      studyDeckId: deck,
    );
    core = core > store.debugCoreCommands - before
        ? core
        : store.debugCoreCommands - before;
    final int s = counter.count('select') + counter.count('insert');
    statements = statements > s ? statements : s;
    final SrsStudyState plan = out.study!;
    final SrsStudyState fresh = (await store.studyState(deck))!;
    expect(plan.next, fresh.next);
    expect(plan.summary.newCount, fresh.summary.newCount);
    expect(plan.summary.learnCount, fresh.summary.learnCount);
    expect(plan.summary.reviewCount, fresh.summary.reviewCount);
    next = plan.next;
  }
  return (core: core, statements: statements);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('评分 → 下一张：两次内核命令，开销不随库大小增长，排出的下一张与重新排队一致', () async {
    final (SrsDbStore store, CountingInterceptor counter) = await _open();
    await _import(store, 30);
    final String deck = await _biggestRoot(store);
    final _Cost small = await _answerLoop(store, counter, deck, 5);
    await _import(store, 300);
    final _Cost large = await _answerLoop(store, counter, deck, 5);
    // 预览 + apply（写入、刷新、排队一起）。
    expect(small.core, 2, reason: 'small: $small');
    expect(large.core, 2, reason: 'large: $large');
    expect(
      large.statements,
      lessThanOrEqualTo(small.statements),
      reason: 'small=$small large=$large [${counter.summary()}]',
    );
  });

  final String? bench = Platform.environment['FUSHI_SRS_ANSWER_BENCH'];
  test(
    '基准：评分 → 下一张',
    () async {
      final String? cached = Platform.environment['FUSHI_SRS_ANSWER_BENCH_DB'];
      final bool build = cached != null && !File(cached).existsSync();
      final (SrsDbStore store, CountingInterceptor counter) = await _open(
        inline: false,
        path: build ? cached : null,
        copyFrom: build ? null : cached,
      );
      final Stopwatch imp = Stopwatch()..start();
      if (cached == null || build) await _import(store, int.parse(bench!));
      if (build) {
        stdout.writeln('BENCH built $cached in ${imp.elapsedMilliseconds}ms');
        return;
      }
      final String deck = await _biggestRoot(store);
      final SrsStudyState first = (await store.studyState(deck))!;
      stdout.writeln(
        'BENCH import=${imp.elapsedMilliseconds}ms deck=$deck '
        'total=${first.summary.totalCards} new=${first.summary.newCount} '
        'learn=${first.summary.learnCount} review=${first.summary.reviewCount}',
      );
      String? next = first.next;
      final List<int> ms = <int>[];
      int core = 0;
      int statements = 0;
      for (int i = 0; i < 40 && next != null; i++) {
        final int before = store.debugCoreCommands;
        counter.reset();
        final Stopwatch sw = Stopwatch()..start();
        final SrsAnswerOutcome out = await store.answerAndStudy(
          next,
          3,
          studyDeckId: deck,
        );
        ms.add(sw.elapsedMicroseconds);
        core += store.debugCoreCommands - before;
        statements += counter.count('select') + counter.count('insert');
        next = out.study!.next;
      }
      // 前几次含首轮 worker / 语句缓存预热，只看稳定段。
      final List<int> steady = ms.sublist(5)..sort();
      stdout.writeln(
        'BENCH answers=${ms.length} median=${steady[steady.length ~/ 2] / 1000}ms '
        'p90=${steady[(steady.length * 9) ~/ 10] / 1000}ms '
        'first=${ms.first / 1000}ms '
        'core/answer=${core / ms.length} drift/answer=${statements / ms.length}',
      );
    },
    skip: bench == null ? 'set FUSHI_SRS_ANSWER_BENCH=<notes>' : false,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
