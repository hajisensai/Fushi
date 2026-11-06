// 首页复习条「今日」一行的数据源 [SrsDbStore.todayReviewSummary]（反馈 4mY-bG0T96）：
// - 口径与复习统计页「今天」一节（loadSrsStats → todayStats）逐项相同：次数、用时、重来次数；
// - 只算今天（store 的日界）：昨天的复习不进；被撤销的复习不进（有效复习投影）；
// - 远程复习库经线格式还原的结果与主机上直接读到的相同。
import 'dart:convert';

import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsReviewLog;
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:fushi_engine/srs/srs_stats.dart';
import 'package:fushi_engine/srs/srs_stats_loader.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart' show openTestStore;

const String _uid = '01928c3e-0000-7000-8000-00000000d4a1';

void main() {
  test('与统计页今天一节同口径；昨天与撤销的不算', () async {
    // 本地中午（离日界 4 点远），每次取时钟前进 1 秒。
    int clock = DateTime(2026, 11, 3, 12).millisecondsSinceEpoch;
    final SrsDbStore store = await openTestStore(
      profileUid: _uid,
      deviceId: 'dev',
      now: () => clock += 1000,
    );
    final List<String> cards = <String>[];
    for (final String w in <String>['食べる', '飲む', '走る', '読む']) {
      final String note = await store.createNote(
        noteTypeId: store.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(_uid, 'Expression'): w,
          srsLapisFieldId(_uid, 'MainDefinition'): 'm',
        },
      );
      cards.add((await store.cardsOfNote(note)).first.id);
    }
    expect(await store.todayReviewSummary(), SrsTodayReviewSummary.empty);
    expect((await store.todayReviewSummary()).correctRate, isNull);

    // 昨天的一次复习。
    await store.answer(cards[0], 3, durationMs: 9000);
    clock += const Duration(days: 1).inMilliseconds;

    await store.answer(cards[1], 3, durationMs: 1500);
    await store.answer(cards[2], 1, durationMs: 2500);
    final SrsReviewLog undone = await store.answer(
      cards[3],
      4,
      durationMs: 4000,
    );
    expect(await store.undo(cards[3], undone.id), isTrue);

    final SrsTodayReviewSummary s = await store.todayReviewSummary();
    expect(s.count, 2);
    expect(s.durationMs, 4000);
    expect(s.again, 1);
    expect(s.correctRate, 0.5);

    final SrsTodayStats page = (await loadSrsStats(store)).data.todayStats();
    expect(s.count, page.count);
    expect(s.durationMs, page.durationMs);
    expect(s.again, page.ratings[0]);
  });

  test('远程线格式往返不丢字段', () {
    const SrsTodayReviewSummary s = SrsTodayReviewSummary(
      count: 42,
      durationMs: 612000,
      again: 5,
    );
    final Object? json = jsonDecode(jsonEncode(SrsRemoteWire.todayReviews(s)));
    expect(SrsRemoteWire.todayReviewsFrom(json), s);
  });
}
