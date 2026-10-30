// 牌组「新卡计划」（牌组键 newPlan）：每周新卡任务按本周剩余天数摊到每天、周一起算；
// 本周今天之前学过的新卡从任务里扣掉；任务完成当天不再出新卡。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String kPlanProfile = '01928c3e-0000-7000-8000-0000000000c7';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const int dayMs = 86400000;
  // 2026-10-28 是周三：本周（含今天）还剩 5 天。
  int t = DateTime.utc(2026, 10, 28, 12).millisecondsSinceEpoch;

  setUp(() {
    t = DateTime.utc(2026, 10, 28, 12).millisecondsSinceEpoch;
  });

  Future<SrsDbStore> open() =>
      openTestStore(profileUid: kPlanProfile, deviceId: 'a', now: () => t);

  Future<void> addCards(SrsDbStore s, int n) async {
    for (int i = 0; i < n; i++) {
      t += 1000;
      await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kPlanProfile, 'Expression'): 'w$i',
        },
      );
    }
  }

  /// 学完今天能出的新卡，返回学了几张。
  Future<int> learnNew(SrsDbStore s) async {
    int n = 0;
    for (int guard = 0; guard < 100; guard++) {
      final String? id = await s.nextCard(s.defaultDeckId);
      if (id == null) break;
      final bool isNew = (await s.cardRow(id))!.queue == SrsQueue.newCard.wire;
      await s.answer(id, 4);
      if (isNew) n++;
    }
    return n;
  }

  Future<SrsDeckSummary> summary(SrsDbStore s) async =>
      (await s.deckSummaries()).firstWhere(
        (SrsDeckSummary d) => d.deck.id == s.defaultDeckId,
      );

  Future<void> setPlan(SrsDbStore s, SrsNewCardPlan plan) => s.editFields(
    SrsEntityKind.deck,
    s.defaultDeckId,
    <String, Object?>{SrsFieldKeys.deckNewPlan: plan.toValue()},
  );

  test('星期：第 0 天（1970-01-01）是周四；周一起算', () {
    expect(srsWeekdayOfDay(0), 3);
    final int wed = srsDateToDay(2026, 10, 28);
    expect(srsWeekdayOfDay(wed), 2);
    expect(srsWeekStartDay(wed), srsDateToDay(2026, 10, 26));
  });

  test('每周任务摊到本周剩余天数；今天之前学的从任务里扣；完成后当天暂停', () async {
    final SrsDbStore s = await open();
    await addCards(s, 30);
    await setPlan(s, const SrsNewCardPlan(perWeek: 10));
    expect(
      (await s.deckTree())[s.defaultDeckId]!.newCardPlan,
      const SrsNewCardPlan(perWeek: 10),
    );
    // 周三：⌈10 / 5⌉ = 2。
    expect((await summary(s)).newCount, 2);
    expect(await learnNew(s), 2);
    // 周四：剩 8，⌈8 / 4⌉ = 2。
    t += dayMs;
    expect((await summary(s)).newCount, 2);
    expect(await learnNew(s), 2);
    // 周五改成每周 4：本周已学 4，任务完成。
    t += dayMs;
    await setPlan(s, const SrsNewCardPlan(perWeek: 4));
    final SrsDeckSummary done = await summary(s);
    expect(done.newCount, 0);
    expect(done.newBudget.reason, SrsNewCardBudgetReason.weekDone);
    // 下周一重新起算：⌈4 / 7⌉ = 1。
    t += 3 * dayMs;
    expect((await summary(s)).newCount, 1);
  });

  test('不设每周任务时与以前相同：按每日上限', () async {
    final SrsDbStore s = await open();
    await addCards(s, 30);
    final SrsDeckSummary d = await summary(s);
    expect(d.newCount, d.deck.newPerDay.clamp(0, 30));
    expect(d.newBudget.reason, isNull);
  });
}
