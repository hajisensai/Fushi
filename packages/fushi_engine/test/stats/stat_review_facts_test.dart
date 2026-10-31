// 统计中心总览读时合并 SRS 复习时长（BUG-3771）：主库只放 profiles，复习投影在真实 srs.db 里，
// 由真实 SrsDbStore 写日志。
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import '../srs/apkg/apkg_test_support.dart' show FakeFsrsEngine;
import '../srs/support/srs_bulk_fixture.dart' show importBench;
import '../srs/support/srs_test_storage.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FushiDatabase db;
  late SrsStorage srs;
  late SrsDbStore store;
  late int profileId;
  late int otherProfileId;
  int now = 0;

  Future<int> addProfile(String name) => db
      .into(db.profiles)
      .insert(ProfilesCompanion.insert(name: name, createdAt: 0, updatedAt: 0));

  setUp(() async {
    // 2026-10-14 01:00 UTC = JST 10:00。
    now = DateTime.utc(2026, 10, 14, 1).millisecondsSinceEpoch;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    profileId = await addProfile('A');
    otherProfileId = await addProfile('B');
    srs = await openTestSrsStorage();
    store = await SrsDbStore.open(
      db: srs.db,
      core: srs.core,
      profileUid: await db.profileUidOf(profileId),
      deviceId: 'dev',
      engine: const FakeFsrsEngine(),
      trustedClock: SrsTrustedClock(wallClockMs: () => now, bootId: 'b'),
      fallbackRolloverHour: () => 4,
    );
    // 日志的 UTC 偏移取 profile 设置（没有时是本机偏移，随跑测试的机器变）：钉成 JST，期望日期可以写死。
    await store.editField(
      SrsEntityKind.profile,
      store.profileUid,
      SrsFieldKeys.utcOffsetMin,
      540,
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

  /// 统计域自己的日界函数（写入端本地墙钟 → 统计日）：与被测 SQL 的整数除法分桶互为对照。
  String statKeyOfJst(int y, int m, int d, int h) =>
      FushiDatabase.statDateKeyOf(DateTime(y, m, d, h));

  test('总览含复习时长（原生 + 导入的 Anki revlog），undo 撤掉的不算', () async {
    // 1 条笔记 2 张卡、每卡 3 条 revlog，Anki time = 5000 ms。
    await importBench(store, 1);
    final String card = (await store.allCardRows()).first.id;
    final SrsReviewLog kept = await store.answer(card, 3, durationMs: 4000);
    final SrsReviewLog undone = await store.answer(card, 1, durationMs: 9000);
    expect(await store.undo(card, undone.id), isTrue);
    expect(kept.utcOffsetMin, 540);

    final StatFacts f = await loadStatFacts(
      db,
      activityLimit: 0,
      profileId: profileId,
      reviewsFrom: srs.db,
    );
    expect(reviewMs(f), 2 * 3 * 5000 + 4000);
    // 日面 / 小时面各一份（与段同形），不并进同一列表。
    expect(
      f.hourly.where((StatFact x) => x.isReview).fold(0, (a, x) => a + x.ms),
      reviewMs(f),
    );
    // JST 2026-10-14 10:00 的复习：统计日 2026-10-14、本地 10 点。
    expect(statKeyOfJst(2026, 10, 14, 10), '2026-10-14');
    final StatFact todays = reviews(
      f,
    ).singleWhere((StatFact x) => x.dateKey == '2026-10-14');
    expect(todays.ms, 4000);
    expect(todays.lastActiveMs, kept.occurredAt);
    expect(
      f.hourly
          .singleWhere((StatFact x) => x.isReview && x.dateKey == '2026-10-14')
          .hour,
      10,
    );
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
      reviewsFrom: srs.db,
    );
    expect(reviews(other), isEmpty);
    // 对照：同一份 srs.db、本 profile 有复习。
    final StatFacts mine = await loadStatFacts(
      db,
      activityLimit: 0,
      profileId: profileId,
      reviewsFrom: srs.db,
    );
    expect(reviews(mine), isNotEmpty);
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
        reviewsFrom: srs.db,
      );
      return reviews(
        f,
      ).singleWhere((StatFact x) => x.lastActiveMs == l.occurredAt).dateKey;
    }

    // JST 10:00：0 点重置仍是当天；23 点重置时 10:00 落在前一天 23:00 开始的统计日里。
    expect(await keyWith(0), '2026-10-14');
    FushiDatabase.statDayResetHour = 0;
    expect(statKeyOfJst(2026, 10, 14, 10), '2026-10-14');
    expect(await keyWith(23), '2026-10-13');
    expect(statKeyOfJst(2026, 10, 14, 10), '2026-10-13');
    // 跨午夜：JST 10/15 02:00 的复习，0 点重置算 10/15，4 点重置算 10/14。
    now = DateTime.utc(2026, 10, 14, 17).millisecondsSinceEpoch;
    final SrsReviewLog late = await store.answer(
      (await store.allCardRows()).last.id,
      3,
      durationMs: 1000,
    );
    Future<String> lateKey(int resetHour) async {
      FushiDatabase.statDayResetHour = resetHour;
      return reviews(
        await loadStatFacts(
          db,
          activityLimit: 0,
          profileId: profileId,
          reviewsFrom: srs.db,
        ),
      ).singleWhere((StatFact x) => x.lastActiveMs == late.occurredAt).dateKey;
    }

    expect(await lateKey(0), '2026-10-15');
    expect(statKeyOfJst(2026, 10, 15, 2), '2026-10-15');
    expect(await lateKey(4), '2026-10-14');
    expect(statKeyOfJst(2026, 10, 15, 2), '2026-10-14');
  });
}
