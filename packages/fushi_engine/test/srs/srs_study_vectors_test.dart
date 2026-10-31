// 复习排队（牌组计数 + 出卡）的输入→输出回归向量。
//
// 向量由**旧的 Dart 实现**（`_countContext` / `_deckTallies` / `_countTree` / SQL `pick`，2026-10-29 L2 之前）
// 在下面几个确定性场景里生成，存进 fixtures/srs_study_vectors.json；排队搬进 Rust（`study` 命令）之后，新实现
// 必须逐项给出同样的结果：每一步的全部牌组计数（新 / 学习 / 到期 / 总数 / 新卡配额）、从几个牌组出的下一张、
// 排除下一张后的再下一张。场景覆盖多层子树与层层上限（BUG-3502）、复习上限、学习 / 重学到期窗口、暂停、
// 搁置到明天、改到期日、重置、跨日界（翻日时刻 + UTC 偏移）、RWKV-Instant 与 FSRS 牌组混排（假打分器）、
// 「按位置」新卡顺序。
//
// 重新生成（只在有意改变排队语义时）：SRS_STUDY_VECTORS_WRITE=1 跑本文件。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_rwkv_scheduling.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:test/test.dart';

import 'apkg/apkg_test_support.dart';

const String kVecProfile = '01928c3e-0000-7000-8000-0000000000b9';

final String _fixture =
    '${Directory.current.path}/test/srs/fixtures/srs_study_vectors.json'
        .replaceAll('\\', '/');

/// 确定性假打分器：R 只取决于卡的标签与它最后一条日志是否存在（同一输入同一输出）。
final class _FakeRwkv implements SrsRwkvScheduling {
  _FakeRwkv(this.labelOf);

  final Map<String, String> labelOf;

  @override
  bool get ready => true;

  @override
  Future<List<double>?> instantRetrievability(
    List<SrsRwkvCandidate> cards, {
    required int nowMs,
  }) async => <double>[
    for (final SrsRwkvCandidate c in cards)
      (((labelOf[c.id] ?? c.id).hashCode.abs() + (c.lastLogId ?? '').length) %
              97) /
          100.0,
  ];

  @override
  Future<void> onAnswered(String cardId, SrsReviewLog log) async {}

  @override
  Future<void> onCardsPurged(List<String> cardIds) async {}
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final bool write = Platform.environment['SRS_STUDY_VECTORS_WRITE'] == '1';
  final Map<String, Object?> produced = <String, Object?>{};

  tearDownAll(() {
    if (write) {
      File(_fixture).writeAsStringSync(
        '${const JsonEncoder.withIndent(' ').convert(produced)}\n',
      );
    }
  });

  Future<void> scenario(
    String name, {
    required bool rwkv,
    required bool positionOrder,
  }) async {
    int t = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;
    final SrsDbStore s = await openTestStore(
      profileUid: kVecProfile,
      deviceId: 'v',
      now: () => t,
    );
    final Map<String, String> label = <String, String>{};
    String lab(String? id) => id == null ? '-' : (label[id] ?? '?$id');
    await s.editField(
      SrsEntityKind.profile,
      kVecProfile,
      SrsFieldKeys.utcOffsetMin,
      0,
    );
    await s.editField(
      SrsEntityKind.profile,
      kVecProfile,
      SrsFieldKeys.dayRolloverHour,
      4,
    );
    Future<void> limits(String deck, int n, int r) => s.editField(
      SrsEntityKind.deck,
      deck,
      SrsFieldKeys.deckLimits,
      <String, Object?>{'new': n, 'review': r},
    );
    final String root = await s.ensureDeckPath('Root');
    final String a = await s.ensureDeckPath('Root::A');
    final String a1 = await s.ensureDeckPath('Root::A::A1');
    final String a2 = await s.ensureDeckPath('Root::A::A2');
    final String b = await s.ensureDeckPath('Root::B');
    final String b1 = await s.ensureDeckPath('Root::B::B1');
    final String other = await s.ensureDeckPath('Other');
    await limits(root, 6, 9);
    await limits(a, 3, 4);
    await limits(a1, 50, 50);
    await limits(a2, 2, 50);
    await limits(b, 20, 2);
    await limits(b1, 20, 20);
    await limits(other, 4, 5);
    // 向量是加「RWKV 牌组没写过步长 = 不用步长」与「新建牌组忽略每日复习上限」（PR #2663）之前用旧实现
    // 生成的：把那时的生效值明确写上（学习 / 重学步长 1 10 / 10，按每日复习上限截断），向量照旧逐项对拍。
    // 新语义另有测试（srs_rwkv_service_test.dart、native/fushi_fsrs store/study.rs）。
    for (final String d in <String>[
      s.defaultDeckId,
      root,
      a,
      a1,
      a2,
      b,
      b1,
      other,
    ]) {
      await s.editFields(SrsEntityKind.deck, d, <String, Object?>{
        SrsFieldKeys.deckSteps: <String, Object?>{
          'learn': SrsDeckView.defaultLearnSteps,
          'relearn': SrsDeckView.defaultRelearnSteps,
        },
        SrsFieldKeys.deckRwkvQueue: const SrsRwkvQueueSettings().toValue(),
      });
    }
    // 子牌组用 FSRS-7（与 RWKV 混排）；Other 用 RWKV 默认。
    await s.editField(
      SrsEntityKind.deck,
      b,
      SrsFieldKeys.deckParamsMode,
      'own',
    );
    await s.editField(
      SrsEntityKind.deck,
      b,
      SrsFieldKeys.deckAlgorithm,
      <String, Object?>{'alg': 'fsrs7', 'auto': false},
    );
    if (positionOrder) {
      await s.editField(
        SrsEntityKind.deck,
        root,
        SrsFieldKeys.deckNewOrder,
        SrsNewCardOrder.position.wire,
      );
    }
    int seq = 0;
    Future<List<String>> addNew(String deck, int n) async {
      final List<String> out = <String>[];
      for (int i = 0; i < n; i++) {
        t += 1000;
        final String noteId = await s.createNote(
          noteTypeId: s.lapisNoteTypeId,
          fieldsById: <String, String>{
            srsLapisFieldId(kVecProfile, 'Expression'): 'w$seq',
          },
          deckId: deck,
        );
        final String id = (await s.cardsOfNote(noteId)).single.id;
        label[id] = 'c$seq';
        seq++;
        out.add(id);
      }
      return out;
    }

    await addNew(root, 2);
    final List<String> inA1 = await addNew(a1, 5);
    await addNew(a2, 4);
    final List<String> inB = await addNew(b, 3);
    await addNew(b1, 4);
    final List<String> inOther = await addNew(other, 4);
    if (positionOrder) {
      await s.setNewCardPositions(<String, int>{
        inA1[3]: 0,
        inB[2]: 1,
        inA1[0]: 2,
      });
    }
    if (rwkv) s.rwkv = _FakeRwkv(label);

    Future<Map<String, Object?>> snapshot() async {
      final List<SrsDeckSummary> all = await s.deckSummaries();
      Future<List<String>> two(String deck) async {
        final String? n = await s.nextCard(deck);
        final String? after = n == null
            ? null
            : await s.nextCard(deck, exclude: <String>{n});
        return <String>[lab(n), lab(after)];
      }

      final SrsDeckSummary? one = await s.deckSummary(a);
      return <String, Object?>{
        'decks': <Object?>[
          for (final SrsDeckSummary d in all)
            <Object?>[
              d.fullName,
              d.depth,
              d.newCount,
              d.learnCount,
              d.reviewCount,
              d.totalCards,
              d.newBudget.limit,
              d.newBudget.allowed,
              d.newBudget.reviewBudget,
              d.newBudget.reason?.name,
            ],
        ],
        'A': <Object?>[one?.newCount, one?.learnCount, one?.reviewCount],
        'Root': await two(root),
        'A1': await two(a1),
        'B': await two(b),
        'Other': await two(other),
        'instantDue': rwkv
            ? (<String>[
                for (final String id
                    in (await s.instantDueCardIds()) ?? <String>{})
                  lab(id),
              ]..sort())
            : null,
      };
    }

    final List<Object?> steps = <Object?>[];
    const List<int> ratings = <int>[3, 1, 4, 3, 2, 3, 4, 1, 3, 3, 4, 2];
    // 每步之后时钟前进的分钟数：有学习步内、跨学习到期窗口、跨日界（04:00 UTC 翻日）。
    const List<int> advance = <int>[
      1,
      3,
      12,
      30,
      25,
      600,
      2,
      15,
      900,
      45,
      5,
      1500,
    ];
    for (int step = 0; step < 36; step++) {
      final Map<String, Object?> snap = await snapshot();
      String? pickFrom = <String>[root, other, a1, b][step % 4];
      String? id = await s.nextCard(pickFrom);
      id ??= await s.nextCard(root);
      snap['answered'] = lab(id);
      steps.add(snap);
      if (id != null) {
        await s.answer(id, ratings[step % ratings.length], durationMs: 1000);
      }
      switch (step) {
        case 5:
          await s.setSuspended(inA1[1], true);
        case 8:
          // 搁置到明天（今天的排程日序号 + 1）。
          final SrsDayContext day = await s.dayContext();
          await s.buryUntil(inB[0], day.dayIndexOf(t) + 1);
        case 12:
          final SrsDayContext day = await s.dayContext();
          await s.setDueDay(inOther[0], day.dayIndexOf(t));
        case 20:
          await s.setSuspended(inA1[1], false);
          await s.resetCard(inOther[1]);
        case 26:
          await limits(a, 1, 1);
      }
      t += advance[step % advance.length] * 60000;
    }
    produced[name] = steps;
    if (!write) {
      final Map<String, Object?> want =
          (jsonDecode(File(_fixture).readAsStringSync()) as Map)
              .cast<String, Object?>();
      final List<Object?> expected = want[name]! as List<Object?>;
      expect(steps.length, expected.length);
      for (int i = 0; i < steps.length; i++) {
        expect(
          jsonEncode(steps[i]),
          jsonEncode(expected[i]),
          reason: '$name step $i',
        );
      }
    }
  }

  test('FSRS 到期序 + 词频新卡序', () async {
    await scenario('fsrs_frequency', rwkv: false, positionOrder: false);
  });

  test('RWKV-Instant 与 FSRS 牌组混排', () async {
    await scenario('rwkv_mixed', rwkv: true, positionOrder: false);
  });

  test('按位置的新卡序', () async {
    await scenario('fsrs_position', rwkv: false, positionOrder: true);
  });
}
