// RWKV 牌组的「到期」= 今天结束前回忆率会降到目标保留率以下的卡（用户 2026-11-03 拍板）：排队向 RWKV 要的是
// 今天结束那一刻（下一个翻日时刻前 1 ms）的 R，不是此刻的 R。此刻还在目标线上、今天之内会掉下去的卡算今天到期，
// 计数与出卡同一口径；混合子树的父行把 FSRS 与 RWKV 的到期加在一起。
//
// 走真实路径：真 store + Rust 内核排队，只把 RWKV 打分换成确定性假打分器。
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String _profile = '01928c3e-0000-7000-8000-0000000a2801';

/// 今天结束前回忆率会降到 0.5（低于目标），此刻之前一律 0.99（高于目标）。记下每次要的时刻。
final class _DecayingRwkv implements SrsRwkvScheduling {
  _DecayingRwkv(this.dayEndMs);

  final int dayEndMs;
  final List<int> asked = <int>[];

  @override
  bool get ready => true;

  @override
  Future<List<double>?> instantRetrievability(
    List<SrsRwkvCandidate> cards, {
    required int atMs,
  }) async {
    asked.add(atMs);
    return List<double>.filled(cards.length, atMs >= dayEndMs ? 0.5 : 0.99);
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
}
