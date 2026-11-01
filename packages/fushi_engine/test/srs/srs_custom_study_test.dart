// 自定义学习（反馈 -qGgW6_2hS）：提升今日上限经修改记录写进牌组、只对今天有效、累加；临时会话按条件出卡、
// 照常排程、会话结束不留任何状态。规则在 Rust 排队内核（native/fushi_fsrs/src/store/study.rs），这里测
// Dart 端到端（store → FFI → 内核 → 结果解析）。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String kProfile = '01928c3e-0000-7000-8000-0000000c0501';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  int t = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;

  setUp(() {
    t = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;
  });

  int seq = 0;
  Future<List<String>> addNew(
    SrsDbStore s,
    String deckId,
    int n, {
    List<String> tags = const <String>[],
  }) async {
    final List<String> out = <String>[];
    for (int i = 0; i < n; i++) {
      final String noteId = await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(kProfile, 'Expression'): 'w${seq++}',
        },
        deckId: deckId,
        tags: tags,
      );
      out.add((await s.cardsOfNote(noteId)).single.id);
    }
    return out;
  }

  test('extending today limits adds up, syncs as a register and expires '
      'the next day', () async {
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    final String deck = await s.ensureDeckPath('Custom');
    await s.editField(
      SrsEntityKind.deck,
      deck,
      SrsFieldKeys.deckLimits,
      <String, Object?>{'new': 2, 'review': 200},
    );
    await addNew(s, deck, 10);
    expect((await s.deckSummary(deck))!.newCount, 2);

    expect(await s.extendTodayLimits(deck, newCards: 3), (
      newCards: 3,
      reviews: 0,
    ));
    expect(await s.extendTodayLimits(deck, newCards: 2, reviews: 5), (
      newCards: 5,
      reviews: 5,
    ));
    expect((await s.deckSummary(deck))!.newCount, 7);
    final SrsDeckView view = (await s.deckTree())[deck]!;
    final int today = (await s.dayContext()).dayIndexOf(t);
    expect(view.limitExtension?.on(today), (newCards: 5, reviews: 5));

    // 第二天：追加作废，下一次追加从零开始。
    t += 86400000;
    expect((await s.deckSummary(deck))!.newCount, 2);
    expect(await s.extendTodayLimits(deck, newCards: 1), (
      newCards: 1,
      reviews: 0,
    ));
  });

  test('a filter session picks by state and tag, answers schedule normally, '
      'and the limit counts answered cards', () async {
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    final String deck = await s.ensureDeckPath('Tagged');
    await s.editField(
      SrsEntityKind.deck,
      deck,
      SrsFieldKeys.deckLimits,
      <String, Object?>{'new': 0, 'review': 200},
    );
    final List<String> plain = await addNew(s, deck, 2);
    final List<String> tagged = await addNew(
      s,
      deck,
      2,
      tags: <String>['Grammar::N1'],
    );
    // 每日新卡上限 0：正常复习一张不出。
    expect(await s.nextCard(deck), isNull);

    final SrsCustomStudy session = SrsCustomStudy(
      mode: SrsCustomStudyMode.filter,
      sinceMs: t,
      limit: 1,
      states: const <SrsCustomStudyState>{SrsCustomStudyState.newCards},
      tags: const <String>['grammar'],
    );
    t += 1000;
    final SrsStudyState first = (await s.studyState(deck, custom: session))!;
    expect(tagged, contains(first.next));
    expect(plain, isNot(contains(first.next)));
    expect(first.custom?.left, 1);

    final SrsAnswerOutcome out = await s.answerAndStudy(
      first.next!,
      4,
      studyDeckId: deck,
      custom: session,
    );
    // Easy：照常排程进复习队列（不是预览）。
    expect((await s.cardRow(first.next!))!.queue, SrsQueue.review.wire);
    // 上限 1 已用完：会话结束。
    expect(out.study?.next, isNull);
    expect(out.study?.custom?.left, 0);
    // 正常排队不受影响。
    expect(await s.nextCard(deck), isNull);
  });

  test('review ahead serves cards due later, not today', () async {
    final SrsDbStore s = await openTestStore(
      profileUid: kProfile,
      deviceId: 'a',
      now: () => t,
    );
    final String deck = await s.ensureDeckPath('Ahead');
    final List<String> cards = await addNew(s, deck, 1);
    await s.answer(cards.single, 4);
    expect(await s.nextCard(deck), isNull);
    final SrsCardCacheRow row = (await s.cardRow(cards.single))!;
    final int today = (await s.dayContext()).dayIndexOf(t);
    final int ahead = row.dueDay! - today;
    expect(ahead, greaterThan(0));
    // 会话从这之后开始（之前那次作答不算会话里答过的）。
    t += 1000;

    SrsCustomStudy session(int days) =>
        SrsCustomStudy(mode: SrsCustomStudyMode.ahead, sinceMs: t, days: days);
    expect((await s.studyState(deck, custom: session(ahead - 1)))?.next, null);
    expect(
      (await s.studyState(deck, custom: session(ahead)))?.next,
      cards.single,
    );
  });
}
