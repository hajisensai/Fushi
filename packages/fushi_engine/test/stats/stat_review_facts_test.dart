// 统计中心总览读时合并 SRS 复习时长（BUG-3771）：真实库、真实 SrsDbStore 写日志。
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../srs/apkg/apkg_test_support.dart' show FakeFsrsEngine;
import '../srs/support/srs_bulk_fixture.dart' show importBench;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FushiDatabase db;
  late SrsDbStore store;
  late int profileId;
  late int otherProfileId;
  int now = 0;

  Future<int> addProfile(String name) => db
      .into(db.profiles)
      .insert(ProfilesCompanion.insert(name: name, createdAt: 0, updatedAt: 0));

  setUp(() async {
    // 2026-10-14 01:00 UTC。
    now = DateTime.utc(2026, 10, 14, 1).millisecondsSinceEpoch;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    profileId = await addProfile('A');
    otherProfileId = await addProfile('B');
    store = await SrsDbStore.open(
      db: db,
      profileUid: await db.profileUidOf(profileId),
      deviceId: 'dev',
      engine: const FakeFsrsEngine(),
      trustedClock: SrsTrustedClock(
        wallClockMs: () => now,
        monotonicMs: () => now,
        bootId: 'b',
      ),
      fallbackRolloverHour: () => 4,
    );
  });

  tearDown(() async {
    FushiDatabase.statDayResetHour = 0;
    await db.close();
  });

  Iterable<StatFact> reviews(StatFacts f) =>
      f.daily.where((StatFact x) => x.isReview);
  int reviewMs(StatFacts f) =>
      reviews(f).fold(0, (int a, StatFact x) => a + x.ms);

  /// 写入端本地时刻（按日志自己记下的 UTC 偏移）→ 统计日 key。
  Future<String> dateKeyOfLog(String logId, {int resetHour = 0}) async {
    final QueryRow r = await db
        .customSelect(
          'SELECT occurred_at, utc_offset_min FROM srs_stat_reviews '
          'WHERE log_id = ?',
          variables: <Variable<Object>>[Variable<String>(logId)],
        )
        .getSingle();
    final DateTime local = DateTime.fromMillisecondsSinceEpoch(
      r.read<int>('occurred_at') +
          r.read<int>('utc_offset_min') * 60000 -
          resetHour * 3600000,
      isUtc: true,
    );
    return FushiDatabase.statCalendarDayKeyOf(local);
  }

  test('总览含复习时长（原生 + 导入的 Anki revlog），undo 撤掉的不算', () async {
    // 1 条笔记 2 张卡、每卡 3 条 revlog，Anki time = 5000 ms。
    await importBench(store, 1);
    final String card = (await store.allCardRows()).first.id;
    final SrsReviewLog kept = await store.answer(card, 3, durationMs: 4000);
    final SrsReviewLog undone = await store.answer(card, 1, durationMs: 9000);
    expect(await store.undo(card, undone.id), isTrue);

    final StatFacts f = await loadStatFacts(
      db,
      activityLimit: 0,
      profileId: profileId,
      includeReviews: true,
    );
    expect(reviewMs(f), 2 * 3 * 5000 + 4000);
    // 日面 / 小时面各一份（与段同形），不并进同一列表。
    expect(
      f.hourly.where((StatFact x) => x.isReview).fold(0, (a, x) => a + x.ms),
      reviewMs(f),
    );
    final String today = await dateKeyOfLog(kept.id);
    final StatFact todays = reviews(
      f,
    ).singleWhere((StatFact x) => x.dateKey == today);
    expect(todays.ms, 4000);
    expect(todays.mediaKey, kStatReviewMediaKey);
    expect(todays.chars, 0);
    // 复习不进会话流 / 活动流。
    expect(f.sessions, isEmpty);
    expect(f.activityRows, isEmpty);
  });

  test('不要复习（复习模块关）/ 别的 Profile：总览没有「复习」', () async {
    await importBench(store, 1);
    await store.answer(
      (await store.allCardRows()).first.id,
      3,
      durationMs: 4000,
    );
    final StatFacts off = await loadStatFacts(
      db,
      activityLimit: 0,
      profileId: profileId,
    );
    expect(reviews(off), isEmpty);
    final StatFacts other = await loadStatFacts(
      db,
      activityLimit: 0,
      profileId: otherProfileId,
      includeReviews: true,
    );
    expect(reviews(other), isEmpty);
  });

  test('日界用统计域的「今日」重置整点（读时分桶）', () async {
    await importBench(store, 1);
    final SrsReviewLog l = await store.answer(
      (await store.allCardRows()).first.id,
      3,
      durationMs: 4000,
    );
    Future<String> keyWith(int resetHour) async {
      FushiDatabase.statDayResetHour = resetHour;
      final StatFacts f = await loadStatFacts(
        db,
        activityLimit: 0,
        profileId: profileId,
        includeReviews: true,
      );
      return reviews(
        f,
      ).singleWhere((StatFact x) => x.lastActiveMs == l.occurredAt).dateKey;
    }

    expect(await keyWith(0), await dateKeyOfLog(l.id));
    expect(await keyWith(23), await dateKeyOfLog(l.id, resetHour: 23));
    expect(await keyWith(23), isNot(await keyWith(0)));
  });
}
