// FSRS 与 RWKV 牌组混在同一棵子树里时，牌组行的「到期」一格按算法拆开（PR #2801 审查）：
// - FSRS 子牌组的真实到期数照旧给出（[SrsDeckSummary.fsrsDue]），不含 RWKV 此刻合格的卡；
// - 父行沿牌组树汇总；纯 FSRS 子树不标 RWKV。
//
// 走真实路径：真 store + Rust 内核排队，只把 RWKV 打分换成确定性假打分器。
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String _profile = '01928c3e-0000-7000-8000-0000000a2801';

/// 一律给低回忆率：RWKV 牌组里的复习卡此刻都合格。
final class _LowRecallRwkv implements SrsRwkvScheduling {
  @override
  bool get ready => true;

  @override
  Future<List<double>?> instantRetrievability(
    List<SrsRwkvCandidate> cards, {
    required int nowMs,
  }) async => List<double>.filled(cards.length, 0.1);

  @override
  Future<void> onAnswered(String cardId, SrsReviewLog log) async {}

  @override
  Future<void> onCardsPurged(List<String> cardIds) async {}
}

void main() {
  test('混合子树：父行的 FSRS 到期只数 FSRS 子牌组，不含 RWKV 此刻合格的卡', () async {
    int t = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;
    final SrsDbStore s = await openTestStore(
      profileUid: _profile,
      deviceId: 'split',
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
    final String plain = await s.ensureDeckPath('Plain');
    for (final String d in <String>[f, plain]) {
      await s.editField(
        SrsEntityKind.deck,
        d,
        SrsFieldKeys.deckParamsMode,
        'own',
      );
      await s.editField(
        SrsEntityKind.deck,
        d,
        SrsFieldKeys.deckAlgorithm,
        <String, Object?>{'alg': 'fsrs7', 'auto': false},
      );
    }
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
    final List<String> inR = await graduated(r, 2);
    final List<String> inPlain = await graduated(plain, 1);
    t += const Duration(days: 1).inMilliseconds;
    // RWKV 牌组 16 次复习，FSRS 牌组 5 次复习。
    for (int i = 0; i < 16; i++) {
      t += 60000;
      await s.answer(inR[0], 3, durationMs: 1000);
    }
    for (int i = 0; i < 5; i++) {
      t += 60000;
      await s.answer(inF[0], 3, durationMs: 1000);
    }
    final SrsDayContext day = await s.dayContext();
    for (final String id in <String>[...inF, ...inPlain]) {
      await s.setDueDay(id, day.dayIndexOf(t));
    }
    t += const Duration(hours: 1).inMilliseconds;
    s.rwkv = _LowRecallRwkv();

    final Map<String, SrsDeckSummary> rows = <String, SrsDeckSummary>{
      for (final SrsDeckSummary d in await s.deckSummaries()) d.deck.id: d,
    };
    final SrsDeckSummary rootRow = rows[root]!;
    expect(rootRow.rwkvScheduled, isTrue);
    expect(rootRow.fsrsDue, 2, reason: 'FSRS 子牌组的 2 张到期在父行照旧看得到');
    expect(
      rootRow.reviewCount,
      greaterThanOrEqualTo(2),
      reason: '到期本身照旧含 RWKV 此刻合格的卡（出卡判断用）',
    );

    final SrsDeckSummary fRow = rows[f]!;
    expect(fRow.rwkvScheduled, isFalse);
    expect(fRow.fsrsDue, 2);
    expect(fRow.reviewCount, 2);

    final SrsDeckSummary rRow = rows[r]!;
    expect(rRow.rwkvScheduled, isTrue);
    expect(rRow.fsrsDue, 0);

    final SrsDeckSummary plainRow = rows[plain]!;
    expect(plainRow.rwkvScheduled, isFalse);
    expect(plainRow.fsrsDue, 1);
    expect(plainRow.reviewCount, 1);
  });
}
