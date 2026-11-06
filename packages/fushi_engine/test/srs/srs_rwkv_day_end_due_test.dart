// RWKV 牌组的「到期」= 今天结束前回忆率会降到目标保留率以下的卡（用户 2026-11-03 拍板）：排队向 RWKV 要的是
// 今天结束那一刻（下一个翻日时刻前 1 ms）的 R，不是此刻的 R。此刻还在目标线上、今天之内会掉下去的卡算今天到期，
// 计数与出卡同一口径；混合子树的父行把 FSRS 与 RWKV 的到期加在一起。
//
// 今天已答过的卡按此刻的 R 判（PR #2818 审查 major）：它也按今天结束时的 R 判的话，刚答完模型仍预测它撑不到
// 今天结束，同日间隔守卫（默认 5 张 / 30 秒）一过就又合格，同一张卡一天里被反复刷、答一张计数不降。
//
// 走真实路径：真 store + Rust 内核排队，只把 RWKV 打分换成确定性假打分器。
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String _profile = '01928c3e-0000-7000-8000-0000000a2801';

/// 今天结束前回忆率会降到 0.5（低于目标），此刻之前一律 0.99（高于目标）。记下每次要的时刻与卡。
/// 此刻的 R（[currentRetrievability]）在 [dropAtMs] 之前 0.99、之后 0.5：模拟刚答完的卡过一阵才真掉到线下。
final class _DecayingRwkv implements SrsRwkvScheduling {
  _DecayingRwkv(this.dayEndMs, {int? dropAtMs})
    : dropAtMs = dropAtMs ?? dayEndMs;

  final int dayEndMs;
  int dropAtMs;
  final List<int> asked = <int>[];
  final List<Set<String>> askedCards = <Set<String>>[];
  final List<int> askedNow = <int>[];
  final List<Set<String>> askedNowCards = <Set<String>>[];

  @override
  bool get ready => true;

  @override
  Future<List<double>?> instantRetrievability(
    List<SrsRwkvCandidate> cards, {
    required int atMs,
  }) async {
    asked.add(atMs);
    askedCards.add(<String>{for (final SrsRwkvCandidate c in cards) c.id});
    return List<double>.filled(cards.length, atMs >= dayEndMs ? 0.5 : 0.99);
  }

  @override
  Future<List<double>?> currentRetrievability(
    List<SrsRwkvCandidate> cards, {
    required int nowMs,
  }) async {
    askedNow.add(nowMs);
    askedNowCards.add(<String>{for (final SrsRwkvCandidate c in cards) c.id});
    return List<double>.filled(cards.length, nowMs >= dropAtMs ? 0.5 : 0.99);
  }

  @override
  Future<void> onAnswered(String cardId, SrsReviewLog log) async {}

  @override
  Future<void> onCardsPurged(List<String> cardIds) async {}
}

void main() {
  test('RWKV 到期按今天结束时的 R 数：此刻在线上、今天会掉下去的卡算到期且能出；父行 FSRS + RWKV 相加', () async {
    int t = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;
    final SrsDbStore s = await openTestStore(
      profileUid: _profile,
      deviceId: 'day-end',
      now: () => t,
    );
    await s.editField(
      SrsEntityKind.profile,
      _profile,
      SrsFieldKeys.utcOffsetMin,
      0,
    );
    await s.editField(
      SrsEntityKind.profile,
      _profile,
      SrsFieldKeys.dayRolloverHour,
      4,
    );
    final String root = await s.ensureDeckPath('Root');
    final String f = await s.ensureDeckPath('Root::F');
    final String r = await s.ensureDeckPath('Root::R');
    await s.editField(
      SrsEntityKind.deck,
      f,
      SrsFieldKeys.deckParamsMode,
      'own',
    );
    await s.editField(
      SrsEntityKind.deck,
      f,
      SrsFieldKeys.deckAlgorithm,
      <String, Object?>{'alg': 'fsrs7', 'auto': false},
    );
    int seq = 0;
    Future<List<String>> graduated(String deck, int n) async {
      final List<String> out = <String>[];
      for (int i = 0; i < n; i++) {
        t += 1000;
        final String note = await s.createNote(
          noteTypeId: s.lapisNoteTypeId,
          fieldsById: <String, String>{
            srsLapisFieldId(_profile, 'Expression'): 'w${seq++}',
          },
          deckId: deck,
        );
        final String id = (await s.cardsOfNote(note)).single.id;
        await s.answer(id, 4, durationMs: 1000);
        out.add(id);
      }
      return out;
    }

    final List<String> inF = await graduated(f, 2);
    await graduated(r, 3);
    t += const Duration(days: 1).inMilliseconds;
    final SrsDayContext day = await s.dayContext();
    final int today = day.dayIndexOf(t);
    for (final String id in inF) {
      await s.setDueDay(id, today);
    }
    final _DecayingRwkv rwkv = _DecayingRwkv(day.dayStartMs(today + 1) - 1);
    s.rwkv = rwkv;

    final Map<String, SrsDeckSummary> rows = <String, SrsDeckSummary>{
      for (final SrsDeckSummary d in await s.deckSummaries()) d.deck.id: d,
    };
    expect(rwkv.asked, isNotEmpty);
    expect(rwkv.asked.toSet(), <int>{rwkv.dayEndMs}, reason: '排队要的是今天结束那一刻的 R');
    final SrsDeckSummary rRow = rows[r]!;
    expect(rRow.rwkvScheduled, isTrue);
    expect(rRow.reviewCount, 3, reason: '此刻 0.99、今天结束时 0.5：三张都是今天到期');
    expect(rows[f]!.reviewCount, 2);
    expect(rows[f]!.rwkvScheduled, isFalse);
    expect(rows[root]!.reviewCount, 5, reason: '父行 = FSRS 2 + RWKV 3');
    expect(await s.nextCard(r), isNotNull, reason: '计数里的卡点进去就能出（同一口径）');
  });

  test('今天答过的卡按此刻的 R 判：答一张计数减一，同日间隔守卫过了也不立刻重出，真掉到线下才再出', () async {
    int t = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;
    final SrsDbStore s = await openTestStore(
      profileUid: _profile,
      deviceId: 'day-end-answered',
      now: () => t,
    );
    await s.editField(
      SrsEntityKind.profile,
      _profile,
      SrsFieldKeys.utcOffsetMin,
      0,
    );
    await s.editField(
      SrsEntityKind.profile,
      _profile,
      SrsFieldKeys.dayRolloverHour,
      4,
    );
    final String r = await s.ensureDeckPath('Root::R');
    // 这里测「按 R 合格」的计数，不测每天最少复习数：新建牌组默认的最少 40 会把 R 高于目标的卡补进来。
    await s.editField(
      SrsEntityKind.deck,
      (await s.deckTree()).paramsOwner(r).id,
      SrsFieldKeys.deckRwkvQueue,
      const SrsRwkvQueueSettings().toValue(),
    );
    final List<String> cards = <String>[];
    for (int i = 0; i < 7; i++) {
      t += 1000;
      final String note = await s.createNote(
        noteTypeId: s.lapisNoteTypeId,
        fieldsById: <String, String>{
          srsLapisFieldId(_profile, 'Expression'): 'a$i',
        },
        deckId: r,
      );
      final String id = (await s.cardsOfNote(note)).single.id;
      await s.answer(id, 4, durationMs: 1000);
      cards.add(id);
    }
    t += const Duration(days: 1).inMilliseconds;
    final SrsDayContext day = await s.dayContext();
    final int today = day.dayIndexOf(t);
    final _DecayingRwkv rwkv = _DecayingRwkv(day.dayStartMs(today + 1) - 1);
    s.rwkv = rwkv;

    Future<int> due() async => (await s.deckSummary(r))!.reviewCount;

    expect(await due(), 7, reason: '七张今天结束时都掉到线下');
    final String first = (await s.nextCard(r))!;
    final List<int> counts = <int>[];
    final List<String> order = <String>[first];
    t += 1000;
    await s.answer(first, 3, durationMs: 1000);
    counts.add(await due());
    // 再答五张别的卡、过 30 秒以上：同日间隔守卫（默认 5 张 / 30 秒）对 first 放行。
    for (int i = 0; i < 5; i++) {
      final String next = (await s.nextCard(r))!;
      expect(order, isNot(contains(next)), reason: '今天答过的卡不重出');
      order.add(next);
      t += 10000;
      await s.answer(next, 3, durationMs: 1000);
      counts.add(await due());
    }
    expect(counts, <int>[6, 5, 4, 3, 2, 1], reason: '每答一张计数减一（单调减少）');
    t += const Duration(minutes: 1).inMilliseconds;
    expect(await due(), 1, reason: '守卫已过，但 first 此刻的 R 仍在线上：不算回今天到期');
    final String last = cards.firstWhere((String c) => !order.contains(c));
    expect(await s.nextCard(r), last, reason: '出的是还没答过的那张，不是守卫刚放行的 first');
    expect(rwkv.askedNowCards.last, order.toSet(), reason: '今天答过的卡要的是此刻的 R');
    expect(rwkv.askedNow.last, t);
    expect(rwkv.askedCards.last, <String>{last}, reason: '今天结束时的 R 只给今天还没答过的卡');
    expect(rwkv.asked.toSet(), <int>{rwkv.dayEndMs});

    // 此刻的 R 真掉到线下：守卫已过的 first 同日重出、计数加回；其余五张之后答的卡还不够 5 张，守卫照旧挡着。
    rwkv.dropAtMs = t;
    expect(await due(), 2, reason: 'first（守卫已过、此刻掉到线下）+ 没答过的一张');
    expect(
      await s.nextCard(r, exclude: <String>{last}),
      first,
      reason: '同日重出看此刻的 R',
    );
  });
}
