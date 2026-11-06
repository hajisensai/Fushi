/// 复习页「打开牌组到出第一张卡」的真实数据计时（手动跑，不进 CI）。
///
/// 需要一份库的**只读副本**（连 -wal 一起拷；别直接指向在用的库）：
///
/// ```
/// FUSHI_SRS_OPEN_BENCH_DB=<副本>/fushi.db FUSHI_SRS_OPEN_BENCH_DECK=<deckId> \
///   dart test test/srs/srs_review_open_real_data_bench_test.dart
/// ```
///
/// 按复习页首屏的真实调用序列（计数 → 选卡 → 卡片详情 → 渲染 → 音频设置 → 预览，
/// 再加后台预取下一张）逐步计时。
library;

import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:test/test.dart';
import 'support/srs_test_storage.dart';

void main() {
  final String? source = Platform.environment['FUSHI_SRS_OPEN_BENCH_DB'];
  final String? deckId = Platform.environment['FUSHI_SRS_OPEN_BENCH_DECK'];
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test(
    'review page first card timing',
    () async {
      // FUSHI_SRS_OPEN_BENCH_DB 指向一份 srs.db（Rust 独占库）。
      final TestSrs srs = await openTestSrsAt(source!, inline: false);
      final SrsDatabase db = srs.db;
      final String profileUid =
          (await db
                  .customSelect(
                    'SELECT profile_uid FROM srs_cards_cache LIMIT 1',
                  )
                  .getSingle())
              .read<String>('profile_uid');
      final SrsDbStore store = await SrsDbStore.open(
        db: db,
        core: srs.core,
        profileUid: profileUid,
        deviceId: 'bench',
      );
      Future<T> timed<T>(String label, Future<T> Function() body) async {
        final Stopwatch sw = Stopwatch()..start();
        final T r = await body();
        stdout.writeln('${label.padRight(28)} ${sw.elapsedMilliseconds} ms');
        return r;
      }

      for (int round = 0; round < 3; round++) {
        stdout.writeln('--- round $round');
        final Stopwatch total = Stopwatch()..start();
        await timed('deckSummaries (all)', store.deckSummaries);
        final SrsDeckSummary? one = await timed(
          'deckSummary (this deck)',
          () => store.deckSummary(deckId!),
        );
        stdout.writeln(
          'counts new=${one?.newCount} learn=${one?.learnCount} '
          'due=${one?.reviewCount} total=${one?.totalCards}',
        );
        final String? id = await timed(
          'nextCard',
          () => store.nextCard(deckId!),
        );
        if (id == null) {
          stdout.writeln('no card');
          break;
        }
        final SrsCardDetail? detail = await timed(
          'cardDetail',
          () => store.cardDetail(id),
        );
        final SrsRenderedCard? rendered = await timed(
          'renderCard',
          () => store.renderCard(id),
        );
        await timed('deckTree', store.deckTree);
        await timed('dayContext', store.dayContext);
        if (store.canSchedule) await timed('preview', () => store.preview(id));
        stdout.writeln(
          'first card total           ${total.elapsedMilliseconds} ms',
        );
        stdout.writeln(
          'note type ${detail?.noteType.name} '
          'q=${rendered?.question.length} a=${rendered?.answer.length} '
          'css=${rendered?.css.length}',
        );
        await timed(
          'prefetch nextCard',
          () => store.nextCard(deckId!, exclude: <String>{id}),
        );
      }
      await db.close();
    },
    skip: source == null || deckId == null
        ? 'set FUSHI_SRS_OPEN_BENCH_DB / FUSHI_SRS_OPEN_BENCH_DECK'
        : false,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
